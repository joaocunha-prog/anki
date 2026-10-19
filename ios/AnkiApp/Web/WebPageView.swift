// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI
import UIKit
import WebKit

/// Lets a screen talk to the page shown by a WebPageView.
@MainActor
final class WebPageProxy {
    fileprivate weak var webView: WKWebView?
    /// Set once the deck options page reported it is ready (deckOptionsReady).
    fileprivate(set) var isReady = false
    fileprivate var close: () -> Void = {}

    /// Ask the page to close, as the desktop does when its window is closed:
    /// the deck options page asks before discarding unsaved changes, then
    /// requests the close itself (deckOptionsRequireClose). Other pages are
    /// closed immediately.
    func requestClose() {
        guard let webView, isReady else {
            close()
            return
        }
        let script = """
        (function(){var a=globalThis.anki;
        if(a&&a.deckOptionsPendingChanges){a.deckOptionsPendingChanges();return true;}return false;})()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            if result as? Bool != true {
                self?.close()
            }
        }
    }

    func reload() {
        webView?.reload()
    }
}

/// Shows one of Anki's web pages (ts/routes), served from the app bundle by
/// AnkiWebSchemeHandler, and talking to the Rust backend like the desktop's
/// pages do.
///
/// `path` is what the desktop loads, without its server address:
/// - SvelteKit pages (load_sveltekit_page): "deck-options/<deckId>", "graphs",
///   "card-info/<cardId>", "change-notetype/<notetypeId>", "congrats",
///   "preferences", "image-occlusion/...", "import-csv/<path>", ...
/// - other pages (load_ts_page): "_anki/pages/<name>.html"
///
/// Example:
///
///     WebPageView(backend: model.backend, path: "deck-options/\(deckId)", onClose: { dismiss() })
struct WebPageView: UIViewRepresentable {
    let backend: AnkiBackend
    let path: String
    /// The collection's media folder, for media referenced by the pages
    /// (eg images in a deck description). nil serves no media.
    var mediaFolder: URL?
    var proxy: WebPageProxy?
    /// The page wants to be closed, eg after deck options were saved.
    var onClose: () -> Void = {}
    /// The page changed the collection; other screens may need reloading.
    var onCollectionChanged: () -> Void = {}
    /// The page asked to show a search in the browser.
    var onSearchInBrowser: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let handler = AnkiWebSchemeHandler(backend: backend, mediaFolder: mediaFolder)
        handler.host = coordinator
        coordinator.schemeHandler = handler

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: AnkiWebSchemeHandler.scheme)
        // pages keep nothing between launches
        config.websiteDataStore = .nonPersistent()
        let night = context.environment.colorScheme == .dark
        let controller = config.userContentController
        controller.addUserScript(
            WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        controller.addUserScript(
            WKUserScript(source: Self.stylingScript(night: night), injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        controller.add(WeakScriptMessageHandler(coordinator), name: Self.bridgeName)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.allowsLinkPreview = false
        coordinator.webView = webView
        bindProxy(coordinator: coordinator, webView: webView)

        if let url = AnkiWebSchemeHandler.url(for: path, night: night) {
            coordinator.loadedPath = path
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        bindProxy(coordinator: coordinator, webView: webView)
        if coordinator.loadedPath != path,
           let url = AnkiWebSchemeHandler.url(for: path, night: context.environment.colorScheme == .dark)
        {
            coordinator.loadedPath = path
            coordinator.isReady = false
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: bridgeName)
        webView.stopLoading()
        coordinator.schemeHandler?.host = nil
    }

    @MainActor
    private func bindProxy(coordinator: Coordinator, webView: WKWebView) {
        guard let proxy else { return }
        proxy.webView = webView
        proxy.isReady = coordinator.isReady
        proxy.close = { [weak coordinator] in coordinator?.parent.onClose() }
    }

    static let bridgeName = "ankiBridge"

    /// The desktop's pages can send commands to Python with bridgeCommand()
    /// (eg the graphs' "browserSearch: ..."). Results are not supported.
    static let bridgeScript = """
    window.bridgeCommand = window.pycmd = function (cmd, cb) {
        window.webkit.messageHandlers.\(bridgeName).postMessage(String(cmd));
        return false;
    };
    """

    /// Like add_dynamic_styling_and_props_then_show() in qt/aqt/webview.py:
    /// platform font and body classes, and night mode.
    static func stylingScript(night: Bool) -> String {
        let css = """
        body { background-color: var(--canvas); }
        html { font-family: -apple-system, "Helvetica Neue", sans-serif; }
        button { font-family: -apple-system, "Helvetica Neue", sans-serif; }
        """
        let bodyClasses = ["isMac", "isIOS", "fancy"] + (night ? ["nightMode", "night_mode"] : [])
        let classList = bodyClasses.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function(){
            const style = document.createElement('style');
            style.innerHTML = `\(css)`;
            document.head.appendChild(style);
            document.body.classList.add(\(classList));
            \(night ? "document.documentElement.classList.add(\"night-mode\");" : "")
        })();
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AnkiWebHost {
        var parent: WebPageView
        weak var webView: WKWebView?
        var schemeHandler: AnkiWebSchemeHandler?
        var loadedPath: String?
        var isReady = false {
            didSet { parent.proxy?.isReady = isReady }
        }

        init(parent: WebPageView) {
            self.parent = parent
        }

        // AnkiWebHost

        func webPageRequestsClose() {
            parent.onClose()
        }

        func webPageDidBecomeReady() {
            isReady = true
        }

        func webPageDidChangeCollection() {
            parent.onCollectionChanged()
        }

        func webPageSearchInBrowser(_ search: String) {
            parent.onSearchInBrowser(search)
        }

        func webPageAskUser(text: String, title: String?, defaultNo _: Bool) async -> Bool {
            await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("No", comment: ""), style: .cancel) { _ in
                    continuation.resume(returning: false)
                })
                alert.addAction(UIAlertAction(title: NSLocalizedString("Yes", comment: ""), style: .default) { _ in
                    continuation.resume(returning: true)
                })
                if !present(alert) {
                    continuation.resume(returning: false)
                }
            }
        }

        func webPageShowMessage(text: String, title: String?) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                    continuation.resume()
                })
                if !present(alert) {
                    continuation.resume()
                }
            }
        }

        // WKUIDelegate: the pages use alert() and confirm(), eg to show
        // errors and to confirm discarding changes.

        func webView(
            _: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame _: WKFrameInfo
        ) async {
            await webPageShowMessage(text: message, title: nil)
        }

        func webView(
            _: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame _: WKFrameInfo
        ) async -> Bool {
            await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                    continuation.resume(returning: false)
                })
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                    continuation.resume(returning: true)
                })
                if !present(alert) {
                    continuation.resume(returning: false)
                }
            }
        }

        func webView(
            _: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame _: WKFrameInfo
        ) async -> String? {
            await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = defaultText
                }
                alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                    continuation.resume(returning: nil)
                })
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { [weak alert] _ in
                    continuation.resume(returning: alert?.textFields?.first?.text ?? "")
                })
                if !present(alert) {
                    continuation.resume(returning: nil)
                }
            }
        }

        /// window.open() and target=_blank links open in the browser.
        func webView(
            _: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme) {
                UIApplication.shared.open(url)
            }
            return nil
        }

        // WKNavigationDelegate: the pages stay on anki-web; other links open
        // externally (set_open_links_externally() on the desktop).

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else {
                return .cancel
            }
            if [AnkiWebSchemeHandler.scheme, "about", "blob"].contains(url.scheme) {
                return .allow
            }
            if ["http", "https", "mailto"].contains(url.scheme) {
                _ = await UIApplication.shared.open(url)
            }
            return .cancel
        }

        /// The web content process can be killed by iOS while in the
        /// background; reload instead of showing a blank page.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            webView.reload()
        }

        // WKScriptMessageHandler: bridgeCommand()

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let command = message.body as? String else { return }
            let browserSearch = "browserSearch:"
            if command.hasPrefix(browserSearch) {
                let search = command.dropFirst(browserSearch.count).trimmingCharacters(in: .whitespaces)
                parent.onSearchInBrowser(search)
            }
        }

        /// Presents `controller` over the screen showing the web view.
        /// Returns false if there is nothing to present it from.
        private func present(_ controller: UIViewController) -> Bool {
            guard var top = webView?.window?.rootViewController else {
                return false
            }
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            top.present(controller, animated: true)
            return true
        }
    }
}

/// Avoids the retain cycle between WKUserContentController and its handler.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
