"""Test real shell download/cache/checksum/assembly flow with inert tool fixtures."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os,pathlib,shutil,sys
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
with open(os.environ["LOG"],"a") as f: f.write(name+" "+repr(a)+"\n")
if name=="curl":
    if os.environ.get("FAIL_DOWNLOAD"): sys.exit(22)
    tool=a[-3].split("/")[-1]
    shutil.copy(pathlib.Path(os.environ["FIXTURES"])/tool,a[-1])
elif name=="xcrun":
    if a[1]=="-verify_arch":
        if os.environ.get("WRONG_ARCH"): sys.exit(1)
    elif a[1]=="-create": shutil.copy(a[2],a[-1])
    else: sys.exit(2)
elif name=="codesign":
    if os.environ.get("FAIL_SIGN"): sys.exit(1)
elif name=="xattr": pass
else: sys.exit(3)
'''
class BundleFFmpeg(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix="ffmpeg bundle tests ")
        self.root=Path(self.tmp.name)
        self.repo=self.root/"repo with spaces"
        (self.repo/"scripts").mkdir(parents=True)
        self.fixtures=self.root/"fixtures"; self.fixtures.mkdir()
        hashes={}
        for tool in ("ffmpeg","ffprobe"):
            path=self.fixtures/(tool+".zip")
            with zipfile.ZipFile(path,"w") as z:
                z.writestr(tool,"#!/bin/sh\necho 'fixture media tool version'\n")
            hashes[tool]=hashlib.sha256(path.read_bytes()).hexdigest()
        source=(ROOT/"scripts/bundle-ffmpeg.sh").read_text()
        source=re.sub(r'(release="[^"]+"; hash=")[a-f0-9]{64}',lambda m:m[1]+hashes["ffprobe" if "ffprobe" in source[:m.start()].split(";;")[-1] else "ffmpeg"],source)
        self.script=self.repo/"scripts/bundle-ffmpeg.sh"; self.script.write_text(source)
        tools=self.root/"tools"; tools.mkdir()
        for name in ("curl","xcrun","codesign","xattr"):
            p=tools/name; p.write_text(MOCK); p.chmod(0o755)
        self.log=self.root/"log"
        self.env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ["PATH"],LOG=str(self.log),FIXTURES=str(self.fixtures))
        self.app=self.root/"Margherita.app"
    def tearDown(self): self.tmp.cleanup()
    def run_bundle(self,*arch,**env):
        return subprocess.run(["bash",str(self.script),str(self.app),*(arch or ("arm64",))],env=dict(self.env,**env),capture_output=True,text=True)
    def test_verified_cached_pair_and_signing(self):
        first=self.run_bundle()
        self.assertEqual(first.returncode,0,first.stdout+first.stderr)
        for tool in ("ffmpeg","ffprobe"):
            p=self.app/"Contents/Resources/bin"/tool
            self.assertTrue(os.access(p,os.X_OK))
        before=self.log.read_text().count("curl ")
        second=self.run_bundle(FAIL_DOWNLOAD="1")
        self.assertEqual(second.returncode,0,second.stderr)
        self.assertEqual(before,self.log.read_text().count("curl "))
        self.assertIn("com.apple.quarantine",self.log.read_text())
        self.assertIn("'--force', '-s', '-'",self.log.read_text())
    def test_intel_and_universal(self):
        for archs in [("x86_64",),("arm64","x86_64")]:
            r=self.run_bundle(*archs)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertIn("'-create'",self.log.read_text())
    def test_corrupt_cache_is_replaced(self):
        self.assertEqual(self.run_bundle().returncode,0)
        (self.repo/".ffmpeg-cache/ffmpeg-9.0.2-arm64.zip").write_bytes(b"corrupt")
        r=self.run_bundle()
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn("Discarding corrupt",r.stderr)
    def test_bad_hash_is_never_executed_or_cached(self):
        (self.fixtures/"ffmpeg.zip").write_bytes(b"tampered")
        r=self.run_bundle()
        self.assertNotEqual(r.returncode,0)
        self.assertIn("SHA256 verification failed",r.stderr)
        self.assertNotIn("codesign",self.log.read_text())
        self.assertFalse(list((self.repo/".ffmpeg-cache").glob("*.zip")))
    def test_failure_no_pair_installed(self):
        for env in [{"FAIL_DOWNLOAD":"1"},{"WRONG_ARCH":"1"},{"FAIL_SIGN":"1"}]:
            r=self.run_bundle(**env)
            self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertFalse((self.app/"Contents/Resources/bin/ffmpeg").exists())
    def test_bundle_precedes_absolute_path_and_homebrew(self):
        s=(ROOT/"Margherita/ExtendedMedia.swift").read_text()
        self.assertLess(s.index('bin/ffmpeg'),s.index('environment["PATH"]'))
        self.assertLess(s.index('environment["PATH"]'),s.index('"/opt/homebrew/bin/ffmpeg"'))
        self.assertIn('directory.hasPrefix("/")',s)
if __name__=="__main__": unittest.main()
