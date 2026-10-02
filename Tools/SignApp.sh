#!/bin/zsh
# Keep one private local signing identity across Murmur rebuilds. This does not
# grant privacy permissions, change trust settings, or create a distribution ID.
set -euo pipefail
umask 077

SIGNING_NAME='Murmur Local Signing (app.murmur.mac)'
BUNDLE_ID='app.murmur.mac'
PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/Murmur.app"
PREPARE_ONLY=false

if [[ ${1:-} == '--prepare' ]]; then
  PREPARE_ONLY=true
  shift
elif [[ ${1:-} == '--help' || ${1:-} == '-h' ]]; then
  print 'Usage: SignApp.sh [APP_PATH] | SignApp.sh --prepare'
  print 'Creates/reuses a private local signing identity in your login keychain.'
  print 'Quit Murmur before signing. A Keychain access dialog may require approval.'
  exit 0
fi
if (( $# > 1 )) || { $PREPARE_ONLY && (( $# > 0 )); }; then
  print -u2 'Usage: SignApp.sh [APP_PATH] | SignApp.sh --prepare'
  exit 2
fi
if (( $# == 1 )); then
  APP_DIR=${1:A}
fi
if ! $PREPARE_ONLY; then
  if [[ ! -d "$APP_DIR" || ! -f "$APP_DIR/Contents/Info.plist" ]]; then
    print -u2 "Not an application bundle: $APP_DIR"
    exit 2
  fi
  ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")
  if [[ "$ACTUAL_ID" != "$BUNDLE_ID" ]]; then
    print -u2 "Refusing to sign an application other than $BUNDLE_ID."
    exit 2
  fi
  if /usr/bin/pgrep -x Murmur >/dev/null 2>&1; then
    print -u2 'Quit Murmur before signing. The running application was not changed.'
    exit 3
  fi
fi

# Use the existing login keychain, never the System keychain or a trust override.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [[ ! -f "$KEYCHAIN" ]]; then
  print -u2 'The login keychain is unavailable. Open Keychain Access to set it up.'
  exit 4
fi
SIGNING_TEMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/murmur-signing.XXXXXXXX")
chmod 700 "$SIGNING_TEMP"
cleanup_signing_files() {
  if [[ -d "$SIGNING_TEMP" ]]; then
    for SIGNING_FILE in certificate.pem certificate.cnf private-key.pem identity.pem generation.log; do
      [[ ! -f "$SIGNING_TEMP/$SIGNING_FILE" ]] || /bin/rm -- "$SIGNING_TEMP/$SIGNING_FILE"
    done
    /bin/rmdir "$SIGNING_TEMP"
  fi
}
trap cleanup_signing_files EXIT HUP INT TERM

if ! /usr/bin/security find-certificate -c "$SIGNING_NAME" -p "$KEYCHAIN" >"$SIGNING_TEMP/certificate.pem" 2>/dev/null; then
  cat >"$SIGNING_TEMP/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = Murmur Local Signing (app.murmur.mac)
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CONFIG
  /usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes \
    -days 3650 -config "$SIGNING_TEMP/certificate.cnf" \
    -keyout "$SIGNING_TEMP/private-key.pem" \
    -out "$SIGNING_TEMP/certificate.pem" \
    >"$SIGNING_TEMP/generation.log" 2>&1
  cat "$SIGNING_TEMP/certificate.pem" "$SIGNING_TEMP/private-key.pem" >"$SIGNING_TEMP/identity.pem"
  # -x prevents later extraction of the private key. -T scopes its application
  # ACL to codesign. Do not use -A or alter any existing key's partition list.
  /usr/bin/security import "$SIGNING_TEMP/identity.pem" -k "$KEYCHAIN" \
    -f pemseq -x -T /usr/bin/codesign
  /bin/rm -- "$SIGNING_TEMP/private-key.pem" "$SIGNING_TEMP/identity.pem"
fi

# Certificate names alone are not an identity. Resolve and use the exact
# fingerprint, and refuse a certificate that no longer has its private key.
CERT_SUBJECT=$(/usr/bin/openssl x509 -in "$SIGNING_TEMP/certificate.pem" -noout -subject -nameopt RFC2253)
CERT_SUBJECT=${CERT_SUBJECT#subject=}
CERT_SUBJECT=${CERT_SUBJECT# }
if [[ "$CERT_SUBJECT" != "CN=$SIGNING_NAME" ]]; then
  print -u2 'The existing signing certificate has an unexpected subject; no app was signed.'
  exit 5
fi
SIGNING_HASH=$(/usr/bin/openssl x509 -in "$SIGNING_TEMP/certificate.pem" -noout -fingerprint -sha1 | /usr/bin/awk -F= '{gsub(":", "", $2); print $2}')
if [[ ! "$SIGNING_HASH" =~ '^[0-9A-Fa-f]{40}$' ]]; then
  print -u2 'Could not identify the local signing certificate; no app was signed.'
  exit 5
fi
if ! /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | /usr/bin/awk -v hash="$SIGNING_HASH" '$2 == hash { found=1 } END { exit !found }'; then
  print -u2 'The Murmur signing certificate is missing its matching private key.'
  print -u2 'Repair the identity in Keychain Access; it was not silently replaced.'
  exit 5
fi
if $PREPARE_ONLY; then
  print 'Murmur local signing identity is ready in the login keychain.'
  exit 0
fi

# A certificate fingerprint plus the identifier proves that each new build was
# signed by this same private key. An identifier-only ad-hoc requirement would
# let unrelated code impersonate Murmur and must never be used here.
REQUIREMENT="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGNING_HASH\""
sign_code() {
  if ! /usr/bin/codesign "$@"; then
    print -u2 'Signing failed. If macOS showed a Keychain dialog, approve only codesign access to the Murmur Local Signing key, then rerun this script.'
    print -u2 'The keychain may need unlocking in Keychain Access. No trust settings or privacy permissions were changed.'
    exit 6
  fi
}
if [[ -d "$APP_DIR/Contents/Resources/Helpers" ]]; then
  for HELPER in "$APP_DIR/Contents/Resources/Helpers/MurmurParakeet" "$APP_DIR/Contents/Resources/Helpers/whisper-cli"; do
    if [[ -f "$HELPER" ]]; then
      # These tools do not request Microphone or Accessibility privileges.
      # Keep their valid existing signatures rather than requesting access to
      # the private signing key again for each tool during every build.
      if ! /usr/bin/codesign --verify --strict --verbose=2 "$HELPER"; then
        print -u2 "The bundled helper signature is invalid: $HELPER"
        print -u2 'Rebuild the local speech helpers before signing the application.'
        exit 6
      fi
    fi
  done
fi
sign_code --force --sign "$SIGNING_HASH" --keychain "$KEYCHAIN" \
  --timestamp=none --identifier "$BUNDLE_ID" --requirements "=$REQUIREMENT" "$APP_DIR"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
/usr/bin/codesign --verify --test-requirement "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SIGNING_HASH\"" "$APP_DIR"
print "Signed with the persistent Murmur local identity: $APP_DIR"
