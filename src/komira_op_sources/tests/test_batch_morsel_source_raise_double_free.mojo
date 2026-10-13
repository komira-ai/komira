# =============================================================================
# ⛔⛔ A RAISE INSIDE `BatchMorselSource.__init__`'s DRAIN LOOP DOUBLE-FREED THE
#     INPUT BATCHES (2026-09-22).
# =============================================================================
#
# THE DEFECT, in the shape `Slab.take_slot_unchecked`'s own ⛔⛔ clause names:
#
#     for bi in range(n_batches):
#         var chunk = batches.take_slot_unchecked(bi)   # moves out, len UNCHANGED
#         ...
#         split_record_batch(chunk^, rows)              # `raises`
#     batches.set_len_unchecked(0)                      # SKIPPED on a raise
#
# `take_slot_unchecked` is a BITWISE take: the slot's bytes are left exactly as
# they were and `_len_t` is not adjusted, so the length fix has to be a separate
# statement AFTER the loop. An error escaping the loop skips it, the slab
# unwinds still claiming all N slots are live, and its destructor
# `destroy_pointee`s the ones already moved out. For a heap-owning `T` like
# `RecordBatch` — whose column buffers are Arc-shared — that is a DOUBLE FREE,
# not a leak: the Arc refcount is decremented twice for one increment.
#
# ⚠ AND THE LOOP BODY REALLY DOES RAISE ON REAL INPUT. `morsel._slice_column`
# has no LARGE_STRING / LARGE_BINARY arm and refuses one BY NAME
# (`ArrowFixedWidthFallthrough`), which is correct — but every `join` /
# `sort` / `distinct` over a `large_string` PAYLOAD column reaches this drain
# and unwinds through it.
#
# ★ MEASURED, and it is why this is a P0 rather than a tidiness fix. On
# darwin/arm64 at ``, over the cross-surface corpus's own fixture
# (`k int64, g int64, v large_string`, six rows) driven through
# `//src/cmd/plan_matrix_rig` — the Mojo-native untyped door, i.e. a plain
# `ctx.read_parquet(p).join(...)`:
#
#     join_inner_dup/large_string/full       rc=139  SIGSEGV
#     join_left_all/large_string/full        rc=139  SIGSEGV
#     join_left_unmatched/large_string/full  rc=139  SIGSEGV
#     join_semi/large_string/full            rc=139  SIGSEGV
#     join_anti/large_string/full            rc=139  SIGSEGV
#     join_inner_k/large_string/full         rc=9    clean REFUSED
#
# every crash inside tcmalloc's free list, in THREE different destructors
# (`LogicalPlan::__deinit__`, `Slab[JoinProbeOpAdapter]::__deinit__`,
# `SharedEngine::__deinit__` at process exit). The farm run at ``
# crashed a DIFFERENT subset of the same cells at the same commit-range. One
# write, many victims: the crash SITE is not the bug site, and which cells die
# is a fact about allocator layout on the day.
#
# ⛔⛔ THIS TEST DELIBERATELY DOES NOT ASSERT A CRASH, AND IT DOES NOT USE
#    `large_string`.
#
# Two reasons, both load-bearing:
#
#  1. The double free is UB, not a guaranteed fault (`take_slot_unchecked`'s
#     docstring says so, and `join_inner_k` above is the proof — it raises at
#     the very same line and exits cleanly). A test that asserted "the process
#     dies" would be asserting a coin flip. What IS deterministic is the
#     REFCOUNT ARITHMETIC: one increment, two decrements. So the assertion is
#     on a CANARY that shares the batch's buffers — after the raise the canary
#     must still read its own values.
#
#     ⭐ AND ON THIS BOX THE ALLOCATOR GETS THERE FIRST, WHICH IS BETTER
#     EVIDENCE THAN THE CANARY. Measured red-before, this file against an
#     UNFIXED `batch_morsel_source.mojo` (two worktrees at ``, the
#     only difference being the source fix):
#
#         an internal module] Attempt to free invalid pointer 0x7f
#         ...
#         10  ArcPointer::__deinit__(...T=[HeapRegion...]) + 56
#         11  main + 92
#         Abort trap: 6
#
#     tcmalloc NAMES the second release, in `ArcPointer[HeapRegion]`'s
#     destructor. The gate reports that as a failed build, so the test is red
#     before the fix without reaching a single assertion. ⚠ DO NOT DELETE THE
#     CANARY ASSERTIONS ON THE STRENGTH OF THAT: an allocator that does not
#     validate (or a size class that happens to be reusable) turns the abort
#     back into a silent wrong value, and the canary is the only thing that
#     still sees it.
#
#  2. The trigger here is a **LIST** column, not a `large_string` one. A
#     LARGE_STRING arm in `morsel._slice_column` is a real and wanted fix (see
#     the guard's own message: *"Add an explicit arm for this type"*), and the
#     day it lands it would silently make a `large_string`-triggered test
#     VACUOUS — green because nothing raises any more, which is exactly the
#     shape of a regression guard that stops guarding. LIST carries offsets AND
#     children and has no byte width at all, so no byte-stride copier will ever
#     grow an arm for it: `check_fixed_width_dispatch` will refuse it forever.
#     ⛔ DO NOT "simplify" this fixture to the type that found the bug.
# =============================================================================

