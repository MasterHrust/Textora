#!/usr/bin/env python3
"""Offline release-pipeline tests. No GitHub requests, signing keys or DMG mounting."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("release_notes", ROOT / "Scripts/release-notes.py")
notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notes)

GENERATOR = r'''#!/usr/bin/env python3
import base64, os, pathlib, sys, xml.etree.ElementTree as ET
args = sys.argv[1:]
assert '--embed-release-notes' in args
assert args[args.index('--account')+1] == 'Textora'
assert args[args.index('--maximum-deltas')+1] == '0'
folder = pathlib.Path(args[-1])
(folder / 'generator-called').write_text('yes')
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ET.register_namespace('sparkle', ns[1:-1])
rss = ET.Element('rss', {'version':'2.0'})
item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
ET.SubElement(item, ns+'version').text = '5.0'
ET.SubElement(item, ns+'shortVersionString').text = os.getenv('FAKE_VERSION', '1.4.0')
ET.SubElement(item, ns+'fullReleaseNotesLink').text = args[args.index('--full-release-notes-url')+1]
if not os.getenv('OMIT_NOTES'):
    desc = ET.SubElement(item, 'description', {ns+'format': 'markdown'})
    desc.text = (folder/'Textora.md').read_text() + os.getenv('ALTER_NOTES', '')
signature = '' if os.getenv('OMIT_SIGNATURE') else base64.b64encode(b's'*64).decode()
ET.SubElement(item, 'enclosure', {'url':args[args.index('--download-url-prefix')+1]+'Textora.dmg',
    ns+'edSignature':signature, 'length':str((folder/'Textora.dmg').stat().st_size)})
ET.ElementTree(rss).write(args[args.index('-o')+1], encoding='utf-8', xml_declaration=True)
'''
GH = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['GH_LOG']).write_text(json.dumps(sys.argv[1:]))
if os.getenv('GH_FAIL'): sys.exit(1)
print(os.environ['GH_RELEASE'])
'''


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="textora-release-tests-")
        self.root = Path(self.temporary.name)
        self.bin = self.root / "Sparkle tools with spaces"
        self.bin.mkdir()
        for name, contents in [("generate_appcast", GENERATOR), ("gh", GH)]:
            path = self.bin / name
            path.write_text(contents)
            path.chmod(0o755)
        self.dmg = self.root / "Source image with spaces.dmg"
        self.dmg.write_bytes(b"Unmodified test archive bytes")
        self.output = self.root / "prepared update"
        self.file = self.root / "release notes.md"
        self.body = "## New features\n- My Style\n- Message\n\n## Fixes\n- Вставка & копирование <текста>\n"
        self.file.write_text(self.body)
        self.env = dict(os.environ, SPARKLE_BIN=str(self.bin), PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
            GH_RELEASE=json.dumps({'body': self.body, 'tagName': 'v1.4.0'}), GH_LOG=str(self.root/'gh-arguments.json'))

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, local=True, overrides=None):
        args = ['bash', str(ROOT/'Scripts/prepare-update.sh'), 'v1.4.0', str(self.dmg), str(self.output)]
        if local: args.append(str(self.file))
        return subprocess.run(args, env=dict(self.env, **(overrides or {})), capture_output=True, text=True)

    def test_local_markdown_is_embedded_and_archive_is_unchanged(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output/'Textora.dmg').read_bytes(), self.dmg.read_bytes())
        item = ET.parse(self.output/'appcast.xml').find('./channel/item')
        self.assertEqual(item.find('description').text, self.body)
        self.assertEqual(item.find('description').get(notes.SPARKLE+'format'), 'markdown')
        self.assertFalse((self.root/'gh-arguments.json').exists())

    def test_github_release_body_is_default_and_only_read_actions_are_used(self):
        result = self.prepare(local=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output/'Textora.md').read_text(), self.body)
        self.assertEqual(json.loads((self.root/'gh-arguments.json').read_text()),
            ['release', 'view', 'v1.4.0', '--repo', 'MasterHrust/Textora', '--json', 'body,tagName'])

    def test_empty_local_notes_fail_before_signing(self):
        self.file.write_text(' \n\t')
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_empty_github_notes_fail_before_signing(self):
        result = self.prepare(local=False, overrides={'GH_RELEASE': json.dumps({'tagName':'v1.4.0','body':''})})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_missing_release_or_authentication_does_not_create_an_empty_feed(self):
        result = self.prepare(local=False, overrides={'GH_FAIL':'1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertIn('Could not read the GitHub Release', result.stderr)

    def test_wrong_github_tag_is_rejected(self):
        result = self.prepare(local=False, overrides={'GH_RELEASE': json.dumps({'tagName':'v1.4.1','body':self.body})})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertIn('different release tag', result.stderr)

    def test_marketing_version_must_match_tag(self):
        result = self.prepare(overrides={'FAKE_VERSION':'1.3.2'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)

    def test_unsigned_archive_is_not_reported_ready(self):
        result = self.prepare(overrides={'OMIT_SIGNATURE':'1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('EdDSA', result.stderr)

    def test_missing_embedded_notes_are_rejected(self):
        result = self.prepare(overrides={'OMIT_NOTES':'1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('embedded Markdown', result.stderr)

    def test_changed_embedded_notes_are_rejected(self):
        result = self.prepare(overrides={'ALTER_NOTES':'unexpected addition'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('differ', result.stderr)

    def test_validation_never_rewrites_a_generated_feed(self):
        self.assertEqual(self.prepare().returncode, 0)
        feed = self.output/'appcast.xml'
        before = feed.read_bytes()
        notes.validate_feed(feed, self.output/'Textora.md', 'v1.4.0', self.output/'Textora.dmg')
        self.assertEqual(feed.read_bytes(), before)

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output/'keep'; marker.write_text('keep')
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertFalse((self.output/'generator-called').exists())

    def test_unicode_xml_characters_and_cdata_boundary_remain_literal_text(self):
        self.body = '## Что изменилось\n- <script> is code, not execution & "quotes"\n- Literal ]]> boundary\n'
        self.file.write_text(self.body)
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(ET.parse(self.output/'appcast.xml').find('./channel/item/description').text, self.body)

    def test_line_endings_bom_and_illegal_xml_controls(self):
        self.assertEqual(notes.normalize_notes('\ufeff  - item\r\n- пункт\r'), '  - item\n- пункт\n')
        for text in ['', '\n  ', '\ufeff', 'bad\x00text']:
            with self.assertRaises(ValueError): notes.normalize_notes(text)


if __name__ == '__main__':
    unittest.main()
