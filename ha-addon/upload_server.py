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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Calibre DeDRM</title>
<style>
  *, *::before, *::after {{ box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    background: #f0f2f5;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    margin: 0;
    padding: 20px;
  }}
  .card {{
    background: #fff;
    border-radius: 12px;
    box-shadow: 0 2px 16px rgba(0,0,0,.10);
    padding: 36px 40px 32px;
    width: 100%;
    max-width: 480px;
  }}
  .logo {{
    width: 48px; height: 48px;
    background: #03a9f4;
    border-radius: 10px;
    display: flex; align-items: center; justify-content: center;
    margin-bottom: 20px;
  }}
  .logo svg {{ fill: #fff; }}
  h1 {{ font-size: 1.35em; font-weight: 700; margin: 0 0 6px; color: #111; }}
  .sub {{ color: #777; font-size: .9em; margin: 0 0 28px; }}
  .drop-zone {{
    border: 2px dashed #c8cdd5;
    border-radius: 8px;
    padding: 36px 20px;
    text-align: center;
    cursor: pointer;
    transition: border-color .15s, background .15s;
    position: relative;
  }}
  .drop-zone:hover, .drop-zone.over {{ border-color: #03a9f4; background: #f0faff; }}
  .drop-zone input {{
    position: absolute; inset: 0; opacity: 0; cursor: pointer; width: 100%; height: 100%;
  }}
  .drop-icon {{ font-size: 2.2em; margin-bottom: 8px; }}
  .drop-label {{ color: #555; font-size: .95em; }}
  .drop-label strong {{ color: #03a9f4; }}
  .file-name {{
    margin-top: 10px; font-size: .88em; color: #333;
    background: #f0f2f5; border-radius: 4px; padding: 4px 10px;
    display: none;
  }}
  button {{
    margin-top: 20px;
    width: 100%;
    padding: 11px;
    background: #03a9f4;
    color: #fff;
    border: none;
    border-radius: 7px;
    font-size: 1em;
    font-weight: 600;
    cursor: pointer;
    transition: background .15s;
  }}
  button:hover {{ background: #0290d0; }}
  button:disabled {{ background: #a0d8f1; cursor: default; }}
  .msg {{
    margin-top: 20px;
    padding: 12px 16px;
    border-radius: 7px;
    font-size: .92em;
    line-height: 1.45;
  }}
  .ok  {{ background: #e8f5e9; color: #1b5e20; border-left: 4px solid #43a047; }}
  .err {{ background: #fdecea; color: #b71c1c; border-left: 4px solid #e53935; }}
</style>
</head>
<body>
<div class="card">
  <div class="logo">
    <svg xmlns="http://www.w3.org/2000/svg" height="28" viewBox="0 0 24 24" width="28">
      <path d="M19 9h-4V3H9v6H5l7 7 7-7zm-8 2V5h2v6h1.17L12 13.17 9.83 11H11zm-6 7h14v2H5v-2z"/>
    </svg>
  </div>
  <h1>Upload ACSM</h1>
  <p class="sub">Drop your library loan file — it will be decrypted within 30&nbsp;seconds.</p>
  <form method="post" enctype="multipart/form-data" id="form">
    <div class="drop-zone" id="zone">
      <input type="file" name="acsm" accept=".acsm" required id="picker">
      <div class="drop-icon">📂</div>
      <div class="drop-label"><strong>Choose file</strong> or drag &amp; drop here</div>
    </div>
    <div class="file-name" id="fname"></div>
    <button type="submit" id="btn">Upload</button>
  </form>
  {message}
</div>
<script>
  var picker = document.getElementById('picker');
  var zone   = document.getElementById('zone');
  var fname  = document.getElementById('fname');
  var btn    = document.getElementById('btn');
  picker.addEventListener('change', function() {{
    if (picker.files.length) {{
      fname.textContent = picker.files[0].name;
      fname.style.display = 'block';
    }}
  }});
  ['dragover','dragenter'].forEach(function(e) {{
    zone.addEventListener(e, function(ev) {{ ev.preventDefault(); zone.classList.add('over'); }});
  }});
  ['dragleave','drop'].forEach(function(e) {{
    zone.addEventListener(e, function() {{ zone.classList.remove('over'); }});
  }});
  document.getElementById('form').addEventListener('submit', function() {{
    btn.disabled = true; btn.textContent = 'Uploading…';
  }});
</script>
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
