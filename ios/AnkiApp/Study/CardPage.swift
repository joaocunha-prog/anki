// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// Builds the HTML document shown in the card web view, similar to the
/// desktop reviewer's page.
enum CardPage {
    /// Media files are served from this origin by `MediaSchemeHandler`, so
    /// that relative <img src="..."> references resolve to the media folder.
    static let baseURL = URL(string: "\(MediaSchemeHandler.scheme)://media/")!

    static func html(body: String, css: String, ord: Int, nightMode: Bool, isAnswer: Bool) -> String {
        let bodyClass = "card card\(ord + 1)" + (nightMode ? " nightMode night_mode" : "")
        let mathJax = needsMathJax(body) ? mathJaxScript : ""
        let scrollToAnswer = isAnswer
            ? "<script>var a=document.getElementById('answer');if(a){a.scrollIntoView();}</script>"
            : ""
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>\(baseCSS)</style>
        <style>\(css)</style>
        \(mathJax)
        </head>
        <body class="\(bodyClass)">
        <div id="qa">\(body)</div>
        \(scrollToAnswer)
        </body>
        </html>
        """
    }

    private static func needsMathJax(_ text: String) -> Bool {
        text.contains("\\(") || text.contains("\\[")
    }

    // Uses the same delimiters as the desktop app. Requires a network
    // connection; offline, the raw TeX is shown instead.
    private static let mathJaxScript = """
    <script>
    window.MathJax = {
      tex: { inlineMath: [["\\\\(", "\\\\)"]], displayMath: [["\\\\[", "\\\\]"]],
             processEscapes: false, processEnvironments: false, processRefs: false },
      svg: { fontCache: "global" },
      startup: { typeset: true }
    };
    </script>
    <script async src="https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-svg-full.js"></script>
    """

    private static let baseCSS = """
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 20px 16px 40px; overflow-wrap: break-word; }
    .card.nightMode { background-color: #1c1c1e; color: #e5e5e7; }
    .nightMode a { color: #77aaff; }
    img { max-width: 100%; height: auto; }
    .nightMode img.drawing { filter: invert(1) hue-rotate(180deg); }
    hr#answer { margin: 20px 0; }
    .replay-button { display: inline-block; text-decoration: none; vertical-align: middle; margin: 0 4px; }
    .replay-button svg { width: 40px; height: 40px; }
    .replay-button svg circle { fill: #fff; stroke: #414141; }
    .replay-button svg path { fill: #414141; }
    .nightMode .replay-button svg circle { fill: #3a3a3c; stroke: #e5e5e7; }
    .nightMode .replay-button svg path { fill: #e5e5e7; }
    #typeans { width: 100%; box-sizing: border-box; font-family: monospace; font-size: 1em; padding: 6px; }
    input#typeans { border: 1px solid #888; border-radius: 6px; }
    .nightMode input#typeans { background: #2c2c2e; color: #e5e5e7; }
    code#typeans { white-space: pre-wrap; }
    .typeGood { background: #afa; color: black; }
    .typeBad { color: black; background: #faa; }
    .typeMissed { color: black; background: #ccc; }
    .cloze { font-weight: bold; color: blue; }
    .nightMode .cloze { color: #77aaff; }
    """
}
