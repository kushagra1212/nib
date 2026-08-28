#!/usr/bin/env python3
"""Probe harper-ls over LSP stdio to confirm it publishes diagnostics.

Sequences the handshake the way a real LSP client does: send `initialize`,
wait for its response, then `initialized`, then `didOpen`. Sending all three
in one flush races the server's own init and it silently drops the document.

Run: python3 Scripts/probe_harper.py
Exits non-zero if no diagnostics come back for known-bad text.
"""
import json
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARPER = os.path.join(HERE, "vendor", "harper-ls")
URI = "file:///private/tmp/nib-probe.md"
TEXT = "Their is many erors here. This sentance are wrong.\n"

# harper-ls refuses to lint unless the settings object it pulls has this key.
HARPER_SETTINGS = {
    "linters": {},
    "codeActions": {"forceStable": False},
    "markdown": {"IgnoreLinkTitle": False},
    "diagnosticSeverity": "hint",
    "isolateEnglish": False,
    "dialect": "American",
    "maxFileLength": 120000,
}


def frame(payload: dict) -> bytes:
    body = json.dumps(payload).encode()
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


class Server:
    def __init__(self, path):
        self.proc = subprocess.Popen(
            [path, "--stdio"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.messages = []
        self.errors = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        buf = b""
        while True:
            c = self.proc.stdout.read(1)
            if not c:
                return
            buf += c
            if not buf.endswith(b"\r\n\r\n"):
                continue
            length = None
            for line in buf.decode(errors="replace").split("\r\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            buf = b""
            if length is None:
                continue
            body = b""
            while len(body) < length:
                more = self.proc.stdout.read(length - len(body))
                if not more:
                    return
                body += more
            try:
                self.messages.append(json.loads(body))
            except json.JSONDecodeError:
                pass

    def _read_stderr(self):
        for line in self.proc.stderr:
            self.errors.append(line)

    def send(self, payload):
        self.proc.stdin.write(frame(payload))
        self.proc.stdin.flush()

    def wait_for(self, pred, timeout=10.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            for m in list(self.messages):
                if pred(m):
                    return m
            time.sleep(0.03)
        return None

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def stderr_text(self):
        return b"".join(self.errors).decode(errors="replace")


def main() -> int:
    if not os.path.exists(HARPER):
        print(f"FAIL: {HARPER} missing", file=sys.stderr)
        return 1

    srv = Server(HARPER)
    srv.send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "processId": os.getpid(),
            "rootUri": "file:///private/tmp",
            "workspaceFolders": [{"uri": "file:///private/tmp", "name": "tmp"}],
            "capabilities": {
                "textDocument": {"publishDiagnostics": {}},
                "workspace": {"configuration": True},
            },
        },
    })
    if srv.wait_for(lambda m: m.get("id") == 1) is None:
        print("FAIL: no initialize response", file=sys.stderr)
        srv.stop()
        return 1

    srv.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    time.sleep(0.3)
    srv.send({
        "jsonrpc": "2.0", "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": URI, "languageId": "markdown", "version": 1, "text": TEXT
            }
        },
    })

    start = time.time()
    # harper-ls pulls settings before it will lint, and rejects a reply that
    # lacks the "harper-ls" key outright. Answer requests as they arrive.
    hit = None
    answered = set()
    deadline = time.time() + 20
    while time.time() < deadline and hit is None:
        for m in list(srv.messages):
            mid = m.get("id")
            if m.get("method") == "workspace/configuration" and mid not in answered:
                answered.add(mid)
                items = m.get("params", {}).get("items", []) or [{}]
                srv.send({
                    "jsonrpc": "2.0", "id": mid,
                    "result": [{"harper-ls": HARPER_SETTINGS} for _ in items],
                })
            elif m.get("method") == "client/registerCapability" and mid not in answered:
                answered.add(mid)
                srv.send({"jsonrpc": "2.0", "id": mid, "result": None})
            elif m.get("method") == "textDocument/publishDiagnostics":
                hit = m
                break
        time.sleep(0.03)

    elapsed = time.time() - start
    seen = sorted({m.get("method") or f"resp:{m.get('id')}" for m in srv.messages})
    err = srv.stderr_text().strip()

    print(f"methods seen: {seen}")
    if err:
        print(f"stderr: {err[:500]}")
    if hit is None:
        print(f"FAIL: no diagnostics after {elapsed:.1f}s", file=sys.stderr)
        srv.stop()
        return 1

    diags = hit["params"]["diagnostics"]
    print(f"PASS: {len(diags)} diagnostics in {elapsed:.2f}s")
    for d in diags:
        r = d["range"]
        print(
            f'  L{r["start"]["line"]}:{r["start"]["character"]}-'
            f'{r["end"]["character"]} :: {d.get("message")}'
        )

    # The panel needs replacement text, which lives in code actions, not in the
    # diagnostics themselves. Confirm we can pull edits for the first one.
    first = diags[0]
    srv.send({
        "jsonrpc": "2.0", "id": 100, "method": "textDocument/codeAction",
        "params": {
            "textDocument": {"uri": URI},
            "range": first["range"],
            "context": {"diagnostics": [first]},
        },
    })
    resp = srv.wait_for(lambda m: m.get("id") == 100, 10)
    if resp is None or not resp.get("result"):
        print("WARN: no code actions returned; one-click fixes unavailable")
        srv.stop()
        return 1

    print(f'code actions for {first["message"]!r}:')
    for action in resp["result"]:
        title = action.get("title")
        edits = []
        changes = (action.get("edit") or {}).get("changes") or {}
        for _uri, edit_list in changes.items():
            edits += [e.get("newText") for e in edit_list]
        print(f"  {title!r} -> edits={edits}")
    srv.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
