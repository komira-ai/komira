# =============================================================================
# Falsifier: the DICTIONARY merge must not be O(d^2)
# =============================================================================
#
# THE HAZARD. `_concat_variable_width_batches` routes a whole batch onto the
# pair-wise fold the moment ONE column is BOOL or DICTIONARY. A fold whose
# DICTIONARY arm merges the per-row-group dictionaries with a LINEAR SCAN over
# a `List[String]` assumes the merged cardinality is small; but a
# DuckDB-written parquet writes a dictionary PER ROW GROUP, so a TPC-H SF1
# lineitem interns ~5.7M distinct `l_comment` values across 49 row groups and
# such a fold costs Σ k·d² ≈ 1.6e13 string comparisons — ~70x the wall of the
# same concat over PLAIN strings, byte-identical output.
#
# WHY THIS TEST IS A COUNTER AND NOT A CLOCK. A wall-clock threshold makes a
# flaky build gate. So the PRIMARY assertion is a deterministic OPERATION
# COUNT: `DictInterner` and a linear scan both report one "probe" per
# candidate byte-string comparison, flushed once per merge into a
# process-global counter, and the assertion is the O(d) bound
#
#     probes <= PROBE_SLACK * sum(dict_size_i)
#
# At N=4 batches x d=4000 disjoint entries a linear-scan fold performs
# ~1.1e8 probes against a bound of 128,000 — it fails by ~880x, in about a
# second, on any machine, with no timing surface at all.
#
# ⚠ A FAST MERGE THAT IS WRONG PRODUCES WRONG VALUES WITH NO CRASH, so the
# probe bound is never asserted alone. Every probe test here is paired with a
# value oracle, and `test_dict_concat_matches_plain_control` reproduces the
# one-bit-flip control as an in-process equivalence: the same logical values
# built once as DICTIONARY (disjoint per-batch dictionaries) and once as
# STRING must concat to the same rows.
# =============================================================================

from std.memory import alloc, UnsafePointer
from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.concat import _concat_columns
from komira_arrow.dict_interner import (
    DictInterner,
    dict_merge_probe_count,
    reset_dict_merge_probe_count,
)
from komira_arrow.dictionary_merge import merge_dict_columns
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    Schema,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_arrow.streaming_concat import (
    _concat_variable_width_batches,
)
from komira_buffer.heap_region import HeapRegion


# Slack over the O(d) floor. Open addressing at <= 50% load averages ~1.5
# occupied slots examined per lookup; 8 leaves an order of magnitude of head
# room and is still ~3 orders below the quadratic fold at this size.
comptime PROBE_SLACK = 8

comptime N_BATCHES = 4
comptime DICT_D = 4000


# =============================================================================
# builders
# =============================================================================


def _mk_dict_column(
    dict_values: List[String], indices: List[Int32]
) raises -> Column[HeapRegion]:
    """A DICTIONARY Column with the given dictionary and raw index stream."""
    comptime int32_size = size_of[Int32]()
    var dict_arr = StringArray.from_strings(dict_values)
    var n = len(indices)
    var idx_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
    for i in range(n):
        idx_buf.set_typed[Int32](i, indices[i])
    idx_buf.set_length(Int64(n * int32_size))
    var idx_arr = PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)
    var sda = StringDictionaryArray(idx_arr^, dict_arr^, n)
    return Column.from_dictionary(sda)


def _dict_batch(
    dict_values: List[String], indices: List[Int32]
) raises -> RecordBatch:
    var col = _mk_dict_column(dict_values, indices)
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DICTIONARY, False))
    return RecordBatch.from_typed_columns_1(sb.build()^, col^)


def _string_batch(values: List[String]) raises -> RecordBatch:
    var col = Column.from_string(StringArray.from_strings(values)^)
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    return RecordBatch.from_typed_columns_1(sb.build()^, col^)


def _disjoint_dict(batch: Int, d: Int) -> List[String]:
    """`d` entries none of which appears in any other batch's dictionary."""
    var out = List[String]()
    for i in range(d):
        out.append(String("b") + String(batch) + String("_key_") + String(i))
    return out^


def _identity_indices(d: Int) -> List[Int32]:
    var out = List[Int32]()
    for i in range(d):
        out.append(Int32(i))
    return out^


