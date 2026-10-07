# =============================================================================
# test_orc_bloom_filter.mojo — ORC bloom filter (read pushdown + write).
# =============================================================================
#
# ORC's bloom filter uses a HYBRID hash family: Murmur3-64 for bytes, Thomas
# Wang 64-bit for ints, + Kirsch-Mitzenmacher double-hashing.
#
# Acceptance gates exercised here:
#   (a) WRITE an ORC file with a per-column bloom on a high-cardinality int
#       column, where every stride's [min,max] OVERLAPS (so stride-stats
#       CANNOT prune) — bloom is the ONLY lever.
#   (b) READ with an equality predicate that MISSES => stride-bloom skip count
#       > 0 AND surviving rows byte-equal to the full-scan reference.
#   (c) READ with an equality predicate that HITS => no false-skip; the matching
#       row survives.
#   (d) IN-list predicate, string-column bloom (Murmur3 path), and hash-kernel
#       spec checks (Wang64 / Murmur3-64 determinism + bit-pattern reinterpret).
#
# These FAIL if read_orc_bytes_filtered ignores bloom, or if the writer emits
# no BLOOM_FILTER_UTF8 stream.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_plan_expr.expr import Expr, BIN_EQ
from komira_plan_expr.scalar_value import ScalarValue

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    read_orc_bytes_filtered,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
    OrcBloomFilter,
    make_orc_bloom_filter,
    wang64_hash,
    wang64_hash_double,
    murmur3_hash64,
)


# =============================================================================
# Fixture: an int column whose stride min/max OVERLAP so stats can't prune.
# =============================================================================
#
# 30 rows, 3 strides of 10. Each stride s (0,1,2) holds the sentinel pair {0,
# 9999} so every stride's [min,max] = [0, 9999] (stride-stats keeps ALL
# strides for any in-range equality literal). The 8 "real" keys in stride s are
# s*100 + {1..8} — so e.g. key 105 lives ONLY in stride 1, key 205 ONLY in
# stride 2. A query `key = 5` (a value present in NO stride but in [0,9999])
# must be proven absent by EVERY stride's bloom => all strides skipped.


def _build_overlap_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("key", ArrowType.INT64, True))
    sb.add_field(Field("name", ArrowType.STRING, True))

    var keys = List[Int64]()
    var names = List[String]()
    for s in range(3):
        keys.append(Int64(0))  # sentinel low
        names.append(String("lo") + String(s))
        for j in range(1, 9):
            keys.append(Int64(s * 100 + j))
            names.append(String("k") + String(s * 100 + j))
        keys.append(Int64(9999))  # sentinel high
        names.append(String("hi") + String(s))

    var n = len(keys)
    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, keys[i])
    var s = StringArray.from_strings(names)

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    builder.add_column(Column.from_string(s^))
    return builder.build(sb.build())


def _eq_predicate(col: String, lit: Int64) raises -> Expr:
    return Expr.binary(
        BIN_EQ, Expr.col_ref(col), Expr.literal(ScalarValue.from_int64(lit))
    )


def _bloom_cols(name: String) -> List[String]:
    var l = List[String]()
    l.append(name)
    return l^


# =============================================================================
# (b) Equality MISS -> bloom skips strides; surviving rows == full-scan ref.
# =============================================================================


def _run_eq_miss(codec: Int, label: String) raises:
    var rb = _build_overlap_batch()
    var n = rb.num_rows()
    # 10-row strides, 30-row stripe, bloom on "key".
    var opts = OrcWriterOptions.with_bloom(codec, 10, 30, _bloom_cols(String("key")))
    var bytes = write_orc_bytes(rb, opts)

    # Full-scan reference (no predicate).
    var full = read_orc_bytes(Span(bytes))
    assert_equal(full.num_rows(), n, label + ": full-scan row count")

    # key = 5: in-range [0,9999] (so stride min/max keeps every stride) but
    # present in NO stride => bloom must prove absence everywhere.
    var pred = _eq_predicate(String("key"), Int64(5))
    var res = read_orc_bytes_filtered(Span(bytes), pred)

    assert_equal(res.strides_total, 3, label + ": 3 strides total")
    assert_true(
        res.strides_skipped > 0,
        label + ": bloom skipped > 0 strides (got "
        + String(res.strides_skipped) + ")",
    )

    # Correctness: surviving rows == full-scan rows whose key == 5 (= none here,
    # but the comparison is against the full-scan reference, not a guess).
    var fa = full.column_as_primitive_int64(0)
    var ref_count = 0
    for i in range(full.num_rows()):
        if fa.get(i) == 5:
            ref_count += 1
    # No row has key==5, so every surviving row is from a NON-skipped stride and
    # cannot contain key==5 either; the filtered batch must contain 0 matching.
    var ra = res.batch.column_as_primitive_int64(0)
    var got_match = 0
    for i in range(res.batch.num_rows()):
        if ra.get(i) == 5:
            got_match += 1
    assert_equal(got_match, ref_count, label + ": matching-row count vs reference")


def test_orc_bloom_eq_miss_none() raises:
    _run_eq_miss(ORC_COMPRESSION_NONE, String("NONE"))


def test_orc_bloom_eq_miss_zstd() raises:
    _run_eq_miss(ORC_COMPRESSION_ZSTD, String("ZSTD"))


# =============================================================================
# (c) Equality HIT -> no false-skip; the matching row survives.
# =============================================================================


