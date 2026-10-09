"""The branches of `scan_dedup_cache` the welded tests do not reach: the
`share_on` switch's copy arm, the flag-driven byte budget and the
RAM-sized constructor, the cap clamps, a duplicate insert, the hit counters
and the per-key miss, and the bytes estimate of every buffer kind.

Each test names the mutant it catches in its docstring.
"""

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_host.proc_probe import detect_scan_cache_ram_basis_bytes

from komira_dispatch_scan.scan_dedup_cache import (
    SCAN_DEDUP_MAX_BYTES_CEILING,
    SCAN_DEDUP_MAX_BYTES_DEFAULT,
    SCAN_DEDUP_MAX_ENTRIES_DEFAULT,
    SCAN_DEDUP_MIN_BYTES,
    ScanDedupCache,
    _estimate_batch_bytes,
    _scan_dedup_budget_from_ram,
    resolve_scan_dedup_max_bytes,
)


comptime _GIB: Int = 1 << 30


def _hit(mut cache: ScanDedupCache, key: String) raises -> RecordBatch:
    """The batch a hit returns (the test fails on a miss)."""
    var o = cache.lookup_copy(key)
    assert_true(Bool(o), "expected a hit on " + key)
    return o.take()


def _ints(n: Int) raises -> RecordBatch:
    """One non-null INT64 column of `n` rows: exactly `n * 8` data bytes."""
    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int64(i * 3))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](a^))
    return b.build(sb.build())


# =============================================================================
# The share switch
# =============================================================================


def _poke_row0(mut b: RecordBatch):
    """Write 123 into the low byte of row 0 of column 0, in place. A batch
    that shares that buffer sees the write; a copy does not."""
    var patch = List[UInt8]()
    patch.append(UInt8(123))
    b._columns[0]._data.copy_from_bytes_list_at(0, patch)


def test_share_off_hands_out_an_independent_copy() raises:
    """With `share_on=False` a hit is a deep copy: equal cells, and a write
    into one hit's buffer is not seen by the next hit.
    MUTANT: ignore `_share_on` (always share) and the second hit sees the
    write."""
    var cache = ScanDedupCache(share_on=False)
    assert_false(cache.share_on())
    cache.insert(String("k"), _ints(16))
    var got = _hit(cache, String("k"))
    assert_equal(got.num_rows(), 16)
    assert_equal(got.column_at(0).as_primitive[DType.int64]().get(5), Int64(15))
    _poke_row0(got)
    assert_equal(got.column_at(0).as_primitive[DType.int64]().get(0), Int64(123))
    var again = _hit(cache, String("k"))
    assert_equal(
        again.column_at(0).as_primitive[DType.int64]().get(0), Int64(0),
        "a copy must not share the cached buffer",
    )
    var capped = ScanDedupCache(2, 1 << 20, share_on=False)
    assert_false(capped.share_on())


def test_share_on_hands_out_the_cached_buffers() raises:
    """With the default every hit aliases the cached buffer, so a write
    through one hit is seen by the next.
    MUTANT: invert the `if self._share_on` test and the next hit is a copy
    that does not see it."""
    var cache = ScanDedupCache()
    assert_true(cache.share_on())
    cache.insert(String("k"), _ints(16))
    var a = _hit(cache, String("k"))
    _poke_row0(a)
    var b = _hit(cache, String("k"))
    assert_equal(
        b.column_at(0).as_primitive[DType.int64]().get(0), Int64(123),
        "a share aliases the cached buffer",
    )


# =============================================================================
# The byte budget from a flag
# =============================================================================


def test_a_flag_value_overrides_the_ram_basis() raises:
    """MUTANT: ignore `max_bytes_flag` and `8G` is replaced by the RAM
    fraction."""
    assert_equal(resolve_scan_dedup_max_bytes(String("8G")), 8 * _GIB)
    assert_equal(resolve_scan_dedup_max_bytes(String("123")), 123)
    var c = ScanDedupCache.ram_sized(String("2G"))
    assert_equal(c.max_bytes(), 2 * _GIB)
    assert_equal(c.max_entries(), SCAN_DEDUP_MAX_ENTRIES_DEFAULT)
    assert_true(c.share_on())


