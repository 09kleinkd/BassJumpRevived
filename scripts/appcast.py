#!/usr/bin/env python3
"""Adds (or replaces) a release in appcast.xml, the Sparkle update feed.
Usage: appcast.py <version> <build> <zip> <edSignature> <minimumSystemVersion>"""
import os, sys, email.utils, re
version, build, zip_path, sig, min_os = sys.argv[1:6]
root = os.path.join(os.path.dirname(__file__), "..")
path = os.path.join(root, "appcast.xml")
url = f"https://github.com/09kleinkd/BassJumpRevived/releases/download/v{version}/{os.path.basename(zip_path)}"
item = f"""    <item>
      <title>BassJump Revived {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/09kleinkd/BassJumpRevived/releases/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{url}" length="{os.path.getsize(zip_path)}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>
"""
if os.path.exists(path):
    xml = open(path).read()
    xml = re.sub(r"    <item>\s*<title>BassJump Revived " + re.escape(version) + r"</title>.*?</item>\n", "", xml, flags=re.S)
else:
    xml = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BassJump Revived</title>
    <link>https://github.com/09kleinkd/BassJumpRevived</link>
    <language>en</language>
  </channel>
</rss>
"""
xml = xml.replace("    <language>en</language>\n", "    <language>en</language>\n" + item, 1)
open(path, "w").write(xml)
print(f"appcast.xml: added {version} ({build})")
