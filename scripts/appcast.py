#!/usr/bin/env python3
"""Writes the Mac app's Sparkle appcast (updates/appcast.xml, its SUFeedURL): the newest release, which installed
copies offer as an update once a day, checked against the EdDSA key in their Info.plist.

    appcast.py <version> <build> <dmg> <sparkle.txt> <notes.md> <out.xml>

<sparkle.txt> is what Sparkle's sign_update printed for the DMG (sparkle:edSignature="…" length="…"). The download is
the release's Murmur-<version>.dmg on GitHub. The notes (scripts/release-notes/<version>.md) become the update window's
text: paragraphs, and lines starting with "- " as a list.
"""
import datetime
import html
import re
import sys
from pathlib import Path

REPO = "shubhamsWEB/murmur-app"


def notes_html(markdown):
    out, items = [], []
    for line in markdown.strip().splitlines():
        line = line.strip()
        bullet = re.match(r"^[-*]\s+(.*)", line)
        if bullet:
            items.append(f"<li>{inline(bullet.group(1))}</li>")
            continue
        if items:
            out.append("<ul>" + "".join(items) + "</ul>")
            items = []
        if line.startswith("#"):
            out.append(f"<h3>{inline(line.lstrip('#').strip())}</h3>")
        elif line:
            out.append(f"<p>{inline(line)}</p>")
    if items:
        out.append("<ul>" + "".join(items) + "</ul>")
    return "\n".join(out)


def inline(text):
    text = html.escape(text, quote=False)
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)


def main():
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    version, build, dmg, signed, notes, out = sys.argv[1:]
    signature = Path(signed).read_text()
    ed = re.search(r'sparkle:edSignature="([^"]+)"', signature)
    length = re.search(r'length="(\d+)"', signature)
    if not ed or not length:
        sys.exit(f"no signature in {signed}: {signature!r}")
    url = f"https://github.com/{REPO}/releases/download/v{version}/{Path(dmg).name}"
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    body = notes_html(Path(notes).read_text(encoding="utf-8"))
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Murmur</title>
    <link>https://usemurmur.live/</link>
    <description>Murmur's updates</description>
    <language>en</language>
    <item>
      <title>Murmur {html.escape(version)}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{body}]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" sparkle:edSignature="{ed.group(1)}" length="{length.group(1)}"/>
    </item>
  </channel>
</rss>
"""
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_text(xml, encoding="utf-8")
    print(f"{out}: Murmur {version} (build {build})")


if __name__ == "__main__":
    main()
