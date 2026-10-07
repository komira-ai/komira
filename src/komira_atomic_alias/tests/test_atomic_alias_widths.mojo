# =============================================================================
# komira_atomic_alias/tests/test_atomic_alias_widths.mojo
#   — the falsifier for the Mojo 1.1 `Atomic` cutover file.
# =============================================================================
#
# `komira_atomic_alias/atypes.mojo` is six `comptime` rows and NOTHING ELSE, so
# there is no behaviour to test — except the two things that actually go wrong
# when somebody edits it:
#
#   1. ⚠ A `comptime` alias is elaborated LAZILY. A row nothing imports is
#      never type-checked at all, so a row spelled for the WRONG compiler
#      generation compiles clean and fails only at the call site that first
#      reaches it. This test NAMES ALL SIX, which forces all six to elaborate.
#   2. A row bound to the wrong WIDTH or the wrong SIGNEDNESS. `size_of` alone
#      cannot see signedness — `AtomicI8` and `AtomicU8` are both one byte — so
#      every row also round-trips a value that only its own dtype can hold: a
#      NEGATIVE one for the signed rows, and the unsigned MAXIMUM (which reads
#      back negative through a signed alias) for the unsigned ones. Those
#      round trips go through `Int`, which is 64 bits wide, so at 64 bits a
#      sign swap wraps in and wraps back out unseen: the bound dtype is
#      therefore also compared exactly, and the two 64-bit rows compare
#      against zero in their own scalar type after a `fetch_sub` below zero.
#
# ⛔ This test must stay green ACROSS the cutover edit. If it goes red after
# `Atomic[DType.int64]` becomes `Atomic[Int64]`, the cutover is wrong — the two
# spellings are the SAME TYPE (measured: identical `size_of`/`align_of` on both
# compilers), so nothing here should move.
# =============================================================================

from std.sys import align_of, size_of
from std.testing import assert_equal, assert_false, assert_true

from komira_atomic_alias import (
    AtomicI8,
    AtomicI32,
    AtomicI64,
    AtomicU8,
    AtomicU32,
    AtomicU64,
)


def test_widths() raises:
    """Each row is bound to the width its NAME claims."""
    assert_equal(size_of[AtomicI8](), 1)
    assert_equal(size_of[AtomicI32](), 4)
    assert_equal(size_of[AtomicI64](), 8)
    assert_equal(size_of[AtomicU8](), 1)
    assert_equal(size_of[AtomicU32](), 4)
    assert_equal(size_of[AtomicU64](), 8)


def test_alignment_is_natural() raises:
    """Natural alignment — a lock-free atomic that is under-aligned is not one."""
    assert_equal(align_of[AtomicI8](), 1)
    assert_equal(align_of[AtomicI32](), 4)
    assert_equal(align_of[AtomicI64](), 8)
    assert_equal(align_of[AtomicU8](), 1)
    assert_equal(align_of[AtomicU32](), 4)
    assert_equal(align_of[AtomicU64](), 8)


def test_signed_rows_hold_negative_values() raises:
    """A signed row round-trips a NEGATIVE value. An unsigned row cannot."""
    var i8 = AtomicI8(-1)
    assert_equal(Int(i8.load()), -1)

    var i32 = AtomicI32(-2_000_000_000)
    assert_equal(Int(i32.load()), -2_000_000_000)

    var i64 = AtomicI64(-9_000_000_000_000_000_000)
    assert_equal(Int(i64.load()), -9_000_000_000_000_000_000)


def test_unsigned_rows_hold_the_unsigned_maximum() raises:
    """An unsigned row round-trips its MAXIMUM, which a signed row reads back
    negative. This is the half `size_of` cannot see."""
    var u8 = AtomicU8(255)
    assert_equal(Int(u8.load()), 255)

    var u32 = AtomicU32(4_294_967_295)
    assert_equal(Int(u32.load()), 4_294_967_295)

    var u64 = AtomicU64(9_223_372_036_854_775_807)
    assert_equal(Int(u64.load()), 9_223_372_036_854_775_807)