def _resolve_dict_column(c: Column[HeapRegion]) raises -> List[String]:
    """Every row of a DICTIONARY column, resolved through its dictionary."""
    var out = List[String]()
    for i in range(c._length):
        var code = Int(c._data.get_typed[Int32](i))
        var bv = c.string_dict_value_at(code)
        var buf = List[UInt8](capacity=bv.len() + 1)
        bv.copy_to(buf, 0, bv.len())
        buf.append(UInt8(0))
        # SAFETY: `buf` is alive through the String ctor, which copies.
        out.append(String(unsafe_from_utf8_ptr=buf.unsafe_ptr()))
    return out^


def _resolve_string_column(c: Column[HeapRegion]) raises -> List[String]:
    var out = List[String]()
    var sa = c.as_string()
    for i in range(c._length):
        out.append(String(sa.get(i)))
    return out^


# =============================================================================
# PRIMARY — the deterministic probe bound, on the live pair-wise fold
# =============================================================================


def test_dict_concat_probe_bound_streaming_fold() raises:
    """`_concat_variable_width_batches` on N DICTIONARY batches with disjoint
    dictionaries must intern in O(sum of dict sizes), not O(sum k*d^2).

    A linear scan reports 119,994,000 probes against a bound of 128,000
    (937x over); the interner reports 15,118.

    ⚠ WHAT THIS BOUND DOES **NOT** PROVE. The pair-wise fold re-seeds the
    interner from the accumulated left dictionary at every step, so the fold is
    still O(N^2 * d) BYTE COPIES even though each probe is now O(1) — at N=4
    that is 24,000 seeds + 12,000 lookups, comfortably inside 8*N*d, and at
    N=49 it would not be. Removing that term is the N-way merge (wire
    `merge_dict_columns` into the sink), a separate change. The defect this
    bound falsifies is the QUADRATIC-IN-CARDINALITY scan, which is the term
    that makes a multi-million-entry merge unable to finish at all.
    """
    var staging = alloc[Optional[RecordBatch]](N_BATCHES)
    for k in range(N_BATCHES):
        (staging + k).unsafe_write(
            Optional[RecordBatch](
                _dict_batch(_disjoint_dict(k, DICT_D), _identity_indices(DICT_D))
            )
        )

    reset_dict_merge_probe_count()
    var out = _concat_variable_width_batches(staging, N_BATCHES)
    var probes = dict_merge_probe_count()
    staging.free()

    assert_equal(
        out.num_rows(), N_BATCHES * DICT_D, "fold must preserve row count"
    )

    # ANTI-VACUITY. A bound-only assertion is satisfied by a merge that reports
    # ZERO probes -- which is what a reverted fix that also drops the counter
    # looks like. 16000 entries in an open-addressed table held at <= 50% load
    # collide with probability indistinguishable from 1 (measured: 15118), so a
    # zero here means the counter is not wired to whatever performed the merge,
    # or the merge did not run. Either way the bound below proves nothing.
    assert_true(
        probes > 0,
        String("probe counter reported 0 -- the dictionary merge is not")
        + String(" instrumented, so the bound below is vacuous"),
    )

    var bound = PROBE_SLACK * N_BATCHES * DICT_D
    assert_true(
        probes <= bound,
        String("dictionary merge is super-linear: ")
        + String(probes)
        + String(" candidate comparisons for ")
        + String(N_BATCHES * DICT_D)
        + String(" dictionary entries (bound ")
        + String(bound)
        + String("). The merge is scanning the merged dictionary linearly."),
    )

    # VALUE ORACLE on the same output: every row must still resolve to the
    # value its own batch's dictionary held.
    ref col = out.column_at(0)
    assert_equal(col.arrow_type, ArrowType.DICTIONARY, "output stays DICTIONARY")
    var got = _resolve_dict_column(col)
    assert_equal(len(got), N_BATCHES * DICT_D, "resolved row count")
    for k in range(N_BATCHES):
        var expect = _disjoint_dict(k, DICT_D)
        for i in range(DICT_D):
            assert_equal(
                got[k * DICT_D + i],
                expect[i],
                String("row ") + String(k * DICT_D + i),
            )


