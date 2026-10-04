# The value a generated client fills an unset idempotency token with.
#
# A member the model marks `idempotencyToken: true` (EC2's
# `RunInstances.ClientToken`, for one) is how the service tells a resend
# from a new request. botocore fills an unset one before the request is
# built (`generate_idempotent_uuid` in botocore/handlers.py, registered on
# `before-parameter-build`) with `str(uuid.uuid4())`, so every attempt of
# one call carries the same token and a call retried after a 5xx or a
# dropped response is not applied twice. A generated client calls
# `aws_idempotency_token` once per call, before the request is built and
# so before the retry loop, which resends the same bytes.

from komira_crypto import system_entropy


def _hex_digit(v: Int) -> String:
    """One lowercase hex digit for `v` in [0, 16)."""
    if v < 10:
        return chr(0x30 + v)
    return chr(0x61 + v - 10)


def aws_idempotency_token() raises -> String:
    """A fresh random (version 4) UUID in its lowercase hyphenated form, as
    Python's `str(uuid.uuid4())` writes it: 122 random bits from the
    CSPRNG, the version nibble 4 and the RFC 9562 variant bits `10`."""
    var b = List[UInt8]()
    for _ in range(16):
        b.append(UInt8(0))
    system_entropy(Span(b))
    b[6] = (b[6] & 0x0F) | 0x40
    b[8] = (b[8] & 0x3F) | 0x80
    var out = String()
    for i in range(16):
        var v = Int(b[i])
        out += _hex_digit(v >> 4)
        out += _hex_digit(v & 0x0F)
        if i == 3 or i == 5 or i == 7 or i == 9:
            out += "-"
    return out^
