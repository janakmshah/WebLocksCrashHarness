import SwiftUI
import WebKit
import Network

// A throwaway harness that reproduces the iOS 26.5 WebKit renderer crash where a
// frame holding a Web Lock is torn down, causing a malformed
// WebLockRegistryProxy::ClientIsGoingAway IPC that kills the WebContent process
// and blanks the page. Run it on iOS 26.5 to confirm the crash, then on a later
// build (e.g. 26.6) to check whether Apple have fixed it.

@main
struct WebLocksCrashHarnessApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Status

enum HarnessStatus: Equatable {
    case idle, running, crashed, survived
}

// MARK: - Loopback HTTP server
//
// navigator.locks is only exposed in a secure context. Content loaded via
// loadHTMLString runs on an insecure origin where navigator.locks is undefined,
// so we serve the pages over http://localhost, which WebKit treats as a secure
// context. localhost and 127.0.0.1 are different origins, which lets the
// cross-origin mode place the iframe in a separate site.

final class LoopbackServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "weblocks.harness.server")
    private(set) var port: UInt16 = 0
    var onReady: ((UInt16) -> Void)?

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let p = listener.port?.rawValue {
                    self.port = p
                    self.onReady?(p)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            NSLog("LoopbackServer failed to start: \(error)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n").first.map(String.init) ?? ""
            let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = self.responseBody(for: path)
            let headers = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            let response = Data((headers + body).utf8)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func responseBody(for path: String) -> String {
        if path.hasPrefix("/child") {
            return childHTML()
        }
        let mode = path.contains("mode=direct") ? "direct" : "popup"
        return parentHTML(port: port, mode: mode)
    }
}

// MARK: - Page content

private func parentHTML(port: UInt16, mode: String) -> String {
    // The crash reproduces when a cross-site iframe is hosted in a WebContent
    // process that never committed the iframe's origin, so
    // WebLockRegistryProxy's MESSAGE_CHECK(hasCommittedClientOrigin) fails and
    // the renderer is killed. Apple's own regression test creates that state
    // with an about:blank popup (which inherits the opener's origin and process)
    // holding a cross-site iframe. "direct" injects the cross-site iframe
    // straight into the page, which normally does NOT crash (the iframe gets its
    // own process or its origin is committed) and is kept only for comparison.
    let childOrigin = "http://127.0.0.1:\(port)"
    return """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body { font: -apple-system-body; margin: 16px; color: #111; }
      #status { font-size: 20px; font-weight: 700; margin-bottom: 8px; }
      #detail { color: #555; }
    </style></head>
    <body>
      <div id="status">Starting…</div>
      <div id="detail"></div>
      <script>
        const MODE = "\(mode)";
        const CHILD = "\(childOrigin)/child";

        function bridge(type, text) {
          try { window.webkit.messageHandlers.bridge.postMessage({ type: type, text: text }); } catch (e) {}
        }
        function log(t) { bridge("log", t); }
        function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

        async function reproPopup() {
          const popup = window.open("");
          if (!popup) { log("window.open returned null (popup blocked)"); bridge("result", "popup-blocked"); return; }
          window.__popup = popup;
          log("opened about:blank popup (inherits opener origin + process)");
          const frame = popup.document.createElement("iframe");
          frame.id = "subframe";
          frame.onload = () => log("cross-site iframe loaded inside popup");
          frame.src = CHILD;
          popup.document.body.appendChild(frame);
          log("injected cross-site iframe " + CHILD + " into popup; it requests a Web Lock");
          await sleep(1500);
          log("detaching cross-site iframe (calls WebLockRegistryProxy::clientIsGoingAway)");
          try { popup.document.getElementById("subframe").remove(); }
          catch (e) { log("detach threw: " + e); }
          await sleep(1500);
        }

        async function reproDirect() {
          const frame = document.createElement("iframe");
          frame.id = "subframe";
          frame.style.cssText = "width:1px;height:1px;border:0;position:absolute;left:-9999px;top:-9999px;";
          frame.onload = () => log("cross-site iframe loaded in page");
          frame.src = CHILD;
          document.body.appendChild(frame);
          log("injected cross-site iframe " + CHILD + " into page; it requests a Web Lock");
          await sleep(1500);
          log("detaching cross-site iframe (calls WebLockRegistryProxy::clientIsGoingAway)");
          frame.remove();
          await sleep(1500);
        }

        async function run() {
          log("mode=" + MODE + " isSecureContext=" + window.isSecureContext + " typeof navigator.locks=" + (typeof navigator.locks));
          if (typeof navigator.locks === "undefined") {
            document.getElementById("status").textContent = "navigator.locks unavailable (not a secure context)";
            bridge("result", "unavailable");
            return;
          }
          if (MODE === "direct") { await reproDirect(); } else { await reproPopup(); }
          document.getElementById("status").textContent = "SURVIVED — no renderer crash";
          log("survived without a renderer crash");
          bridge("result", "survived");
        }

        run();
      </script>
    </body>
    </html>
    """
}

