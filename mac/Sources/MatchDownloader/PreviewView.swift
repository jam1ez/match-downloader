import SwiftUI
import WebKit
import MatchCore

struct PreviewItem: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    var target: Double
    var port: Int
    var id: String { url + ":" + String(target) }
    var pageURL: URL {
        var parts = URLComponents(string: "http://127.0.0.1:\(port)/embed/preview")!
        parts.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "target", value: String(target))]
        return parts.url!
    }
    /// The recording on its own site, opened at the match (YouTube `t=`, others `#t=`).
    var recordingURL: URL? {
        guard var url = URLComponents(string: self.url) else { return nil }
        if url.host?.contains("youtu") == true { url.queryItems = (url.queryItems ?? []).filter { $0.name != "t" && $0.name != "start" } + [URLQueryItem(name: "t", value: "\(Int(target))s")] }
        else if url.host?.contains("vimeo") == true {
            // Vimeo takes "#t=30s" on the video's own page; an event page ignores it, so link to the video.
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.first == "event", let i = parts.lastIndex(of: "video"), parts.indices.contains(i + 1), Int(parts[i + 1]) != nil { url.path = "/" + parts[i + 1]; url.query = nil }
            url.fragment = "t=\(Int(target))s"
        }
        else { url.fragment = "t=\(Int(target))" }
        return url.url
    }
}
@MainActor @Observable
final class PreviewBridge {
    var webView: WKWebView?
    var position: Double?
    var message = "Loading recording…"
    var ready = false
    var initialized = false
    /// Set when the recording can’t play here (for example YouTube blocks embedding it).
    var error: String?
    func jump() { webView?.evaluateJavaScript("window.matchPreview?.jump()") }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        webView?.evaluateJavaScript("window.matchPreview?.seek(\(max(0, time)))")
    }
    func currentTime() async throws -> Double {
        guard let webView, let number = try await webView.callAsyncJavaScript("return await window.matchPreview.currentTime()", arguments: [:], in: nil, contentWorld: .page) as? Double, number.isFinite else {
            throw APIError.badResponse("Wait for the recording player to load.")
        }
        return number
    }
}
struct EmbeddedPreview: NSViewRepresentable {
    let item: PreviewItem
    let bridge: PreviewBridge
    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge, port: item.port, external: item.recordingURL) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "preview")
        let view = KeyWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        bridge.webView = view
        view.load(URLRequest(url: item.pageURL))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.url != item.pageURL {
            context.coordinator.url = item.pageURL; bridge.ready = false; bridge.initialized = false
            view.load(URLRequest(url: item.pageURL))
        }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.matchPreview?.destroy()")
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "preview")
        coordinator.bridge.webView = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let bridge: PreviewBridge
        let port: Int
        var url: URL?
        let external: URL?
        init(bridge: PreviewBridge, port: Int, external: URL?) { self.bridge = bridge; self.port = port; self.external = external }
        /// Links the player opens in a new window (such as YouTube’s “Watch on YouTube”) go to the
        /// default browser, at the match time when the link is to the same site.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let requested = navigationAction.request.url, requested.scheme == "https" || requested.scheme == "http" {
                let youtube = requested.host?.contains("youtu") == true
                NSWorkspace.shared.open(youtube ? (external ?? requested) : requested)
            }
            return nil
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1",
                  message.frameInfo.securityOrigin.port == port, let body = message.body as? [String: Any] else { return }
            if let initialized = body["initialized"] as? Bool { bridge.initialized = initialized }
            bridge.ready = body["ready"] as? Bool ?? bridge.ready
            if bridge.ready { bridge.error = nil }
            else if let failure = body["error"] as? String, !failure.isEmpty { bridge.error = failure }
            if let position = body["position"] as? Double, position.isFinite { bridge.position = position }
            let notice = ["error", "warning", "loading"].compactMap { body[$0] as? String }.first { !$0.isEmpty }
            bridge.message = notice ?? bridge.position.map { Format.clock($0) + " in the recording" } ?? "Press Play to start at the match."
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
               !(url.host == "127.0.0.1" && url.port == port && url.path == "/embed/preview") {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { bridge.message = error.localizedDescription }
    }
}
@MainActor @Observable
final class PreviewWindows {
    static let shared = PreviewWindows()
    var open: Set<String> = []
}
struct PreviewWindow: View {
    let item: PreviewItem
    @State private var bridge = PreviewBridge()
    var body: some View {
        // The player fills the whole window (16:9, no bar underneath); controls live in the toolbar.
        EmbeddedPreview(item: item, bridge: bridge)
            .ignoresSafeArea()
            .overlay { if let error = bridge.error { unavailable(error) } }
            .background(WindowAspect(ratio: 16.0 / 9.0))
            .frame(minWidth: 480, minHeight: 270)
            .navigationTitle(item.title)
            .navigationSubtitle(bridge.message)
            .toolbar {
                ToolbarItemGroup {
                    Button("Go to Match Start", systemImage: "backward.end") { bridge.jump() }.disabled(!bridge.ready)
                    Button("Open in Browser", systemImage: "safari") { openInBrowser() }
                }
            }
            .onAppear { PreviewWindows.shared.open.insert(item.id) }
            .onDisappear { PreviewWindows.shared.open.remove(item.id) }
    }
    /// Shown when the recording can't play inside the app: say why and offer the way out.
    private func unavailable(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title)
            Text(Self.reason(error)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Open in Browser at \(Format.clock(item.target))") { openInBrowser() }
                .buttonStyle(.glassProminent).controlSize(.large)
            Text("It opens on the recording’s own site, at the match.").font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: 420).glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
    /// The player's message points at a web-page link that doesn't exist here; keep only the reason.
    private static func reason(_ error: String) -> String {
        let text = error.components(separatedBy: " Use “Open recording").first ?? error
        return text.hasSuffix(".") ? text : text + "."
    }
    private func openInBrowser() { if let url = item.recordingURL { NSWorkspace.shared.open(url) } }
}
