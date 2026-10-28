#!/bin/zsh
# Packages Murmur for a GitHub release. It does not publish anything.
#   Tools/Release.sh 1.1      sets the version, builds, and writes dist/Murmur-1.1.zip
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"
VERSION=${1:?Usage: Tools/Release.sh <version>, for example 1.1}
[[ $VERSION =~ '^[0-9]+(\.[0-9]+)*$' ]] || { print -u2 "Version must look like 1.1 or 1.2.3"; exit 1; }
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
[[ -x Resources/Helpers/MurmurParakeet ]] || ./Tools/BuildLocalSpeech.sh --parakeet-only
./build.sh
mkdir -p dist
ZIP="dist/Murmur-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent Murmur.app "$ZIP"
print "\nPackaged $ZIP ($(du -h "$ZIP" | cut -f1)), build $BUILD"
print "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
print "\nTo publish (review first):"
print "  git commit -am \"Release $VERSION\" && git tag v$VERSION && git push --tags"
print "  gh release create v$VERSION $ZIP --title \"Murmur $VERSION\" --generate-notes"
print "\nThis build is locally signed, not notarized: people opening it the first time"
print "right-click Murmur.app and choose Open."
