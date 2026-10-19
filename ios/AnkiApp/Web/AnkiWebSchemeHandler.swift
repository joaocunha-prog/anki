// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation
import SwiftProtobuf
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The parts of a page's requests that the desktop implements in Python
/// (post_handlers in qt/aqt/mediasrv.py), and which need the app's UI.
/// Implemented by WebPageView.
@MainActor
protocol AnkiWebHost: AnyObject {
    /// The page wants to be closed (eg deckOptionsRequireClose, or deck
    /// options were saved).
    func webPageRequestsClose()
    /// The deck options page finished loading (deckOptionsReady).
    func webPageDidBecomeReady()
    /// A request changed the collection (the page sent Anki-Op-Changes, or
    /// saved deck options), so other screens may need to reload.
    func webPageDidChangeCollection()
    /// searchInBrowser, or the graphs' "browserSearch:" bridge command.
    func webPageSearchInBrowser(_ search: String)
    /// askUser: a yes/no question.
    func webPageAskUser(text: String, title: String?, defaultNo: Bool) async -> Bool
    /// showMessageBox.
    func webPageShowMessage(text: String, title: String?) async
}

/// Serves Anki's web pages to a WKWebView at anki-web://localhost/, the way
/// qt/aqt/mediasrv.py serves them to the desktop's web views at
/// http://127.0.0.1:<port>/:
///
/// - GET: static files from the app bundle's "web" folder (built by
///   ios/build-web.sh; same layout as the desktop's aqt/data/web):
///   - SvelteKit routes (deck-options/<id>, graphs, card-info/<id>, ...):
///     sveltekit/index.html, which then loads /_app/... from sveltekit/_app/
///   - /_anki/<path>: <path>, with the desktop's legacy remapping of
///     /_anki/<name>.css and /_anki/<name>.js
///   - anything else: a file in the collection's media folder, if one was
///     given, served with the desktop's restrictive CSP
/// - POST /_anki/<method>: the protobuf-encoded request is passed to the Rust
///   backend (BackendMethods.byName), and its output is returned as
///   application/binary; errors are returned as 500 with the error message
///   as text, like the desktop. The few methods the desktop implements in
///   Python are handled here (see `postHandler(for:)`).
///
/// Desktop Python handlers (post_handler_list) and their status here:
/// - replicated: congratsInfo and getDeckConfigsForUpdate (forwarded to the
///   backend), updateDeckConfigs (waits for the save instead of running it
///   in the background, then closes the page unless only parameters were
///   computed), deckOptionsReady, deckOptionsRequireClose, getConfigJson
///   (null for missing keys), get/setProfileConfigJson and get/setMetaJson
///   (UserDefaults), openLink, searchInBrowser (as a search string, via
///   buildSearchString), askUser, showMessageBox.
/// - not yet (404, so the page shows an error): getSchedulingStatesWithContext
///   and setSchedulingStates (reviewer, custom scheduling), changeNotetype,
///   importDone, importDialogRequireClose, and the editor's
///   convertPastedImage, openFilePicker, openMedia, showInMediaFolder,
///   recordAudio, playFile, readClipboard, writeClipboard, closeAddCards,
///   closeEditCurrent, openFieldsDialog, openCardsDialog, saveCustomColours.
///   Add them to `postHandler(for:)` when the page that needs them is used.
/// - also not replicated: /_anki/legacyPageData, /_addons/, and the
///   op-changes refresh, which is reduced to webPageDidChangeCollection().
/// A handler for POST /_anki/<method>, given the request's protobuf bytes.
/// Screens that open a page can add their own (see
/// `WebPageView.extraPostHandlers`), eg for the editor's Python handlers.
typealias WebPostHandler = @MainActor (Data) async throws -> Data

