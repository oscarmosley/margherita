"""1.0.2 release guards; end-to-end CryptoKit signing test runs on macOS."""
import base64
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
NS = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
class Release102(unittest.TestCase):
    def test_configuration_and_no_secret_in_git(self):
        info = plistlib.loads((ROOT/'Margherita/Info.plist').read_bytes())
        self.assertEqual(len(base64.b64decode(info['SUPublicEDKey'])),32)
        self.assertEqual(info['SUFeedURL'],'https://raw.githubusercontent.com/oscmo1/margherita/main/appcast.xml')
        tracked = subprocess.check_output(['git','ls-files'],cwd=ROOT,text=True)
        self.assertNotIn('private-key', tracked)
        self.assertEqual(ET.parse(ROOT/'appcast.xml').getroot().tag,'rss')
        generator = (ROOT/'scripts/generate_project.py').read_text()
        yml = (ROOT/'project.yml').read_text()
        self.assertIn(info['SUPublicEDKey'],generator)
        self.assertIn(info['SUPublicEDKey'],yml)
    def test_hover_scroll_lifecycle_and_clipping(self):
        src = (ROOT/'Margherita/CompatibilityMatrix.swift').read_text()
        for token in ['NSView.boundsDidChangeNotification','clip.postsBoundsChangedNotifications = true',
                      'window.mouseLocationOutsideOfEventStream','visibleRect.contains(p)',
                      'nsView.stopObservingScroll()','NotificationCenter.default.removeObserver(observer)',
                      'viewDidMoveToSuperview','observeScroll()']:
            self.assertIn(token,src)
    def test_permissions_refresh_and_regrant_guidance(self):
        src = (ROOT/'Margherita/Views.swift').read_text()
        permission = src[src.index('final class PermissionStatus'):src.index('struct PermissionsTab')]
        self.assertIn('AXIsProcessTrusted()',permission)
        self.assertIn('CGPreflightListenEventAccess()',permission)
        self.assertIn('getNotificationSettings',permission)
        self.assertIn('Timer.publish(every: 1',src)
        self.assertIn('didBecomeActiveNotification',src)
        self.assertIn('ad-hoc signed',src)
        self.assertIn('remove its old Accessibility and Input Monitoring entries',src)
    def test_signing_validates_archive_and_key(self):
        script = (ROOT/'scripts/write-appcast.swift').read_text()
        for token in ['Curve25519.Signing.PrivateKey(rawRepresentation: seed)',
                      'key.publicKey.isValidSignature(signature, for: data)',
                      'publicKey == info["SUPublicEDKey"]',
                      'version == expected["CFBundleVersion"]',
                      'Contents/Frameworks/Sparkle.framework/Sparkle',
                      'sparkle:edSignature','sparkle:minimumSystemVersion','options: .atomic']:
            self.assertIn(token,script)
        for name in ['Sign Release.command','scripts/sign-release.sh']:
            subprocess.run(['bash','-n',str(ROOT/name)],check=True)
    @unittest.skipUnless(platform.system()=='Darwin','CryptoKit needs macOS SDK')
    def test_actual_signer_with_fixture_archive_and_wrong_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp); app=d/'Margherita.app'; (app/'Contents/Frameworks/Sparkle.framework').mkdir(parents=True)
            (app/'Contents/Frameworks/Sparkle.framework/Sparkle').write_bytes(b'fixture')
            # RFC 8032 Ed25519 test vector, public fixture only, never the release key.
            seed=bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
            pub=bytes.fromhex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
            info=plistlib.loads((ROOT/'Margherita/Info.plist').read_bytes())
            info['CFBundleIdentifier']='com.oscar.margherita';info['SUPublicEDKey']=base64.b64encode(pub).decode()
            source=d/'Info.plist';source.write_bytes(plistlib.dumps(info));(app/'Contents/Info.plist').write_bytes(source.read_bytes())
            key=d/'key';key.write_bytes(base64.b64encode(seed));dmg=d/'fixture.dmg';dmg.write_bytes(b'actual archive bytes')
            feed=d/'appcast.xml';feed.write_bytes((ROOT/'appcast.xml').read_bytes())
            cmd=['xcrun','swift',str(ROOT/'scripts/write-appcast.swift'),str(dmg),str(key),str(app),str(source),str(feed)]
            subprocess.run(cmd,check=True)
            enclosure=ET.parse(feed).find('./channel/item/enclosure')
            self.assertEqual(enclosure.attrib['length'],str(dmg.stat().st_size))
            self.assertEqual(len(base64.b64decode(enclosure.attrib['{'+NS['s']+'}edSignature'])),64)
            subprocess.run(cmd,check=True)
            self.assertEqual(len(ET.parse(feed).findall('./channel/item')),1)
            before=feed.read_bytes();key.write_bytes(base64.b64encode(bytes(32)))
            self.assertNotEqual(subprocess.run(cmd,capture_output=True).returncode,0)
            self.assertEqual(feed.read_bytes(),before)
