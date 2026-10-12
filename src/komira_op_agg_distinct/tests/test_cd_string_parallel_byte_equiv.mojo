# =============================================================================
# `count(DISTINCT <STRING>)` — the parallel kernel against an INDEPENDENT oracle
# =============================================================================
#
# WHAT THIS PINS. `cd_string_parallel.count_distinct_string_column` answers a
# 0-key `count(DISTINCT s)` over a resident STRING / LARGE_STRING column by
# hashing the column's `(offsets, data)` buffers in place, scattering PACKED
# `(fingerprint, row)` entries into value-hash partitions in parallel, and
# deduping each partition in parallel with a byte-compare verify. It replaced
# running the whole `SELECT DISTINCT <col>` operator and taking the row count of
# its output — a SERIAL insert of every row into an untyped row directory plus
# the materialisation of every distinct VALUE, none of which the caller wanted.
#
# ============================ THE ORACLE =====================================
#
# NOT this kernel, and NOT the kernel's own serial arm alone. Every expectation
# is recomputed from the RAW fixture lists by `_oracle_distinct` — a linear scan
# with a `List[String]` and `==`, no hash, no fingerprint, no packing, no
# partitioning. A defect shared by the parallel and serial arms cannot make this
# file agree with itself.
#
# ============================ THE ARMS =======================================
#
#   §1  DIFFERENTIAL. parallel == serial == raw oracle, over a fixture large
#       enough (>= `_CDSTR_MIN_ROWS`) that the PARALLEL arm is the one running.
#   §2  ⭐ THE SKEW ARM, and the reason the duplicate pre-filter exists. 95% of
#       the fixture is ONE value, the ClickBench Q5 shape (86,825,105 of
#       99,997,497 rows are the empty string). Hash-partitioning by VALUE sends
#       every copy of that value to ONE partition, so this is the fixture where
#       a kernel that scatters per-ROW instead of per-VALUE, or whose pre-filter
#       drops values it has NOT emitted, gives a wrong number.
#   §3  THE NULL RULE. SQL:2016 / DuckDB: `COUNT(DISTINCT x)` does not count
#       NULL. The fixture carries NULLs AND an EMPTY STRING as a real value, so
#       an implementation that merged them, or that counted the NULL, differs
#       from the oracle in a way a null-free fixture cannot see.
#   §4  WORKER-COUNT INVARIANCE. The same fixture at 1 / 2 / 4 / 8 workers gives
#       ONE answer. A partition map that depends on the row's POSITION rather
#       than its VALUE, or a pre-filter whose correctness depends on slice
#       boundaries, moves this number; the value's answer cannot.
#   §5  DEGENERATE COLUMNS. all-NULL -> 0, all-one-value -> 1, empty -> 0.
#   §6  LARGE_STRING. The Int64 offsets layout, strided at its own width.
#   §7  THE PACKING. `(fingerprint, row)` round-trips at row 0, at an interior
#       row and at the last representable row — the arithmetic the 32-bit row
#       guard exists to protect.
#   §8  THE TYPE REFUSAL. An INT64 column RAISES rather than striding an
#       `(offsets, data)` pair that is not there — fail-closed.
#  §10  ⭐ A REAL FINGERPRINT COLLISION — two DIFFERENT strings whose xxHash64
#       agrees in the low 32 bits AND in the partition bits. The only arm that
#       makes the byte-compare confirm load-bearing; without it, deleting the
#       confirm leaves every other arm GREEN (measured).
#   §9  LENGTH AND PREFIX SENSITIVITY. `"ab"`, `"abc"`, `"abcd"`, `"ba"` are
#       four values, and a fixture of 1-byte-apart neighbours is counted at full
#       cardinality — the arm a hash that ignored length, or a verify that
#       compared only the shorter span, would fail.
#
# ============================ REVERT-AND-RED =================================
#
# This file tests the KERNEL, not a caller's route to it: a caller that sends
# `count(DISTINCT <string>)` elsewhere returns the same Int64, so the route is
# carried by `cd_string_kernel_taken_count()`, a process-global counter this
# kernel increments. Inside the kernel: scatter by ROW instead of by HASH ->
# §1/§2/§4 RED. Verify the pre-filter's occupant against `row` instead of
# `crow` -> §1/§2 RED (every fingerprint match then "equals itself" and real
# values are dropped). Drop the null skip -> §3/§5 RED. Verify the fingerprint
# WITHOUT the byte compare, in either the pre-filter or the dedup table -> §10
# RED and nothing else (that is what §10 exists for). Replace all three
# `clen == vlen and bytes_equal(...)` confirms with a bare `clen == vlen` ->
# §10 RED: the collision pair is fixed-width, and
# `test_the_collision_pair_still_collides` pins the two lengths EQUAL (with a
# 6-vs-7-byte pair that mutant passed every case).
#
# =============================================================================

