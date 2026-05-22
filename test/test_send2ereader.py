#!/usr/bin/env python3
"""
Test the send2ereader upload flow (generate → upload → URL construction).

Usage:
    python3 test/test_send2ereader.py [base_url]

Default base_url: http://localhost:3001
Requires send2ereader running:
    docker compose -f docker-compose.test.yml up send2ereader
"""
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
import urllib.request


BASE_URL = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:3001"
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_EPUB = os.path.join(
    REPO_ROOT, "test-data", "books",
    "Afrika is besmettelijk - Steven van de Vijver.epub",
)


def push_to_send2ereader(epub_path: str, base_url: str) -> str:
    """
    Mirrors push_to_send2ereader() from ha-addon/run.sh using the same curl
    commands so this test exercises the real code path.
    Returns the download URL on success, empty string on failure.
    """
    cookie_file = tempfile.mktemp(suffix=".cookies")
    try:
        # Step 1: generate a server-registered code
        result = subprocess.run(
            ["curl", "-sf", "-c", cookie_file, "-X", "POST", f"{base_url}/generate"],
            capture_output=True, text=True,
        )
        code = result.stdout.strip()
        if not code or len(code) != 4:
            return ""

        # Step 2: upload with same cookie session — server returns plain text, check HTTP status
        result = subprocess.run(
            [
                "curl", "-sf", "-b", cookie_file,
                "-o", "/dev/null", "-w", "%{http_code}",
                "-F", f"key={code}",
                "-F", f"file=@{epub_path};type=application/epub+zip",
                f"{base_url}/upload",
            ],
            capture_output=True, text=True,
        )
        if result.stdout.strip() != "200":
            return ""

        # Step 3: construct download URL — server route is GET /:filename?key=CODE
        filename = os.path.basename(epub_path)
        encoded_name = urllib.parse.quote(filename, safe="")
        return f"{base_url}/{encoded_name}?key={code}"
    finally:
        if os.path.exists(cookie_file):
            os.unlink(cookie_file)


class TestSend2ereader(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        if not os.path.exists(TEST_EPUB):
            raise unittest.SkipTest(f"Test epub not found: {TEST_EPUB}")
        if subprocess.run(["which", "curl"], capture_output=True).returncode != 0:
            raise unittest.SkipTest("curl not found in PATH")
        try:
            urllib.request.urlopen(BASE_URL, timeout=3)
        except Exception as exc:
            raise unittest.SkipTest(
                f"send2ereader not reachable at {BASE_URL} — "
                "run: docker compose -f docker-compose.test.yml up send2ereader"
            ) from exc

    def test_url_structure(self):
        url = push_to_send2ereader(TEST_EPUB, BASE_URL)
        self.assertTrue(url, "Expected a non-empty download URL")
        parsed = urllib.parse.urlparse(url)
        params = urllib.parse.parse_qs(parsed.query)
        self.assertIn("key", params, f"URL missing ?key= param: {url}")
        self.assertEqual(len(params["key"][0]), 4, "Key should be 4 characters")
        self.assertNotIn(" ", url, f"URL contains unencoded spaces: {url}")
        self.assertIn("Afrika", url)

    def test_download_url_returns_200(self):
        url = push_to_send2ereader(TEST_EPUB, BASE_URL)
        self.assertTrue(url, "No URL returned from push_to_send2ereader")
        # Use curl to download: send2ereader matches the downloader UA against the
        # generator UA. curl was used in push_to_send2ereader, so it must be used
        # here too until the patched image (UA check removed) is deployed.
        result = subprocess.run(
            ["curl", "-sf", "-o", "/dev/null", "-w", "%{http_code}", url],
            capture_output=True, text=True,
        )
        self.assertEqual(result.stdout.strip(), "200", f"Download URL returned {result.stdout.strip()}: {url}")

    def test_unreachable_server_returns_empty(self):
        url = push_to_send2ereader(TEST_EPUB, "http://localhost:19999")
        self.assertEqual(url, "", "Expected empty string for unreachable server")


if __name__ == "__main__":
    print(f"Testing against {BASE_URL}\n")
    unittest.main(argv=[sys.argv[0]], verbosity=2)
