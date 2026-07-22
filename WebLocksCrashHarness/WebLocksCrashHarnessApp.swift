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
    case inconclusive(reason: String)
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

    // Buffers received bytes across multiple receive() calls until a full
    // header block (\r\n\r\n) has arrived before parsing the request line. A
    // single unbuffered receive() would risk misreading a request split
    // across TCP reads (e.g. a truncated "/child" request served as "/",
    // silently swapping in the wrong page and invalidating the test).
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(to: buffer[..<headerEnd.lowerBound], on: connection)
                    return
                }
                if isComplete || error != nil || buffer.count > 65_536 {
                    self.respondBadRequest(on: connection)
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    private func respond(to headerData: Data, on connection: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8),
              let requestLine = headerText.split(separator: "\r\n").first,
              let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) else {
            respondBadRequest(on: connection)
            return
        }
        send(body: responseBody(for: path), status: "200 OK", on: connection)
    }

    private func respondBadRequest(on connection: NWConnection) {
        send(body: "Bad Request", status: "400 Bad Request", on: connection)
    }

    private func send(body: String, status: String, on connection: NWConnection) {
        let headers = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        let response = Data((headers + body).utf8)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func responseBody(for path: String) -> String {
        let query = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        let runID = value("runId") ?? ""
        if path.hasPrefix("/child") {
            return childHTML(runID: runID)
        }
        let mode = value("mode") == "direct" ? "direct" : "popup"
        return parentHTML(port: port, mode: mode, runID: runID)
    }
}

// MARK: - Page content

