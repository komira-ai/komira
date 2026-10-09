# =============================================================================
# komira_tls_interop_e2e/cpython.mojo -- the CPython `ssl` peer: starting
# cpython_peer.py with the pinned interpreter, and the port its server prints
# =============================================================================
#
# A test gets the pinned interpreter, `bin/python3.13` of
# komira//third_party/python:cpython, as its `--python` flag (BUCK), and the
# peer script staged in its working directory as `cpython_peer.py`.
# `start_cpython_peer` runs `<python> -I -S cpython_peer.py <args>`:
#
#   * `-I` reads no PYTHON* variable and no user site directory, and puts
#     neither the script's directory nor the working directory on sys.path;
#     `-S` imports no `site`: the script sees the archive's standard library
#     and nothing else (no wheel is needed);
#   * its environment is exactly `LC_ALL=C` and `TZ=UTC0`, as `py_test`'s
#     (tools/build/python/README.md): no locale coercion that maps the
#     worker's locale files, and none of the test's own variables
#     (LD_LIBRARY_PATH names the Mojo runtime libraries, not Python's).
#
# The server peer binds 127.0.0.1 on a port the kernel picks and prints it;
# `listening_port` reads it from that line, which is also the readiness
# signal: the port is listening once the line is printed.
# =============================================================================

from .children import PeerGroup

comptime PEER_SCRIPT = "cpython_peer.py"
comptime LISTENING = "Listening on port "


def start_cpython_peer(mut peers: PeerGroup, var label: String, python: String, args: List[String]) raises -> Int:
    """Start the CPython peer (`server` or `client`, first of `args`) with
    the pinned interpreter; returns its handle in `peers`."""
    var argv: List[String] = [String("-I"), String("-S"), String(PEER_SCRIPT)]
    for a in args:
        argv.append(a)
    var env: List[String] = [String("LC_ALL=C"), String("TZ=UTC0")]
    return peers.start(label^, python, argv, env=env)


def listening_port(text: String) raises -> UInt16:
    """The port of the one `Listening on port <n>` line of `text`; raises
    unless there is exactly one and `n` is a port (1 to 65535)."""
    var found = List[String]()
    for raw in text.split("\n"):
        var line = String(raw)
        if line.startswith(LISTENING):
            found.append(String(String(line[byte = String(LISTENING).byte_length() :]).strip()))
    if len(found) != 1:
        raise Error("cpython peer: expected one '" + LISTENING + "<n>' line, found " + String(len(found)) + " in:\n" + text)
    var digits = found[0].copy()
    if digits.byte_length() == 0 or digits.byte_length() > 5:
        raise Error("cpython peer: not a port: '" + digits + "'")
    var n = 0
    var bytes = digits.as_bytes()
    for i in range(len(bytes)):
        var d = Int(bytes[i]) - 48
        if d < 0 or d > 9:
            raise Error("cpython peer: not a port: '" + digits + "'")
        n = n * 10 + d
    if n < 1 or n > 65535:
        raise Error("cpython peer: not a port: '" + digits + "'")
    return UInt16(n)
