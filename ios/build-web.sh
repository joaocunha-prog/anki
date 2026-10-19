#!/bin/bash
# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
#
# Builds Anki's web pages (ts/routes, ts/ pages, sass, qt/aqt/data/web) and
# copies them to ios/build/web/, which the app bundles as the "web" folder.
#
# Runs on Linux or macOS. The pages are built by the project's own build
# system through the justfile (`just build`, which produces
# out/qt/_aqt/data/web/ as used by the desktop app); node, yarn and the other
# build tools are downloaded by it on the first run.
#
# The layout of ios/build/web/ is the same as the folder the desktop's
# qt/aqt/mediasrv.py serves under /_anki/:
#
#   pages/        legacy/standalone pages, eg /_anki/pages/congrats.html
#   sveltekit/    the SvelteKit app; index.html is the fallback page for every
#                 route (deck-options/<id>, graphs, card-info/<id>, ...), and
#                 _app/ holds its scripts and styles (/_app/...)
#   css/ js/ imgs/   shared assets (/_anki/css/..., /_anki/js/...)
#
# Environment:
#   SKIP_WEB_BUILD=1   only copy; out/qt/_aqt/data/web must already exist
#                      (eg built by an earlier `just build`)
#   WEB_OUT=<dir>      destination (default: ios/build/web)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SRC="$ROOT/out/qt/_aqt/data/web"
DEST=${WEB_OUT:-"$ROOT/ios/build/web"}

if [ "${SKIP_WEB_BUILD:-}" != "1" ]; then
    # Translations are needed to build the pages.
    if [ ! -f ftl/core-repo/core/sync.ftl ]; then
        git submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
    fi
    if ! command -v just > /dev/null; then
        echo "just not found: see https://github.com/casey/just (eg brew install just, cargo install just)" >&2
        exit 1
    fi
    # Builds pylib and qt; the qt target includes out/qt/_aqt/data/web.
    just build
fi

for required in sveltekit/index.html sveltekit/_app pages css js; do
    if [ ! -e "$SRC/$required" ]; then
        echo "$SRC/$required is missing; is the web build complete?" >&2
        exit 1
    fi
done

rm -rf "$DEST"
mkdir -p "$DEST"
# Source maps are only useful when debugging, and roughly double the size.
if command -v rsync > /dev/null; then
    rsync -a --delete --exclude '*.map' "$SRC/" "$DEST/"
else
    cp -R "$SRC/." "$DEST/"
    find "$DEST" -name '*.map' -delete
fi

echo "Copied web pages to $DEST ($(du -sh "$DEST" | cut -f1), $(find "$DEST" -type f | wc -l | tr -d ' ') files)"
