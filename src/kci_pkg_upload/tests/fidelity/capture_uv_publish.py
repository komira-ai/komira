#!/usr/bin/env python3
"""Capture what `uv publish` SENDS, against a LOCAL loopback recorder only.

WHY. `kci_pkg_upload`'s legacy upload is meant to be the request `uv publish`
sends, byte for byte. That is a claim about another program's wire format, so it
is MEASURED, not transcribed from documentation: this script builds small,
deterministic probe wheels, runs the real `uv publish` at a recorder bound to
127.0.0.1, and writes what arrived as committed fixtures. The welded Mojo test
`tests/test_pkg_upload_uv_fidelity.mojo` then builds the same upload with the
Mojo client and compares it with the recording, byte for byte, after putting the
client's boundary where uv's random one was (both are 67 characters, so even the
Content-Length agrees).

NO REAL REGISTRY IS CONTACTED. The publish URL is `http://127.0.0.1:<ephemeral>/`,
the credential is a fixed placeholder that is not a token of any index, uv's own
configuration and keyring are disabled, and trusted publishing is set to never.

FIXTURES (per case, in this directory):
  <case>.whl       the probe wheel uv uploaded (deterministic: fixed timestamps,
                   sorted members, stored, not deflated)
  <case>.METADATA  that wheel's `.dist-info/METADATA` — the text the Mojo client
                   takes as `upload_meta` (it has no archive reader)
  <case>.request   what uv sent: a text header (`KEY value` lines, a blank line)
                   followed by the RAW request body

  The Authorization header is NOT stored. The script asserts uv sent exactly
  `Basic base64("__token__:" + PLACEHOLDER)`, and the Mojo test asserts its own
  header is the same function of the same placeholder.

USAGE
  capture_uv_publish.py --write   re-capture and overwrite the fixtures
  capture_uv_publish.py --check   re-capture and compare with the committed ones
                                  (exit 0 same, 1 DIFFERENT, 3 cannot measure)
  capture_uv_publish.py --selftest  the parts that need no uv (exit 0 / 1)

  --check needs `uv` on PATH. Without it the answer is exit 3, never a pass: a
  fidelity check that did not run has measured nothing.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

PLACEHOLDER_PASSWORD = "fidelity-probe-placeholder-not-a-credential"
USERNAME = "__token__"
DIST = "komira_fidelity_probe"
VERSION = "1.1.7"
WHEEL_NAME = f"{DIST}-{VERSION}-py3-none-linux_x86_64.whl"

# The two cases. `minimal` is the shape the repo's wheel rule writes (name,
# version, summary, Requires-Dist pins). `rich` carries every single-valued and
# multi-valued field the upload form maps, a body description, raw UTF-8, and
# the value shapes uv transforms (Project-URL whitespace) or keeps (trailing
# whitespace, Keywords spacing).
CASES: dict[str, str] = {
    "minimal": (
        "Metadata-Version: 2.1\n"
        f"Name: {DIST}\n"
        f"Version: {VERSION}\n"
        f"Summary: Komira Mojo package `{DIST}`.\n"
        "Requires-Dist: mojo ==1.0.0\n"
        f"Requires-Dist: komira_protobuf =={VERSION}\n"
        "\n"
    ),
    "rich": (
        "Metadata-Version: 2.1\n"
        f"Name: {DIST}\n"
        f"Version: {VERSION}\n"
        "Summary: Komira probe — café\n"
        "Home-page: https://example.invalid/komira\n"
        "Download-URL: https://example.invalid/dl\n"
        "Author: Komira Maintainers\n"
        "Author-email: Komira <maintainers@example.invalid>\n"
        "Maintainer: Komira Maintainers\n"
        "Maintainer-email: maintainers@example.invalid\n"
        "License: Apache-2.0  \n"
        "Keywords: mojo, komira ,probe\n"
        "Platform: linux\n"
        "Classifier: Programming Language :: Python :: 3\n"
        "Classifier: License :: OSI Approved :: Apache Software License\n"
        "Dynamic: License\n"
        "License-File: LICENSE\n"
        "Project-URL: Source,https://example.invalid/src\n"
        "Project-URL: Docs ,  https://example.invalid/docs\n"
        "Requires-Python: >=3.10\n"
        "Description-Content-Type: text/markdown\n"
        "Provides-Extra: docs\n"
        "Requires-Dist: mojo ==1.0.0\n"
        f"Requires-Dist: komira_protobuf =={VERSION}\n"
        "Requires-Dist: sphinx ; extra == 'docs'\n"
        "Requires-External: libc\n"
        "Obsoletes-Dist: komira_old_probe\n"
        "Provides-Dist: komira_fidelity_alias\n"
        "\n"
        f"# {DIST}\n\nA probe wheel. It is never uploaded anywhere but a loopback recorder.\n"
    ),
    # No body: the description comes from the `Description` HEADER instead.
    "description_header": (
        "Metadata-Version: 2.1\n"
        f"Name: {DIST}\n"
        f"Version: {VERSION}\n"
        "Summary: a probe whose description is a header\n"
        "Description: One line of description, carried as a header.\n"
        "\n"
    ),
}


def make_wheel(meta: str) -> bytes:
    """A minimal, DETERMINISTIC wheel carrying `meta` as its METADATA."""
    info = f"{DIST}-{VERSION}.dist-info"
    files = {
        f"{DIST}/__init__.py": b"",
        f"{info}/METADATA": meta.encode("utf-8"),
        f"{info}/WHEEL": (
            b"Wheel-Version: 1.0\nGenerator: komira-fidelity-probe\n"
            b"Root-Is-Purelib: false\nTag: py3-none-linux_x86_64\n\n"
        ),
    }
    record = ""
    for name, data in files.items():
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
        record += f"{name},sha256={digest.decode()},{len(data)}\n"
    record += f"{info}/RECORD,,\n"
    files[f"{info}/RECORD"] = record.encode()
    buf = __import__("io").BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for name in sorted(files):
            zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            zi.external_attr = 0o644 << 16
            z.writestr(zi, files[name])
    return buf.getvalue()


class _Recorder(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    captured: list[dict] = []

    def do_POST(self) -> None:  # noqa: N802 (http.server's spelling)
        te = self.headers.get("Transfer-Encoding", "")
        if "chunked" in te.lower():
            body = b""
            while True:
                size = int(self.rfile.readline().strip().split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        _Recorder.captured.append(
            {
                "method": self.command,
                "path": self.path,
                "headers": list(self.headers.items()),
                "chunked": "chunked" in te.lower(),
                "body": body,
            }
        )
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, *args) -> None:  # silence
        pass


class _QuietServer(http.server.ThreadingHTTPServer):
    """uv closes the connection by RESET after reading the answer; that is not
    a recording failure, so it is not printed as one."""

    def handle_error(self, request, client_address) -> None:
        if isinstance(sys.exc_info()[1], ConnectionResetError):
            return
        super().handle_error(request, client_address)


def _header(headers: list[tuple[str, str]], name: str) -> str:
    for k, v in headers:
        if k.lower() == name.lower():
            return v
    return ""


def capture(uv: str, meta: str, work: Path) -> tuple[bytes, dict]:
    """Run `uv publish` for one probe wheel; return (wheel bytes, capture)."""
    dist = work / "dist"
    if dist.exists():
        shutil.rmtree(dist)
    dist.mkdir(parents=True)
    wheel = make_wheel(meta)
    (dist / WHEEL_NAME).write_bytes(wheel)
    _Recorder.captured = []
    srv = _QuietServer(("127.0.0.1", 0), _Recorder)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    env = {k: v for k, v in os.environ.items() if not k.startswith("UV_")}
    env["UV_NO_CONFIG"] = "1"
    env["UV_KEYRING_PROVIDER"] = "disabled"
    env["HOME"] = str(work)  # no user-level uv config, cache or credentials
    env["XDG_CONFIG_HOME"] = str(work / "xdg")
    env["UV_CACHE_DIR"] = str(work / "uv-cache")
    try:
        r = subprocess.run(
            [
                uv,
                "publish",
                "--no-config",
                "--trusted-publishing",
                "never",
                "--publish-url",
                f"http://127.0.0.1:{port}/legacy/",
                "--username",
                USERNAME,
                "--password",
                PLACEHOLDER_PASSWORD,
                str(dist / WHEEL_NAME),
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )
    finally:
        srv.shutdown()
        srv.server_close()
    if r.returncode != 0:
        raise RuntimeError(f"uv publish exited {r.returncode}: {r.stderr.strip()[-800:]}")
    if len(_Recorder.captured) != 1:
        raise RuntimeError(f"expected ONE request at the recorder, got {len(_Recorder.captured)}")
    return wheel, _Recorder.captured[0]


def render_request(cap: dict) -> bytes:
    """The committed `.request` bytes for one capture (see the module doc)."""
    headers = cap["headers"]
    ctype = _header(headers, "Content-Type")
    prefix = "multipart/form-data; boundary="
    if not ctype.startswith(prefix):
        raise RuntimeError(f"uv's Content-Type is not multipart with a boundary: {ctype!r}")
    boundary = ctype[len(prefix):]
    want_auth = "Basic " + base64.b64encode(
        f"{USERNAME}:{PLACEHOLDER_PASSWORD}".encode()
    ).decode()
    got_auth = _header(headers, "Authorization")
    if got_auth != want_auth:
        raise RuntimeError("uv's Authorization is not Basic __token__:<placeholder>")
    if cap["chunked"]:
        raise RuntimeError("uv sent the body CHUNKED; the fixture format assumes Content-Length")
    body = cap["body"]
    if str(len(body)) != _header(headers, "Content-Length"):
        raise RuntimeError("the recorded body length disagrees with Content-Length")
    head = (
        f"METHOD {cap['method']}\n"
        f"PATH {cap['path']}\n"
        f"CONTENT-TYPE {ctype}\n"
        f"ACCEPT {_header(headers, 'Accept')}\n"
        f"BOUNDARY {boundary}\n"
        f"FILENAME {WHEEL_NAME}\n"
        f"BODY-LENGTH {len(body)}\n"
        "\n"
    )
    return head.encode() + body


def normalized(request: bytes) -> bytes:
    """A `.request` with its (random) boundary replaced by a fixed token, for
    comparing two captures of the same wheel."""
    head, _, _ = request.partition(b"\n\n")
    boundary = b""
    for line in head.split(b"\n"):
        if line.startswith(b"BOUNDARY "):
            boundary = line[len(b"BOUNDARY "):]
    if not boundary:
        raise RuntimeError("a .request with no BOUNDARY line")
    return request.replace(boundary, b"<BOUNDARY>")


def capture_all(uv: str) -> dict[str, bytes]:
    out: dict[str, bytes] = {}
    with tempfile.TemporaryDirectory(prefix="uv-fidelity-") as tmp:
        for case, meta in CASES.items():
            wheel, cap = capture(uv, meta, Path(tmp) / case)
            out[f"{case}.whl"] = wheel
            out[f"{case}.METADATA"] = meta.encode("utf-8")
            out[f"{case}.request"] = render_request(cap)
    return out


def selftest() -> int:
    """What can be checked without uv: the wheels are deterministic, the
    normaliser erases exactly the boundary, and the committed fixtures are
    internally consistent (each .request's file part IS the committed .whl)."""
    failures = 0

    def check(ok: bool, what: str) -> None:
        nonlocal failures
        print(("  ok   " if ok else "  FAIL ") + what)
        if not ok:
            failures += 1

    for case, meta in CASES.items():
        check(make_wheel(meta) == make_wheel(meta), f"{case}: the probe wheel is deterministic")
        whl = HERE / f"{case}.whl"
        req = HERE / f"{case}.request"
        md = HERE / f"{case}.METADATA"
        if not (whl.exists() and req.exists() and md.exists()):
            check(False, f"{case}: committed fixtures exist")
            continue
        check(whl.read_bytes() == make_wheel(meta), f"{case}: committed .whl == the generator's")
        check(md.read_bytes() == meta.encode(), f"{case}: committed .METADATA == the generator's")
        body = req.read_bytes().partition(b"\n\n")[2]
        check(whl.read_bytes() in body, f"{case}: the recorded body carries the committed wheel")
        n = normalized(req.read_bytes())
        check(b"<BOUNDARY>" in n and n.count(b"<BOUNDARY>") >= 3, f"{case}: normaliser finds the boundary")
    fake = b"METHOD POST\nBOUNDARY abc\n\n--abc\r\nx\r\n--abc--\r\n"
    check(normalized(fake) == b"METHOD POST\nBOUNDARY <BOUNDARY>\n\n--<BOUNDARY>\r\nx\r\n--<BOUNDARY>--\r\n",
          "normaliser replaces every boundary occurrence")
    print(f"capture_uv_publish selftest: {'GREEN' if failures == 0 else f'RED ({failures})'}")
    return 0 if failures == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    g.add_argument("--selftest", action="store_true")
    ap.add_argument("--uv", default=shutil.which("uv") or "", help="the uv binary (default: PATH)")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.uv:
        print("CANNOT MEASURE: no `uv` on PATH (pass --uv). A check that did not run is not a pass.",
              file=sys.stderr)
        return 3
    version = subprocess.run([args.uv, "--version"], capture_output=True, text=True).stdout.strip()
    try:
        fresh = capture_all(args.uv)
    except Exception as e:  # noqa: BLE001 — every failure here is "cannot measure"
        print(f"CANNOT MEASURE ({version}): {e}", file=sys.stderr)
        return 3
    if args.write:
        for name, data in fresh.items():
            (HERE / name).write_bytes(data)
        print(f"wrote {len(fresh)} fixtures from {version}")
        return 0
    diffs = []
    for name, data in fresh.items():
        path = HERE / name
        if not path.exists():
            diffs.append(f"{name}: not committed")
            continue
        old = path.read_bytes()
        same = normalized(old) == normalized(data) if name.endswith(".request") else old == data
        if not same:
            diffs.append(f"{name}: {version} now sends something different")
    if diffs:
        print("FIDELITY DRIFT — uv's request is no longer what the fixtures (and so the Mojo client) "
              "send:\n  " + "\n  ".join(diffs), file=sys.stderr)
        return 1
    print(f"uv fidelity fixtures reproduce under {version}: {len(fresh)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
