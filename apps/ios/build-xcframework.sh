#!/bin/bash
# Build the shared Rust core (oura-core) for iOS device + simulator and package the
# OuraCore.xcframework the app links. Re-run after changing any Rust core code.
#
# The simulator-only dev harness (OuraApp/build_run.sh) refreshes just the sim slice;
# this produces BOTH slices, which a device build / TestFlight archive needs.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
HEADERS="$REPO/apps/ios/generated/headers"   # UniFFI header + module.modulemap
OUT="$REPO/apps/ios/OuraCore.xcframework"
LIB="liboura_core.a"

# Build the simulator library for the Mac running the tests. Device builds
# always use the ARM iPhone target.
case "$(uname -m)" in
  arm64) SIM_TARGET=aarch64-apple-ios-sim ;;
  x86_64) SIM_TARGET=x86_64-apple-ios ;;
  *) echo "Unsupported Mac architecture" >&2; exit 1 ;;
esac

for t in aarch64-apple-ios "$SIM_TARGET"; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> regenerate matching Swift bindings and headers"
cargo build -p oura-core
cargo run -p oura-core --bin uniffi-bindgen -- generate \
  --library "$REPO/target/debug/liboura_core.dylib" --language swift \
  --out-dir "$REPO/apps/ios/generated"
cp "$REPO/apps/ios/generated/oura_coreFFI.h" "$HEADERS/oura_coreFFI.h"

echo "==> build oura-core (release) for device + simulator"
cargo build -p oura-core --release --target aarch64-apple-ios
cargo build -p oura-core --release --target "$SIM_TARGET"

rm -rf "$OUT"
echo "==> create xcframework"
xcodebuild -create-xcframework \
  -library "$REPO/target/aarch64-apple-ios/release/$LIB"     -headers "$HEADERS" \
  -library "$REPO/target/$SIM_TARGET/release/$LIB" -headers "$HEADERS" \
  -output "$OUT"
echo "✓ $OUT"
