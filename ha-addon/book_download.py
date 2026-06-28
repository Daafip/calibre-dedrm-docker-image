#!/usr/bin/env python3
"""Download the .acsm for a loaned onlinebibliotheek.nl book.

A loaned book's catalogue/detail page contains a download button:
    <a id="download" class="button primary"
       href="https://www.onlinebibliotheek.nl/catalogus/download/redirect?state=...">
The ``state`` is per-session, so it is extracted fresh from the detail page each
time. Following that redirect (authenticated) yields the Adobe .acsm fulfillment
token, which the existing pipeline turns into a DRM-free ePub.

Used by library_sensor.py; can also be run standalone for testing:
  KB_USERNAME=... KB_PASSWORD=... python3 book_download.py <catalogue-url>
"""
import os
import sys
import urllib.parse
import urllib.request
from html.parser import HTMLParser

from library_sensor import _BROWSER_HEADERS, _read_body


class BookNotAvailable(Exception):
    """Raised when a loaned book has no download option (read-online only,
    reserved, or expired) — i.e. it cannot be downloaded as an .acsm."""


def _encode_url(url):
    """Percent-encode non-ASCII characters in a URL so urllib can put it in the
    HTTP request line (book slugs contain accents, e.g. 'ik-ga-tóch-...')."""
    parts = urllib.parse.urlsplit(url)
    # safe="/%" / "...%" keeps already-encoded sequences and structural chars.
    path = urllib.parse.quote(parts.path, safe="/%:@!$&'()*+,;=~-._")
    query = urllib.parse.quote(parts.query, safe="/%:@!$&'()*+,;=~-._?")
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, query, parts.fragment))


class _DownloadLinkParser(HTMLParser):
    """Find the href of the <a id="download"> button on a book detail page."""

    def __init__(self):
        super().__init__()
        self.href = None

    def handle_starttag(self, tag, attrs):
        if tag != "a" or self.href:
            return
        d = dict(attrs)
        if d.get("id") == "download" and d.get("href"):
            self.href = d["href"]


def find_download_url(html):
    p = _DownloadLinkParser()
    p.feed(html)
    return p.href


def _filename_from_response(resp, fallback):
    cd = resp.headers.get("Content-Disposition", "")
    for part in cd.split(";"):
        part = part.strip()
        if part.lower().startswith("filename="):
            name = part.split("=", 1)[1].strip().strip('"')
            if name:
                return name
    return fallback


def download_acsm(opener, book_url, fallback_name="book.acsm"):
    """Return (filename, content_bytes) for the book's .acsm.
    Raises BookNotAvailable if the book has no download option."""
    req = urllib.request.Request(_encode_url(book_url), headers=dict(_BROWSER_HEADERS))
    with opener.open(req, timeout=30) as resp:
        html = _read_body(resp)

    dl_url = find_download_url(html)
    if not dl_url:
        raise BookNotAvailable("no download button on the catalogue page")
    if dl_url.startswith("/"):
        dl_url = "https://www.onlinebibliotheek.nl" + dl_url

    req = urllib.request.Request(_encode_url(dl_url), headers=dict(_BROWSER_HEADERS))
    with opener.open(req, timeout=60) as resp:
        # .acsm is small XML; read raw bytes (do not html-decode).
        content = resp.read()
        name = _filename_from_response(resp, fallback_name)

    head = content[:200].lstrip()
    if not (head.startswith(b"<?xml") or b"fulfillmentToken" in content[:2000] or
            b"<fulfillmentToken" in content[:2000] or name.lower().endswith(".acsm")):
        raise RuntimeError(
            f"downloaded content does not look like an .acsm ({len(content)} bytes, "
            f"starts with {head[:60]!r})"
        )
    if not name.lower().endswith(".acsm"):
        name += ".acsm"
    return name, content


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: KB_USERNAME=… KB_PASSWORD=… python3 book_download.py <catalogue-url>")
    book_url = sys.argv[1]
    user = os.environ.get("KB_USERNAME", "").strip()
    pw = os.environ.get("KB_PASSWORD", "")
    if not (user and pw):
        raise SystemExit("Set KB_USERNAME and KB_PASSWORD.")

    import kb_login
    jar, _ = kb_login.login(user, pw)
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    name, content = download_acsm(opener, book_url)
    out = sys.argv[2] if len(sys.argv) > 2 else name
    with open(out, "wb") as f:
        f.write(content)
    print(f">>> Saved {len(content)} bytes to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