from std.collections import List, Optional
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.cd_string_parallel import (
    _CDSTR_MAX_ROWS,
    _CDSTR_MIN_ROWS,
    _cdstr_fp,
    _cdstr_pack,
    _cdstr_partition_count,
    _cdstr_row,
    _CDSTR_ROW_COST_BYTES,
    _CDSTR_TILES_PER_WORKER,
    cd_string_column_supported,
    cd_string_value_hash,
    cdstr_scan_slices,
    count_distinct_string_column,
    count_distinct_string_column_serial,
)


# =============================================================================
# §0 — HARNESS
# =============================================================================


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _oracle_distinct(
    imm vals: List[String], imm nulls: List[Bool]
) raises -> Int:
    """SQL `COUNT(DISTINCT s)` by linear scan over the RAW lists. No hash, no
    fingerprint, no partition — nothing this kernel also does."""
    var seen: List[String] = []
    for r in range(len(vals)):
        if nulls[r]:
            continue
        var found = False
        for j in range(len(seen)):
            if seen[j] == vals[r]:
                found = True
                break
        if not found:
            seen.append(vals[r])
    return len(seen)


def _string_batch(
    imm vals: List[String], imm nulls: List[Bool], large: Bool = False
) raises -> RecordBatch:
    var n = len(vals)
    var valid = List[Bool](capacity=n)
    var any_null = False
    for r in range(n):
        valid.append(not nulls[r])
        if nulls[r]:
            any_null = True
    var rbb = RecordBatchBuilder.with_capacity(1)
    if large:
        # A REAL Int64-offsets layout, not a STRING column with its type tag
        # rewritten: the kernel strides the offsets buffer at the width the
        # `arrow_type` names, so a relabelled Int32 buffer would test the
        # relabelling and nothing else.
        var larr = LargeStringArray.from_strings_with_validity(vals, valid)
        rbb.add_column(Column.from_large_string(larr^))
    else:
        var sarr = StringArray.from_strings_with_validity(vals, valid)
        rbb.add_column(Column.from_string(sarr^))
    var sb = SchemaBuilder()
    var at = ArrowType.LARGE_STRING if large else ArrowType.STRING
    sb.add_field(Field(String("s"), at, any_null))
    return rbb.build(sb.build())


def _parallel(
    imm batch: RecordBatch, n_workers: Int = 8, bytebal: Bool = True
) raises -> Int64:
    """Drive the kernel over a REAL multi-worker dispatcher."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var got = count_distinct_string_column(
        batch, 0, disp, CancellationToken.new(), bytebal
    )
    _ = rt^
    return got


def _no_nulls(n: Int) raises -> List[Bool]:
    var out = List[Bool](capacity=n)
    for _ in range(n):
        out.append(False)
    return out^


def _rot(seed: UInt64) -> UInt64:
    """A tiny deterministic LCG — the FIXTURE's shuffle, not the kernel's hash.
    Written here on purpose: a fixture generated with the kernel's own hash
    could be blind to a defect in it."""
    return seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)


# =============================================================================
# §1 — THE DIFFERENTIAL, on a fixture the PARALLEL arm actually runs
# =============================================================================


def _mixed_fixture() raises -> List[String]:
    """`_CDSTR_MIN_ROWS + 4096` rows over ~3000 distinct values, in an order no
    slice boundary can make special: the value at row r is a pseudo-random draw,
    so equal values land in different workers' slices."""
    var n = _CDSTR_MIN_ROWS + 4096
    var out = List[String](capacity=n)
    var s = UInt64(0x2545F4914F6CDD1D)
    for _ in range(n):
        s = _rot(s)
        out.append(String("v") + String(Int(s % UInt64(3000))))
    return out^