@MainActor
final class AnkiWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "anki-web"
    static let host = "localhost"
    static let origin = "\(scheme)://\(host)"

    /// The URL to open `path` at, eg "deck-options/1", "graphs" or
    /// "_anki/pages/congrats.html". Like the desktop, `night` appends
    /// #night, which the pages check to enable dark mode.
    static func url(for path: String, night: Bool) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(origin)/\(trimmed)\(night ? "#night" : "")")
    }

    private let backend: AnkiBackend
    private let webRoot: URL?
    private let mediaFolder: URL?
    weak var host: AnkiWebHost?
    /// Tasks WebKit has stopped; they must not be answered.
    private var stoppedTasks = Set<ObjectIdentifier>()

    /// - Parameters:
    ///   - webRoot: the folder with the built pages (default: "web" in the
    ///     app bundle).
    ///   - mediaFolder: the collection's media folder, for images in eg deck
    ///     descriptions. nil serves no media.
    init(backend: AnkiBackend, webRoot: URL? = nil, mediaFolder: URL? = nil) {
        self.backend = backend
        self.webRoot = (webRoot ?? Bundle.main.url(forResource: "web", withExtension: nil))?.standardizedFileURL
        self.mediaFolder = mediaFolder?.standardizedFileURL
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        stoppedTasks.remove(ObjectIdentifier(task))
        let request = task.request
        guard let url = request.url, url.host?.lowercased() == Self.host else {
            respond(task, text: "Forbidden", status: 403)
            return
        }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        switch request.httpMethod?.uppercased() {
        case "POST":
            handlePost(task, path: path, request: request)
        case "OPTIONS":
            // In case WebKit treats the custom scheme's origin as opaque and
            // preflights the pages' requests.
            respond(task, data: Data(), mime: "text/plain", status: 204, headers: [
                "Access-Control-Allow-Methods": "GET, POST",
                "Access-Control-Allow-Headers": "Content-Type, Anki-Op-Changes",
            ])
        default:
            handleGet(task, path: path)
        }
    }

    func webView(_: WKWebView, stop task: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(task))
    }

    // GET
    ///////

    private func handleGet(_ task: WKURLSchemeTask, path: String) {
        switch resolve(path) {
        case let .bundled(relative, sveltekitRoute):
            serveBundled(task, relative: relative, sveltekitRoute: sveltekitRoute)
        case let .media(relative):
            serveMedia(task, relative: relative)
        case .notFound:
            respond(task, text: "Invalid path: \(path)", status: 404)
        }
    }

    private enum Resolved {
        /// A path inside the web folder.
        case bundled(String, sveltekitRoute: String?)
        /// A path inside the media folder.
        case media(String)
        case notFound
    }

    /// Mirrors _extract_internal_request() in qt/aqt/mediasrv.py.
    private func resolve(_ original: String) -> Resolved {
        var path = original
        if path == "favicon.ico" {
            return .bundled("imgs/favicon.ico", sveltekitRoute: nil)
        }
        let route = Self.sveltekitRoute(for: path)
        if route != nil {
            path = "_anki/sveltekit/_app/\(path)"
        }
        if path.hasPrefix("_app/") {
            path = "_anki/sveltekit/" + path
        }
        let prefix = "_anki/"
        guard path.hasPrefix(prefix) else {
            return mediaFolder == nil ? .notFound : .media(original)
        }
        var relative = String(path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        if components.count == 1 {
            // remap legacy top-level references
            let name = relative as NSString
            let ext = name.pathExtension.lowercased()
            let base = name.deletingPathExtension
            if ext == "css" {
                relative = "css/\(relative)"
            } else if ext == "js" {
                relative = ["jquery-ui", "jquery", "plot"].contains(base) ? "js/vendor/\(relative)" : "js/\(relative)"
            }
        } else if relative == "js/vendor/jquery.js" {
            relative = "js/vendor/jquery.min.js"
        } else if relative == "js/vendor/jquery-ui.js" {
            relative = "js/vendor/jquery-ui.min.js"
        }
        // the SvelteKit app handles its routes itself, from its index page
        if relative.hasPrefix("sveltekit/"), !relative.contains("immutable") {
            relative = "sveltekit/index.html"
        }
        return .bundled(relative, sveltekitRoute: route)
    }

    /// The routes of the SvelteKit app (get_sveltekit_route() in mediasrv.py).
    static func sveltekitRoute(for path: String) -> String? {
        let page = String(path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return sveltekitRoutes.contains(page) ? page : nil
    }

    static let sveltekitRoutes: Set<String> = [
        "graphs",
        "congrats",
        "card-info",
        "change-notetype",
        "deck-options",
        "import-anki-package",
        "import-csv",
        "import-page",
        "image-occlusion",
        "preferences",
        "editor",
    ]

    /// Routes that show user content (is_untrusted_sveltekit_route()).
    static let untrustedSveltekitRoutes: Set<String> = ["editor", "image-occlusion"]

    private func serveBundled(_ task: WKURLSchemeTask, relative: String, sveltekitRoute: String?) {
        guard let webRoot else {
            respond(task, text: "Web pages are missing from the app bundle (ios/build-web.sh)", status: 500)
            return
        }
        guard let file = Self.safeFile(relative, in: webRoot) else {
            respond(task, text: "Invalid path: \(relative)", status: 403)
            return
        }
        guard var data = try? Data(contentsOf: file) else {
            respond(task, text: "Invalid path: \(relative)", status: 404)
            return
        }
        let mime = Self.mimeType(for: file.lastPathComponent)
        var headers: [String: String] = [:]
        if relative.contains("immutable") {
            headers["Cache-Control"] = "max-age=31536000"
        } else if mime == "application/javascript" {
            headers["Cache-Control"] = "no-cache"
        }
        if let sveltekitRoute {
            let isIndex = relative.hasSuffix("index.html")
            if Self.untrustedSveltekitRoutes.contains(sveltekitRoute) {
                let hash = isIndex ? Self.sveltekitScriptHash(in: data) : nil
                headers["Content-Security-Policy"] = Self.untrustedSveltekitCSP(scriptHash: hash)
            } else if isIndex {
                // replace the default CSP set in the SvelteKit config
                data = Self.strippingCSPMeta(data)
                headers["Content-Security-Policy"] = Self.trustedPageCSP
            }
        } else if mime == "text/html" {
            headers["Content-Security-Policy"] = Self.trustedPageCSP
        }
        respond(task, data: data, mime: mime, status: 200, headers: headers)
    }

    private func serveMedia(_ task: WKURLSchemeTask, relative: String) {
        guard let mediaFolder, let file = Self.safeFile(relative, in: mediaFolder) else {
            respond(task, text: "Invalid path: \(relative)", status: 403)
            return
        }
        guard let data = try? Data(contentsOf: file) else {
            respond(task, text: "Invalid path: \(relative)", status: 404)
            return
        }
        respond(
            task,
            data: data,
            mime: Self.mimeType(for: file.lastPathComponent),
            status: 200,
            headers: ["Content-Security-Policy": Self.untrustedMediaCSP]
        )
    }

    /// `relative` inside `folder`, refusing directory traversal and folders
    /// (ensure_safe_path() in mediasrv.py).
    private static func safeFile(_ relative: String, in folder: URL) -> URL? {
        let file = folder.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(folder.path + "/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nil
        }
        return file
    }

    // Content security policies, as in mediasrv.py
    ////////////////////////////////////////////////

    /// Our pages are always shown top-level.
    static let trustedPageCSP = "frame-ancestors 'none'"

    static let untrustedMediaCSP = [
        "default-src 'none'",
        "script-src 'none'",
        "connect-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self'",
        "font-src 'self'",
        "media-src 'self'",
        "sandbox allow-same-origin",
    ].joined(separator: "; ")

    static func untrustedSveltekitCSP(scriptHash: String?) -> String {
        var sources = ["\(origin)/_anki/", "\(origin)/_app/"]
        if let scriptHash {
            sources.append(scriptHash)
        }
        return [
            "script-src \(sources.joined(separator: " "))",
            "form-action 'none'",
            trustedPageCSP,
        ].joined(separator: "; ")
    }

    // swiftlint:disable:next force_try
    private static let cspMetaRegex = try! NSRegularExpression(
        pattern: "<meta http-equiv=\"content-security-policy\" content=\"script-src 'self' ('sha256-[A-Za-z0-9+/=]+')\">"
    )

    /// The hash SvelteKit computed for its inline render script.
    static func sveltekitScriptHash(in html: Data) -> String? {
        let text = String(decoding: html, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = cspMetaRegex.firstMatch(in: text, range: range),
              let hashRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[hashRange])
    }

    static func strippingCSPMeta(_ html: Data) -> Data {
        let text = String(decoding: html, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        let stripped = cspMetaRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return Data(stripped.utf8)
    }

    /// Hard-coded like _mime_for_path() in mediasrv.py.
    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let known: [String: String] = [
            "css": "text/css",
            "js": "application/javascript",
            "mjs": "application/javascript",
            "html": "text/html",
            "htm": "text/html",
            "svg": "image/svg+xml",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "webp": "image/webp",
            "ico": "image/x-icon",
            "json": "application/json",
            "woff": "font/woff",
            "woff2": "font/woff2",
            "ttf": "font/ttf",
            "otf": "font/otf",
            "mp3": "audio/mpeg",
            "mp4": "video/mp4",
            "webm": "video/webm",
            "ogg": "audio/ogg",
            "pdf": "application/pdf",
            "txt": "text/plain",
            "wasm": "application/wasm",
        ]
        if let mime = known[ext] {
            return mime
        }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    // POST
    ////////

    private func handlePost(_ task: WKURLSchemeTask, path: String, request: URLRequest) {
        let prefix = "_anki/"
        let method = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        guard !method.isEmpty, !method.contains("/") else {
            respond(task, text: "Invalid path: \(path)", status: 404)
            return
        }
        // Like the desktop, refuse requests that were not sent by postProto()
        // (ts/lib/generated/post.ts). The header is allowed to be missing, as
        // only pages in this web view can reach the anki-web scheme.
        if let contentType = request.value(forHTTPHeaderField: "Content-Type"),
           contentType != "application/binary"
        {
            respond(task, text: "Forbidden", status: 403)
            return
        }
        guard let handler = postHandler(for: method) else {
            respond(task, text: "Invalid path: \(path)", status: 404)
            return
        }
        let input = Self.body(of: request)
        let opChanges = Int(request.value(forHTTPHeaderField: "Anki-Op-Changes") ?? "") ?? 0
        Task { @MainActor in
            do {
                let output = try await handler(input)
                if opChanges != 0 {
                    self.host?.webPageDidChangeCollection()
                }
                if output.isEmpty {
                    self.respond(task, text: "", status: 204)
                } else {
                    self.respond(task, data: output, mime: "application/binary", status: 200)
                }
            } catch {
                let message = (error as? BackendError)?.message ?? error.localizedDescription
                self.respond(task, text: message, status: 500)
            }
        }
    }

    private typealias PostHandler = WebPostHandler

    /// Handlers added by the screen showing the page; checked first.
    var extraPostHandlers: [String: WebPostHandler] = [:]

    /// The handler for POST /_anki/<method>: one of the desktop's Python
    /// handlers (post_handler_list in mediasrv.py) that is replicated here,
    /// or a backend method the desktop exposes (exposed_backend_list).
    private func postHandler(for method: String) -> PostHandler? {
        let backend = self.backend
        if let extra = extraPostHandlers[method] {
            return extra
        }
        switch method {
        case "getConfigJson":
            // The desktop returns null for missing keys.
            return { input in
                do {
                    return try await Self.callBackend(backend, "getConfigJson", input)
                } catch let error as BackendError where error.kind == "NOT_FOUND_ERROR" {
                    var json = Anki_Generic_Json()
                    json.json = Data("null".utf8)
                    return try json.serializedBytes()
                }
            }
        case "updateDeckConfigs":
            // The desktop saves in the background, and closes the dialog
            // afterwards unless only the FSRS parameters were computed. Here
            // the page waits for the save, so errors are shown by the page.
            return { [weak self] input in
                let request = try Anki_DeckConfig_UpdateDeckConfigsRequest(serializedBytes: input)
                let output = try await Self.callBackend(backend, "updateDeckConfigs", input)
                self?.host?.webPageDidChangeCollection()
                // UPDATE_DECK_CONFIGS_MODE_COMPUTE_ALL_PARAMS
                if request.mode.rawValue != 2 {
                    self?.host?.webPageRequestsClose()
                }
                return output
            }
        case "deckOptionsReady":
            return { [weak self] _ in
                self?.host?.webPageDidBecomeReady()
                return Data()
            }
        case "deckOptionsRequireClose":
            return { [weak self] _ in
                self?.host?.webPageRequestsClose()
                return Data()
            }
        case "getProfileConfigJson":
            return { input in try Self.getSettingJson(input, store: "webProfileConfig") }
        case "setProfileConfigJson":
            return { input in try Self.setSettingJson(input, store: "webProfileConfig") }
        case "getMetaJson":
            return { input in try Self.getSettingJson(input, store: "webMeta") }
        case "setMetaJson":
            return { input in try Self.setSettingJson(input, store: "webMeta") }
        case "openLink":
            return { input in
                let link = try Anki_Generic_String(serializedBytes: input).val
                if let url = URL(string: link) {
                    _ = await UIApplication.shared.open(url)
                }
                return Data()
            }
        case "searchInBrowser":
            return { [weak self] input in
                let output = try await Self.callBackend(backend, "buildSearchString", input)
                let search = try Anki_Generic_String(serializedBytes: output).val
                self?.host?.webPageSearchInBrowser(search)
                return Data()
            }
        case "askUser":
            return { [weak self] input in
                let request = try Anki_Frontend_AskUserRequest(serializedBytes: input)
                let answer = await self?.host?.webPageAskUser(
                    text: request.text,
                    title: request.hasTitle ? request.title : nil,
                    defaultNo: request.hasDefaultNo && request.defaultNo
                ) ?? false
                var reply = Anki_Generic_Bool()
                reply.val = answer
                return try reply.serializedBytes()
            }
        case "showMessageBox":
            return { [weak self] input in
                let request = try Anki_Frontend_ShowMessageBoxRequest(serializedBytes: input)
                await self?.host?.webPageShowMessage(
                    text: request.text,
                    title: request.hasTitle ? request.title : nil
                )
                var reply = Anki_Generic_Bool()
                reply.val = true
                return try reply.serializedBytes()
            }
        default:
            guard Self.exposedBackendMethods.contains(method) else {
                return nil
            }
            return { input in try await Self.callBackend(backend, method, input) }
        }
    }

    private static func callBackend(_ backend: AnkiBackend, _ method: String, _ input: Data) async throws -> Data {
        guard let index = BackendMethods.byName[method] else {
            throw BackendError(kind: "NOT_FOUND_ERROR", message: "\(method) not found")
        }
        return try await backend.rpc(service: index.service, method: index.method, input: input)
    }

    /// Backend methods the pages may call. As on the desktop
    /// (exposed_backend_list in qt/aqt/mediasrv.py, plus the Python handlers
    /// that only forward to the backend: congratsInfo,
    /// getDeckConfigsForUpdate), other methods are not reachable from web
    /// content. Add new ones here when a page needs them.
    static let exposedBackendMethods: Set<String> = [
        // forwarded by Python handlers on the desktop
        "congratsInfo",
        "getDeckConfigsForUpdate",
        // CollectionService
        "latestProgress",
        "getCustomColours",
        // DeckService
        "getDeckNames",
        "getDeck",
        // I18nService
        "i18nResources",
        // ImportExportService
        "getCsvMetadata",
        "getImportAnkiPackagePresets",
        "importCsv",
        "importAnkiPackage",
        "importJsonFile",
        "importJsonString",
        // NotesService
        "getFieldNames",
        "getNote",
        "newNote",
        "noteFieldsCheck",
        "defaultsForAdding",
        "defaultDeckForNotetype",
        "addNote",
        "updateNotes",
        "updateNotetype",
        // NotetypesService
        "getNotetype",
        "getNotetypeNames",
        "getChangeNotetypeInfo",
        "getClozeFieldOrds",
        // StatsService
        "cardStats",
        "getReviewLogs",
        "graphs",
        "getGraphPreferences",
        "setGraphPreferences",
        // TagsService
        "completeTag",
        // ImageOcclusionService
        "getImageForOcclusion",
        "addImageOcclusionNote",
        "getImageOcclusionNote",
        "updateImageOcclusionNote",
        "getImageOcclusionFields",
        // SchedulerService
        "computeFsrsParams",
        "computeOptimalRetention",
        "setWantsAbort",
        "evaluateParamsLegacy",
        "getOptimalRetentionParameters",
        "simulateFsrsReview",
        "simulateFsrsWorkload",
        // DeckConfigService
        "getIgnoredBeforeCount",
        "getRetentionWorkload",
        // CardRenderingService
        "encodeIriPaths",
        "decodeIriPaths",
        "htmlToTextLine",
        // ConfigService
        "setConfigJson",
        "getConfigBool",
        // MediaService
        "addMediaFile",
        "addMediaFromPath",
        "addMediaFromUrl",
        "getAbsoluteMediaPath",
        "extractMediaFiles",
        // CardsService
        "getCard",
    ]

    /// The desktop keeps these settings in the profile (prefs21.db); here
    /// they are JSON values in UserDefaults, under "<store>.<key>".
    private static func getSettingJson(_ input: Data, store: String) throws -> Data {
        let key = try Anki_Generic_String(serializedBytes: input).val
        var json = Anki_Generic_Json()
        json.json = UserDefaults.standard.data(forKey: "\(store).\(key)") ?? Data("null".utf8)
        return try json.serializedBytes()
    }

    private static func setSettingJson(_ input: Data, store: String) throws -> Data {
        let request = try Anki_Frontend_SetSettingJsonRequest(serializedBytes: input)
        UserDefaults.standard.set(request.valueJson, forKey: "\(store).\(request.key)")
        return Data()
    }

    /// WebKit may pass a POST body either as data or as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    // Responses
    /////////////

    private func respond(_ task: WKURLSchemeTask, text: String, status: Int) {
        respond(task, data: Data(text.utf8), mime: "text/plain", status: status)
    }

    private func respond(
        _ task: WKURLSchemeTask,
        data: Data,
        mime: String,
        status: Int,
        headers extra: [String: String] = [:]
    ) {
        // answering a stopped task raises an exception
        guard stoppedTasks.remove(ObjectIdentifier(task)) == nil, let url = task.request.url else {
            return
        }
        var headers = extra
        headers["Content-Type"] = mime
        // only pages in our web view can reach this scheme
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Content-Length"] = String(data.count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        task.didReceive(response)
        if !data.isEmpty {
            task.didReceive(data)
        }
        task.didFinish()
    }
}
