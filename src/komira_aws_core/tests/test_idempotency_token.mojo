# aws_idempotency_token (idempotency.mojo): the value a generated client
# fills an unset `idempotencyToken` member with. botocore fills one with
# `str(uuid.uuid4())` (botocore/handlers.py `generate_idempotent_uuid`):
# 36 characters, lowercase hex in groups of 8-4-4-4-12, the version
# nibble 4 and the RFC 9562 variant (the first digit of the fourth group
# one of 8, 9, a, b).

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import aws_idempotency_token


def _is_lower_hex(c: UInt8) -> Bool:
    return (c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)


def _assert_uuid4(t: String) raises:
    var b = t.as_bytes()
    assert_equal(len(b), 36, t)
    for i in range(36):
        if i == 8 or i == 13 or i == 18 or i == 23:
            assert_equal(b[i], UInt8(0x2D), t)  # '-'
        else:
            assert_true(_is_lower_hex(b[i]), t)
    assert_equal(b[14], UInt8(0x34), t)  # the version, '4'
    # The variant: '8', '9', 'a' or 'b'.
    var v = b[19]
    assert_true(v == 0x38 or v == 0x39 or v == 0x61 or v == 0x62, t)


def test_a_token_is_a_version_4_uuid() raises:
    for _ in range(64):
        _assert_uuid4(aws_idempotency_token())


def test_each_call_draws_a_fresh_token() raises:
    var a = aws_idempotency_token()
    var b = aws_idempotency_token()
    var c = aws_idempotency_token()
    assert_false(a == b)
    assert_false(b == c)
    assert_false(a == c)


def main() raises:
    test_a_token_is_a_version_4_uuid()
    test_each_call_draws_a_fresh_token()
