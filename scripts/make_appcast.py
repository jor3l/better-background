#!/usr/bin/env python3
"""Signs a release .dmg with the Sparkle EdDSA key and writes appcast.xml.

The private key comes from the SPARKLE_PRIVATE_KEY environment variable: the
base64 of the 32-byte Ed25519 seed (or seed + public key, 64 bytes). The
signature covers the raw bytes of the .dmg, which is what Sparkle checks.

    SPARKLE_PRIVATE_KEY=... make_appcast.py --dmg build/BetterBackground.dmg \
        --version 0.1.3 --url https://.../BetterBackground.dmg \
        --notes-url https://.../releases/tag/v0.1.3 --plist Resources/Info.plist \
        --notes-file build/notes.txt --out build/appcast.xml

    make_appcast.py --generate-key   # prints a new private key and its public key
"""
import argparse
import base64
import html
import os
import plistlib
import sys
from email.utils import formatdate

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey


def public_b64(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def load_private_key(text: str) -> Ed25519PrivateKey:
    raw = base64.b64decode(text.strip())
    if len(raw) not in (32, 64):
        sys.exit(f"SPARKLE_PRIVATE_KEY must decode to 32 or 64 bytes, got {len(raw)}")
    return Ed25519PrivateKey.from_private_bytes(raw[:32])


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--generate-key", action="store_true")
    p.add_argument("--dmg")
    p.add_argument("--version")
    p.add_argument("--url")
    p.add_argument("--notes-url")
    p.add_argument("--notes-file")
    p.add_argument("--plist", help="Info.plist to read SUPublicEDKey and LSMinimumSystemVersion from")
    p.add_argument("--out")
    a = p.parse_args()

    if a.generate_key:
        key = Ed25519PrivateKey.generate()
        seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                 serialization.NoEncryption())
        print("private (repo secret SPARKLE_PRIVATE_KEY):", base64.b64encode(seed).decode())
        print("public  (Info.plist SUPublicEDKey):       ", public_b64(key))
        return

    for name in ("dmg", "version", "url", "plist", "out"):
        if not getattr(a, name):
            sys.exit(f"--{name.replace('_', '-')} is required")

    secret = os.environ.get("SPARKLE_PRIVATE_KEY", "")
    if not secret.strip():
        sys.exit("SPARKLE_PRIVATE_KEY is not set")
    key = load_private_key(secret)

    with open(a.plist, "rb") as f:
        info = plistlib.load(f)
    expected = info.get("SUPublicEDKey", "")
    if public_b64(key) != expected:
        sys.exit("SPARKLE_PRIVATE_KEY does not match SUPublicEDKey in Info.plist; "
                 "installed apps would reject this update")
    min_os = info.get("LSMinimumSystemVersion", "15.0")

    data = open(a.dmg, "rb").read()
    signature = key.sign(data)
    Ed25519PublicKey.from_public_bytes(base64.b64decode(expected)).verify(signature, data)
    sig_b64 = base64.b64encode(signature).decode()

    notes = ""
    if a.notes_file and os.path.exists(a.notes_file):
        lines = [l.strip() for l in open(a.notes_file, encoding="utf-8") if l.strip()]
        if lines:
            notes = "<ul>" + "".join(f"<li>{html.escape(l)}</li>" for l in lines) + "</ul>"

    q = lambda s: html.escape(s, quote=True)
    notes_link = f"\n      <sparkle:fullReleaseNotesLink>{q(a.notes_url)}</sparkle:fullReleaseNotesLink>" if a.notes_url else ""
    description = f"\n      <description><![CDATA[{notes}]]></description>" if notes else ""
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BetterBackground</title>
    <item>
      <title>Version {q(a.version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{q(a.version)}</sparkle:version>
      <sparkle:shortVersionString>{q(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{q(min_os)}</sparkle:minimumSystemVersion>{notes_link}{description}
      <enclosure url="{q(a.url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{sig_b64}"/>
    </item>
  </channel>
</rss>
"""
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(xml)
    print(f"Wrote {a.out} for {a.version} ({len(data)} bytes, signature verified)")


if __name__ == "__main__":
    main()