def test_an_empty_or_malformed_flag_falls_back_to_the_ram_basis() raises:
    """The fallback is the pure policy over this machine's probe, whatever
    it reads: inside [floor, ceiling], or the fixed default when RAM is
    unknown.
    MUTANT: treat an empty flag as a zero-byte override and the budget is
    0."""
    var want = _scan_dedup_budget_from_ram(detect_scan_cache_ram_basis_bytes(), 0)
    assert_equal(resolve_scan_dedup_max_bytes(String("")), want)
    assert_equal(resolve_scan_dedup_max_bytes(String("garbage")), want)
    assert_true(
        want == SCAN_DEDUP_MAX_BYTES_DEFAULT
        or (want >= SCAN_DEDUP_MIN_BYTES and want <= SCAN_DEDUP_MAX_BYTES_CEILING)
    )
    assert_equal(ScanDedupCache.ram_sized(String("")).max_bytes(), want)


# =============================================================================
# Caps, duplicates, counters
# =============================================================================


def test_a_non_positive_cap_is_clamped_to_one() raises:
    """MUTANT: keep a zero entry cap and the eviction loop's `len > 1`
    floor is all that stops it; the cap reads 0."""
    var c = ScanDedupCache(0, -5)
    assert_equal(c.max_entries(), 1)
    assert_equal(c.max_bytes(), 1)
    c.insert(String("a"), _ints(2))
    c.insert(String("b"), _ints(2))
    assert_equal(c.size(), 1)
    assert_true(c.has(String("b")))


def test_a_duplicate_insert_is_a_no_op() raises:
    """The first batch stays, and neither the miss count nor the bytes move.
    MUTANT: drop the duplicate check and the miss count reads 2."""
    var c = ScanDedupCache()
    c.insert(String("k"), _ints(4))
    c.insert(String("k"), _ints(9))
    assert_equal(c.size(), 1)
    assert_equal(c.miss_count(), 1)
    assert_equal(c.total_bytes(), 32)
    assert_equal(_hit(c, String("k")).num_rows(), 4)


def test_the_hit_counters_and_a_missing_key() raises:
    """`hit_count` counts every hit across keys, a miss counts nothing, a
    missing key's per-key count is -1, and `clear` resets the total.
    MUTANT: bump `_hit_count` on a miss too and the total reads 3."""
    var c = ScanDedupCache()
    c.insert(String("a"), _ints(1))
    c.insert(String("b"), _ints(1))
    _ = c.lookup_copy(String("a"))
    _ = c.lookup_copy(String("b"))
    _ = c.lookup_copy(String("zz"))
    assert_equal(c.hit_count(), 2)
    assert_equal(c.hit_count_for(String("a")), 1)
    assert_equal(c.hit_count_for(String("zz")), -1)
    c.clear()
    assert_equal(c.hit_count(), 0)
    assert_equal(c.size(), 0)


# =============================================================================
# The bytes estimate
# =============================================================================


def test_the_estimate_counts_offsets_validity_and_dictionary_bytes() raises:
    """A plain INT64 column is its data; a STRING column adds its offsets; a
    nullable column adds its bitmap; a dictionary column adds its values.
    MUTANT: drop the `_dict_data` term and the dictionary batch estimate
    equals its codes alone."""
    assert_equal(_estimate_batch_bytes(_ints(10)), 80)

    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(9):
        vals.append(String("ab"))
        valid.append(i != 4)
    var bb = RecordBatchBuilder()
    bb.add_column(Column.from_string(StringArray.from_strings_with_validity(vals, valid)))
    var sbatch = bb.build(sb.build())
    ref sc = sbatch.column_at(0)
    var want_s = sc._data.len() + sc._offsets.value().len() + ((sc._validity.value().length + 7) >> 3)
    assert_equal(_estimate_batch_bytes(sbatch), want_s)
    assert_true(Bool(sc._validity), "the fixture must carry a bitmap")

    var dvals = List[String]()
    dvals.append(String("red"))
    dvals.append(String("green"))
    var idx = List[Int32]()
    idx.append(0); idx.append(1); idx.append(0)
    var dsb = SchemaBuilder()
    dsb.add_field(Field(String("d"), ArrowType.STRING, False))
    var dbb = RecordBatchBuilder()
    dbb.add_column(
        Column.from_dictionary(
            StringDictionaryArray.from_parts(
                PrimitiveArray[DType.int32].from_list(idx), StringArray.from_strings(dvals)
            )
        )
    )
    var dbatch = dbb.build(dsb.build())
    ref dc = dbatch.column_at(0)
    assert_true(Bool(dc._dict_data), "the fixture must carry dictionary values")
    var want_d = dc._data.len() + dc._dict_data.value().len()
    if dc._offsets:
        want_d += dc._offsets.value().len()
    if dc._validity:
        want_d += (dc._validity.value().length + 7) >> 3
    assert_equal(_estimate_batch_bytes(dbatch), want_d)
    assert_true(_estimate_batch_bytes(dbatch) > dc._data.len())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
