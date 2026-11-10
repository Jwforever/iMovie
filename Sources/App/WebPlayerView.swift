import SwiftUI
import WebKit

@MainActor final class PagePlaybackController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var loading = false
    @Published var error: String?
    @Published var candidates: [MediaLink] = []
    let webView: WKWebView
    private let source: MediaLink

    init(media: MediaLink) {
        source = media
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        if let url = Bundle.main.url(forResource: "media-observer", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "iMovieMedia")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = HTMLSourceAdapter.userAgent
        webView.isOpaque = false
        webView.backgroundColor = .black
    }

    func load() {
        do {
            let url = try HTTPAddress.parse(source.url)
            var request = URLRequest(url: url, timeoutInterval: 35)
            source.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            loading = true
            error = nil
            candidates = []
            webView.load(request)
        } catch { self.error = error.localizedDescription }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "iMovieMedia", let payload = message.body as? [String: Any],
              let value = payload["url"] as? String, let url = HTTPAddress.optional(value),
              let pageValue = payload["page"] as? String, let page = HTTPAddress.optional(pageValue),
              let frame = message.frameInfo.request.url, frame.host == page.host,
              candidates.count < 20, !candidates.contains(where: { $0.url == url.absoluteString }) else { return }
        var headers = ["User-Agent": HTMLSourceAdapter.userAgent]
        let policy = (payload["referrerPolicy"] as? String ?? "").lowercased()
        if policy != "no-referrer" {
            let origin = page.scheme! + "://" + (page.host ?? "") + (page.port.map { ":\($0)" } ?? "") + "/"
            headers["Referer"] = url.host == page.host ? page.absoluteString : origin
        }
        candidates.append(MediaLink(title: source.title, url: url.absoluteString, headers: headers, group: source.group))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false
        self.error = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // 不打开站点广告弹窗；主页面和 iframe 仍按正常浏览器流程加载。
        nil
    }

    func pause() { webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(v=>v.pause())", completionHandler: nil) }
    func stop() { pause(); webView.stopLoading(); webView.loadHTMLString("", baseURL: nil) }
}

@MainActor private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: PagePlaybackController?
    init(_ target: PagePlaybackController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor struct PageVideoView: UIViewRepresentable {
    let controller: PagePlaybackController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor struct WebPlayerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PagePlaybackController
    @State private var nativeRequest: PlaybackRequest?
    let media: MediaLink

    init(media: MediaLink) {
        self.media = media
        _controller = StateObject(wrappedValue: PagePlaybackController(media: media))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controller.loading { ProgressView().padding(8) }
                if let error = controller.error {
                    HStack { Text(error).font(.caption); Button("重试") { controller.load() } }.padding()
                }
                if let candidate = controller.candidates.first {
                    HStack(spacing: 12) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
                        Text("已找到媒体地址").font(.subheadline)
                        Spacer()
                        Button("系统播放") { controller.pause(); nativeRequest = PlaybackRequest(media: candidate) }
                            .buttonStyle(.borderedProminent)
                    }.padding(12).background(Theme.panel)
                }
                PageVideoView(controller: controller)
                Text("可直接使用网页播放器。找到媒体地址后，可切换系统播放；部分来源仅支持网页内播放。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .background(Theme.backdrop)
            .navigationTitle(media.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { controller.load() } label: { Image(systemName: "arrow.clockwise") } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .sheet(item: $nativeRequest) { request in PlayerSheet(media: request.media).environmentObject(store) }
        }
        .onAppear { controller.load(); store.record(media, position: 0) }
        .onDisappear { controller.stop() }
    }
}