def test_parallel_equals_serial_equals_raw_oracle() raises:
    var vals = _mixed_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    var par = _parallel(batch)
    var ser = count_distinct_string_column_serial(batch, 0)
    assert_equal(Int(par), oracle)
    assert_equal(Int(ser), oracle)
    _ = batch^


def test_the_differential_fixture_is_above_the_parallel_threshold() raises:
    """FIXTURE-DESIGN PIN. Below `_CDSTR_MIN_ROWS` the driver takes its SERIAL
    arm and §1 would be comparing the serial arm with itself — a differential
    that cannot see a defect in the code it was written for."""
    assert_true(len(_mixed_fixture()) > _CDSTR_MIN_ROWS)


# =============================================================================
# §2 — THE SKEW ARM (the ClickBench Q5 shape, and the pre-filter's reason)
# =============================================================================


def _skewed_fixture() raises -> List[String]:
    """95% ONE value. Every copy hashes to the SAME partition, so this is the
    fixture that separates a value-hash scatter from a row-position one and
    exercises the duplicate pre-filter at the rate the corpus does."""
    var n = _CDSTR_MIN_ROWS + 4096
    var out = List[String](capacity=n)
    var s = UInt64(0x9E3779B97F4A7C15)
    for _ in range(n):
        s = _rot(s)
        if (s % UInt64(100)) < UInt64(95):
            out.append(String(""))
        else:
            out.append(String("p") + String(Int(s % UInt64(700))))
    return out^


def test_skewed_column_counts_exactly() raises:
    var vals = _skewed_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(Int(_parallel(batch)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


def test_the_skew_fixture_is_actually_skewed() raises:
    """FIXTURE-DESIGN PIN. If the dominant value were not dominant this arm
    would be §1 again. Assert the majority share directly."""
    var vals = _skewed_fixture()
    var dom = 0
    for r in range(len(vals)):
        if vals[r] == String(""):
            dom += 1
    assert_true(dom * 2 > len(vals))


# =============================================================================
# §3 — THE NULL RULE, beside a real EMPTY STRING
# =============================================================================


def _null_fixture_vals() raises -> List[String]:
    """NULLs AND `''` as a real value. The two share a byte span (a NULL row's
    offsets are empty), so an implementation that read the payload instead of
    the validity bit would merge them and under-count by one. The values and
    the null mask are generated by the SAME deterministic draw, so the two
    halves stay row-aligned without returning a tuple."""
    var n = _CDSTR_MIN_ROWS + 1024
    var vals = List[String](capacity=n)
    var s = UInt64(0xDEADBEEFCAFEF00D)
    for _ in range(n):
        s = _rot(s)
        var bucket = s % UInt64(10)
        if bucket == UInt64(0):
            # ⚠ THE NULL ROW'S PAYLOAD IS A VALUE THAT EXISTS NOWHERE ELSE.
            # A first version of this fixture gave the null rows the EMPTY
            # STRING, which the fixture ALSO carries as a real value — so an
            # implementation that counted the null row added a value that was
            # already counted and the arm passed. Measured: deleting the null
            # skip left this test GREEN. The payload has to be a value the
            # correct answer does NOT contain.
            vals.append(String("null-payload-carried-by-no-valid-row"))
        elif bucket == UInt64(1):
            # ... and a REAL empty string, so the `''`-vs-NULL merge is still
            # visible in the same fixture.
            vals.append(String(""))
        else:
            vals.append(String("k") + String(Int(s % UInt64(500))))
    return vals^


def _null_fixture_nulls() raises -> List[Bool]:
    var n = _CDSTR_MIN_ROWS + 1024
    var nulls = List[Bool](capacity=n)
    var s = UInt64(0xDEADBEEFCAFEF00D)
    for _ in range(n):
        s = _rot(s)
        nulls.append((s % UInt64(10)) == UInt64(0))
    return nulls^


def test_nulls_are_not_counted_and_empty_string_still_is() raises:
    var vals = _null_fixture_vals()
    var nulls = _null_fixture_nulls()
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(Int(_parallel(batch)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


def _oracle_distinct_if_nulls_were_counted(
    imm vals: List[String], imm nulls: List[Bool]
) raises -> Int:
    """The number a NULL-BLIND implementation returns: distinct over EVERY row,
    payload included. §3 is only evidence if this differs from the truth."""
    var all_valid = List[Bool](capacity=len(vals))
    for _ in range(len(vals)):
        all_valid.append(False)
    return _oracle_distinct(vals, all_valid)


def test_the_null_fixture_can_actually_see_a_counted_null() raises:
    """FIXTURE-DESIGN PIN, and it caught a blind fixture. The fixture must carry
    (a) NULLs, (b) a REAL empty string, and (c) a NULL PAYLOAD that is not also
    a valid value — without (c), counting the null adds a value that was already
    counted and the null rule is untestable."""
    var vals = _null_fixture_vals()
    var nulls = _null_fixture_nulls()
    assert_equal(len(vals), len(nulls))
    var n_null = 0
    var n_empty_value = 0
    for r in range(len(vals)):
        if nulls[r]:
            n_null += 1
        elif vals[r] == String(""):
            n_empty_value += 1
    assert_true(n_null > 0)
    assert_true(n_empty_value > 0)
    # (c): the null-blind answer must be a DIFFERENT number.
    assert_true(
        _oracle_distinct_if_nulls_were_counted(vals, nulls)
        != _oracle_distinct(vals, nulls)
    )


# =============================================================================
# §4 — WORKER-COUNT INVARIANCE
# =============================================================================


def test_the_answer_does_not_depend_on_the_worker_count() raises:
    var vals = _skewed_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(Int(_parallel(batch, 1)), oracle)
    assert_equal(Int(_parallel(batch, 2)), oracle)
    assert_equal(Int(_parallel(batch, 4)), oracle)
    assert_equal(Int(_parallel(batch, 8)), oracle)
    _ = batch^


# =============================================================================
# §5 — DEGENERATE COLUMNS
# =============================================================================


def test_all_null_column_counts_zero() raises:
    var n = _CDSTR_MIN_ROWS + 8
    var vals = List[String](capacity=n)
    var nulls = List[Bool](capacity=n)
    for _ in range(n):
        vals.append(String(""))
        nulls.append(True)
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch)), 0)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), 0)
    _ = batch^


