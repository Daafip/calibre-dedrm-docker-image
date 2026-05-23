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

ctx = ssl.create_default_context()
with smtplib.SMTP(host, port) as server:
    server.ehlo()
    server.starttls(context=ctx)
    server.login(user, password)
    server.sendmail(user, to_addr, msg.as_string())
