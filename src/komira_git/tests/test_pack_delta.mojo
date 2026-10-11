# =============================================================================
# komira_git/tests/test_pack_delta.mojo -- applying git deltas.
# =============================================================================
#
# The deltas here are written by hand in the instruction encoding of
# gitformat-pack ("Deltified representation"); the conformance package
# (src/tests/conformance/komira_git_pack_conformance) applies the deltas
# git itself writes.
#
# WHAT EACH TEST CATCHES:
#   * test_copy_and_insert: a copy instruction whose offset or size bytes
#     are read in the wrong order or from the wrong flag bits, an insert
#     that takes one byte too many or too few.
#   * test_copy_size_zero_is_64k: the rule that a copy size of 0 means
#     0x10000 (a delta of a 64 KiB copy would rebuild nothing).
#   * test_multi_byte_sizes: the header sizes as little-endian base-128
#     (a big-endian reading gives other sizes and the base check fails).
#   * test_refusals: each refusal by its exact message: a base of the
#     wrong size, a result over the limit, opcode 0, a copy past the base,
#     an insert past the delta, a result past or short of its size, a
#     truncated header or copy, a size varint over 64 bits.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import apply_delta, read_delta_header


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _varint(mut out: List[UInt8], v: Int):
    var x = v
    while x >= 128:
        out.append(UInt8((x & 127) | 128))
        x >>= 7
    out.append(UInt8(x))


def _header(base_size: Int, result_size: Int) -> List[UInt8]:
    var out = List[UInt8]()
    _varint(out, base_size)
    _varint(out, result_size)
    return out^


def _err(base: List[UInt8], delta: List[UInt8], max_size: Int = 1 << 20) -> String:
    try:
        _ = apply_delta(Span(base), Span(delta), max_size)
        return "OK"
    except e:
        return String(e)


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def test_copy_and_insert() raises:
    var base = _bytes("hello, world: the base object")
    # "world" (copy 5 at 7), " says " (insert), "hello" (copy 5 at 0).
    var d = _header(len(base), 16)
    d.append(0x91)  # copy: offset byte 0, size byte 0
    d.append(7)
    d.append(5)
    d.append(6)  # insert 6
    d.extend(Span(_bytes(" says ")))
    d.append(0x90)  # copy: no offset byte (0), size byte 0
    d.append(5)
    var out = apply_delta(Span(base), Span(d), 100)
    assert_equal(_text(out), "world says hello")
    # Offset bytes 1 and 2 present, byte 0 absent: offset 0x000300 + 0.
    var big = List[UInt8](length=0x400, fill=UInt8(0))
    big[0x300] = 65
    big[0x301] = 66
    var d2 = _header(len(big), 2)
    d2.append(0x80 | 0x02 | 0x10)  # offset byte 1 only, size byte 0
    d2.append(0x03)
    d2.append(2)
    assert_equal(_text(apply_delta(Span(big), Span(d2), 100)), "AB")
    var head = read_delta_header(Span(d))
    assert_equal(head.base_size, len(base))
    assert_equal(head.result_size, 16)
    assert_equal(head.instructions_start, 2)


def test_copy_size_zero_is_64k() raises:
    var base = List[UInt8](length=0x10000 + 3, fill=UInt8(7))
    base[0x10000 + 2] = 9
    var d = _header(len(base), 0x10000 + 1)
    d.append(0x80)  # copy: offset 0, size absent = 0x10000
    d.append(0x80 | 0x01 | 0x04 | 0x10)  # copy: offset bytes 0 and 2, size byte 0
    d.append(0x02)
    d.append(0x01)
    d.append(1)
    var out = apply_delta(Span(base), Span(d), 1 << 20)
    assert_equal(len(out), 0x10000 + 1)
    assert_equal(Int(out[0xFFFF]), 7)
    assert_equal(Int(out[0x10000]), 9)


def test_multi_byte_sizes() raises:
    var base = List[UInt8](length=300, fill=UInt8(1))
    var d = _header(300, 200)
    # 300 = 0xAC 0x02, 200 = 0xC8 0x01
    assert_equal(Int(d[0]), 0xAC)
    assert_equal(Int(d[1]), 0x02)
    assert_equal(Int(d[2]), 0xC8)
    assert_equal(Int(d[3]), 0x01)
    d.append(0x90)
    d.append(200)
    assert_equal(len(apply_delta(Span(base), Span(d), 1000)), 200)


def test_refusals() raises:
    var p = "komira_git: delta: "
    var base = _bytes("0123456789")
    var d = _header(9, 1)
    d.append(1)
    d.append(65)
    assert_equal(_err(base, d), p + "expects a base of 9 bytes, the base is 10")
    d = _header(10, 5000)
    assert_equal(_err(base, d, 4999), p + "result of 5000 bytes is over the limit 4999")
    d = _header(10, 1)
    d.append(0)
    assert_equal(_err(base, d), p + "opcode 0 is reserved")
    d = _header(10, 4)
    d.append(0x91)
    d.append(8)
    d.append(4)
    assert_equal(_err(base, d), p + "copy of 4 bytes at 8 runs past the 10-byte base")
    d = _header(10, 4)
    d.append(5)
    d.append(65)
    assert_equal(_err(base, d), p + "insert of 5 bytes runs past the end of the delta")
    d = _header(10, 2)
    d.append(3)
    d.extend(Span(_bytes("abc")))
    assert_equal(_err(base, d), p + "result runs past its declared 2 bytes")
    d = _header(10, 2)
    d.append(0x90)
    d.append(3)
    assert_equal(_err(base, d), p + "result runs past its declared 2 bytes")
    d = _header(10, 3)
    d.append(2)
    d.extend(Span(_bytes("ab")))
    assert_equal(_err(base, d), p + "result is 2 bytes, the header says 3")
    d = List[UInt8]()
    d.append(0x8A)
    assert_equal(_err(base, d), p + "truncated header")
    d = _header(10, 3)
    d.append(0x91)
    d.append(1)
    assert_equal(_err(base, d), p + "truncated copy instruction")
    d = _header(10, 3)
    d.append(0x81)  # an offset byte announced, none follows
    assert_equal(_err(base, d), p + "truncated copy instruction")
    d = List[UInt8]()
    for _ in range(10):
        d.append(0xFF)
    d.append(1)
    assert_equal(_err(base, d), p + "size does not fit 64 bits")
    d = _header(10, 0)
    assert_equal(_err(base, d), "OK")


def main() raises:
    test_copy_and_insert()
    test_copy_size_zero_is_64k()
    test_multi_byte_sizes()
    test_refusals()
    print("komira_git delta tests passed")