def test_single_repeated_value_counts_one() raises:
    var n = _CDSTR_MIN_ROWS + 8
    var vals = List[String](capacity=n)
    for _ in range(n):
        vals.append(String("only"))
    var nulls = _no_nulls(n)
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch)), 1)
    _ = batch^


def test_all_empty_strings_count_one() raises:
    var n = _CDSTR_MIN_ROWS + 8
    var vals = List[String](capacity=n)
    for _ in range(n):
        vals.append(String(""))
    var nulls = _no_nulls(n)
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch)), 1)
    _ = batch^


def test_empty_column_counts_zero() raises:
    var vals = List[String]()
    var nulls = List[Bool]()
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch)), 0)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), 0)
    _ = batch^


# =============================================================================
# §6 — LARGE_STRING (Int64 offsets)
# =============================================================================


def test_large_string_offsets_width() raises:
    var vals = _mixed_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls, large=True)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(Int(_parallel(batch)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


# =============================================================================
# §7 — THE PACKING, including the boundary the 32-bit row guard protects
# =============================================================================


def test_packed_entry_round_trips() raises:
    assert_equal(Int(_cdstr_row(_cdstr_pack(UInt32(0), 0))), 0)
    assert_equal(Int(_cdstr_fp(_cdstr_pack(UInt32(0), 0))), 0)
    assert_equal(Int(_cdstr_row(_cdstr_pack(UInt32(0xFFFFFFFF), 123456))),
                 123456)
    assert_equal(
        Int(_cdstr_fp(_cdstr_pack(UInt32(0xFFFFFFFF), 123456))),
        Int(UInt32(0xFFFFFFFF)),
    )
    assert_equal(
        Int(_cdstr_row(_cdstr_pack(UInt32(7), _CDSTR_MAX_ROWS))),
        _CDSTR_MAX_ROWS,
    )
    assert_equal(Int(_cdstr_fp(_cdstr_pack(UInt32(7), _CDSTR_MAX_ROWS))), 7)


def test_zero_is_never_a_valid_packed_entry() raises:
    """The EMPTY marker. `row + 1` is what keeps 0 free; drop the `+ 1` and row
    0 becomes indistinguishable from an empty slot."""
    assert_true(_cdstr_pack(UInt32(0), 0) != Int64(0))


def test_partition_count_is_a_power_of_two_at_least_the_worker_count() raises:
    for nw in [1, 2, 3, 7, 20, 88]:
        for rows in [1, 1000, 100_000, 100_000_000]:
            var np = _cdstr_partition_count(rows, nw)
            assert_true(np >= nw)
            assert_true(np & (np - 1) == 0)


# =============================================================================
# §8 — THE TYPE REFUSAL
# =============================================================================


def test_envelope_names_exactly_the_two_varlen_string_layouts() raises:
    assert_true(cd_string_column_supported(ArrowType.STRING))
    assert_true(cd_string_column_supported(ArrowType.LARGE_STRING))
    assert_true(not cd_string_column_supported(ArrowType.INT64))
    assert_true(not cd_string_column_supported(ArrowType.INT32))
    assert_true(not cd_string_column_supported(ArrowType.DICTIONARY))


def test_an_int_column_raises_rather_than_striding_absent_offsets() raises:
    var arr = PrimitiveArray[DType.int64].allocate(4)
    for r in range(4):
        arr.store[1](r, Int64(r))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("i"), ArrowType.INT64, False))
    var batch = rbb.build(sb.build())
    var raised = False
    try:
        _ = count_distinct_string_column_serial(batch, 0)
    except:
        raised = True
    assert_true(raised)
    _ = batch^


