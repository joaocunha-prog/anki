#!/bin/bash
# Copyright: Ankitects Pty Ltd and contributors
# License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
#
# Builds Anki's Rust core for iOS, and packages it as
# ios/build/AnkiBridge.xcframework. Must be run on macOS with Xcode installed.
#
# Set TARGETS to limit the architectures built, eg for Apple Silicon only:
#   TARGETS="aarch64-apple-ios aarch64-apple-ios-sim" ios/build-rust.sh
#
# Building the core also writes out/ios/generated/BackendServices.swift (from
# rslib/proto/build.rs). Afterwards, if protoc-gen-swift is installed
# (`brew install swift-protobuf`), ios/gen-swift-protos.sh is run to generate
# the Swift message types too; set SKIP_SWIFT_PROTOS=1 to skip that step.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/ios/build"
TARGETS=${TARGETS:-"aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"}
PROFILE=${PROFILE:-release}
export IPHONEOS_DEPLOYMENT_TARGET=16.0

# Translations are needed by the core's build script.
if [ ! -f ftl/core-repo/core/sync.ftl ]; then
    git submodule update --init --depth 1 ftl/core-repo ftl/qt-repo
fi

# protoc is expected at the path configured in .cargo/config.toml.
PROTOC_DIR="$ROOT/out/extracted/protoc"
if [ ! -x "$PROTOC_DIR/bin/protoc" ]; then
    mkdir -p "$PROTOC_DIR"
    curl -sSL -o "$PROTOC_DIR/protoc.zip" \
        https://github.com/protocolbuffers/protobuf/releases/download/v31.1/protoc-31.1-osx-universal_binary.zip
    echo "99ea004549c139f46da5638187a85bbe422d78939be0fa01af1aa8ab672e395f  $PROTOC_DIR/protoc.zip" | shasum -a 256 -c
    (cd "$PROTOC_DIR" && unzip -qo protoc.zip && rm protoc.zip)
fi

# The Swift service wrappers are written by anki_proto's build script, which
# cargo will not rerun on its own if only its output was deleted.
if [ ! -f "$ROOT/out/ios/generated/BackendServices.swift" ]; then
    touch "$ROOT/rslib/proto/build.rs"
fi

device_libs=()
sim_libs=()
for target in $TARGETS; do
    rustup target add "$target"
    cargo build -p anki_ios_bridge --profile "$PROFILE" --target "$target"
    lib="$ROOT/target/$target/$PROFILE/libanki_ios_bridge.a"
    case "$target" in
        *-sim | x86_64-*) sim_libs+=("$lib") ;;
        *) device_libs+=("$lib") ;;
    esac
done

rm -rf "$OUT/AnkiBridge.xcframework"
mkdir -p "$OUT"
args=()
if [ ${#device_libs[@]} -gt 0 ]; then
    args+=(-library "${device_libs[0]}" -headers "$ROOT/ios/bridge/include")
fi
if [ ${#sim_libs[@]} -gt 0 ]; then
    lipo -create "${sim_libs[@]}" -output "$OUT/libanki_ios_bridge-sim.a"
    args+=(-library "$OUT/libanki_ios_bridge-sim.a" -headers "$ROOT/ios/bridge/include")
fi
xcodebuild -create-xcframework "${args[@]}" -output "$OUT/AnkiBridge.xcframework"
echo "Created $OUT/AnkiBridge.xcframework"

if [ "${SKIP_SWIFT_PROTOS:-0}" != 1 ]; then
    if [ ! -f "$ROOT/ios/gen-swift-protos.sh" ]; then
        echo "ios/gen-swift-protos.sh not found; skipping Swift protobuf generation"
    elif command -v protoc-gen-swift >/dev/null || [ -n "${PROTOC_GEN_SWIFT:-}" ]; then
        bash "$ROOT/ios/gen-swift-protos.sh"
    else
        echo "protoc-gen-swift not found (brew install swift-protobuf);" \
            "run ios/gen-swift-protos.sh before building the app"
    fi
fi