def test_dtype_is_pinned_exactly() raises:
    """Each row is bound to EXACTLY the dtype its name claims.

    The round trips above go through `Int`, which is 64 bits wide: a 64-bit
    row bound to the wrong signedness wraps on the way in and wraps back on
    the way out, so `AtomicI64` on `DType.uint64` (or `AtomicU64` on
    `DType.int64`) passes them unchanged. Comparing the bound dtype itself
    sees the swap at every width.
    """
    assert_true(AtomicI8.dtype == DType.int8)
    assert_true(AtomicI32.dtype == DType.int32)
    assert_true(AtomicI64.dtype == DType.int64)
    assert_true(AtomicU8.dtype == DType.uint8)
    assert_true(AtomicU32.dtype == DType.uint32)
    assert_true(AtomicU64.dtype == DType.uint64)


def test_64_bit_rows_compare_with_their_own_sign() raises:
    """Behavioural twin of the dtype check for the two 64-bit rows, where an
    `Int` round trip cannot see signedness. The comparison runs in the row's
    own scalar type, never through `Int`.

    A signed row taken below zero by `fetch_sub` reads back less than zero; an
    unsigned row wraps to its maximum instead. An unsigned row holding its
    maximum reads back greater than zero; a signed row holding the same bits
    reads back -1.
    """
    var i64 = AtomicI64(0)
    _ = i64.fetch_sub(1)
    var i = i64.load()
    assert_true(i < 0)
    assert_true(i == -1)

    var u64 = AtomicU64(0)
    _ = u64.fetch_sub(1)
    var u = u64.load()
    assert_false(u < 0)
    assert_true(u > 0)


def test_fetch_add_round_trip() raises:
    """The RMW path elaborates and observes its own write, on every row."""
    var i8 = AtomicI8(1)
    _ = i8.fetch_add(2)
    assert_equal(Int(i8.load()), 3)

    var i32 = AtomicI32(10)
    _ = i32.fetch_add(32)
    assert_equal(Int(i32.load()), 42)

    var i64 = AtomicI64(42)
    _ = i64.fetch_add(8)
    assert_equal(Int(i64.load()), 50)

    var u8 = AtomicU8(7)
    _ = u8.fetch_add(1)
    assert_equal(Int(u8.load()), 8)

    var u32 = AtomicU32(100)
    _ = u32.fetch_add(5)
    assert_equal(Int(u32.load()), 105)

    var u64 = AtomicU64(1)
    _ = u64.fetch_add(1)
    assert_equal(Int(u64.load()), 2)


def test_store_then_load() raises:
    """`store` is on the alias too — the whole API is the aliased type's."""
    var c = AtomicI64(0)
    c.store(1234)
    assert_equal(Int(c.load()), 1234)


struct _Holder(Movable):
    """A STRUCT FIELD of an aliased type — the shape the tree actually uses.

    This is the case a bare `var x = AtomicI64(0)` does not cover: a field
    declaration forces the alias through layout computation, not just through
    an expression.
    """

    var ctr: AtomicI64
    var flag: AtomicU8

    def __init__(out self):
        self.ctr = AtomicI64(0)
        self.flag = AtomicU8(0)


def test_alias_as_struct_field() raises:
    var h = _Holder()
    _ = h.ctr.fetch_add(5)
    h.flag.store(1)
    assert_equal(Int(h.ctr.load()), 5)
    assert_equal(Int(h.flag.load()), 1)


def main() raises:
    test_widths()
    test_alignment_is_natural()
    test_signed_rows_hold_negative_values()
    test_unsigned_rows_hold_the_unsigned_maximum()
    test_dtype_is_pinned_exactly()
    test_64_bit_rows_compare_with_their_own_sign()
    test_fetch_add_round_trip()
    test_store_then_load()
    test_alias_as_struct_field()
    print("test_atomic_alias_widths: OK")