private func childHTML() -> String {
    return """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head>
    <body>
      <script>
        // Acquiring and holding a lock registers this frame with the Web Lock
        // registry. When the frame's process never committed this origin, the
        // request (or the later teardown) trips WebKit's MESSAGE_CHECK.
        try {
          navigator.locks.request("iframe-lock", () => new Promise(() => {}));
        } catch (e) {}
      </script>
    </body></html>
    """
}


// MARK: - Web controller (delegate + JS bridge)

@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var status: HarnessStatus = .idle
    @Published var logs: [String] = []
    @Published var iteration: String = ""
    @Published var ready = false

    let osVersion = UIDevice.current.systemVersion
    private let server = LoopbackServer()
    private var popups: [WKWebView] = []
    private weak var containerView: UIView?

    @Published var webView: WKWebView = WKWebView(frame: .zero)

    private func makeFreshWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "bridge")
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // A fresh, non-persistent data store guarantees a brand-new WebContent
        // process for every run, so a renderer killed by the previous run can
        // never be silently reused or mask the next run's result.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }

    override init() {
        super.init()
        webView = makeFreshWebView()
        server.onReady = { [weak self] port in
            DispatchQueue.main.async {
                self?.ready = true
                self?.log("Loopback server ready on port \(port)")
            }
        }
        server.start()
    }

    func run(mode: String) {
        guard ready, server.port != 0 else { return }
        status = .running
        logs.removeAll()
        iteration = ""
        popups.forEach { $0.removeFromSuperview() }
        popups.removeAll()

        // Discard the previous WKWebView entirely rather than reloading it.
        // Reloading a view whose WebContent process was just killed can spawn
        // a new process with different timing, masking a real crash as a
        // false "survived" on the very next run.
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        webView = makeFreshWebView()

        log("Running \(mode) repro…")
        let url = URL(string: "http://localhost:\(server.port)/?mode=\(mode)")!
        webView.load(URLRequest(url: url))
    }

    private func log(_ text: String) {
        NSLog("[WebLocksHarness] \(text)")
        logs.append(text)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        let text = dict["text"] as? String ?? ""
        switch type {
        case "log":
            log(text)
        case "iteration":
            iteration = text
        case "result":
            if text == "survived" {
                status = .survived
                log("RESULT: survived — the bug appears fixed on iOS \(osVersion)")
            } else {
                log("RESULT: \(text)")
            }
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Page loaded")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status = .crashed
        log("RENDERER CRASHED: WebContent process terminated — BUG PRESENT on iOS \(osVersion)")
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.isHidden = true
        webView.addSubview(popup)
        popups.append(popup)
        log("Popup WebView created for window.open() (about:blank, shares process)")
        return popup
    }
}

// MARK: - Views

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        embed(webView, in: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // controller.webView is replaced with a brand-new instance on every
        // run(), so swap the embedded subview rather than relying on
        // makeUIView being called again.
        if uiView.subviews.first !== webView {
            uiView.subviews.forEach { $0.removeFromSuperview() }
            embed(webView, in: uiView)
        }
    }

    private func embed(_ webView: WKWebView, in container: UIView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

struct ContentView: View {
    @StateObject private var controller = WebController()
    @State private var mode = "popup"
    @State private var autoRan = false

    private var bannerColor: Color {
        switch controller.status {
        case .idle, .running: return Color(white: 0.9)
        case .crashed: return Color.red.opacity(0.9)
        case .survived: return Color.green.opacity(0.85)
        }
    }

    private var bannerText: String {
        switch controller.status {
        case .idle: return "Idle — tap Run"
        case .running: return "Running \(controller.iteration)"
        case .crashed: return "RENDERER CRASHED — bug present on iOS \(controller.osVersion)"
        case .survived: return "SURVIVED — bug appears fixed on iOS \(controller.osVersion)"
        }
    }

    private var bannerForeground: Color {
        switch controller.status {
        case .crashed, .survived: return .white
        case .idle, .running: return .black
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(bannerText)
                .font(.headline)
                .foregroundStyle(bannerForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(bannerColor)

            HStack {
                Picker("Mode", selection: $mode) {
                    Text("Popup repro").tag("popup")
                    Text("Direct (control)").tag("direct")
                }
                .pickerStyle(.segmented)

                Button("Run") { controller.run(mode: mode) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.ready)
            }
            .padding(8)

            WebViewContainer(webView: controller.webView)
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .border(Color(white: 0.85))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(controller.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: controller.logs.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .onChange(of: controller.ready) { _, isReady in
            if isReady && !autoRan {
                autoRan = true
                controller.run(mode: mode)
            }
        }
    }
}