from std.sys import size_of
from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.list_array import ListArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_op_sources.batch_morsel_source import BatchMorselSource


comptime _CANARY_ROWS = 4
comptime _CANARY_BASE = Int64(0x5150_4142_4344_4500)


def _mk_int64_column(n: Int, base: Int64) raises -> Column[HeapRegion]:
    """A NON-NULLABLE INT64 column — the layout `split_record_batch` slices
    ZERO-COPY, which is what makes it an Arc-sharing canary."""
    comptime w = size_of[Int64]()
    var buf = OwnedAlignedBuffer(n * w)
    # ⚠ WRITE THROUGH THE TYPED VIEW, THEN `set_length`. `set_typed` bounds-
    # checks against `_length`, which is 0 until it is set; the package's own
    # fixtures use this order for the same reason.
    var p64 = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        p64.unsafe_offset(i)[] = base + Int64(i)
    buf.set_length(Int64(n * w))
    var arr = PrimitiveArray[DType.int64](buf^, n, None, 0, 0)
    return Column.from_primitive[DType.int64](arr)


def _mk_batch_one_column(
    name: String, var col: Column[HeapRegion], at: ArrowType, n: Int
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, False))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(col^)
    return builder.build(sb.build())


def _mk_list_column() raises -> Column[HeapRegion]:
    """A LIST column — `carries_offsets` AND `carries_children`, so
    `morsel._slice_column`'s fixed-width fallthrough refuses it PERMANENTLY."""
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(7)
    l0.append(8)
    lists.append(l0^)
    var l1 = List[Int]()
    l1.append(9)
    lists.append(l1^)
    return Column.from_list(ListArray.from_int_lists(lists))


def _heap_churn(sentinel: UInt8) raises -> Int:
    """Re-allocate the size class the canary's data buffer lives in, and write
    a SENTINEL into every byte.

    ⭐ THIS IS THE HALF THAT TURNS A LATENT DOUBLE FREE INTO AN OBSERVABLE
    WRONG VALUE. A freed-but-still-referenced block reads its ORIGINAL bytes
    until something reuses it; without this loop the canary would very often
    still look right and the test would be a coin flip in the OTHER direction.

    Returns a value derived from the writes so the loop cannot be optimised
    away as dead.
    """
    comptime w = size_of[Int64]()
    var acc = 0
    var keep = List[OwnedAlignedBuffer]()
    for _ in range(256):
        var b = OwnedAlignedBuffer(_CANARY_ROWS * w)
        var p8 = b.view_typed_ro[DType.uint8]()
        for j in range(_CANARY_ROWS * w):
            p8.unsafe_offset(j)[] = sentinel
        b.set_length(Int64(_CANARY_ROWS * w))
        acc += Int(b.view_typed_ro[DType.uint8]().unsafe_offset(0)[])
        keep.append(b^)
    return acc


