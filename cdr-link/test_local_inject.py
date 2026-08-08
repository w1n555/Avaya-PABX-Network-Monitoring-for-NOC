"""Local inject of a fake customized-length record (no CM needed)."""
from __future__ import annotations

import socket
import sys
from pathlib import Path

# Build a 173-byte fake record matching CUSTOM layout
# date MMDDYY + time HHMM + sec-dur etc.
body = (
    "080826"  # date MMDDYY
    + " "
    + "1430"  # time
    + " "
    + "00120"  # sec-dur
    + " "
    + "9"  # cond
    + " "
    + "1401"  # code-used
    + " "
    + "    "  # code-dial
    + " "
    + ("85291234567".ljust(23))  # dialed
    + " "
    + ("2123".ljust(15))  # clg
    + " "
    + "0001"  # in-trk
    + " "
    + "0001"  # in-crt
    + " "
    + ("2123".ljust(15))  # calling
    + " "
    + "0002"  # out-crt
    + " "
    + "00000"  # ppm
    + " "
    + (" ".ljust(11))  # isdn
    + " "
    + "  "  # attd
    + " "
    + (" ".ljust(16))  # vdn
    + " "
    + (" ".ljust(15))  # acct
    + " "
    + (" ".ljust(13))  # auth
    + " "
    + "01"  # node
    + "\r\n"  # return + lf (2 bytes)
)
# adjust to exactly 173
if len(body) < 173:
    body = body[:-2] + (" " * (173 - len(body))) + "\r\n"
body = body[:173]
assert len(body) == 173, len(body)

host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9000
print(f"Sending {len(body)} bytes to {host}:{port}")
s = socket.create_connection((host, port), timeout=5)
s.sendall(body.encode("ascii"))
s.close()
print("OK — check cdr\\YYYYMMDD.TXT")
