# =============================================================================
# src/komira_http/tests/test_body.mojo — Body trait + EmptyBody + BytesBody
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http.client.body import BytesBody, EmptyBody


def test_empty_body_content_length() raises:
    var b = EmptyBody.new()
    assert_equal(b.content_length(), 0)


def test_empty_body_drains_zero() raises:
    var b = EmptyBody.new()
    var dst = List[UInt8]()
    var i = 0
    while i < 16:
        dst.append(UInt8(0))
        i = i + 1
    var n = b.read_chunk(Span[UInt8](dst))
    assert_equal(n, 0)


def test_bytes_body_from_str_drain_all() raises:
    var b = BytesBody.from_str(String("hello"))
    assert_equal(b.content_length(), 5)
    var dst = List[UInt8]()
    var i = 0
    while i < 16:
        dst.append(UInt8(0))
        i = i + 1
    var n = b.read_chunk(Span[UInt8](dst))
    assert_equal(n, 5)
    assert_equal(Int(dst[0]), Int(ord("h")))
    assert_equal(Int(dst[1]), Int(ord("e")))
    assert_equal(Int(dst[2]), Int(ord("l")))
    assert_equal(Int(dst[3]), Int(ord("l")))
    assert_equal(Int(dst[4]), Int(ord("o")))
    # Next read returns 0 (drained).
    var n2 = b.read_chunk(Span[UInt8](dst))
    assert_equal(n2, 0)


def test_bytes_body_partial_drain_loops() raises:
    """Drain in pieces — read_chunk returns at most dst.len bytes."""
    var b = BytesBody.from_str(String("0123456789ABCDEF"))
    assert_equal(b.content_length(), 16)
    var total_drained = 0
    var iter = 0
    var dst = List[UInt8]()
    var i = 0
    while i < 5:
        dst.append(UInt8(0))
        i = i + 1
    while True:
        var n = b.read_chunk(Span[UInt8](dst))
        if n == 0:
            break
        total_drained = total_drained + n
        iter = iter + 1
        if iter > 10:
            # Safety bail; we should drain in 4 iters max.
            break
    assert_equal(total_drained, 16)
    # 16 bytes / 5-byte dst = 4 iterations (5+5+5+1).
    assert_equal(iter, 4)


def test_bytes_body_reset_replays() raises:
    var b = BytesBody.from_str(String("retry"))
    var dst = List[UInt8]()
    var i = 0
    while i < 16:
        dst.append(UInt8(0))
        i = i + 1
    var n1 = b.read_chunk(Span[UInt8](dst))
    assert_equal(n1, 5)
    assert_equal(b.bytes_remaining(), 0)
    # Simulate retry — reset to head, replay.
    b.reset()
    assert_equal(b.bytes_remaining(), 5)
    # Clear dst so we observe a fresh write.
    var j = 0
    while j < 16:
        dst[j] = UInt8(0)
        j = j + 1
    var n2 = b.read_chunk(Span[UInt8](dst))
    assert_equal(n2, 5)
    assert_equal(Int(dst[0]), Int(ord("r")))


def test_bytes_body_empty_factory() raises:
    var b = BytesBody.empty()
    assert_equal(b.content_length(), 0)
    var dst = List[UInt8]()
    dst.append(UInt8(0))
    var n = b.read_chunk(Span[UInt8](dst))
    assert_equal(n, 0)


def test_bytes_body_from_bytes_takes_ownership() raises:
    var src = List[UInt8]()
    src.append(UInt8(ord("A")))
    src.append(UInt8(ord("B")))
    src.append(UInt8(ord("C")))
    var b = BytesBody.from_bytes(src^)
    assert_equal(b.content_length(), 3)
    var dst = List[UInt8]()
    var i = 0
    while i < 16:
        dst.append(UInt8(0))
        i = i + 1
    var n = b.read_chunk(Span[UInt8](dst))
    assert_equal(n, 3)
    assert_equal(Int(dst[0]), Int(ord("A")))
    assert_equal(Int(dst[1]), Int(ord("B")))
    assert_equal(Int(dst[2]), Int(ord("C")))


def main() raises:
    test_empty_body_content_length()
    test_empty_body_drains_zero()
    test_bytes_body_from_str_drain_all()
    test_bytes_body_partial_drain_loops()
    test_bytes_body_reset_replays()
    test_bytes_body_empty_factory()
    test_bytes_body_from_bytes_takes_ownership()
    print("OK: test_body")