def test_raise_in_drain_loop_does_not_double_free_the_input() raises:
    """RED BEFORE THE FIX: the canary's rows come back as sentinel bytes.

    Construction, in the order that matters:
      1. batch 0 carries a NON-NULLABLE INT64 column. `split_record_batch`
         slices that layout zero-copy, so a CANARY `share()` of the column
         and the slab's copy hold the SAME Arc-counted buffers.
      2. batch 1 carries a LIST column, which `morsel._slice_column` refuses.
      3. So the drain loop moves slot 0 OUT successfully and then RAISES on
         slot 1 — the exact state in which the pre-fix
         `take_slot_unchecked` + trailing `set_len_unchecked(0)` shape
         destroys slot 0 a SECOND time.
    """
    var canary_src = _mk_int64_column(_CANARY_ROWS, _CANARY_BASE)
    # The canary is an INDEPENDENT owner of the same buffers. It must outlive
    # everything below, so it is taken BEFORE the column is moved into the
    # batch and is never moved again.
    var canary = canary_src.share()

    var batches = Slab[RecordBatch].create(2)
    batches.append(
        _mk_batch_one_column(
            String("v"), canary_src^, ArrowType.INT64, _CANARY_ROWS
        )
    )
    batches.append(
        _mk_batch_one_column(String("v"), _mk_list_column(), ArrowType.LIST, 2)
    )

    # ⚠ THE BATCHES DELIBERATELY DISAGREE ON COLUMN TYPE. The ctor's
    # `from_record_batches` contract wants one schema; what is under test is
    # the UNWIND, and the LIST batch has to be the one that raises. If a
    # future ctor rejects the mismatch BEFORE the drain loop this test goes
    # vacuous — so the refusal text is asserted, not merely the raise.
    var raised = False
    var msg = String("")
    try:
        var src = BatchMorselSource(batches^, 2)
        _ = src^
    except e:
        raised = True
        msg = String(e)

    assert_true(
        raised,
        String(
            "PREMISE: BatchMorselSource must REFUSE a LIST column; it"
            " returned normally, so this test exercised no unwind at all"
        ),
    )
    assert_true(
        msg.find("ArrowFixedWidthFallthrough") >= 0,
        String(
            "PREMISE: the refusal must be `morsel._slice_column`'s"
            " fixed-width fallthrough — that is the raise whose unwind is"
            " under test. Got: "
        )
        + msg,
    )
    assert_true(
        msg.find("_slice_column") >= 0,
        String("PREMISE: the refusal must name the site. Got: ") + msg,
    )

    # The slab has been destroyed by the unwind. Reuse its size class.
    var churn = _heap_churn(UInt8(0xAB))
    assert_true(churn >= 0, String("churn loop must not be elided"))

    # ★ THE ASSERTION. One increment, one decrement: the canary still owns its
    # buffers and reads its own values. Pre-fix the buffers were released a
    # second time by the slab's destructor walking a moved-from slot, and the
    # churn above then re-issued them.
    var got = canary.as_primitive[DType.int64]()
    assert_equal(
        got.length,
        _CANARY_ROWS,
        String("canary row count survived the unwind"),
    )
    for i in range(_CANARY_ROWS):
        assert_equal(
            Int(got.get(i)),
            Int(_CANARY_BASE + Int64(i)),
            String("canary row ")
            + String(i)
            + String(
                " was released by the unwind and re-issued to the churn loop"
                " — the input batch slab double-freed a moved-from slot"
            ),
        )


def test_clean_drain_still_consumes_every_batch() raises:
    """THE OTHER DIRECTION: with no raise, the drain must still yield every
    row exactly once. `replace(bi, RecordBatch())` leaves an EMPTY batch in
    each slot rather than shrinking the slab, and an empty batch that reached
    the morsel stream would show up here as extra morsels or a short count."""
    var batches = Slab[RecordBatch].create(2)
    batches.append(
        _mk_batch_one_column(
            String("v"), _mk_int64_column(4, Int64(100)), ArrowType.INT64, 4
        )
    )
    batches.append(
        _mk_batch_one_column(
            String("v"), _mk_int64_column(3, Int64(200)), ArrowType.INT64, 3
        )
    )

    var src = BatchMorselSource(batches^, 2)
    var seen = 0
    var values = List[Int]()
    while True:
        var m_opt = src.next_morsel(0)
        if not m_opt:
            break
        var m = m_opt.take()
        var col = m.batch.column_at(0).as_primitive[DType.int64]()
        for i in range(col.length):
            values.append(Int(col.get(i)))
        seen += m.batch.num_rows()

    assert_equal(seen, 7, String("every row of both batches is yielded once"))
    var want = List[Int]()
    for i in range(4):
        want.append(100 + i)
    for i in range(3):
        want.append(200 + i)
    assert_equal(len(values), len(want), String("value count"))
    for i in range(len(want)):
        assert_equal(values[i], want[i], String("value at ") + String(i))


def main() raises:
    test_raise_in_drain_loop_does_not_double_free_the_input()
    print("PASS: test_raise_in_drain_loop_does_not_double_free_the_input")
    test_clean_drain_still_consumes_every_batch()
    print("PASS: test_clean_drain_still_consumes_every_batch")
