# The reading of bssl's connection report (bssl.mojo), on text in the form
# aws-lc 1.39.0's PrintConnectionInfo prints, with no bssl run: the three
# facts are read from the indented lines, an empty `ALPN protocol:` is no
# protocol, the CRLF of the -www answer is not part of a value, a fact
# printed twice or not at all is an error (a report of two connections must
# not pass as one), and the cipher-name table maps s2n's names to the RFC
# names bssl prints and refuses a name it does not know.

from std.testing import assert_equal, assert_raises, assert_true

from komira_tls_interop_e2e import is_tls13_suite, parse_report, standard_cipher_name, tls_version_name


comptime _STDERR = (
    "Connecting to 127.0.0.1:4433\nConnected.\n  Version: TLSv1.2\n  Resumed session: no\n"
    + "  Cipher: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256\n  ECDHE group: X25519\n"
    + "  Next protocol negotiated: \n  ALPN protocol: h2\n  Encrypted ClientHello: no\n"
)

comptime _WWW = (
    "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n  Version: TLSv1.3\n  Resumed session: no\n"
    + "  Cipher: TLS_AES_256_GCM_SHA384\n  Next protocol negotiated: \n  ALPN protocol: \n"
)


def test_reads_the_three_facts() raises:
    var r = parse_report(String(_STDERR))
    assert_equal(r.version, String("TLSv1.2"))
    assert_equal(r.cipher, String("TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"))
    assert_equal(r.alpn, String("h2"))


def test_www_answer_and_empty_alpn() raises:
    var r = parse_report(String(_WWW))
    assert_equal(r.version, String("TLSv1.3"))
    assert_equal(r.cipher, String("TLS_AES_256_GCM_SHA384"))
    assert_equal(r.alpn, String(""))


def test_two_reports_or_none_are_errors() raises:
    with assert_raises(contains="found 2"):
        _ = parse_report(String(_STDERR) + String(_STDERR))
    with assert_raises(contains="found 0"):
        _ = parse_report(String("Connected.\n"))


def test_cipher_names() raises:
    assert_equal(standard_cipher_name(String("TLS_AES_128_GCM_SHA256")), String("TLS_AES_128_GCM_SHA256"))
    assert_equal(
        standard_cipher_name(String("ECDHE-RSA-AES128-GCM-SHA256")), String("TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
    )
    assert_equal(
        standard_cipher_name(String("ECDHE-ECDSA-CHACHA20-POLY1305")),
        String("TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"),
    )
    with assert_raises(contains="AES128-SHA"):
        _ = standard_cipher_name(String("AES128-SHA"))
    assert_true(is_tls13_suite(String("TLS_CHACHA20_POLY1305_SHA256")))
    assert_true(not is_tls13_suite(String("TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384")))


def test_version_names() raises:
    assert_equal(tls_version_name(34), String("TLSv1.3"))
    assert_equal(tls_version_name(33), String("TLSv1.2"))
    with assert_raises(contains="32"):
        _ = tls_version_name(32)


def main() raises:
    test_reads_the_three_facts()
    test_www_answer_and_empty_alpn()
    test_two_reports_or_none_are_errors()
    test_cipher_names()
    test_version_names()
    print("test_bssl_report PASS")