def test_merge_dict_columns_probe_bound() raises:
    """The SAME defect in `merge_dict_columns` — the N-way helper whose own
    docstring asserted K "<< 10^4". Disjoint dictionaries, same bound."""
    var cols = Slab[Column[HeapRegion]]()
    for k in range(N_BATCHES):
        cols.append(
            _mk_dict_column(_disjoint_dict(k, DICT_D), _identity_indices(DICT_D))
        )

    reset_dict_merge_probe_count()
    var merged = merge_dict_columns(cols)
    var probes = dict_merge_probe_count()

    # ANTI-VACUITY -- see `test_dict_concat_probe_bound_streaming_fold`.
    assert_true(
        probes > 0,
        String("probe counter reported 0 -- merge_dict_columns is not")
        + String(" instrumented, so the bound below is vacuous"),
    )

    var bound = PROBE_SLACK * N_BATCHES * DICT_D
    assert_true(
        probes <= bound,
        String("merge_dict_columns is super-linear: ")
        + String(probes)
        + String(" candidate comparisons, bound ")
        + String(bound),
    )

    assert_equal(merged._length, N_BATCHES * DICT_D, "merged row count")
    assert_equal(merged._dict_size, N_BATCHES * DICT_D, "merged dict size")
    var got = _resolve_dict_column(merged)
    for k in range(N_BATCHES):
        var expect = _disjoint_dict(k, DICT_D)
        for i in range(DICT_D):
            assert_equal(got[k * DICT_D + i], expect[i], "merged row")


# =============================================================================
# VALUE ORACLES — a fast merge that is wrong is silent
# =============================================================================


def test_dict_concat_overlapping_and_disjoint_values() raises:
    """Overlap, disjointness, and a value present in one row group and absent
    from another — the shapes a remap bug corrupts without crashing."""
    # B0 dict: alpha bravo charlie   B1: delta bravo   B2: charlie echo alpha
    var b0 = _mk_dict_column(
        [String("alpha"), String("bravo"), String("charlie")],
        [Int32(0), Int32(1), Int32(2), Int32(0)],
    )
    var b1 = _mk_dict_column(
        [String("delta"), String("bravo")],
        [Int32(0), Int32(1), Int32(0)],
    )
    var b2 = _mk_dict_column(
        [String("charlie"), String("echo"), String("alpha")],
        [Int32(1), Int32(0), Int32(2)],
    )

    var acc = _concat_columns(b0, b1)
    var out = _concat_columns(acc, b2)

    var expect = [
        String("alpha"),
        String("bravo"),
        String("charlie"),
        String("alpha"),
        String("delta"),
        String("bravo"),
        String("delta"),
        String("echo"),
        String("charlie"),
        String("alpha"),
    ]
    var got = _resolve_dict_column(out)
    assert_equal(len(got), len(expect), "row count")
    for i in range(len(expect)):
        assert_equal(got[i], expect[i], String("row ") + String(i))

    # First-seen insertion order is part of the contract: several byte-equiv
    # oracles compare merged dictionary buffers byte-for-byte.
    assert_equal(out._dict_size, 5, "merged dictionary cardinality")
    var order = List[String]()
    for e in range(out._dict_size):
        var bv = out.string_dict_value_at(e)
        var buf = List[UInt8](capacity=bv.len() + 1)
        bv.copy_to(buf, 0, bv.len())
        buf.append(UInt8(0))
        # SAFETY: `buf` alive through the String ctor, which copies.
        order.append(String(unsafe_from_utf8_ptr=buf.unsafe_ptr()))
    var expect_order = [
        String("alpha"),
        String("bravo"),
        String("charlie"),
        String("delta"),
        String("echo"),
    ]
    for i in range(len(expect_order)):
        assert_equal(order[i], expect_order[i], "first-seen dictionary order")