# =============================================================================
# §9 — LENGTH AND PREFIX SENSITIVITY
# =============================================================================


def test_prefixes_and_one_byte_neighbours_are_distinct_values() raises:
    """`"ab"` / `"abc"` / `"abcd"` are three values, not one: a hash that did
    not mix the LENGTH, or a verify that compared only the shorter span, would
    collapse them. The neighbours differ in ONE byte at varying positions, which
    is what a truncated compare misses."""
    var base: List[String] = [
        String("ab"), String("abc"), String("abcd"), String("ba"),
        String("abce"), String("abdd"), String("bbcd"), String(""),
        String("a"), String("b"),
    ]
    var n = _CDSTR_MIN_ROWS + 512
    var vals = List[String](capacity=n)
    for r in range(n):
        vals.append(base[r % len(base)])
    var nulls = _no_nulls(n)
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(oracle, len(base))
    assert_equal(Int(_parallel(batch)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


def test_long_values_past_the_hash_stripe_loop_are_distinguished() raises:
    """Values longer than the 32-byte xxHash stripe, differing only in their
    LAST byte — the tail-drain path, which a stripe-only hash would ignore."""
    var base = List[String]()
    for i in range(64):
        base.append(
            String("0123456789abcdef0123456789abcdef0123456789abcdef")
            + String(i)
        )
    var n = _CDSTR_MIN_ROWS + 256
    var vals = List[String](capacity=n)
    for r in range(n):
        vals.append(base[r % len(base)])
    var nulls = _no_nulls(n)
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch)), 64)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), 64)
    _ = batch^


# =============================================================================
# §10 — ⭐ A REAL FINGERPRINT COLLISION. The arm that makes the byte compare
#       load-bearing rather than decorative.
# =============================================================================
#
# The kernel probes on the LOW 32 BITS of the value's xxHash64 and confirms every
# match with `bytes_equal`. Without a genuine collision, the confirm is dead code
# in every test: MEASURED, deleting the pre-filter's byte compare (verifying the
# cached entry against ITSELF) left all 19 other arms GREEN. These two strings
# were found by brute force over the FIXED-WIDTH keyspace `"c%06d"`, with an
# independent Python reimplementation of the same xxHash64 spec: they are the
# SAME BYTE LENGTH, their hashes agree in the low 32 bits (the fingerprint), in
# the top 3 bits (the partition at 8 workers) and in the low 14 (the pre-filter
# slot), and they differ overall. `cd_string_value_hash` re-derives every one of
# those facts below, so this arm cannot silently decay into two ordinary values.
#
# ⚠ THE FIXED WIDTH IS NOT COSMETIC, AND THE FIRST PAIR HERE DID NOT HAVE IT.
# "c85878"/"c133100" are 6 bytes against 7, and every confirm in the kernel is
# `clen == vlen and bytes_equal(...)` — so the LENGTH check separated them and
# the byte compare stayed decorative even after the commit written to make it
# reachable. Do not replace this pair with one of unequal length.


