"""cpython_peer.py -- a TLS peer of komira's TLS built on CPython's `ssl`
module (OpenSSL), for the tests of komira_tls_interop_e2e (see BUCK).

Run by a test with the pinned interpreter only
(komira//third_party/python:cpython), as `bin/python3.13 -I -S
cpython_peer.py <mode> <flags>`, from the test's working directory, where the
certificates are staged (cpython.mojo). It imports nothing but the standard
library.

    server --cert C --key K --version V --alpn P1,P2
        Listen on 127.0.0.1, on a port the kernel picks, and print
        `Listening on port <n>` on stdout. Accept one connection; select ALPN
        by `--alpn`, the server's preference (OpenSSL's SSL_select_next_proto:
        the first of the server's protocols the client offers, none when no
        protocol is shared). After the handshake print the report (below) on
        stderr, read one line, answer with the report, then
        `pong from cpython`, and wait for the client's close_notify.

    client --port N --ca CA --server-name S --version V --alpn P1,P2
        Connect to 127.0.0.1:<n> and verify the server against the one root
        `--ca` and the name S (ssl.create_default_context: CERT_REQUIRED,
        hostname check, VERIFY_X509_STRICT). Offer `--alpn` in that order.
        After the handshake print the report on stderr, send
        `ping from cpython`, read until the server's close_notify, and print
        what was read on stdout, exactly.

V is `tls1.3` or `tls1.2`: the context's minimum and maximum version. The
report has the shape of bssl's (bssl.mojo), so `parse_report` reads both:

    Connected.
      Version: TLSv1.3
      Cipher: TLS_AES_256_GCM_SHA384
      ALPN protocol: h2

The cipher suite is OpenSSL's name for it, which is also s2n's (komira's
`negotiated_cipher()`). Every socket operation has a 10 s timeout. Both
sides wrap with `suppress_ragged_eofs=False`, so a peer that closes its
socket without close_notify makes `recv` raise (ssl.SSLEOFError) rather than
return b"". Exit 0 when the exchange completed; 3 when the connection (the
server's accept, the client's connect) or the handshake failed, with
`Connection failed: <error>` or `Handshake failed: <error>` on stderr; 4
when the exchange after it failed, including a peer that closed without
close_notify.
"""

import argparse
import socket
import ssl
import sys

TIMEOUT_S = 10.0
PING = b"ping from cpython\n"
PONG = b"pong from cpython\n"
VERSIONS = {"tls1.3": ssl.TLSVersion.TLSv1_3, "tls1.2": ssl.TLSVersion.TLSv1_2}


def err(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def pin(ctx, version, alpn):
    ctx.minimum_version = VERSIONS[version]
    ctx.maximum_version = VERSIONS[version]
    ctx.set_alpn_protocols(alpn.split(","))


def report(tls):
    return "Connected.\n  Version: %s\n  Cipher: %s\n  ALPN protocol: %s\n" % (
        tls.version(),
        tls.cipher()[0],
        tls.selected_alpn_protocol() or "",
    )


def read_line(tls):
    data = b""
    while not data.endswith(b"\n"):
        chunk = tls.recv(4096)
        if not chunk:
            raise ConnectionError("the peer closed before a whole line: %r" % data)
        data += chunk
    return data


def read_to_close_notify(tls):
    """Everything until the peer's close_notify (recv returns b""). A socket
    closed without one raises (ssl.SSLEOFError), because the socket was
    wrapped with suppress_ragged_eofs=False."""
    data = b""
    while True:
        chunk = tls.recv(4096)
        if not chunk:
            return data
        data += chunk


def server(args):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    pin(ctx, args.version, args.alpn)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.settimeout(TIMEOUT_S)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    print("Listening on port %d" % listener.getsockname()[1], flush=True)
    try:
        conn, _ = listener.accept()
    except OSError as e:
        err("Connection failed: %s" % e)
        return 3
    finally:
        listener.close()
    conn.settimeout(TIMEOUT_S)
    try:
        tls = ctx.wrap_socket(conn, server_side=True, suppress_ragged_eofs=False)
    except (ssl.SSLError, OSError) as e:
        err("Handshake failed: %s" % e)
        return 3
    text = report(tls)
    err(text.rstrip("\n"))
    try:
        line = read_line(tls)
        if line != b"ping from komira\n":
            raise ValueError("read %r, want 'ping from komira'" % line)
        tls.sendall(text.encode() + PONG)
        rest = read_to_close_notify(tls)
        if rest:
            raise ValueError("read %r after the ping" % rest)
    except (ssl.SSLError, OSError, ValueError) as e:
        err("Exchange failed: %s" % e)
        return 4
    tls.close()
    return 0


def client(args):
    ctx = ssl.create_default_context(cafile=args.ca)
    pin(ctx, args.version, args.alpn)
    try:
        sock = socket.create_connection(("127.0.0.1", args.port), timeout=TIMEOUT_S)
    except OSError as e:
        err("Connection failed: %s" % e)
        return 3
    try:
        tls = ctx.wrap_socket(
            sock, server_hostname=args.server_name, suppress_ragged_eofs=False
        )
    except (ssl.SSLError, OSError) as e:
        err("Handshake failed: %s" % e)
        return 3
    err(report(tls).rstrip("\n"))
    try:
        tls.sendall(PING)
        got = read_to_close_notify(tls)
    except (ssl.SSLError, OSError) as e:
        err("Exchange failed: %s" % e)
        return 4
    sys.stdout.write(got.decode())
    sys.stdout.flush()
    tls.close()
    return 0


def main():
    p = argparse.ArgumentParser(prog="cpython_peer.py")
    sub = p.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("server")
    s.add_argument("--cert", required=True)
    s.add_argument("--key", required=True)
    c = sub.add_parser("client")
    c.add_argument("--port", type=int, required=True)
    c.add_argument("--ca", required=True)
    c.add_argument("--server-name", required=True)
    for q in (s, c):
        q.add_argument("--version", choices=sorted(VERSIONS), required=True)
        q.add_argument("--alpn", required=True)
    args = p.parse_args()
    err("OpenSSL: %s" % ssl.OPENSSL_VERSION)
    return server(args) if args.mode == "server" else client(args)


if __name__ == "__main__":
    sys.exit(main())
