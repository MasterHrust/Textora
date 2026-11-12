#!/bin/bash
# Prepares signed local files only; never creates, edits or publishes a GitHub release.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: bash Scripts/prepare-update.sh TAG DMG OUTPUT_DIRECTORY [RELEASE_NOTES.md]" >&2
    echo "Without the fourth argument, notes are read from the GitHub Release description using gh." >&2
    exit 1
fi
tag="$1"
dmg="$2"
output="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
sparkle_bin="${SPARKLE_BIN:-$root/.deriveddata-updates/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Expected stable tag such as v1.4.0" >&2; exit 1; }
[[ -f "$dmg" ]] || { echo "DMG does not exist: $dmg" >&2; exit 1; }
[[ -x "$sparkle_bin/generate_appcast" ]] || { echo "Resolve Sparkle first, or set SPARKLE_BIN to its bin directory." >&2; exit 1; }
[[ ! -e "$output" ]] || { echo "Output directory must not already exist: $output" >&2; exit 1; }
# Stage notes before signing. A missing/empty description fails rather than shipping an empty popup.
if [[ $# -eq 4 ]]; then
    python3 "$root/Scripts/release-notes.py" stage --tag "$tag" --output "$output/Textora.md" --file "$4"
else
    python3 "$root/Scripts/release-notes.py" stage --tag "$tag" --output "$output/Textora.md"
fi
cp "$dmg" "$output/Textora.dmg"
"$sparkle_bin/generate_appcast" \
    --account Textora --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/MasterHrust/Textora/releases/download/$tag/" \
    --link "https://github.com/MasterHrust/Textora/releases/tag/$tag" \
    --full-release-notes-url "https://github.com/MasterHrust/Textora/releases" \
    -o "$output/appcast.xml" "$output"
# Validate only. Rewriting generated XML would invalidate a signed appcast.
python3 "$root/Scripts/release-notes.py" validate --tag "$tag" --feed "$output/appcast.xml" \
    --notes "$output/Textora.md" --dmg "$output/Textora.dmg"
echo "Prepared $output/Textora.dmg and $output/appcast.xml with embedded release notes."
echo "Upload these two files to release $tag. Textora.md is an optional review copy."
echo "If the GitHub description changes, regenerate the appcast from the unchanged DMG before publishing."
