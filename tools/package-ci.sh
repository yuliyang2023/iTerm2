#!/bin/bash
# Package an unsigned contributor build without Apple credentials.
set -euo pipefail

app="${1:?Usage: package-ci.sh /path/to/iTerm2.app /path/to/output}"
output="${2:?Usage: package-ci.sh /path/to/iTerm2.app /path/to/output}"
binary="$app/Contents/MacOS/iTerm2"
test -f "$binary"
# Avoid -verify_arch argument parsing differences between lipo versions.
architectures="$(lipo -archs "$binary")"
echo "Application architectures: $architectures"
for required_arch in arm64 x86_64; do
  case " $architectures " in
    *" $required_arch "*) ;;
    *)
      echo "Missing required architecture: $required_arch" >&2
      exit 1
      ;;
  esac
done

# Ad-hoc sign the nested code and bundle so Apple Silicon can run it. This
# is neither Developer ID signing nor Apple notarization.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

mkdir -p "$output"
output="$(cd "$output" && pwd)"
revision="$(git rev-parse --short=10 HEAD)"
name="iTerm2-3.7.6-BYOK-universal-$revision"
staging="$(mktemp -d)"
dmg_log="$(mktemp)"
trap 'rm -rf "$staging"; rm -f "$dmg_log"' EXIT
ditto "$app" "$staging/iTerm2.app"
ln -s /Applications "$staging/Applications"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$name.zip"
for attempt in 1 2 3; do
  if hdiutil create -volname 'iTerm2 BYOK' -srcfolder "$staging" \
    -format UDZO -ov "$output/$name.dmg" > "$dmg_log" 2>&1; then
    cat "$dmg_log"
    break
  else
    result=$?
    cat "$dmg_log"
    # A busy disk-image service can reject an otherwise valid app image.
    # Each create invocation waits on the service; retry only this error.
    case "$(cat "$dmg_log")" in
      *"create failed - Resource busy"*) ;;
      *) exit "$result" ;;
    esac
    if [[ "$attempt" == 3 ]]; then
      exit "$result"
    fi
    echo "Disk-image service busy; retrying DMG creation (attempt $((attempt + 1))/3)."
  fi
done
(
  cd "$output"
  shasum -a 256 "$name.zip" "$name.dmg" > "$name.sha256"
)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<'TEXT'
## iTerm2 BYOK build

The artifact contains a universal (Intel + Apple Silicon) ZIP and DMG.
This is an ad-hoc signed build, without Apple notarization.

To enable BYOK authentication:

In **Settings > General > AI > Manage AI Models**, edit a manual model and
choose its credential source. Choose the model’s own API key to store a key
for that model in macOS Keychain, or explicitly select a shared vendor key.
This also supports authenticated local endpoints. Chat and Test Connection
use the same credential policy. Automatic keeps vendor keys bound to the
vendor’s own host; select a credential explicitly for a gateway.

BYOK credentials are not needed by this build and are not stored in the repository.
TEXT
fi
