# =============================================================================
# komira_webpush/tests/test_key_seams.mojo
# =============================================================================
#
# The two sender-key steps the system CSPRNG and AWS-LC almost never drive
# down their refusing paths, each through its private seam:
#
#   _draw_private_key: a source that offers n, then 0, then a valid scalar
#     yields the valid scalar on the third draw, and each draw after a
#     refused one starts from a wiped buffer; a source that only offers n
#     is refused with the exact message after exactly 8 draws.
#   _uncompressed_point: an all-zero x || y (what ecdsa_p256_generate_pubkey
#     returns when AWS-LC fails) is refused with the exact message; an x || y
#     whose only non-zero byte is the first, or the last, is accepted and
#     written behind 0x04.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import hex_lower
from komira_webpush.message import (
    _ScalarSource,
    _draw_private_key,
    _uncompressed_point,
)


comptime _N_HEX = (
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
)
comptime _VALID_HEX = (
    "c9f3b0c8c4f2a1e0d3b2a19080706050403020100f0e0d0c0b0a090807060504"
)


def _from_hex(h: StaticString) -> Array[UInt8, 32]:
    var out = Array[UInt8, 32](fill=UInt8(0))
    var bs = h.as_bytes()
    for i in range(32):
        var hi = Int(bs[2 * i])
        var lo = Int(bs[2 * i + 1])
        hi = hi - 48 if hi <= 57 else hi - 87
        lo = lo - 48 if lo <= 57 else lo - 87
        out[i] = UInt8(hi * 16 + lo)
    return out^


struct _ScriptedSource(_ScalarSource):
    """Offers n, then 0, then `_VALID_HEX`, then `_VALID_HEX` again; with
    `only_n`, offers n every time. Counts the draws and records whether any
    draw found a non-zero byte left in the buffer."""

    var draws: Int
    var saw_stale: Bool
    var only_n: Bool

    def __init__(out self, only_n: Bool):
        self.draws = 0
        self.saw_stale = False
        self.only_n = only_n

    def fill(mut self, mut k: Array[UInt8, 32]) raises:
        for i in range(32):
            if k[i] != UInt8(0):
                self.saw_stale = True
        var offer = Array[UInt8, 32](fill=UInt8(0))
        if self.only_n or self.draws == 0:
            offer = _from_hex(_N_HEX)
        elif self.draws >= 2:
            offer = _from_hex(_VALID_HEX)
        for i in range(32):
            k[i] = offer[i]
        self.draws += 1


def _hex32(k: Array[UInt8, 32]) -> String:
    return hex_lower(Span[UInt8](k))


def test_draw_skips_refused_candidates() raises:
    var source = _ScriptedSource(only_n=False)
    var k = _draw_private_key(source)
    assert_equal(_hex32(k), String(_VALID_HEX))
    assert_equal(source.draws, 3)
    assert_true(not source.saw_stale, "a refused candidate was not wiped")


def test_draw_refuses_after_eight() raises:
    var source = _ScriptedSource(only_n=True)
    var outcome = String("no raise")
    try:
        var k = _draw_private_key(source)
        outcome = String("OK ") + _hex32(k)
    except e:
        outcome = String(e)
    assert_equal(outcome, "webpush: no valid P-256 private key in 8 draws")
    assert_equal(source.draws, 8)
    assert_true(not source.saw_stale, "a refused candidate was not wiped")


def _zeros_hex(n: Int) -> String:
    var out = String()
    for _ in range(n):
        out += "00"
    return out^


def _point_outcome(xy: Array[UInt8, 64]) -> String:
    try:
        var p = _uncompressed_point(xy)
        return String("OK ") + hex_lower(Span[UInt8](p))
    except e:
        return String(e)


def test_uncompressed_point() raises:
    var zero = Array[UInt8, 64](fill=UInt8(0))
    assert_equal(
        _point_outcome(zero), "webpush: P-256 public key derivation failed"
    )
    var first = Array[UInt8, 64](fill=UInt8(0))
    first[0] = UInt8(0xA5)
    assert_equal(_point_outcome(first), "OK 04a5" + _zeros_hex(63))
    var last = Array[UInt8, 64](fill=UInt8(0))
    last[63] = UInt8(0x01)
    assert_equal(_point_outcome(last), "OK 04" + _zeros_hex(63) + "01")


def main() raises:
    test_draw_skips_refused_candidates()
    print("PASS _draw_private_key skips n and 0")
    test_draw_refuses_after_eight()
    print("PASS _draw_private_key refuses after 8 draws")
    test_uncompressed_point()
    print("PASS _uncompressed_point")