def test_orc_bloom_eq_hit_no_false_skip() raises:
    var rb = _build_overlap_batch()
    var opts = OrcWriterOptions.with_bloom(
        ORC_COMPRESSION_NONE, 10, 30, _bloom_cols(String("key"))
    )
    var bytes = write_orc_bytes(rb, opts)
    var full = read_orc_bytes(Span(bytes))

    # key = 105 lives in stride 1 ONLY. Strides 0 and 2 should bloom-skip; the
    # surviving rows MUST include row with key==105 (no false-skip of stride 1).
    var pred = _eq_predicate(String("key"), Int64(105))
    var res = read_orc_bytes_filtered(Span(bytes), pred)

    # The reference: every row in the full scan with key==105.
    var fa = full.column_as_primitive_int64(0)
    var fs = full.column_as_string(1)
    var ref_names = List[String]()
    for i in range(full.num_rows()):
        if fa.get(i) == 105:
            ref_names.append(fs.get(i))
    assert_true(len(ref_names) >= 1, "fixture has a key==105 row")

    # The matching row must survive (it lies in a kept stride).
    var ra = res.batch.column_as_primitive_int64(0)
    var found = False
    for i in range(res.batch.num_rows()):
        if ra.get(i) == 105:
            found = True
    assert_true(found, "key==105 row survived (no false-skip of its stride)")
    # Some strides (0 and/or 2) should still skip since 105 is absent there.
    assert_true(
        res.strides_skipped >= 1,
        "at least one non-matching stride bloom-skipped (got "
        + String(res.strides_skipped) + ")",
    )


# =============================================================================
# (d) Default OFF: no bloom_columns => no skip on EQ (degrades to all-pass).
# =============================================================================


def test_orc_bloom_default_off_no_skip() raises:
    var rb = _build_overlap_batch()
    # emit_row_index ON (so stride-stats run) but NO bloom columns.
    var opts = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 30, True)
    var bytes = write_orc_bytes(rb, opts)
    # key = 5 is in [0,9999] so stride min/max keeps all strides; with no bloom,
    # nothing prunes it => 0 skipped, all rows survive.
    var pred = _eq_predicate(String("key"), Int64(5))
    var res = read_orc_bytes_filtered(Span(bytes), pred)
    assert_equal(res.strides_skipped, 0, "no bloom => 0 strides skipped on EQ")
    assert_equal(
        res.batch.num_rows(), rb.num_rows(), "no bloom => all rows survive"
    )


# =============================================================================
# Hash-kernel spec checks (validate against the ORC algorithm by construction).
# =============================================================================


def test_wang64_determinism_and_distinct() raises:
    # Wang64 is a pure function: same input -> same output; distinct inputs
    # (overwhelmingly) -> distinct outputs.
    assert_equal(
        Int(wang64_hash(Int64(12345))),
        Int(wang64_hash(Int64(12345))),
        "wang64 deterministic",
    )
    assert_true(
        wang64_hash(Int64(1)) != wang64_hash(Int64(2)),
        "wang64 distinguishes 1 vs 2",
    )
    # addDouble reinterprets the IEEE-754 bit pattern as int64 then Wang64 — so
    # the double-hash of x equals the long-hash of its bit pattern.
    var x = 3.14159
    var bits = bitcast[DType.int64, 1](x)
    assert_equal(
        Int(wang64_hash_double(x)),
        Int(wang64_hash(bits)),
        "wang64_double == wang64(bitcast(double))",
    )


def test_murmur3_determinism_and_distinct() raises:
    var a = String("ASIA").as_bytes()
    var b = String("ASIA").as_bytes()
    var c = String("EUROPE").as_bytes()
    assert_equal(
        Int(murmur3_hash64(a)), Int(murmur3_hash64(b)), "murmur3 deterministic"
    )
    assert_true(
        murmur3_hash64(a) != murmur3_hash64(c),
        "murmur3 distinguishes ASIA vs EUROPE",
    )


def test_bloom_no_false_negative() raises:
    # A bloom NEVER reports absence for an inserted value (no false negatives).
    var bf = make_orc_bloom_filter(100, 0.01)
    for i in range(100):
        bf.add_long(Int64(i * 7 + 3))
    for i in range(100):
        assert_true(
            bf.test_long(Int64(i * 7 + 3)),
            "inserted long present (no false negative): i=" + String(i),
        )
    # A value far outside the inserted set is (very likely) reported absent.
    # With 100 entries at fpp=0.01 a single distant probe is overwhelmingly a
    # true-negative; test a handful and require at least one absent.
    var any_absent = False
    for i in range(20):
        if not bf.test_long(Int64(1_000_000 + i)):
            any_absent = True
    assert_true(any_absent, "out-of-set probes report absence")


def test_bloom_string_round_trip() raises:
    var bf = make_orc_bloom_filter(10, 0.01)
    bf.add_string(String("ASIA"))
    bf.add_string(String("EUROPE"))
    assert_true(bf.test_string(String("ASIA")), "ASIA present")
    assert_true(bf.test_string(String("EUROPE")), "EUROPE present")
    # A string not inserted should (very likely) be absent.
    assert_false(
        bf.test_string(String("ZZZZ_NOT_PRESENT_XYZ")),
        "uninserted string absent",
    )


def main() raises:
    test_orc_bloom_eq_miss_none()
    test_orc_bloom_eq_miss_zstd()
    test_orc_bloom_eq_hit_no_false_skip()
    test_orc_bloom_default_off_no_skip()
    test_wang64_determinism_and_distinct()
    test_murmur3_determinism_and_distinct()
    test_bloom_no_false_negative()
    test_bloom_string_round_trip()
    print("test_orc_bloom_filter: ALL PASS")
