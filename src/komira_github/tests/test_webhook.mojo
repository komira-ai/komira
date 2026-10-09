# =============================================================================
# komira_github/tests/test_webhook.mojo -- webhook signature verification.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_github_documented_vector: GitHub's own example ("Validating webhook
#     deliveries": secret "It's a Secret to Everybody", payload "Hello,
#     World!", sha256=757107ea...) is produced and accepted. Catches the key
#     and the data swapped in the HMAC, and a digest other than SHA-256.
#   * test_digest_diff_reads_every_byte: `webhook_digest_diff` of two digests
#     that differ at byte 0 (0x01) and byte 31 (0x80) is 0x81. Catches an
#     EARLY-EXIT compare (returns at the first difference: 0x01), a loop
#     that skips the last byte (0x01) or the first (0x80). Equal digests are 0.
#   * test_signature_near_misses: one table of signature values, each a
#     near miss of the right one (empty, prefix, extension, a byte in front,
#     no `sha256=`, `SHA256=`, `sha256:`, upper-case hex, the first and the
#     last hex digit changed, `sha1=` with a valid SHA-1 hex length) is
#     refused, and every refusal is collected before one assert. Catches a
#     `startswith`/`endswith`/substring compare, a case-insensitive one, a
#     compare that skips the first or last byte, and sha1 accepted.
#   * test_forged_body_and_secret: the right signature over a body whose
#     first byte, last byte or length differ, and a signature made with a
#     secret whose last byte differs, are refused; an empty secret is
#     refused even with a signature computed under it.
#   * test_delivery_headers: header-level rules: the signature header found
#     in any case and in last position; none (refused naming the header),
#     only `X-Hub-Signature` (refused naming SHA-1), and two (refused, even
#     when the first is right).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_github import (
    GitHubHeader,
    github_error_kind,
    verify_webhook_delivery,
    verify_webhook_signature,
    webhook_digest_diff,
    webhook_signature_256,
)


comptime SECRET = "It's a Secret to Everybody"
comptime BODY = "Hello, World!"
comptime DOC_SIG = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"


def _refusal(secret: String, body: String, sig: String) -> String:
    """The error text, or "" when the signature is accepted."""
    try:
        verify_webhook_signature(secret.as_bytes(), body.as_bytes(), sig)
    except e:
        return String(e)
    return String("")


def _delivery_refusal(secret: String, body: String, headers: List[GitHubHeader]) -> String:
    try:
        verify_webhook_delivery(secret.as_bytes(), body.as_bytes(), headers)
    except e:
        return String(e)
    return String("")


def test_github_documented_vector() raises:
    assert_equal(
        webhook_signature_256(String(SECRET).as_bytes(), String(BODY).as_bytes()), String(DOC_SIG)
    )
    assert_equal(_refusal(SECRET, BODY, DOC_SIG), String(""), "GitHub's own example verifies")
    print("  test_github_documented_vector PASS")


def test_digest_diff_reads_every_byte() raises:
    var a = Array[UInt8, 32](fill=UInt8(0))
    var b = Array[UInt8, 32](fill=UInt8(0))
    assert_equal(Int(webhook_digest_diff(a, b)), 0, "equal digests")
    b[0] = 0x01
    b[31] = 0x80
    assert_equal(Int(webhook_digest_diff(a, b)), 0x81, "both differences are folded in")
    var c = Array[UInt8, 32](fill=UInt8(0))
    c[31] = 0x04
    assert_equal(Int(webhook_digest_diff(a, c)), 0x04, "a difference in the last byte alone")
    var d = Array[UInt8, 32](fill=UInt8(0))
    d[0] = 0x10
    assert_equal(Int(webhook_digest_diff(a, d)), 0x10, "a difference in the first byte alone")
    print("  test_digest_diff_reads_every_byte PASS")


def _swap_hex(c: String) -> String:
    if c == "0":
        return String("1")
    return String("0")


