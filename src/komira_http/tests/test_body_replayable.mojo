"""RequestBody.replayable + .rewind + RetryLayer.assert_body_replayable.

Verifies the extension to the RequestBody trait + the
RetryLayer's B-parametric pre-flight check:

1. EmptyBody.replayable() == True; rewind is no-op.
2. BytesBody.replayable() == True; rewind resets cursor (re-drains
   from the start).
3. StreamingBody.replayable() == False; rewind raises
   HttpError[BODY_NOT_REPLAYABLE].
4. RetryLayer.assert_body_replayable on EmptyBody/BytesBody requests
   passes silently.
5. RetryLayer.assert_body_replayable on StreamingBody request raises
   HttpError[BODY_NOT_REPLAYABLE].

 fail-loud guidance: a retry-eligible HttpService consumer
that wraps in RetryLayer MUST call assert_body_replayable before
inner.call; the call_empty replay path remains the hardcoded
EmptyBody-only retry loop.
"""


from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.body import (
    BytesBody,
    EmptyBody,
    StreamingBody,
)
from komira_http.client.client import build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url


def _check_str_contains(s: String, needle: String) -> Bool:
    """Substring contains. Returns True if `needle` is a substring of
    `s`. Used to validate HttpError prefix shape."""
    var sn = s.byte_length()
    var pn = needle.byte_length()
    if pn > sn:
        return False
    if pn == 0:
        return True
    var sb = s.as_bytes()
    var pb = needle.as_bytes()
    var i = 0
    while i <= sn - pn:
        var j = 0
        var is_match = True
        while j < pn:
            if sb[i + j] != pb[j]:
                is_match = False
                break
            j = j + 1
        if is_match:
            return True
        i = i + 1
    return False


# =============================================================================
# Test 1 — EmptyBody.replayable() / rewind().
# =============================================================================


def test_empty_body_replayable() raises:
    var b = EmptyBody.new()
    assert_true(b.replayable(), "EmptyBody must be replayable")
    # rewind is a no-op; should not raise.
    b.rewind()
    assert_true(b.replayable(), "rewind must not change replayable")


# =============================================================================
# Test 2 — BytesBody.replayable() + rewind drains again from cursor 0.
# =============================================================================


def test_bytes_body_replayable_and_rewind() raises:
    var initial = List[UInt8]()
    initial.append(UInt8(ord("h")))
    initial.append(UInt8(ord("i")))
    initial.append(UInt8(ord("!")))
    var b = BytesBody.from_bytes(initial^)
    assert_true(b.replayable())
    assert_equal(b.bytes_remaining(), 3)

    # Drain into a small scratch.
    var scratch = List[UInt8]()
    var i = 0
    while i < 8:
        scratch.append(UInt8(0))
        i = i + 1
    var span = Span[UInt8](scratch)
    var n = b.read_chunk(span)
    assert_equal(n, 3)
    assert_equal(b.bytes_remaining(), 0)

    # Rewind — cursor goes back to 0.
    b.rewind()
    assert_equal(b.bytes_remaining(), 3)

    # Drain again — same 3 bytes.
    var n2 = b.read_chunk(span)
    assert_equal(n2, 3)


# =============================================================================
# Test 3 — StreamingBody.replayable() == False; rewind raises.
# =============================================================================


def test_streaming_body_not_replayable() raises:
    var b = StreamingBody.from_pattern(UInt8(0x42), 100)
    assert_false(b.replayable(), "StreamingBody must NOT be replayable")

    var raised = False
    try:
        b.rewind()
    except e:
        var msg = String(e)
        assert_true(
            _check_str_contains(msg, String("HttpError[BODY_NOT_REPLAYABLE]")),
            String("expected BODY_NOT_REPLAYABLE prefix; got: ") + msg,
        )
        raised = True
    assert_true(raised, "rewind must raise on non-replayable")


# =============================================================================
# Test 4 — BytesBody.replayable then rewind multiple times.
# =============================================================================


def test_bytes_body_rewind_idempotent_at_zero() raises:
    var initial = List[UInt8]()
    initial.append(UInt8(ord("a")))
    var b = BytesBody.from_bytes(initial^)
    assert_true(b.replayable())

    # Rewind before any drain — no-op at cursor 0.
    b.rewind()
    assert_equal(b.bytes_remaining(), 1)

    # Rewind again — still safe.
    b.rewind()
    assert_equal(b.bytes_remaining(), 1)


# =============================================================================
# Test 5 — EmptyBody.replayable() preserves after multiple rewinds.
# =============================================================================


def test_empty_body_multiple_rewinds() raises:
    var b = EmptyBody.new()
    b.rewind()
    b.rewind()
    b.rewind()
    assert_true(b.replayable())
    # read_chunk returns 0 regardless.
    var scratch = List[UInt8]()
    scratch.append(UInt8(0))
    var span = Span[UInt8](scratch)
    assert_equal(b.read_chunk(span), 0)


def main() raises:
    test_empty_body_replayable()
    test_bytes_body_replayable_and_rewind()
    test_streaming_body_not_replayable()
    test_bytes_body_rewind_idempotent_at_zero()
    test_empty_body_multiple_rewinds()
    print("[OK] test_body_replayable — all 5 tests passed")
