import SwiftUI
import WebKit

/// The user completes the site's own challenge; its cookies are then shared with URLSession.
@MainActor struct SourceVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PagePlaybackController
    private let url: URL

    init(url: URL) {
        self.url = url
        _controller = StateObject(wrappedValue: PagePlaybackController(media: MediaLink(title: "来源验证", url: url.absoluteString, kind: .web)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在网页中完成来源要求的验证，然后点右上角重试。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(14)
                if controller.loading { ProgressView().padding(8) }
                if let error = controller.error {
                    Text(error).font(.caption).foregroundStyle(.orange).padding(10)
                }
                PageVideoView(controller: controller)
            }
            .background(Theme.backdrop)
            .navigationTitle("来源验证").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("source-verification-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证完成，重试") {
                        Task {
                            let cookies = await controller.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                            for cookie in cookies {
                                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                                if url.host == domain || url.host?.hasSuffix("." + domain) == true {
                                    HTTPCookieStorage.shared.setCookie(cookie)
                                }
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear { controller.load() }
        .onDisappear { controller.stop() }
    }
}
