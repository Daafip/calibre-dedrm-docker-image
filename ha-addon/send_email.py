#!/usr/bin/env python3
"""Send an ePub as an email attachment via SMTP/STARTTLS.

Usage: SMTP_HOST=... SMTP_PORT=... SMTP_USER=... SMTP_PASS=... python3 send_email.py <to> <epub_path>
"""
import os
import ssl
import smtplib
import sys
from email import encoders
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

to_addr, epub_path = sys.argv[1], sys.argv[2]

host = os.environ["SMTP_HOST"]
port = int(os.environ.get("SMTP_PORT", "587"))
user = os.environ["SMTP_USER"]
password = os.environ["SMTP_PASS"]

filename = os.path.basename(epub_path)
subject = filename[:-5] if filename.lower().endswith(".epub") else filename

# File size check — warn early rather than fail mid-transfer
try:
    size_mb = os.path.getsize(epub_path) / 1024 / 1024
except OSError as e:
    print(f"ERROR: Cannot read epub file: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  File size: {size_mb:.1f} MB", file=sys.stderr)
if size_mb > 25:
    print(f"  WARNING: File is {size_mb:.1f} MB — many SMTP providers reject attachments over 25 MB", file=sys.stderr)

msg = MIMEMultipart()
msg["From"] = user
msg["To"] = to_addr
msg["Subject"] = subject
msg.attach(MIMEText("Your book is attached."))

with open(epub_path, "rb") as f:
    part = MIMEBase("application", "epub+zip")
    part.set_payload(f.read())
    encoders.encode_base64(part)
    part.add_header("Content-Disposition", "attachment", filename=filename)
    msg.attach(part)

try:
    ctx = ssl.create_default_context()
    with smtplib.SMTP(host, port, timeout=30) as server:
        server.ehlo()
        server.starttls(context=ctx)
        server.ehlo()
        server.login(user, password)
        server.sendmail(user, to_addr, msg.as_string())
except smtplib.SMTPAuthenticationError as e:
    print(f"ERROR: SMTP authentication failed — check smtp_user / smtp_password (server said: {e.smtp_error.decode(errors='replace') if isinstance(e.smtp_error, bytes) else e})", file=sys.stderr)
    sys.exit(1)
except smtplib.SMTPRecipientsRefused as e:
    print(f"ERROR: Recipient refused by server: {e.recipients}", file=sys.stderr)
    sys.exit(1)
except smtplib.SMTPDataError as e:
    print(f"ERROR: Server rejected message data (code {e.smtp_code}) — likely too large or policy block: {e.smtp_error}", file=sys.stderr)
    sys.exit(1)
except smtplib.SMTPException as e:
    print(f"ERROR: SMTP error: {e}", file=sys.stderr)
    sys.exit(1)
except ssl.SSLError as e:
    print(f"ERROR: TLS/SSL error — server may not support STARTTLS on port {port}: {e}", file=sys.stderr)
    sys.exit(1)
except OSError as e:
    print(f"ERROR: Could not connect to {host}:{port} — {e}", file=sys.stderr)
    sys.exit(1)
