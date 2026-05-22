#!/usr/bin/env python3
"""Minimal ACSM upload server — served via HA ingress."""
import email.parser
import html
import http.server
import os
import pathlib

INPUT_DIR = os.environ.get("INPUT_DIR", "/share/calibre-dedrm/input")
PORT = int(os.environ.get("INGRESS_PORT", "8099"))

PAGE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Calibre DeDRM</title>
<style>
  body {{ font-family: sans-serif; max-width: 520px; margin: 40px auto; padding: 0 20px; }}
  h1 {{ font-size: 1.4em; margin-bottom: 4px; }}
  p {{ color: #555; margin: 0 0 16px; }}
  input[type=file] {{ display: block; margin: 12px 0; }}
  button {{ padding: 8px 22px; cursor: pointer; }}
  .msg {{ margin-top: 16px; padding: 10px 14px; border-radius: 4px; }}
  .ok  {{ background: #d4edda; color: #155724; }}
  .err {{ background: #f8d7da; color: #721c24; }}
</style>
</head>
<body>
<h1>Upload ACSM</h1>
<p>Select an <code>.acsm</code> file. It will be queued and decrypted within 30 seconds.</p>
<form method="post" enctype="multipart/form-data">
  <input type="file" name="acsm" accept=".acsm" required>
  <button type="submit">Upload</button>
</form>
{message}
</body>
</html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # suppress noisy access log

    def do_GET(self):
        self._html(200, "")

    def do_POST(self):
        ct = self.headers.get("Content-Type", "")
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = self.rfile.read(length)
            msg_bytes = f"Content-Type: {ct}\r\n\r\n".encode() + body
            msg = email.parser.BytesParser().parsebytes(msg_bytes)
            field = filename = data = None
            for part in msg.walk():
                if part.get_param("name", header="content-disposition") == "acsm":
                    filename = os.path.basename(part.get_filename() or "").strip()
                    data = part.get_payload(decode=True)
                    break
            if not filename or not data:
                raise ValueError("No file received.")
            if not filename.lower().endswith(".acsm"):
                raise ValueError("Only .acsm files are accepted.")
            dest = pathlib.Path(INPUT_DIR) / filename
            dest.write_bytes(data)
            msg_html = f'<div class="msg ok"><strong>{html.escape(filename)}</strong> queued for processing.</div>'
            self._html(200, msg_html)
        except Exception as exc:
            self._html(400, f'<div class="msg err">Error: {html.escape(str(exc))}</div>')

    def _html(self, code: int, message: str):
        body = PAGE.format(message=message).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    pathlib.Path(INPUT_DIR).mkdir(parents=True, exist_ok=True)
    with http.server.HTTPServer(("0.0.0.0", PORT), Handler) as srv:
        print(f">>> Upload server on port {PORT}", flush=True)
        srv.serve_forever()