def test_dict_concat_preserves_duplicate_seed_entries() raises:
    """A parquet dictionary page is not required to hold DISTINCT values, and
    the left input's index buffer is copied through UNCHANGED — so a duplicate
    in the left dictionary must keep its ordinal. Interning the seed would
    dedupe it and shift every later index, producing wrong values silently."""
    var a = _mk_dict_column(
        [String("x"), String("y"), String("x")],
        [Int32(0), Int32(1), Int32(2)],
    )
    var b = _mk_dict_column(
        [String("x"), String("z")],
        [Int32(0), Int32(1)],
    )
    var out = _concat_columns(a, b)
    var got = _resolve_dict_column(out)
    var expect = [
        String("x"),
        String("y"),
        String("x"),
        String("x"),
        String("z"),
    ]
    assert_equal(len(got), len(expect), "row count")
    for i in range(len(expect)):
        assert_equal(got[i], expect[i], String("row ") + String(i))
    # The duplicate stays: 3 seeded ordinals + "z".
    assert_equal(out._dict_size, 4, "seed duplicates are preserved verbatim")


def _mk_raw_dict_column(
    entries: List[List[UInt8]], indices: List[Int32]
) raises -> Column[HeapRegion]:
    """A DICTIONARY Column whose dictionary entries are RAW BYTES.

    Built from offsets + data directly rather than through
    `StringArray.from_strings`, so an entry may contain a 0x00 byte — which a
    `List[String]`-based merge cannot represent.
    """
    comptime int32_size = size_of[Int32]()
    var n_entries = len(entries)
    var offs = OwnedAlignedBuffer((n_entries + 1) * int32_size)
    offs.set_typed[Int32](0, Int32(0))
    var total = 0
    for i in range(n_entries):
        total += len(entries[i])
        offs.set_typed[Int32](i + 1, Int32(total))
    offs.set_length(Int64((n_entries + 1) * int32_size))

    var data = OwnedAlignedBuffer(max(total, 1))
    var w = 0
    for i in range(n_entries):
        ref bytes = entries[i]
        for b in range(len(bytes)):
            data.write_u8_at(w, bytes[b])
            w += 1
    data.set_length(Int64(total))

    var dict_arr = StringArray[HeapRegion](offs^, data^, None, n_entries, total, 0)
    var n = len(indices)
    var idx_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
    for i in range(n):
        idx_buf.set_typed[Int32](i, indices[i])
    idx_buf.set_length(Int64(n * int32_size))
    var idx_arr = PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)
    var sda = StringDictionaryArray(idx_arr^, dict_arr^, n)
    return Column.from_dictionary(sda)


def test_dict_concat_does_not_truncate_at_embedded_nul() raises:
    """Dictionary entries that differ only AFTER a 0x00 byte are DISTINCT.

    A BYTE_ARRAY parquet column may hold arbitrary bytes. A merge that
    materializes every entry as `String(unsafe_from_utf8_ptr=<scratch + NUL>)`
    STOPS AT THE FIRST 0x00: `ab\x00c` and `ab\x00d` both become `ab`,
    compare equal, and are folded into ONE dictionary entry whose payload has
    also been truncated to two bytes — silently wrong values, no crash, no
    diagnostic.

    Such a merge resolves row 1 to `ab` instead of `ab\x00d`.
    """
    var e_c = List[UInt8]()
    e_c.append(UInt8(97))
    e_c.append(UInt8(98))
    e_c.append(UInt8(0))
    e_c.append(UInt8(99))
    var e_d = List[UInt8]()
    e_d.append(UInt8(97))
    e_d.append(UInt8(98))
    e_d.append(UInt8(0))
    e_d.append(UInt8(100))

    var a_entries = List[List[UInt8]]()
    a_entries.append(e_c.copy())
    var b_entries = List[List[UInt8]]()
    b_entries.append(e_d.copy())

    var a = _mk_raw_dict_column(a_entries, [Int32(0)])
    var b = _mk_raw_dict_column(b_entries, [Int32(0)])
    var out = _concat_columns(a, b)

    assert_equal(out._dict_size, 2, "the two entries must not be conflated")
    assert_equal(out._length, 2, "row count")

    var row0 = out.string_dict_value_at(Int(out._data.get_typed[Int32](0)))
    var row1 = out.string_dict_value_at(Int(out._data.get_typed[Int32](1)))
    assert_equal(row0.len(), 4, "row 0 keeps all 4 bytes")
    assert_equal(row1.len(), 4, "row 1 keeps all 4 bytes")
    assert_equal(Int(row0.read_u8_at(3)), 99, "row 0 trailing byte is 'c'")
    assert_equal(Int(row1.read_u8_at(3)), 100, "row 1 trailing byte is 'd'")
    assert_equal(Int(row0.read_u8_at(2)), 0, "row 0 keeps the NUL")
    assert_equal(Int(row1.read_u8_at(2)), 0, "row 1 keeps the NUL")


