#!/usr/bin/env python3
"""Write one immutable-release enclosure; latest appcast can never point at an old asset."""
import base64
import email.utils
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import quote, urlparse


def write_appcast(plist_path, archive_path, tag, signature, output):
    info = plistlib.loads(pathlib.Path(plist_path).read_bytes())
    archive = pathlib.Path(archive_path)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
        raise ValueError("Invalid release tag")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid EdDSA signature")
    feed = urlparse(info["SUFeedURL"])
    match = re.fullmatch(r"/([^/]+)/([^/]+)/releases/latest/download/appcast.xml", feed.path)
    if feed.scheme != "https" or feed.netloc != "github.com" or not match or feed.query or feed.fragment:
        raise ValueError("Expected a GitHub latest-release appcast URL")
    owner, repo = match.groups()
    build, version = str(info["CFBundleVersion"]), str(info["CFBundleShortVersionString"])
    if not build.isdecimal() or int(build) < 1:
        raise ValueError("Expected a positive numeric build number")
    sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    ET.register_namespace("sparkle", sparkle)
    root = ET.Element("rss", version="2.0")
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Pippa"
    ET.SubElement(channel, "language").text = "de"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Pippa {version}"
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "link").text = f"https://github.com/{owner}/{repo}/releases/tag/{quote(tag, safe='')}"
    for key, value in [("version", build), ("shortVersionString", version),
                       ("minimumSystemVersion", info["LSMinimumSystemVersion"]), ("hardwareRequirements", "arm64")]:
        ET.SubElement(item, f"{{{sparkle}}}{key}").text = value
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{owner}/{repo}/releases/download/{quote(tag, safe='')}/{quote(archive.name, safe='')}",
        f"{{{sparkle}}}edSignature": signature,
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
    })
    ET.indent(root)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("Usage: write-appcast.py Info.plist update.dmg tag signature appcast.xml")
    write_appcast(*sys.argv[1:])
