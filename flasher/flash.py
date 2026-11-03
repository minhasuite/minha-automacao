"""Gravador do MA: `probe <porta>` ou `flash <porta> <url> [sha256]`.

Imprime uma linha JSON no fim ({"type", "version"} ou {"error"}). O
supervisor confere a porta e o endereço antes; aqui só baixa, confere o hash
e chama o universal-silabs-flasher.
"""
import hashlib
import json
import re
import subprocess
import sys
import urllib.request

FLASHER = ["universal-silabs-flasher", "--device"]
DETECTED = re.compile(r"Detected (?:ApplicationType\.)?(\w+), version '([^' ]+)")


def last_line(out):
    lines = (out.stderr or out.stdout).strip().splitlines()
    return lines[-1] if lines else "sem resposta"


def probe(port):
    out = subprocess.run(FLASHER + [port, "probe"], capture_output=True, text=True, timeout=120)
    m = DETECTED.search(out.stdout + out.stderr)
    return {"type": m.group(1).lower(), "version": m.group(2)} if m else {"error": last_line(out)}


def flash(port, url, sha256=None):
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    if sha256 and hashlib.sha256(data).hexdigest() != sha256.lower():
        return {"error": "hash do firmware não confere"}
    with open("/tmp/firmware.gbl", "wb") as f:
        f.write(data)
    out = subprocess.run(FLASHER + [port, "flash", "--firmware", "/tmp/firmware.gbl"], capture_output=True, text=True, timeout=600)
    return probe(port) if out.returncode == 0 else {"error": last_line(out)}


if __name__ == "__main__":
    cmd, port, *rest = sys.argv[1:]
    print(json.dumps(probe(port) if cmd == "probe" else flash(port, *rest)), flush=True)