def test_dict_concat_matches_plain_control() raises:
    """The one-bit-flip control, in process: the same logical values built once
    as DICTIONARY (disjoint per-batch dictionaries) and once as STRING must
    concat to identical rows."""
    comptime n = 3
    comptime d = 64

    var dict_staging = alloc[Optional[RecordBatch]](n)
    var plain_staging = alloc[Optional[RecordBatch]](n)
    var expect = List[String]()
    for k in range(n):
        var vals = _disjoint_dict(k, d)
        for i in range(d):
            expect.append(vals[i])
        (dict_staging + k).unsafe_write(
            Optional[RecordBatch](_dict_batch(vals, _identity_indices(d)))
        )
        (plain_staging + k).unsafe_write(
            Optional[RecordBatch](_string_batch(vals))
        )

    var dict_out = _concat_variable_width_batches(dict_staging, n)
    var plain_out = _concat_variable_width_batches(plain_staging, n)
    dict_staging.free()
    plain_staging.free()

    var got_dict = _resolve_dict_column(dict_out.column_at(0))
    var got_plain = _resolve_string_column(plain_out.column_at(0))
    assert_equal(len(got_dict), n * d, "dict arm row count")
    assert_equal(len(got_plain), n * d, "plain arm row count")
    for i in range(n * d):
        assert_equal(got_dict[i], got_plain[i], "ARM-DICT vs ARM-PLAIN")
        assert_equal(got_dict[i], expect[i], "ARM-DICT vs expected")


# =============================================================================
# The primitive itself
# =============================================================================


def _intern(mut di: DictInterner, s: String) raises -> Int32:
    var sa = StringArray.from_strings([s.copy()])
    return di.find_or_insert(sa.data.view_ro().sub(0, s.byte_length()))


def test_dict_interner_basics() raises:
    var di = DictInterner(expected_entries=4)
    assert_equal(Int(_intern(di, String("alpha"))), 0, "first entry")
    assert_equal(Int(_intern(di, String("bravo"))), 1, "second entry")
    assert_equal(Int(_intern(di, String("alpha"))), 0, "repeat resolves")
    assert_equal(di.size(), 2, "cardinality")
    assert_equal(di.total_bytes(), 10, "arena bytes")
    assert_equal(Int(di.offsets()[0]), 0, "offsets start at 0")
    assert_equal(Int(di.offsets()[2]), 10, "offsets are cumulative")


def test_dict_interner_growth_is_linear() raises:
    """Interning M distinct keys must examine O(M) occupied slots, across many
    rehashes. This is the property the whole fix rests on."""
    comptime m = 20000
    var di = DictInterner()
    for i in range(m):
        var s = String("k") + String(i)
        _ = _intern(di, s)
    assert_equal(di.size(), m, "all distinct")
    assert_true(
        di.probes() <= PROBE_SLACK * m,
        String("interner probes ")
        + String(di.probes())
        + String(" exceed ")
        + String(PROBE_SLACK * m),
    )
    # And every key still resolves to its own ordinal after the rehashes.
    for i in range(m):
        var s = String("k") + String(i)
        assert_equal(Int(_intern(di, s)), i, "ordinal survives rehash")


def test_dict_interner_empty_key() raises:
    """A zero-length entry is a real dictionary value, not a sentinel."""
    var di = DictInterner()
    var sa = StringArray.from_strings([String(""), String("a")])
    var empty = di.find_or_insert(sa.data.view_ro().sub(0, 0))
    var a0 = di.find_or_insert(sa.data.view_ro().sub(0, 1))
    var empty2 = di.find_or_insert(sa.data.view_ro().sub(0, 0))
    assert_equal(Int(empty), 0, "empty interns")
    assert_equal(Int(a0), 1, "non-empty is distinct from empty")
    assert_equal(Int(empty2), 0, "empty resolves to itself")
    assert_equal(di.size(), 2, "two entries")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
