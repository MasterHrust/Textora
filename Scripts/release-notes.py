#!/usr/bin/env python3
"""Stage GitHub release Markdown before Sparkle signing; validate without rewriting."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

REPOSITORY = "MasterHrust/Textora"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def normalize_notes(body):
    if not isinstance(body, str) or not body.strip():
        raise ValueError("Release notes are empty. Add the changes to the GitHub Release or supply a Markdown file.")
    body = body.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    if not body.strip():
        raise ValueError("Release notes are empty.")
    if any((ord(char) < 32 and char not in "\t\n") or ord(char) in (0xFFFE, 0xFFFF) for char in body):
        raise ValueError("Release notes contain characters that cannot be embedded in an XML appcast.")
    return body.rstrip() + "\n"


def read_notes(tag, source=None):
    if source is not None:
        return normalize_notes(Path(source).read_text(encoding="utf-8-sig"))
    try:
        result = subprocess.run(
            ["gh", "release", "view", tag, "--repo", REPOSITORY, "--json", "body,tagName"],
            check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("Could not read the GitHub Release. Create its draft with a non-empty description and authenticate gh, or pass a local Markdown file.") from error
    release = json.loads(result.stdout)
    if not isinstance(release, dict) or release.get("tagName") != tag:
        raise ValueError("GitHub returned a different release tag.")
    return normalize_notes(release.get("body"))


def validate_feed(path, notes_path, tag, dmg_path):
    """No writes: appcasts must never be edited after generate_appcast signs them."""
    root = ET.parse(path).getroot()
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/Textora.dmg"
    items = []
    for item in root.findall("./channel/item"):
        enclosure = item.find("enclosure")
        if enclosure is not None and enclosure.get("url") == expected_url:
            items.append((item, enclosure))
    if len(items) != 1:
        raise ValueError("Appcast must contain exactly one update for this tag and Textora.dmg.")
    item, enclosure = items[0]
    build = item.findtext(SPARKLE + "version") or enclosure.get(SPARKLE + "version")
    if not build or not build.strip():
        raise ValueError("Appcast build number is missing.")
    version = item.findtext(SPARKLE + "shortVersionString") or enclosure.get(SPARKLE + "shortVersionString")
    if version != tag[1:]:
        raise ValueError(f"DMG version {version!r} does not match release tag {tag!r}.")
    try:
        signature = base64.b64decode(enclosure.get(SPARKLE + "edSignature", ""), validate=True)
    except ValueError as error:
        raise ValueError("Missing or malformed Sparkle EdDSA signature.") from error
    if len(signature) != 64:
        raise ValueError("Missing or malformed Sparkle EdDSA signature.")
    if enclosure.get("length") != str(Path(dmg_path).stat().st_size):
        raise ValueError("Appcast download length does not match the staged DMG.")
    description = item.find("description")
    if description is None or description.get(SPARKLE + "format") != "markdown":
        raise ValueError("Appcast is missing embedded Markdown release notes.")
    expected_notes = normalize_notes(Path(notes_path).read_text(encoding="utf-8-sig"))
    if normalize_notes(description.text) != expected_notes:
        raise ValueError("Embedded release notes differ from the selected release description.")
    if item.find(SPARKLE + "releaseNotesLink") is not None:
        raise ValueError("Expected embedded notes, not an external notes download.")
    if item.findtext(SPARKLE + "fullReleaseNotesLink") != f"https://github.com/{REPOSITORY}/releases":
        raise ValueError("Full release history link is missing.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage")
    stage.add_argument("--tag", required=True)
    stage.add_argument("--file", type=Path)
    stage.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--tag", required=True)
    validate.add_argument("--feed", type=Path, required=True)
    validate.add_argument("--notes", type=Path, required=True)
    validate.add_argument("--dmg", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?", args.tag):
        raise ValueError("Expected a stable release tag, such as v1.4.0.")
    if args.command == "stage":
        notes = read_notes(args.tag, args.file)
        if args.output.exists():
            raise ValueError("Refusing to overwrite an existing release-notes file.")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(notes, encoding="utf-8")
    else:
        validate_feed(args.feed, args.notes, args.tag, args.dmg)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
