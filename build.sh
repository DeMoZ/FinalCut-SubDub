#!/bin/zsh
# Builds SubDub without an Xcode project.
#   ./build.sh            → build/SubDub.app (with the Final Cut Pro workflow extension inside)
#   ./build.sh install    → build + install into ~/Applications + register the extension (this Mac)
#   ./build.sh pkg        → build/SubDub-<version>.pkg installer for other Macs
#   ./build.sh cli        → build/subdub (command-line test tool)
#
# Optional signing for distribution (otherwise everything is ad-hoc signed):
#   DEV_ID_APP="Developer ID Application: Company (TEAMID)"
#   DEV_ID_INSTALLER="Developer ID Installer: Company (TEAMID)"
#   NOTARY_PROFILE="profile-name"   # created with: xcrun notarytool store-credentials
set -euo pipefail
cd "${0:A:h}"

VERSION="1.2"
BUILD_NUMBER="4"
BUNDLE_ID="com.subdub.app"
EXT_ID="$BUNDLE_ID.extension"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS=(arm64 x86_64)
OUT="build"
APP_NAME="SubDub"
APP="$OUT/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/SubDubExtension.appex"
DEV_ID_APP="${DEV_ID_APP:-}"
DEV_ID_INSTALLER="${DEV_ID_INSTALLER:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# ProExtension.framework is part of Final Cut Pro. It is not bundled: at runtime the
# extension loads it from whichever Final Cut Pro is installed on the Mac.
FCP_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.FinalCutApp' || kMDItemCFBundleIdentifier == 'com.apple.FinalCut'" | head -1)"
FCP_APP="${FCP_APP:-/Applications/Final Cut Pro.app}"
FCP_RPATHS=(
  "/Applications/Final Cut Pro.app/Contents/Frameworks"
  "/Applications/Final Cut Pro Creator Studio.app/Contents/Frameworks"
  "/Applications/Final Cut Pro Trial.app/Contents/Frameworks"
)

CORE=(Sources/Core/*.swift)
UI=(Sources/UI/*.swift(N))

mkdir -p "$OUT"

# swiftc_universal <output> <swiftc args...> — builds every arch and merges with lipo.
swiftc_universal() {
  local output="$1"; shift
  local slices=()
  for arch in "${ARCHS[@]}"; do
    xcrun swiftc -sdk "$SDK" -target "$arch-apple-macos26.0" -swift-version 5 -O -parse-as-library \
      "$@" -o "$output.$arch"
    slices+=("$output.$arch")
  done
  lipo -create "${slices[@]}" -output "$output"
  rm -f "${slices[@]}"
}

sign() { # sign <path> [entitlements]
  local args=(-f)
  if [[ -n "$DEV_ID_APP" ]]; then
    args+=(-s "$DEV_ID_APP" --options runtime --timestamp)
  else
    args+=(-s -)
  fi
  [[ -n "${2:-}" ]] && args+=(--entitlements "$2")
  codesign "${args[@]}" "$1" 2>&1 | grep -v "replacing existing signature" || true
}

build_cli() {
  echo "→ CLI"
  swiftc_universal "$OUT/subdub" "${CORE[@]}" Sources/CLI/main.swift
  sign "$OUT/subdub"
}

build_app() {
  [[ -d "$FCP_APP/Contents/Frameworks/ProExtension.framework" ]] || {
    echo "Final Cut Pro is required to build (ProExtension.framework not found in $FCP_APP)"; exit 1; }
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

  echo "→ Extension"
  local rpath_flags=()
  for p in "${FCP_RPATHS[@]}"; do rpath_flags+=(-Xlinker -rpath -Xlinker "$p"); done
  swiftc_universal "$APPEX/Contents/MacOS/SubDubExtension" -module-name SubDubExtension \
    "${CORE[@]}" "${UI[@]}" Sources/Extension/*.swift \
    -F "$FCP_APP/Contents/Frameworks" -framework ProExtension \
    -Xlinker -e -Xlinker _ProExtensionMain \
    "${rpath_flags[@]}"
  plist_with_version Resources/Extension-Info.plist "$APPEX/Contents/Info.plist"

  echo "→ App"
  swiftc_universal "$APP/Contents/MacOS/$APP_NAME" -module-name SubDub \
    "${CORE[@]}" "${UI[@]}" Sources/App/*.swift
  plist_with_version Resources/App-Info.plist "$APP/Contents/Info.plist"

  echo "→ Signing (${DEV_ID_APP:-ad-hoc})"
  sign "$APPEX" Resources/Extension.entitlements
  sign "$APP" Resources/App.entitlements
  echo "✓ $APP"
}

plist_with_version() {
  cp "$1" "$2"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$2"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$2"
}

install_local() {
  local dest="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  pluginkit -r "$dest/Contents/PlugIns/SubDubExtension.appex" 2>/dev/null || true
  rm -rf "$dest"
  ditto "$APP" "$dest"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
  # Registration right after removing the old version sometimes doesn't stick: retry.
  for _ in 1 2 3 4 5; do
    pluginkit -a "$dest/Contents/PlugIns/SubDubExtension.appex"
    pluginkit -m -i "$EXT_ID" | grep -q "$EXT_ID" && break
    sleep 1
  done
  pluginkit -e use -i "$EXT_ID" 2>/dev/null || true
  echo "✓ Installed: $dest"
  pluginkit -m -v -p com.apple.FinalCut.WorkflowExtension
}

build_pkg() {
  local pkgroot="$OUT/pkgroot" work="$OUT/pkgwork"
  local pkg="$OUT/SubDub-$VERSION.pkg"
  rm -rf "$pkgroot" "$work" "$pkg"
  mkdir -p "$pkgroot/Applications" "$work"
  ditto --norsrc --noextattr --noqtn "$APP" "$pkgroot/Applications/$APP_NAME.app"

  echo "→ Package"
  # Always install into /Applications, never "relocate" onto a copy found elsewhere.
  pkgbuild --analyze --root "$pkgroot" "$work/components.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"

  xattr -cr "$pkgroot" 2>/dev/null || true
  COPYFILE_DISABLE=1 pkgbuild --root "$pkgroot" --component-plist "$work/components.plist" \
    --scripts Installer/scripts --identifier "$BUNDLE_ID.pkg" --version "$VERSION" \
    --install-location / "$work/SubDub-component.pkg" >/dev/null

  sed "s/__VERSION__/$VERSION/g" Installer/distribution.xml > "$work/distribution.xml"
  local sign_args=()
  [[ -n "$DEV_ID_INSTALLER" ]] && sign_args=(--sign "$DEV_ID_INSTALLER" --timestamp)
  productbuild --distribution "$work/distribution.xml" --resources Installer/resources \
    --package-path "$work" "${sign_args[@]}" "$pkg" >/dev/null

  if [[ -n "$NOTARY_PROFILE" && -n "$DEV_ID_INSTALLER" ]]; then
    echo "→ Notarizing"
    xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$pkg"
  fi
  rm -rf "$pkgroot" "$work"
  echo "✓ $pkg ($(du -h "$pkg" | cut -f1))"
}

case "${1:-app}" in
  cli) build_cli ;;
  app) build_app ;;
  install) build_app; install_local ;;
  pkg) build_app; build_pkg ;;
  all) build_cli; build_app; build_pkg ;;
  *) echo "usage: $0 [app|install|pkg|cli|all]"; exit 2 ;;
esac
