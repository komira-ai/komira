# =============================================================================
# komira_github/webhook.mojo -- is a webhook delivery from GitHub?
# =============================================================================
#
# GitHub signs each delivery with the webhook secret ("Validating webhook
# deliveries"): `X-Hub-Signature-256: sha256=<hex>`, where `<hex>` is the
# lowercase hex HMAC-SHA256 of the raw request body under the secret.
#
# `verify_webhook_delivery(secret, body, headers)` accepts a delivery only
# when:
#   * the secret is not empty (an empty key is a MAC anyone can compute);
#   * exactly one `X-Hub-Signature-256` header is present. A delivery with
#     only the legacy `X-Hub-Signature` (HMAC-SHA1) is refused by name: SHA-1
#     is not accepted however it verifies. Two signature headers are refused
#     rather than one of them chosen;
#   * its value is `sha256=` followed by exactly 64 lowercase hex digits
#     (GitHub's form; `sha1=` there is refused by name);
#   * those 32 bytes equal HMAC-SHA256(secret, body), compared in constant
#     time: `webhook_digest_diff` ORs together the XOR of all 32 byte pairs
#     and the delivery is accepted only when the result is 0. Every byte is
#     read whatever the earlier ones were, so the time taken does not say how
#     long a prefix of a forged signature was right.
#
# The body is the bytes as received: parse it only after it verified, and
# never re-serialize before verifying. The secret is not copied and no
# message quotes the secret, the body or the signature.
# =============================================================================

from komira_crypto import hex_lower_array_32, hmac_sha256

from .error import KIND_WEBHOOK, github_error
from .header import GitHubHeader, header_count, header_value


comptime WEBHOOK_SIGNATURE_256_HEADER: String = "X-Hub-Signature-256"
comptime WEBHOOK_SIGNATURE_SHA1_HEADER: String = "X-Hub-Signature"
comptime WEBHOOK_SIGNATURE_PREFIX: String = "sha256="


def webhook_signature_256(secret: Span[UInt8, _], body: Span[UInt8, _]) -> String:
    """The `X-Hub-Signature-256` value GitHub sends for `body` under
    `secret`: `sha256=` and the lowercase hex HMAC-SHA256."""
    return String(WEBHOOK_SIGNATURE_PREFIX) + hex_lower_array_32(hmac_sha256(secret, body))


def webhook_digest_diff(a: Array[UInt8, 32], b: Array[UInt8, 32]) -> UInt8:
    """The OR of `a[i] ^ b[i]` over all 32 positions: 0 exactly when the two
    are equal. No early exit: the loop reads every pair whatever it found."""
    var diff = UInt8(0)
    for i in range(32):
        diff = diff | (a[i] ^ b[i])
    return diff


def _hex_nibble(c: UInt8) -> Int:
    """0-15 for `[0-9a-f]`, -1 for any other byte (upper case included)."""
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c - UInt8(ord("0")))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return Int(c - UInt8(ord("a"))) + 10
    return -1


def _signature_bytes(value: String) raises -> Array[UInt8, 32]:
    """The 32 bytes of a `sha256=<64 lowercase hex>` value."""
    if value.startswith("sha1="):
        raise github_error(
            KIND_WEBHOOK, "the signature is sha1=; only sha256= (X-Hub-Signature-256) is accepted"
        )
    if not value.startswith(WEBHOOK_SIGNATURE_PREFIX):
        raise github_error(KIND_WEBHOOK, "the signature does not start with sha256=")
    var b = value.as_bytes()
    var start = String(WEBHOOK_SIGNATURE_PREFIX).byte_length()
    if len(b) != start + 64:
        raise github_error(KIND_WEBHOOK, "the signature is not 64 hex digits after sha256=")
    var out = Array[UInt8, 32](fill=0)
    for i in range(32):
        var hi = _hex_nibble(b[start + 2 * i])
        var lo = _hex_nibble(b[start + 2 * i + 1])
        if hi < 0 or lo < 0:
            raise github_error(
                KIND_WEBHOOK, "the signature holds a byte outside lowercase hex"
            )
        out[i] = UInt8(hi * 16 + lo)
    return out^


def verify_webhook_signature(
    secret: Span[UInt8, _], body: Span[UInt8, _], signature_256: String
) raises:
    """Raises `GitHubError[WEBHOOK]` unless `signature_256` (an
    `X-Hub-Signature-256` value) is GitHub's signature of `body` under
    `secret` (module header)."""
    if len(secret) == 0:
        raise github_error(KIND_WEBHOOK, "the webhook secret is empty")
    var got = _signature_bytes(signature_256)
    var want = hmac_sha256(secret, body)
    if webhook_digest_diff(want, got) != UInt8(0):
        raise github_error(KIND_WEBHOOK, "the signature does not match the body")


def verify_webhook_delivery(
    secret: Span[UInt8, _], body: Span[UInt8, _], headers: List[GitHubHeader]
) raises:
    """`verify_webhook_signature` over the one `X-Hub-Signature-256` among
    `headers` (names compared without ASCII case). Raises when there is
    none (naming a lone `X-Hub-Signature`) or more than one."""
    var n = header_count(headers, WEBHOOK_SIGNATURE_256_HEADER)
    if n == 0:
        if header_count(headers, WEBHOOK_SIGNATURE_SHA1_HEADER) > 0:
            raise github_error(
                KIND_WEBHOOK,
                "only X-Hub-Signature (HMAC-SHA1) is present; X-Hub-Signature-256 is required",
            )
        raise github_error(KIND_WEBHOOK, "no X-Hub-Signature-256 header")
    if n > 1:
        raise github_error(KIND_WEBHOOK, "more than one X-Hub-Signature-256 header")
    var value = header_value(headers, WEBHOOK_SIGNATURE_256_HEADER)
    verify_webhook_signature(secret, body, value.value())
