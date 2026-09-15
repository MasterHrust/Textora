#!/bin/bash
# Prepares local files only; never publishes a release.
set -euo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: bash Scripts/prepare-update.sh TAG DMG OUTPUT_DIRECTORY" >&2
    exit 1
fi
tag="$1"
dmg="$2"
output="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_bin="${SPARKLE_BIN:-$root/.deriveddata-updates/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Expected stable tag such as v1.1 or v1.1.1" >&2; exit 1; }
[[ -f "$dmg" ]] || { echo "DMG does not exist: $dmg" >&2; exit 1; }
[[ -x "$sparkle_bin/generate_appcast" ]] || { echo "Resolve Sparkle first, or set SPARKLE_BIN to its bin directory." >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "Output directory must not already exist: $output" >&2; exit 1; }
mkdir -p "$output"
cp "$dmg" "$output/Textora.dmg"
"$sparkle_bin/generate_appcast" \
    --account Textora --maximum-deltas 0 \
    --download-url-prefix "https://github.com/MasterHrust/Textora/releases/download/$tag/" \
    --link "https://github.com/MasterHrust/Textora/releases/tag/$tag" \
    -o "$output/appcast.xml" "$output"
if ! /usr/bin/grep -q 'sparkle:edSignature=' "$output/appcast.xml"; then
    echo "No EdDSA signature generated. Do not publish; check the Textora signing key." >&2
    exit 1
fi
echo "Prepared $output/Textora.dmg and $output/appcast.xml. Upload both to release $tag."
