# =============================================================================
# test_arrow_ipc_flatbuf_wide_inline_struct.mojo: end_table lays out an
# inline struct field over 255 bytes at its true size
# =============================================================================
#
# add_field_inline_struct records a struct's width in a byte (capped at
# 255) and its true size separately; end_table emits the true size. The
# layout pass must place fields by the true size too: one that uses the
# capped width reserves 255 bytes for a 300-byte struct and refuses the
# table ("inline data layout mismatch"). The test builds a table of a u32
# field and a 300-byte struct (plus a third u32 after it, so a struct
# that overran its slot would clobber a neighbour), finalizes the buffer,
# and reads every field back through the vtable: the vtable's inline size
# counts the whole struct, the struct bytes are intact at their vtable
# offset, and both u32 fields read back. A 255-byte struct is the control
# at the cap.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    add_field_inline_struct,
    add_field_u32,
    end_table,
    flatbuf_reader_over,
    start_table,
)


def _struct_bytes(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 7 + 3) & 0xFF))
    return out^


def _check_wide_struct(n: Int) raises:
    var w = FlatbufWriter(4096)
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(0x21B2C3D4))
    add_field_inline_struct(tb, 1, _struct_bytes(n))
    add_field_u32(tb, 2, UInt32(0x01020304))
    var table = end_table(w, tb^)
    var buf = w^.finalize(table)

    var r = flatbuf_reader_over(buf)
    var tpos = r.read_root_offset()
    var vt = tpos - Int(r.read_i32_le(tpos))
    assert_equal(Int(r.read_u16_le(vt)), 4 + 2 * 3)
    var inline_size = Int(r.read_u16_le(vt + 2))
    var f0 = Int(r.read_u16_le(vt + 4))
    var f1 = Int(r.read_u16_le(vt + 6))
    var f2 = Int(r.read_u16_le(vt + 8))
    # 4-byte soffset, two u32 fields and the struct, at least.
    assert_true(inline_size >= 4 + 4 + 4 + n)
    assert_equal(r.read_u32_le(tpos + f0), UInt32(0x21B2C3D4))
    assert_equal(r.read_u32_le(tpos + f2), UInt32(0x01020304))
    var want = _struct_bytes(n)
    for i in range(n):
        assert_equal(r.read_u8(tpos + f1 + i), want[i])
    # Every field lies inside the table's inline area, without overlap.
    assert_true(f1 + n <= inline_size)
    assert_true(f0 + 4 <= f1 or f1 + n <= f0)
    assert_true(f2 + 4 <= f1 or f1 + n <= f2)
    assert_true(f0 + 4 <= inline_size and f2 + 4 <= inline_size)
    assert_true(f0 + 4 <= f2 or f2 + 4 <= f0)
    # No field overlaps the table's leading 4-byte soffset.
    assert_true(f0 >= 4 and f1 >= 4 and f2 >= 4)


def test_inline_struct_over_255_bytes_round_trips() raises:
    _check_wide_struct(300)


def test_inline_struct_of_1000_bytes_round_trips() raises:
    _check_wide_struct(1000)


def test_inline_struct_at_the_255_cap_round_trips() raises:
    """The control at the cap, where width and true size agree."""
    _check_wide_struct(255)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