comptime _COLLIDE_A: String = "c053758"
comptime _COLLIDE_B: String = "c206551"


def test_the_collision_pair_still_collides() raises:
    """FIXTURE-DESIGN PIN, re-derived from the kernel's OWN hash — not trusted
    from a comment. If a future change of hash breaks any of these three, §10
    stops testing what it says it tests and this arm says so."""
    var ha = cd_string_value_hash(_COLLIDE_A)
    var hb = cd_string_value_hash(_COLLIDE_B)
    assert_true(_COLLIDE_A != _COLLIDE_B)
    # ⭐⭐ SAME BYTE LENGTH, AND THIS IS THE HALF THAT MAKES `bytes_equal`
    # LOAD-BEARING RATHER THAN THE LENGTH CHECK. Every confirm in this kernel
    # is spelled `clen == vlen and bytes_equal(...)`. The pair this arm shipped
    # with on 2026-09-19 was "c85878"/"c133100" — SIX bytes against SEVEN — so
    # `clen == vlen` alone separated them and the byte compare was STILL dead
    # code in all 22 cases, including this one. MEASURED by adversarial review:
    # replacing all three confirms with a bare `clen == vlen` passed 22 of 22.
    # With an EQUAL-LENGTH pair the length check cannot discriminate and only
    # the bytes can.
    assert_equal(_COLLIDE_A.byte_length(), _COLLIDE_B.byte_length())
    # same 32-bit fingerprint (the probe gate) ...
    assert_equal(
        Int(ha & UInt64(0xFFFFFFFF)), Int(hb & UInt64(0xFFFFFFFF))
    )
    # ... same top-3-bit partition at 8 workers ...
    assert_equal(Int(ha >> UInt64(61)), Int(hb >> UInt64(61)))
    # ... same direct-mapped pre-filter slot ...
    assert_equal(Int(ha & UInt64(16383)), Int(hb & UInt64(16383)))
    # ... and still two DIFFERENT values.
    assert_true(ha != hb)


def _collision_fixture() raises -> List[String]:
    """The colliding pair interleaved, so each lands in the other's pre-filter
    slot while it is occupied. Sized so the PARALLEL arm runs at 8 workers with
    8 partitions — the configuration the top-3-bit half of the pin assumes."""
    var n = _CDSTR_MIN_ROWS + 64
    var out = List[String](capacity=n)
    for r in range(n):
        if r % 2 == 0:
            out.append(_COLLIDE_A)
        else:
            out.append(_COLLIDE_B)
    return out^


def test_two_values_sharing_a_fingerprint_are_counted_twice() raises:
    var vals = _collision_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls)
    assert_equal(Int(_parallel(batch, 8)), 2)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), 2)
    _ = batch^


