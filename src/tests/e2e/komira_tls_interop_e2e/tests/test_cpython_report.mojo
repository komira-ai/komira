# The reading of what the CPython peer prints (cpython.mojo,
# cpython_peer.py), with no interpreter run: the server's port is read from
# its one `Listening on port <n>` line among others, a second such line or
# none is an error (a test must not connect to a port it guessed), and a
# value that is not a port (empty, not digits, 0, above 65535) is refused.
# The peer's connection report has bssl's shape, and parse_report reads it
# with its OpenSSL cipher name.

from std.testing import assert_equal, assert_raises

from komira_tls_interop_e2e import listening_port, parse_report


def test_reads_the_port() raises:
    assert_equal(Int(listening_port(String("OpenSSL: OpenSSL 3.5.4\nListening on port 40123\n"))), 40123)
    assert_equal(Int(listening_port(String("Listening on port 65535"))), 65535)
    assert_equal(Int(listening_port(String("Listening on port 1\n"))), 1)


def test_one_line_only() raises:
    with assert_raises(contains="found 2"):
        _ = listening_port(String("Listening on port 1\nListening on port 2\n"))
    with assert_raises(contains="found 0"):
        _ = listening_port(String("Handshake failed: timed out\n"))


def test_not_a_port() raises:
    with assert_raises(contains="not a port"):
        _ = listening_port(String("Listening on port \n"))
    with assert_raises(contains="not a port"):
        _ = listening_port(String("Listening on port 80x\n"))
    with assert_raises(contains="not a port"):
        _ = listening_port(String("Listening on port 0\n"))
    with assert_raises(contains="not a port"):
        _ = listening_port(String("Listening on port 65536\n"))
    with assert_raises(contains="not a port"):
        _ = listening_port(String("Listening on port 123456\n"))


def test_report_shape() raises:
    var r = parse_report(
        String(
            "OpenSSL: OpenSSL 3.5.4\nConnected.\n  Version: TLSv1.2\n"
            + "  Cipher: ECDHE-RSA-AES128-GCM-SHA256\n  ALPN protocol: http/1.1\n"
        )
    )
    assert_equal(r.version, String("TLSv1.2"))
    assert_equal(r.cipher, String("ECDHE-RSA-AES128-GCM-SHA256"))
    assert_equal(r.alpn, String("http/1.1"))


def main() raises:
    test_reads_the_port()
    test_one_line_only()
    test_not_a_port()
    test_report_shape()
    print("test_cpython_report PASS")