private func parentHTML(port: UInt16, mode: String, runID: String) -> String {
    // The crash reproduces when a cross-site iframe is hosted in a WebContent
    // process that never committed the iframe's origin, so
    // WebLockRegistryProxy's MESSAGE_CHECK(hasCommittedClientOrigin) fails and
    // the renderer is killed. Apple's own regression test creates that state
    // with an about:blank popup (which inherits the opener's origin and process)
    // holding a cross-site iframe. "direct" injects the cross-site iframe
    // straight into the page, which normally does NOT crash (the iframe gets its
    // own process or its origin is committed) and is kept only for comparison.
    //
    // Every bridge message carries runID so the native side can tell a message
    // belonging to this page apart from one left over from a previous run.
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
        const RUN_ID = "\(runID)";
        const CHILD = "\(childOrigin)/child?runId=" + encodeURIComponent(RUN_ID);

        function bridge(type, text) {
          try { window.webkit.messageHandlers.bridge.postMessage({ type: type, text: text, runId: RUN_ID }); } catch (e) {}
        }
        function log(t) { bridge("log", t); }
        function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

        async function reproPopup() {
          const popup = window.open("");
          if (!popup) { log("window.open returned null (popup blocked)"); bridge("popup-blocked", ""); return; }
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
            bridge("unavailable", "");
            return;
          }
          if (MODE === "direct") { await reproDirect(); } else { await reproPopup(); }
          // Reaching this line only means the JS finished its steps without
          // being killed — it is NOT proof the crash precondition (a held
          // lock) was ever really in place. The native side cross-checks
          // this against a "lock-acquired" confirmation from the child frame
          // before treating it as a real "survived" verdict.
          document.getElementById("status").textContent = "SURVIVED — no renderer crash";
          log("finished without a renderer crash");
          bridge("survived", "");
        }

        run();
      </script>
    </body>
    </html>
    """
}

private func childHTML(runID: String) -> String {
    return """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head>
    <body>
      <script>
        // Acquiring and holding a lock registers this frame with the Web Lock
        // registry. When the frame's process never committed this origin, the
        // request (or the later teardown) trips WebKit's MESSAGE_CHECK. This
        // frame reports back once the lock is actually granted, and reports a
        // request failure explicitly, so the parent page's eventual
        // "survived" message can't be trusted as a real verdict unless the
        // crash precondition (a genuinely held lock) was in place.
        function bridge(type, text) {
          try { window.webkit.messageHandlers.bridge.postMessage({ type: type, text: text, runId: "\(runID)" }); } catch (e) {}
        }
        try {
          navigator.locks.request("iframe-lock", () => {
            bridge("lock-acquired", "");
            return new Promise(() => {});
          });
        } catch (e) {
          bridge("lock-acquire-failed", String(e));
        }
      </script>
    </body></html>
    """
}


// MARK: - Web controller (delegate + JS bridge)

@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var status: HarnessStatus = .idle
    @Published var logs: [String] = []
    @Published var ready = false
    @Published var lastMode: String = ""

    let osVersion = UIDevice.current.systemVersion
    private let server = LoopbackServer()
    private var popups: [WKWebView] = []

    // Which run is currently authoritative, and which run created each
    // WKWebView/popup. A bridge message or delegate callback tagged with any
    // other run id is left over from a previous run and must not affect the
    // current verdict.
    private var activeRunID: UUID?
    private var webViewRunIDs: [ObjectIdentifier: UUID] = [:]

    // A run only reaches .lockHeld once the child frame confirms it actually
    // acquired the Web Lock, so "survived" is only a meaningful verdict once
    // the crash precondition was genuinely armed. A renderer termination is
    // only attributed to this bug while a run is armed or lock-held.
    private enum RunPhase { case idle, armed, lockHeld, finished }
    private var phase: RunPhase = .idle

    // WKUserContentController retains its message handler strongly. Using
    // WebController itself as the handler would keep every retired
    // WKUserContentController (and its WKWebView) alive for the app's
    // lifetime; this forwarder holds WebController weakly to avoid that.
    private lazy var bridgeForwarder = BridgeMessageForwarder(target: self)

    @Published var webView: WKWebView = WKWebView(frame: .zero)

    private func makeFreshWebView(runID: UUID) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(bridgeForwarder, name: "bridge")
        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // A non-persistent data store makes WebKit less likely to reuse a
        // process the previous run just had killed, but this is an observed
        // mitigation, not a documented WebKit guarantee — a full app relaunch
        // remains the only fully trustworthy trial boundary; see README.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webViewRunIDs[ObjectIdentifier(view)] = runID
        return view
    }

    override init() {
        super.init()
        let runID = UUID()
        activeRunID = runID
        webView = makeFreshWebView(runID: runID)
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
        let runID = UUID()
        activeRunID = runID
        phase = .armed
        status = .running
        lastMode = mode
        logs.removeAll()

        // Discard the previous WKWebView and any popups entirely rather than
        // reusing them, and explicitly retire their script handlers and
        // delegates rather than relying on deinit timing — a still-alive
        // stale webview could otherwise deliver a delayed bridge message or
        // termination callback that would need to be filtered by run id
        // alone.
        retire(webView)
        webView.removeFromSuperview()
        popups.forEach { retire($0); $0.removeFromSuperview() }
        popups.removeAll()

        webView = makeFreshWebView(runID: runID)

        log("Running \(mode) repro… (run \(runID.uuidString.prefix(8)))")
        let url = URL(string: "http://localhost:\(server.port)/?mode=\(mode)&runId=\(runID.uuidString)")!
        webView.load(URLRequest(url: url))
    }

    private func retire(_ view: WKWebView) {
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        webViewRunIDs.removeValue(forKey: ObjectIdentifier(view))
    }

    private func log(_ text: String) {
        NSLog("[WebLocksHarness] \(text)")
        logs.append(text)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    // Records a terminal verdict for `runID`: ignores anything from a
    // non-active run, and ignores a second terminal signal for a run that has
    // already finished, so whichever verdict arrives first for a run is the
    // one that sticks — nothing can overwrite it afterwards.
    private func finish(_ newStatus: HarnessStatus, runID: UUID) {
        guard runID == activeRunID, phase != .finished else { return }
        status = newStatus
        phase = .finished
    }

    // MARK: Bridge messages

    fileprivate func handleBridgeMessage(_ message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String,
              let runIDString = dict["runId"] as? String else { return }
        let text = dict["text"] as? String ?? ""

        if type == "log" {
            // Informational only; a stale run's log line is still useful
            // context, so log messages aren't filtered by run id.
            log(text)
            return
        }

        guard let runID = UUID(uuidString: runIDString) else { return }
        guard runID == activeRunID else {
            log("Ignoring \(type) from a stale run (\(runIDString.prefix(8)))")
            return
        }

        switch type {
        case "lock-acquired":
            if phase == .armed { phase = .lockHeld }
            log("Child frame confirmed it holds the Web Lock")
        case "lock-acquire-failed":
            log("Child frame failed to request the lock: \(text)")
            finish(.inconclusive(reason: "child frame failed to request the lock"), runID: runID)
        case "popup-blocked":
            finish(.inconclusive(reason: "window.open() was blocked, so the repro never ran"), runID: runID)
        case "unavailable":
            finish(.inconclusive(reason: "navigator.locks was unavailable (not a secure context)"), runID: runID)
        case "survived":
            guard phase == .lockHeld else {
                log("RESULT: \"survived\" was reported, but the lock was never confirmed held — treating as inconclusive")
                finish(.inconclusive(reason: "repro finished without confirming the lock was ever held"), runID: runID)
                return
            }
            if lastMode == "direct" {
                log("RESULT: control survived, as expected — this mode doesn't exercise the crash condition, so it proves nothing about whether the bug is fixed")
            } else {
                log("RESULT: survived — the bug appears fixed on iOS \(osVersion)")
            }
            finish(.survived, runID: runID)
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("Page loaded")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let runID = webViewRunIDs[ObjectIdentifier(webView)] else {
            log("WebContent process terminated for an untracked webview — ignoring")
            return
        }
        guard runID == activeRunID, phase == .armed || phase == .lockHeld else {
            log("Ignoring WebContent termination from a finished/stale run (\(runID.uuidString.prefix(8)))")
            return
        }
        // WKNavigationDelegate has no public API to distinguish this crash
        // from e.g. a memory-pressure kill (that distinction exists only as
        // WebKit-private SPI), so any termination while a run is armed or
        // lock-held is attributed to this bug. That is a known limitation of
        // the public API, not something this harness can fully rule out.
        if lastMode == "direct" {
            log("RENDERER CRASHED in control mode — unexpected, this mode is not supposed to trigger the bug; investigate before trusting a Popup repro result")
        } else {
            log("RENDERER CRASHED: WebContent process terminated — BUG PRESENT on iOS \(osVersion)")
        }
        finish(.crashed, runID: runID)
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
        if let activeRunID {
            webViewRunIDs[ObjectIdentifier(popup)] = activeRunID
        }
        log("Popup WebView created for window.open() (about:blank, shares process)")
        return popup
    }
}

// Forwards WKScriptMessageHandler callbacks to WebController without
// WKUserContentController holding a strong reference to it (see
// bridgeForwarder above for why that reference would otherwise leak).
@MainActor
private final class BridgeMessageForwarder: NSObject, WKScriptMessageHandler {
    private weak var target: WebController?

    init(target: WebController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleBridgeMessage(message)
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

    private enum BannerKind {
        case idle, running, crashPresent, crashUnexpectedControl, survivedFixed, survivedControlOnly
        case inconclusive(String)
    }

    private var bannerKind: BannerKind {
        switch controller.status {
        case .idle: return .idle
        case .running: return .running
        case .crashed: return controller.lastMode == "direct" ? .crashUnexpectedControl : .crashPresent
        case .survived: return controller.lastMode == "direct" ? .survivedControlOnly : .survivedFixed
        case .inconclusive(let reason): return .inconclusive(reason)
        }
    }

    private var bannerColor: Color {
        switch bannerKind {
        case .idle, .running, .survivedControlOnly, .inconclusive: return Color(white: 0.9)
        case .crashPresent: return Color.red.opacity(0.9)
        case .crashUnexpectedControl: return Color.orange.opacity(0.9)
        case .survivedFixed: return Color.green.opacity(0.85)
        }
    }

    private var bannerText: String {
        switch bannerKind {
        case .idle: return "Idle — tap Run"
        case .running: return "Running…"
        case .crashPresent: return "RENDERER CRASHED — bug present on iOS \(controller.osVersion)"
        case .crashUnexpectedControl: return "Control mode crashed unexpectedly — investigate before trusting Popup repro"
        case .survivedFixed: return "SURVIVED — bug appears fixed on iOS \(controller.osVersion)"
        case .survivedControlOnly: return "Control survived (expected) — run Popup repro for the real verdict"
        case .inconclusive(let reason): return "INCONCLUSIVE — \(reason)"
        }
    }

    private var bannerForeground: Color {
        switch bannerKind {
        case .idle, .running, .survivedControlOnly, .inconclusive: return .black
        case .crashPresent, .crashUnexpectedControl, .survivedFixed: return .white
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
