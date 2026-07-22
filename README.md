# WebLocksCrashHarness

A minimal iOS test harness that reproduces a WebKit renderer crash triggered by the
`navigator.locks` Web Locks API, so you can check whether a given iOS/WebKit build
still has the bug.

## Background

Starting in iOS 26.5, WebKit can crash the WebContent (renderer) process when a
cross-site iframe that has requested a Web Lock is hosted inside a WebContent
process that never committed that iframe's origin — for example, a cross-site
iframe placed inside an `about:blank` popup, which shares the opener's process.

When this happens, WebKit's internal message validation
(`WebLockRegistryProxy::requestLock` / `clientIsGoingAway`) rejects the IPC as
invalid and terminates the renderer:

```
Invalid message dispatched void WebKit::WebLockRegistryProxy::requestLock(...)
Received an invalid message 'WebLockRegistryProxy_RequestLock' from the WebContent process
WebPageProxy::processDidTerminate: (pid ...), reason=Crash
```

In a real app, this shows up as a WKWebView going blank: the page loads
successfully, then the renderer is killed underneath it and nothing is left on
screen. We hit this in production inside a 3-D Secure checkout iframe that reads
`navigator.locks` for bot-detection fingerprinting.

This repro is based on WebKit's own regression test,
[`WebLocks.CrossSiteIframeUsingLocksInsideAboutBlankPopup`](https://github.com/WebKit/WebKit/blob/main/Tools/TestWebKitAPI/Tests/WebKit/WKWebView/WebLocks.mm).

## What the app does

1. Runs a tiny loopback HTTP server on `localhost` inside the app, so pages load
   over a **secure context** (`navigator.locks` is `undefined` on the insecure
   origin you get from `loadHTMLString`).
2. The main page (`localhost` origin) opens an `about:blank` popup via
   `window.open()`. The popup shares the opener's WebContent process and never
   commits a new origin of its own.
3. A cross-site iframe (`127.0.0.1` origin) is injected into the popup. The
   iframe calls `navigator.locks.request(...)` to acquire a lock and reports
   back once the lock is actually granted, then is detached.
4. If the bug is present, the WebContent process is killed at this point. The
   app detects this via `WKNavigationDelegate.webViewWebContentProcessDidTerminate`
   and reports **BUG PRESENT**.
5. If the bug is fixed, the sequence completes normally — but the app only
   reports **SURVIVED** if the child frame's lock-acquired confirmation
   actually arrived first; otherwise it reports **INCONCLUSIVE**, since a
   "finished without crashing" signal proves nothing if the crash
   precondition (a genuinely held lock) was never in place.

A second **Direct (control)** mode injects the same cross-site iframe directly
into the page (no popup). WebKit isolates or commits the origin correctly in
that path, so it should survive even on an affected OS version — it exists only
to confirm the crash is specific to the popup-hosting condition, not to iframe
teardown in general.

Every step is logged to the on-screen console and mirrored to the system log
with an `[WebLocksHarness]` prefix, so you can capture full output via Xcode's
console or `xcrun simctl launch --console-pty`.

## Correctness safeguards

An early version of this harness could report a false verdict in a few ways;
these are now guarded against:

- **Every run is tagged with a UUID**, threaded through the page URL and every
  bridge message. A stale message or process-termination callback from a
  previous run's (possibly still-alive) webview or popup is recognised and
  ignored rather than corrupting the current run's result.
- **"Survived" requires proof the crash precondition was real.** The child
  frame explicitly confirms when it has been granted the Web Lock; the parent
  page finishing its steps without that confirmation (e.g. a blocked popup, an
  unavailable `navigator.locks`, or a lock request that silently failed) is
  reported as **INCONCLUSIVE**, not **SURVIVED**.
- **Whichever terminal signal arrives first for a run wins.** A crash and a
  "finished" message can't race to overwrite each other's verdict.
- WKNavigationDelegate has **no public API to distinguish a genuine crash from
  an unrelated WebContent termination** (e.g. memory pressure) — that
  distinction exists only as WebKit-private SPI. Any termination while a run
  is armed or lock-held is attributed to this bug; on a tiny page like this,
  an unrelated kill in that ~3 second window is very unlikely but not
  impossible.

## Usage

1. Open `WebLocksCrashHarness.xcodeproj` in Xcode.
2. Select a simulator or device running the iOS version you want to test.
3. Run the app. It auto-runs the **Popup repro** on launch and shows a banner:
   - 🔴 **RENDERER CRASHED — BUG PRESENT on iOS x.x** — the bug still
     reproduces on this iOS version.
   - 🟢 **SURVIVED — bug appears fixed on iOS x.x** — the sequence completed
     without the renderer being killed, and the lock was confirmed genuinely
     held beforehand.
   - ⚪ **INCONCLUSIVE — ...** — no verdict was reached (e.g. the popup was
     blocked, or the lock was never confirmed held); re-run rather than
     trusting this result either way.
4. To try again, relaunch the app rather than repeatedly tapping **Run** in the
   same session. Every `run()` discards the old `WKWebView`/popups and builds
   fresh ones with a non-persistent data store, which makes WebKit less likely
   to silently reuse a just-killed process — but that's an observed
   mitigation, not a documented WebKit guarantee. A full app relaunch is the
   only trial boundary this harness treats as fully trustworthy.

## Status as tested

- **iOS 26.5 (simulator):** reproduces reliably — renderer crash on every fresh
  launch of the popup repro.
- Not yet confirmed fixed on any later iOS version — use this harness to check.
