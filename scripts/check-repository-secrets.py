#!/usr/bin/env python3
"""Conservative credential guard. Report filenames only, never matching values."""
import base64
import json
from pathlib import Path
import re
import subprocess

patterns = [re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+[A-Za-z0-9+/=\r\n]{64,}-----END'),
            re.compile(rb'\b(?:sb_secret_|ghp_|github_pat_|sk_live_)[A-Za-z0-9_]{20,}')]
files = subprocess.check_output(['git','ls-files','-co','--exclude-standard','-z']).decode().split('\0')
hits = set()
for name in set(files):
    if not name or not Path(name).is_file(): continue
    data = Path(name).read_bytes()
    if any(p.search(data) for p in patterns): hits.add(name)
    for match in re.finditer(rb'eyJ[A-Za-z0-9_-]+\.(eyJ[A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+', data):
        try:
            raw = match.group(1)
            payload = json.loads(base64.urlsafe_b64decode(raw+b'='*(-len(raw)%4)))
            if payload.get('role') == 'service_role': hits.add(name)
        except (ValueError, UnicodeError): pass
if hits:
    raise SystemExit('Potential committed credentials in: '+', '.join(sorted(hits)))
print('PASS: repository credential-pattern scan (not a substitute for credential rotation or independent scanning)')