def test_signature_near_misses() raises:
    var good = String(DOC_SIG)
    var hex = String(good[byte=7 : good.byte_length()])
    var n = good.byte_length()
    var misses = List[String]()
    misses.append(String(""))
    misses.append(String(good[byte=0 : n - 1]))  # prefix
    misses.append(good + String("0"))  # extension
    misses.append(String("0") + good)  # a byte in front
    misses.append(hex)  # no sha256=
    misses.append(String("SHA256=") + hex)
    misses.append(String("sha256:") + hex)
    misses.append(String("sha256=") + hex.upper())
    misses.append(String("sha256=") + _swap_hex(String(hex[byte=0:1])) + String(hex[byte=1:64]))
    misses.append(String("sha256=") + String(hex[byte=0:63]) + _swap_hex(String(hex[byte=63:64])))
    misses.append(String("sha256=") + String(hex[byte=0:32]) + String("g") + String(hex[byte=33:64]))
    misses.append(String("sha1=") + String(hex[byte=0:40]))
    var accepted = String("")
    for i in range(len(misses)):
        var why = _refusal(SECRET, BODY, misses[i])
        if why.byte_length() == 0 or github_error_kind(why) != "WEBHOOK":
            accepted += String("[") + String(i) + String("] ")
    assert_equal(accepted, String(""), "every near miss is refused")
    assert_true(
        _refusal(SECRET, BODY, String("sha1=") + String(hex[byte=0:40])).find("sha1=") >= 0,
        "a sha1 signature is refused by name",
    )
    print("  test_signature_near_misses PASS")


def test_forged_body_and_secret() raises:
    var refusals = String("")
    if _refusal(SECRET, "hello, World!", DOC_SIG).byte_length() == 0:
        refusals += "first-byte "
    if _refusal(SECRET, "Hello, World?", DOC_SIG).byte_length() == 0:
        refusals += "last-byte "
    if _refusal(SECRET, "Hello, World!!", DOC_SIG).byte_length() == 0:
        refusals += "longer "
    if _refusal(SECRET, "Hello, World", DOC_SIG).byte_length() == 0:
        refusals += "shorter "
    var other_secret = String("It's a Secret to Everybodz")
    var forged = webhook_signature_256(other_secret.as_bytes(), String(BODY).as_bytes())
    if _refusal(SECRET, BODY, forged).byte_length() == 0:
        refusals += "other-secret "
    assert_equal(refusals, String(""), "forged deliveries are refused")
    var empty_sig = webhook_signature_256(String("").as_bytes(), String(BODY).as_bytes())
    assert_true(
        _refusal(String(""), BODY, empty_sig).find("secret is empty") >= 0,
        "an empty secret is refused even when the signature matches it",
    )
    print("  test_forged_body_and_secret PASS")


def test_delivery_headers() raises:
    var h = List[GitHubHeader]()
    h.append(GitHubHeader(String("Content-Type"), String("application/json")))
    h.append(GitHubHeader(String("X-GitHub-Event"), String("ping")))
    h.append(GitHubHeader(String("x-hub-signature-256"), String(DOC_SIG)))
    assert_equal(_delivery_refusal(SECRET, BODY, h), String(""), "lower-case name, last position")

    var none = List[GitHubHeader]()
    none.append(GitHubHeader(String("X-GitHub-Event"), String("ping")))
    assert_true(
        _delivery_refusal(SECRET, BODY, none).find("no X-Hub-Signature-256") >= 0, "no signature"
    )
    var sha1_only = List[GitHubHeader]()
    sha1_only.append(GitHubHeader(String("X-Hub-Signature"), String("sha1=0123456789abcdef0123456789abcdef01234567")))
    assert_true(
        _delivery_refusal(SECRET, BODY, sha1_only).find("HMAC-SHA1") >= 0, "sha1 alone is refused"
    )
    var two = List[GitHubHeader]()
    two.append(GitHubHeader(String("X-Hub-Signature-256"), String(DOC_SIG)))
    two.append(GitHubHeader(String("X-Hub-Signature-256"), String(DOC_SIG)))
    assert_true(
        _delivery_refusal(SECRET, BODY, two).find("more than one") >= 0, "two signatures"
    )
    var wrong_last = List[GitHubHeader]()
    wrong_last.append(GitHubHeader(String("X-Hub-Signature"), String("sha1=0123456789abcdef0123456789abcdef01234567")))
    var doc = String(DOC_SIG)
    var wrong = String(doc[byte=0:70]) + String("0")
    wrong_last.append(GitHubHeader(String("X-Hub-Signature-256"), wrong))
    assert_true(
        _delivery_refusal(SECRET, BODY, wrong_last).find("does not match") >= 0,
        "a wrong 256 signature is refused even beside a sha1 one",
    )
    print("  test_delivery_headers PASS")


def main() raises:
    test_github_documented_vector()
    test_digest_diff_reads_every_byte()
    test_signature_near_misses()
    test_forged_body_and_secret()
    test_delivery_headers()
    print("PASS komira_github webhook")
