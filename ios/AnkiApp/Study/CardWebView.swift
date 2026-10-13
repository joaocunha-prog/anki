// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves files from the collection's media folder to the card web view.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "anki-media"
    private let folder: URL

    init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = folder.appendingPathComponent(name).standardizedFileURL
        // refuse anything outside the media folder
        guard file.path.hasPrefix(folder.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
            ]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}
}

/// Lets the study session talk to the web view (eg to read a typed answer).
@MainActor
final class CardWebViewProxy {
    fileprivate weak var webView: WKWebView?

    /// The text in the type-in-the-answer box, if present.
    func typedAnswer() async -> String {
        guard let webView else { return "" }
        // always returns a string, as the async evaluateJavaScript() variant
        // misbehaves when the script returns null
        let script = "(function(){var e=document.getElementById('typeans');return e&&e.value?String(e.value):'';})()"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String ?? "")
            }
        }
    }
}

struct CardWebView: UIViewRepresentable {
    let html: String
    let mediaFolder: URL
    let proxy: CardWebViewProxy
    /// Called when a replay button is tapped, with the side ("q"/"a") and index.
    let onPlay: (String, Int) -> Void
    /// Called when Return is pressed in the type-in-the-answer box.
    let onSubmitTypedAnswer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(folder: mediaFolder), forURLScheme: MediaSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let submitScript = """
        (function(){var e=document.getElementById('typeans');
        if(e&&e.tagName==='INPUT'){e.addEventListener('keydown',function(ev){
        if(ev.key==='Enter'){ev.preventDefault();window.webkit.messageHandlers.anki.postMessage('ans');}});}})();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: submitScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "anki")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        proxy.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: CardPage.baseURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator _: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "anki")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: CardWebView
        var loadedHTML: String?

        init(parent: CardWebView) {
            self.parent = parent
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else {
                return .allow
            }
            if url.scheme == "anki-play" {
                // anki-play:q:0
                let parts = url.absoluteString.split(separator: ":")
                if parts.count == 3, let index = Int(parts[2]) {
                    parent.onPlay(String(parts[1]), index)
                }
                return .cancel
            }
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme) {
                _ = await UIApplication.shared.open(url)
                return .cancel
            }
            return .allow
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.body as? String == "ans" {
                parent.onSubmitTypedAnswer()
            }
        }
    }
}

/// Avoids the retain cycle between WKUserContentController and its handler.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
