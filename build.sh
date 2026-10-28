#!/bin/zsh
set -euo pipefail
umask 077
PROJECT_DIR=${0:A:h}
APP_DIR="$PROJECT_DIR/Murmur.app"
require_closed_app() {
  if /usr/bin/pgrep -x Murmur >/dev/null 2>&1; then
    print -u2 'Quit Murmur before rebuilding so its running signature stays intact.'
    exit 3
  fi
}
require_closed_app
if [[ -L "$APP_DIR" ]] || { [[ -e "$APP_DIR" && ! -d "$APP_DIR" ]]; }; then
  print -u2 'The destination must be a regular application directory, not a symlink or file.'
  exit 2
fi

# Compile and sign a private sibling bundle on the same filesystem. The
# installed application is not modified if compilation or signing fails.
BUILD_STAGING=$(/usr/bin/mktemp -d "$PROJECT_DIR/.murmur-build.XXXXXXXX")
chmod 700 "$BUILD_STAGING"
STAGED_APP="$BUILD_STAGING/Murmur.app"
PREVIOUS_APP="$BUILD_STAGING/PreviousMurmur.app"
cleanup_build() {
  local BUILD_STATUS=$?
  # Restore the previous bundle if installation was interrupted between moves.
  if [[ -d "$PREVIOUS_APP" && ! -e "$APP_DIR" ]]; then
    if ! /bin/mv -- "$PREVIOUS_APP" "$APP_DIR"; then
      print -u2 "Could not restore the previous app. It is preserved at: $PREVIOUS_APP"
      return 1
    fi
  fi
  if [[ -d "$BUILD_STAGING" ]]; then
    /bin/rm -R -- "$BUILD_STAGING"
  fi
  return "$BUILD_STATUS"
}
trap cleanup_build EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Retain already bundled models/helpers when rebuilding a source checkout
# whose Resources directory may omit those large downloaded files.
if [[ -d "$APP_DIR" ]]; then
  /usr/bin/ditto "$APP_DIR" "$STAGED_APP"
fi
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/clang -fobjc-arc -target arm64-apple-macos26.0 -c "$PROJECT_DIR/Sources/AudioTapBridge.m" -o "$BUILD_STAGING/AudioTapBridge.o"
/usr/bin/swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macos26.0 -module-name Murmur -import-objc-header "$PROJECT_DIR/Sources/AudioTapBridge.h" "$PROJECT_DIR"/Sources/*.swift "$BUILD_STAGING/AudioTapBridge.o" -o "$STAGED_APP/Contents/MacOS/Murmur"
cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
if [[ -f "$PROJECT_DIR/Resources/Murmur.icns" ]]; then
  cp "$PROJECT_DIR/Resources/Murmur.icns" "$STAGED_APP/Contents/Resources/Murmur.icns"
fi
cp "$PROJECT_DIR"/Resources/*.wav "$STAGED_APP/Contents/Resources/"
for folder in Helpers Models ThirdPartyLicenses; do
  if [[ -d "$PROJECT_DIR/Resources/$folder" ]]; then
    /usr/bin/ditto "$PROJECT_DIR/Resources/$folder" "$STAGED_APP/Contents/Resources/$folder"
  fi
done
if [[ -f "$PROJECT_DIR/Resources/THIRD-PARTY.txt" ]]; then
  cp "$PROJECT_DIR/Resources/THIRD-PARTY.txt" "$STAGED_APP/Contents/Resources/"
  cp "$PROJECT_DIR"/Resources/LICENSE-*.txt "$STAGED_APP/Contents/Resources/"
  cp "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
fi
"$PROJECT_DIR/Tools/SignApp.sh" "$STAGED_APP"

# SignApp verifies the complete staged bundle. Recheck for a launch during the
# build, then install only the verified result; roll back if the final move fails.
require_closed_app
if [[ -d "$APP_DIR" ]]; then
  /bin/mv -- "$APP_DIR" "$PREVIOUS_APP"
fi
if ! /bin/mv -- "$STAGED_APP" "$APP_DIR"; then
  print -u2 'Installation failed; restoring the previous application.'
  exit 7
fi
print "Built: $APP_DIR"
