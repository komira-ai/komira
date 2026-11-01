# `wipe_bytes` (codec.mojo): the libc secure-zero call that clears decoded secret
# bytes. A buffer that is about to be freed is where an optimizer drops a plain
# store loop, so the package calls `explicit_bzero` (`memset_s` on macOS); this
# test pins that the call zeroes every element, whatever the length, and only
# those elements.

from std.testing import assert_equal

from komira_encoding.codec import wipe_bytes


def _filled(n: Int, v: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(v)
    return out^


def _count_nonzero(buf: List[UInt8]) -> Int:
    var c = 0
    for i in range(len(buf)):
        if buf[i] != 0:
            c += 1
    return c


def test_zeroes_every_byte_at_every_length() raises:
    for n in range(1, 130):
        var buf = _filled(n, 0xA5)
        wipe_bytes(buf)
        assert_equal(len(buf), n)
        assert_equal(_count_nonzero(buf), 0)


def test_zeroes_a_large_buffer() raises:
    var buf = _filled(100000, 0xFF)
    wipe_bytes(buf)
    assert_equal(len(buf), 100000)
    assert_equal(_count_nonzero(buf), 0)


def test_empty_buffer_is_a_no_op() raises:
    var buf = List[UInt8]()
    wipe_bytes(buf)
    assert_equal(len(buf), 0)


def test_stays_inside_the_buffer() raises:
    # Two adjacent lists are not guaranteed adjacent in memory, so check the
    # contract that can be seen: a wipe of one list leaves another untouched.
    var secret = _filled(64, 0x11)
    var other = _filled(64, 0x22)
    wipe_bytes(secret)
    assert_equal(_count_nonzero(secret), 0)
    for i in range(64):
        assert_equal(other[i], UInt8(0x22))


def main() raises:
    test_zeroes_every_byte_at_every_length()
    test_zeroes_a_large_buffer()
    test_empty_buffer_is_a_no_op()
    test_stays_inside_the_buffer()
    print("test_wipe: OK")
