#!/usr/bin/env python3
"""Automated login to onlinebibliotheek.nl via KB's iWelcome/OneWelcome SSO.

The account pages are protected by OneWelcome's "UIC" login at login.kb.nl. This
replicates the browser flow with plain HTTP so the bookshelf can be read from a
stored username + password (no browser, no manual cookie).

Flow (reverse-engineered from the login SPA, login/api/v2/authenticate):
  0. GET the bookshelf  -> 302 to login.kb.nl/si/login?...&goto=<authorize-url>
  1. GET  authenticate  (Goto-Url: <goto>)            -> starts the transaction
  2. POST authenticate  {module:UsernameAndPassword,  -> validates credentials
                         definition:{username,password}}
  3. follow the success redirect through OAuth authorize -> callback sets the
     authenticated TDP session on onlinebibliotheek.nl
  4. GET the bookshelf again -> authenticated HTML

This is BEST EFFORT and verbose on purpose: run it locally with your credentials
and read the step-by-step log. The exact success/redirect shape can vary, so the
logging is there to let us adjust steps 2-3 quickly.

Usage:
  KB_USERNAME=... KB_PASSWORD=... python3 kb_login.py
"""
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# Reuse the browser headers, body reader and parser from the sensor module.
from library_sensor import (
    BOOKSHELF_URL,
    _BROWSER_HEADERS,
    _read_body,
    looks_authenticated,
    parse_books,
)

LOGIN_ORIGIN = "https://login.kb.nl"
LOGIN_BASE = LOGIN_ORIGIN + "/si"
AUTHENTICATE_URL = LOGIN_BASE + "/login/api/v2/authenticate"
AUTHORIZE_URL = LOGIN_BASE + "/auth/oauth2.0/v1/authorize"
USERNAME_PASSWORD_MODULE = "UsernameAndPassword"

# OAuth client params observed in the redirect from the bookshelf.
OAUTH_CLIENT_ID = "tdpweb"
OAUTH_SCOPE = "profile"
OAUTH_REDIRECT_URI = "https://www.onlinebibliotheek.nl/account/boekenplank.logged.in.html"


def log(msg):
    print(f">>> {msg}", file=sys.stderr)


def _new_opener():
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    return opener, jar


def _open(opener, url, *, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={**_BROWSER_HEADERS, **(headers or {})})
    try:
        resp = opener.open(req, timeout=30)
        body = _read_body(resp)
        log(f"{method or ('POST' if data else 'GET')} {url.split('?')[0]} -> "
            f"HTTP {resp.status}, {len(body)} bytes, final={resp.geturl().split('?')[0]}")
        return resp, body
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        log(f"{method or 'GET'} {url.split('?')[0]} -> HTTP {e.code} ERROR, {len(body)} bytes")
        return e, body


def _extract_goto(final_url):
    qs = urllib.parse.parse_qs(urllib.parse.urlsplit(final_url).query)
    return (qs.get("goto") or [None])[0]


def _build_authorize_url():
    # Note: a fresh, unguessable state per login.
    import uuid
    params = {
        "client_id": OAUTH_CLIENT_ID,
        "scope": OAUTH_SCOPE,
        "response_type": "code",
        "state": str(uuid.uuid4()),
        "redirect_uri": OAUTH_REDIRECT_URI,
    }
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(params)


def login(username, password):
    """Return (jar, bookshelf_html) on success. Raises RuntimeError otherwise."""
    opener, jar = _new_opener()

    # Step 0 — hit the bookshelf to be redirected to the login app; capture goto.
    resp, _ = _open(opener, BOOKSHELF_URL)
    final = resp.geturl()
    goto = _extract_goto(final)
    if goto:
        log(f"captured goto from redirect")
    else:
        goto = _build_authorize_url()
        log("no goto in redirect — initialising authorize URL ourselves")
        _open(opener, goto)  # establishes the auth transaction context

    auth_headers = {"Accept": "application/json", "Goto-Url": goto,
                    "Referer": LOGIN_BASE + "/login", "Origin": LOGIN_ORIGIN}

    # Step 1 — start the authentication transaction.
    resp, body = _open(opener, AUTHENTICATE_URL, headers=auth_headers)
    start = _as_json(body, "authenticate(start)")

    # Step 2 — submit username + password.
    payload = json.dumps({
        "module": USERNAME_PASSWORD_MODULE,
        "definition": {"username": username, "password": password},
    }).encode("utf-8")
    resp, body = _open(opener, AUTHENTICATE_URL, data=payload,
                       headers={**auth_headers, "Content-Type": "application/json"},
                       method="POST")
    result = _as_json(body, "authenticate(credentials)")
    _check_for_2fa(result)

    # Step 3 — follow the success redirect to complete OAuth and set the session.
    redirect = _find_redirect(result) or goto
    log(f"following post-login redirect")
    _open(opener, redirect)

    # Step 4 — fetch the bookshelf, now authenticated.
    resp, html = _open(opener, BOOKSHELF_URL)
    if not looks_authenticated(html):
        raise RuntimeError(
            "login flow finished but bookshelf still not authenticated — "
            "inspect the step log above (response shape may differ)."
        )
    log("authenticated — bookshelf reached.")
    return jar, html


def _as_json(body, label):
    try:
        data = json.loads(body)
        keys = list(data) if isinstance(data, dict) else f"({type(data).__name__})"
        log(f"{label}: JSON keys = {keys}")
        return data
    except ValueError:
        log(f"{label}: non-JSON response (first 200 chars): {body[:200]!r}")
        return {}


def _check_for_2fa(result):
    blob = json.dumps(result).lower()
    if any(k in blob for k in ("twofa", "otp", "totp", "qrcode", "push", "verification")):
        log("WARNING: response mentions 2FA/OTP — the account may require a second "
            "factor, which this HTTP-only flow cannot satisfy.")


def _find_redirect(result):
    if not isinstance(result, dict):
        return None
    for key in ("redirectUrl", "redirect_uri", "successUrl", "location",
                "gotoUrl", "goto", "continueUrl", "url"):
        val = result.get(key)
        if isinstance(val, str) and val.startswith("http"):
            return val
    return None


def main():
    user = os.environ.get("KB_USERNAME", "").strip()
    pw = os.environ.get("KB_PASSWORD", "")
    if not user or not pw:
        raise SystemExit("Set KB_USERNAME and KB_PASSWORD environment variables.")
    jar, html = login(user, pw)
    books = parse_books(html)
    log(f"Found {len(books)} loaned book(s):")
    for b in books:
        print(f"    - {b['title']} — {b.get('author') or '?'} "
              f"({b.get('format') or '?'}, due {b.get('due_raw') or '?'})")
    print(json.dumps(books, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
