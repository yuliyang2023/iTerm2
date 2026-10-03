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
name="iTerm2-3.7.3-BYOK-universal-$revision"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/iTerm2.app"
ln -s /Applications "$staging/Applications"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$name.zip"
hdiutil create -volname 'iTerm2 BYOK' -srcfolder "$staging" \
  -format UDZO -ov "$output/$name.dmg"
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

Each manual model can have its own **API Key** in **Edit Manual AI Model**.
This key is stored in macOS Keychain and is used by Chat and Test Connection,
including for local hosts. Leave it empty to use the shared provider key:

1. Keep the BYOK key in **Settings > General > AI > API Key > OpenAI**.
2. In **Settings > Advanced**, search for **Local AI hosts**.
3. Add the endpoint's exact hostname or IP (for example, `byok.local` or `10.0.0.10`), without the scheme, port, or path.
4. Create a new AI Chat using the custom Chat Completions model.

Only explicitly listed local hosts receive the model provider's saved key.
The setting covers all ports and paths on each listed host.
Chat and Test Connection now apply the same authentication policy.
BYOK credentials are not needed by this build and are not stored in the repository.
TEXT
fi
