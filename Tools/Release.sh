#!/bin/zsh
# Packages a notarized Murmur for a GitHub release. It does not publish anything.
#   Tools/Release.sh 1.1        sets the version, builds into dist/, signs with Developer ID,
#                               notarizes, staples, verifies, and writes dist/Murmur-1.1.zip
#   Tools/Release.sh --check    only checks the certificate and the notary profile
#
# Needs the "Developer ID Application: … (ZX6ABY8QF9)" identity in the login keychain and
# the notarytool keychain profile below. No password is read, stored or asked for here.
# The Murmur you run (./Murmur.app) is never touched, so it can keep running.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
TEAM_ID=${MURMUR_TEAM_ID:-ZX6ABY8QF9}
PROFILE=${MURMUR_NOTARY_PROFILE:-lemma-notary}
DIST="$PROJECT_DIR/dist"
APP="$DIST/Murmur.app"

fail() { print -u2 "✗ $1"; exit 1; }
pass() { print "✓ $1"; }

check_setup() {
  /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -q "\"Developer ID Application: .*($TEAM_ID)\"" ||
    fail "No \"Developer ID Application: … ($TEAM_ID)\" identity in the keychain."
  pass "Developer ID Application certificate ($TEAM_ID)"
  /usr/bin/xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 ||
    fail "The notary keychain profile \"$PROFILE\" is missing or was rejected."
  pass "Notary profile \"$PROFILE\""
}

if [[ ${1:-} == --check ]]; then check_setup; exit 0; fi
VERSION=${1:?Usage: Tools/Release.sh <version>, for example 1.1 (or --check)}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*$' ]] || fail "Version must look like 1.1 or 1.2.3"
check_setup

BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
[[ -x Resources/Helpers/MurmurParakeet ]] || ./Tools/BuildLocalSpeech.sh --parakeet-only

# A fresh build every time: nothing left over from an earlier release.
/bin/rm -rf -- "$DIST"
mkdir -p "$DIST"
MURMUR_APP_DIR="$APP" MURMUR_SIGNING=developer-id MURMUR_TIMESTAMP=1 ./build.sh

# Apple checks the app; the ticket is then stapled to it, so it opens offline too.
SUBMISSION="$DIST/Murmur-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION"
print "\n→ Notarizing (usually a few minutes)"
RESULT=$(/usr/bin/xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait 2>&1) || true
print -- "$RESULT"
/bin/rm -f -- "$SUBMISSION"
if ! print -- "$RESULT" | /usr/bin/grep -q 'status: Accepted'; then
  SUBMISSION_ID=$(print -- "$RESULT" | /usr/bin/awk '/^ *id:/ { print $2; exit }')
  [[ -n "$SUBMISSION_ID" ]] && /usr/bin/xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" || true
  fail "Apple did not accept the build (see above)."
fi
/usr/bin/xcrun stapler staple "$APP"

print "\n→ Verifying"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" || fail "The signature doesn't verify"
pass "Signature valid (deep, strict)"
SIGNATURE=$(/usr/bin/codesign -d --verbose=2 "$APP" 2>&1)
[[ "$SIGNATURE" == *flags=*runtime* ]] || fail "Hardened runtime missing"
pass "Hardened runtime on"
/usr/sbin/spctl -a -vv -t execute "$APP" || fail "Gatekeeper refuses it"
pass "Gatekeeper accepts it"
/usr/bin/xcrun stapler validate "$APP" || fail "No notarization ticket stapled"
pass "Notarization ticket stapled"

ZIP="$DIST/Murmur-$VERSION.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
print "\nPackaged $ZIP ($(du -h "$ZIP" | cut -f1)), build $BUILD"
print "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
print "It is signed with Developer ID and notarized: it opens with a double-click on any Mac."
print "\nTo publish (review first):"
print "  git commit -am \"Release $VERSION\" && git tag v$VERSION && git push --tags"
print "  gh release create v$VERSION $ZIP --repo lhz56/murmur --title \"Murmur $VERSION\" --generate-notes"
print "Then remove dist/ to free the space: rm -rf dist"