def test_the_collision_pair_survives_beside_other_values() raises:
    """The same pair inside a populated column: the confirm has to hold while
    the tables are loaded and probing, not only on a two-value fixture."""
    var n = _CDSTR_MIN_ROWS + 4096
    var vals = List[String](capacity=n)
    var s = UInt64(0x5DEECE66D)
    for r in range(n):
        s = _rot(s)
        if r % 3 == 0:
            vals.append(_COLLIDE_A)
        elif r % 3 == 1:
            vals.append(_COLLIDE_B)
        else:
            vals.append(String("f") + String(Int(s % UInt64(900))))
    var nulls = _no_nulls(n)
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    assert_equal(Int(_parallel(batch, 8)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


# =============================================================================
# §11 — the scan slices are cut by COST (`bytebal`)
# =============================================================================
#
# The slice cut decides only which task hashes which row, never the count, so
# the pins are (a) the slices PARTITION `[0, n)` on both arms, (b) the cost arm
# is actually BALANCED on a byte-skewed column where the equal-row arm is not
# (a vacuity guard: without it a no-op "bytebal" passes (a)), and (c) the
# kernel's answer over that column still equals the raw oracle.


def _byte_skewed_fixture() raises -> List[String]:
    """Three quarters EMPTY strings, then a quarter of ~200-byte values — the
    cbq05 shape in miniature: equal-ROW slices put all the bytes in the last
    quarter of the slices."""
    var n = _CDSTR_MIN_ROWS + 4096
    var out = List[String](capacity=n)
    var pad = String("")
    for _ in range(190):
        pad += "x"
    for r in range(n):
        if r < (3 * n) // 4:
            out.append(String(""))
        else:
            out.append(pad + String(r % 997))
    return out^


def _slice_cost(imm vals: List[String], lo: Int, hi: Int) -> Int:
    var c = 0
    for r in range(lo, hi):
        c += vals[r].byte_length() + _CDSTR_ROW_COST_BYTES
    return c


def _assert_partition(
    imm batch: RecordBatch, n: Int, nw: Int, bytebal: Bool
) raises -> Int:
    var sl = cdstr_scan_slices[DType.int32](batch, 0, n, nw, bytebal)
    assert_true(len(sl) >= 1, "at least one slice")
    assert_equal(sl[0].lo, 0, "first slice starts at row 0")
    assert_equal(sl[len(sl) - 1].hi, n, "last slice ends at n")
    for i in range(len(sl)):
        assert_true(sl[i].lo < sl[i].hi, "no empty slice")
        if i > 0:
            assert_equal(sl[i].lo, sl[i - 1].hi, "slices are contiguous")
    if bytebal:
        assert_true(
            len(sl) <= nw * _CDSTR_TILES_PER_WORKER,
            "at most TILES_PER_WORKER x nw slices",
        )
    else:
        assert_true(len(sl) <= nw, "the equal-row arm cuts at most nw slices")
    return len(sl)


def test_cdstr_byte_slices_partition_the_rows() raises:
    var vals = _byte_skewed_fixture()
    var n = len(vals)
    var batch = _string_batch(vals, _no_nulls(n))
    var nws: List[Int] = [1, 3, 8, 20]
    for i in range(len(nws)):
        _ = _assert_partition(batch, n, nws[i], False)
        _ = _assert_partition(batch, n, nws[i], True)
    _ = batch^


def test_cdstr_byte_slices_are_balanced_where_rows_are_not() raises:
    var vals = _byte_skewed_fixture()
    var n = len(vals)
    var batch = _string_batch(vals, _no_nulls(n))
    var nw = 8
    var total = _slice_cost(vals, 0, n)
    var row_max = 190 + 3 + _CDSTR_ROW_COST_BYTES  # the costliest single row
    # Vacuity guard: the EQUAL-ROW cut is badly unbalanced on this column.
    var er = cdstr_scan_slices[DType.int32](batch, 0, n, nw, False)
    var er_max = 0
    for i in range(len(er)):
        var c = _slice_cost(vals, er[i].lo, er[i].hi)
        if c > er_max:
            er_max = c
    assert_true(
        er_max * len(er) > 2 * total,
        "fixture must defeat the equal-row cut (max slice > 2x the mean)",
    )
    # The COST cut: every slice within one row of its target.
    var bb = cdstr_scan_slices[DType.int32](batch, 0, n, nw, True)
    var tiles = nw * _CDSTR_TILES_PER_WORKER
    var target = total // tiles
    for i in range(len(bb)):
        var c = _slice_cost(vals, bb[i].lo, bb[i].hi)
        assert_true(
            c <= 2 * target + row_max,
            "cost slice " + String(i) + " is out of balance",
        )
    _ = batch^


def test_byte_balanced_scan_answers_the_same() raises:
    var vals = _byte_skewed_fixture()
    var nulls = _no_nulls(len(vals))
    var batch = _string_batch(vals, nulls)
    var oracle = _oracle_distinct(vals, nulls)
    for bytebal in [True, False]:
        assert_equal(Int(_parallel(batch, 1, bytebal)), oracle)
        assert_equal(Int(_parallel(batch, 3, bytebal)), oracle)
        assert_equal(Int(_parallel(batch, 8, bytebal)), oracle)
    assert_equal(Int(count_distinct_string_column_serial(batch, 0)), oracle)
    _ = batch^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
