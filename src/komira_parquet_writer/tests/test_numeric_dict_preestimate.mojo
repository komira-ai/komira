# =============================================================================
# The numeric cardinality pre-estimate of
# `komira_parquet_writer.dict_encoder_numeric.encode_numeric_dict_column`.
#
# ★ THE DEFECT THIS PINS. On a 100%-distinct FLOAT64 column a plain build
# makes a dictionary that is STRUCTURALLY GUARANTEED to be discarded: the
# dictionary page encoder stops the instant `success == False`, before
# statistics, thrift, def-levels or RLE, so every cycle spent below the
# abandon point produces nothing that survives. And it pays for it in the
# most expensive shape available — the probe table is born at 64 slots and
# has to reach 65,536, TEN zero-fill-and-rehash steps, 92% of 406,092 table
# operations per column being growth bookkeeping against 32,769 real
# inserts, all serial on the thread driving the write.
#
# ⚠ WHY THE ASSERTION IS ON `table_grows` AND NOT ON THE WRITTEN BYTES.
# An abandon the pre-estimate takes for free and an abandon paid for with a
# full dict build return BYTE-IDENTICAL results — that identity IS the safety
# argument for the change, and it is exactly what makes the defect invisible
# to any black-box assertion. `NumericDictEncodingResult.table_grows` carries
# out the one thing that differs: how much probe-table growth was paid.
# Without it the only instrument left is a stopwatch, and a wall-clock
# assertion in a unit test is a flake, not a guard.
#
# ⛔ DO NOT "SIMPLIFY" THIS FILE BY DELETING THE LOW/MID-CARDINALITY CASES.
# The pre-estimate is a SAMPLED gate, and the failure mode that costs real
# money is the opposite of the one above: refusing a column the exact build
# would have KEPT writes BYTE_STREAM_SPLIT / DELTA_BINARY_PACKED where a
# dictionary page belonged, silently, with nothing going red. Those tests are
# the one-sidedness half of the guard, and every one of them is load-bearing:
#   * low-cardinality     — 50 distinct over 100,000 rows (the lineitem shape
#                           the `64` literal existed to serve)
#   * mid-cardinality     — 12,000 distinct over 100,000 rows; a gate that
#                           refused on the linear extrapolation ALONE would
#                           wrongly refuse this one
#   * run-structured      — a sorted key with runs of exactly the stride
#                           length: 100% distinct under a PURE STRIDE, ~5%
#                           under blocks. The BLOCKED pass is why this is kept
#   * tiled               — a repeating cycle of distinct values: 100%
#                           distinct under BLOCKS, ~12% under a stride. The
#                           STRIDED pass is why this is kept
#   * short all-distinct  — near-unique but too SHORT to overflow the cap
#
# - No file I/O: these assert on the encoder's own result, not on a written
#   parquet file, so nothing here needs a scratch path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray

from komira_parquet_writer.dict_encoder_numeric import (
    NUMERIC_DICT_MAX_CARDINALITY,
    NUMERIC_DICT_TABLE_MIN_SLOTS,
    encode_numeric_dict_column,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _f64_array(values: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        (ptr + i)[] = Scalar[DType.float64](values[i])
    return arr^


def _i64_array(values: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        (ptr + i)[] = Scalar[DType.int64](values[i])
    return arr^


# ---------------------------------------------------------------------------
# 1. THE DEFECT: 100,000 all-distinct values.
# ---------------------------------------------------------------------------


def test_all_distinct_float64_column_is_never_dict_built() raises:
    """A 100%-distinct FLOAT64 column must be refused BEFORE the build.

    100,000 rows of `i * 0.25`, every value distinct. The dictionary can never be kept, so
    not one probe-table doubling may be paid for it.

    Without the pre-estimate this assertion reads `table_grows == 10`:
    the table is born at 64 slots and doubled its way to 65,536 before the
    abandon at unique value 32,769 — 131,008 slot fills and 45,835 rehash
    re-inserts per column, thrown away.
    """
    var n = 100_000
    var values = List[Float64]()
    for i in range(n):
        values.append(Float64(i) * 0.25)
    var arr = _f64_array(values)

    var result = encode_numeric_dict_column[DType.float64](arr)

    assert_false(
        result.success,
        String(
            "a 100%-distinct FLOAT64 column has 100,000 unique values, far"
            " over the "
        )
        + String(NUMERIC_DICT_MAX_CARDINALITY)
        + " cap, so the encoder must abandon it",
    )
    assert_equal(
        result.table_grows,
        0,
        String("THE DEFECT: the probe table doubled ")
        + String(result.table_grows)
        + " time(s) building a dictionary that is structurally guaranteed to"
        " be discarded (the page encoder drops it on `not success`"
        " before any surviving work). The cardinality pre-estimate must"
        " refuse this column up front, paying ZERO doublings.",
    )


def test_all_distinct_int64_column_is_never_dict_built() raises:
    """The INT64 sibling — the gate is dtype-generic, not float-specific."""
    var n = 100_000
    var values = List[Int64]()
    for i in range(n):
        values.append(Int64(i) * Int64(7))
    var arr = _i64_array(values)

    var result = encode_numeric_dict_column[DType.int64](arr)

    assert_false(result.success, "100,000 distinct INT64 values exceed the cap")
    assert_equal(
        result.table_grows,
        0,
        String("INT64 must take the same free abandon as FLOAT64; paid ")
        + String(result.table_grows)
        + " doubling(s)",
    )


# ---------------------------------------------------------------------------
# 2. ONE-SIDEDNESS. Every column the exact build would have KEPT is kept,
#    with byte-identical output.
# ---------------------------------------------------------------------------


def _assert_kept_and_exact[
    dtype: DType
](
    array: PrimitiveArray[dtype],
    expected_dict: List[Scalar[dtype]],
    expected_idx: List[Int32],
    what: String,
) raises:
    """The encoder kept the column AND produced the exact first-seen mapping.

    `expected_dict` / `expected_idx` are derived from the fixture's own
    closed form, independently of the encoder. The probe table is an internal
    accelerator, so neither its capacity nor the pre-estimate may move a
    single entry of either.
    """
    var result = encode_numeric_dict_column[dtype](array)

    assert_true(
        result.success,
        what
        + ": the exact build keeps this column ("
        + String(len(expected_dict))
        + " distinct, under the "
        + String(NUMERIC_DICT_MAX_CARDINALITY)
        + " cap), so the SAMPLED pre-estimate must not refuse it. Refusing"
        " writes BYTE_STREAM_SPLIT/DELTA_BINARY_PACKED where a dictionary"
        " page belonged — a silent compression regression that nothing else"
        " in the tree would catch.",
    )
    assert_equal(
        len(result.dict_values),
        len(expected_dict),
        what + ": dictionary entry count",
    )
    for d in range(len(expected_dict)):
        if result.dict_values[d] != expected_dict[d]:
            raise Error(
                what
                + ": dictionary entry "
                + String(d)
                + " is not the first-seen value — probe-table SIZING changed"
                " the written bytes, which it must never do"
            )
    for i in range(len(expected_idx)):
        if result.indices.get(i) != expected_idx[i]:
            raise Error(
                what + ": index stream diverged at row " + String(i)
            )


def test_low_cardinality_column_still_dict_encodes() raises:
    """50 distinct values over 100,000 rows — the lineitem shape.

    The `_NumericDictTable(64)` literal existed to keep exactly this column
    in L1. Sizing from a sample must not lose that, and the pre-estimate must
    not refuse it.
    """
    var n = 100_000
    var values = List[Int64]()
    var expect_dict = List[Scalar[DType.int64]]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(1000) + Int64(i % 50) * Int64(7))
        expect_idx.append(Int32(i % 50))
    for k in range(50):
        expect_dict.append(Scalar[DType.int64](Int64(1000) + Int64(k) * Int64(7)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("low-cardinality INT64 (50 distinct / 100K rows)"),
    )


def test_mid_cardinality_column_still_dict_encodes() raises:
    """12,000 distinct over 100,000 rows — the extrapolation trap.

    A uniform sample of this column reads well under 95% distinct, but its
    LINEAR extrapolation is enormous. A gate that refused on the
    extrapolation alone would throw away a 12,000-entry dictionary that is a
    genuine win over PLAIN. The uniqueness condition is what keeps it.
    """
    var n = 100_000
    var d = 12_000
    var values = List[Int64]()
    var expect_dict = List[Scalar[DType.int64]]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(i % d))
        expect_idx.append(Int32(i % d))
    for k in range(d):
        expect_dict.append(Scalar[DType.int64](Int64(k)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("mid-cardinality INT64 (12,000 distinct)"),
    )


def test_run_structured_column_still_dict_encodes() raises:
    """A sorted key with runs of ~24 rows — the PURE-STRIDE blind spot.

    100,000 rows of `i // 24`, so ~4,167 distinct. The strided pass takes
    every 24th row and sees a brand-new value every time — 100% distinct,
    extrapolating to 100,000. Only the BLOCKED pass (128 consecutive rows,
    ~6 distinct each) can tell this from a genuinely unique column.
    """
    var n = 100_000
    var values = List[Int64]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(i // 24))
        expect_idx.append(Int32(i // 24))
    var d = (n + 23) // 24
    var expect_dict = List[Scalar[DType.int64]]()
    for k in range(d):
        expect_dict.append(Scalar[DType.int64](Int64(k)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("run-structured INT64 (runs of 24)"),
    )


def test_tiled_column_still_dict_encodes() raises:
    """A repeating cycle of 4,096 distinct values — the BLOCKED blind spot.

    Every block of 128 consecutive rows holds 128 distinct values, so the
    blocked pass reads 100% distinct and extrapolates to 100,000. Only the
    STRIDED pass (stride 24 over a period of 4,096 — gcd 8, so it visits one
    residue class in eight) can tell this from a unique column.
    """
    var n = 100_000
    var d = 4_096
    var values = List[Int64]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(i % d))
        expect_idx.append(Int32(i % d))
    var expect_dict = List[Scalar[DType.int64]]()
    for k in range(d):
        expect_dict.append(Scalar[DType.int64](Int64(k)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("tiled INT64 (cycle of 4,096)"),
    )


def test_short_all_distinct_column_still_dict_encodes() raises:
    """20,000 rows, ALL distinct, but under the 32,768 cap.

    Both passes read 100% distinct; the extrapolation lands at 20,000. The
    column is near-unique and still perfectly dict-encodable, so the gate's
    `n_valid > NUMERIC_DICT_MAX_CARDINALITY` precondition and its
    clears-the-cap-by-2x condition must both refuse to fire.
    """
    var n = 20_000
    var values = List[Float64]()
    var expect_dict = List[Scalar[DType.float64]]()
    var expect_idx = List[Int32]()
    for i in range(n):
        var v = Float64(i) * 0.25
        values.append(v)
        expect_dict.append(Scalar[DType.float64](v))
        expect_idx.append(Int32(i))
    var arr = _f64_array(values)
    _assert_kept_and_exact[DType.float64](
        arr,
        expect_dict,
        expect_idx,
        String("short all-distinct FLOAT64 (20,000 rows)"),
    )


def test_tiny_column_is_unaffected() raises:
    """Below `DICT_PREESTIMATE_MIN_ROWS` nothing is sampled at all.

    The pre-estimate is a PERF optimisation; on a column too small for the
    dict build to cost anything it buys nothing and its error bars are worst.
    A 12-row column must still encode exactly.
    """
    var n = 12
    var values = List[Float64]()
    var expect_dict = List[Scalar[DType.float64]]()
    var expect_idx = List[Int32]()
    for i in range(n):
        var v = Float64(i) * 1.5
        values.append(v)
        expect_dict.append(Scalar[DType.float64](v))
        expect_idx.append(Int32(i))
    var arr = _f64_array(values)
    _assert_kept_and_exact[DType.float64](
        arr,
        expect_dict,
        expect_idx,
        String("tiny all-distinct FLOAT64 (12 rows)"),
    )


# ---------------------------------------------------------------------------
# 3. SIZING. The survivors stop paying the growth cascade.
# ---------------------------------------------------------------------------


def test_low_cardinality_column_pays_no_growth_cascade() raises:
    """A 50-entry dictionary must not rehash its way up from 64 slots.

    Sized from the sample's own EXACT distinct count (50 -> 128 slots), so
    zero doublings. This is the half of the change that is byte-identical by
    construction: the probe table's capacity cannot reach the output.
    """
    var n = 100_000
    var values = List[Int64]()
    for i in range(n):
        values.append(Int64(1000) + Int64(i % 50) * Int64(7))
    var arr = _i64_array(values)
    var result = encode_numeric_dict_column[DType.int64](arr)
    assert_true(result.success, "50 distinct values must dict-encode")
    assert_equal(
        result.table_grows,
        0,
        String(
            "a 50-entry dictionary sized from a sample that SAW all 50 values"
            " must never rehash; paid "
        )
        + String(result.table_grows)
        + " doubling(s)",
    )


# ---------------------------------------------------------------------------
# 4. THE NULL AXIS, THE NEAR-CAP AXIS, AND THE START CAPACITY.
#
# Everything above this line was written against fixtures built with
# `PrimitiveArray.allocate(n)` and every slot written, so `null_count == 0` in
# all nine. That left the gate's denominator — the count of NON-NULL rows the
# sample actually reached — completely uncovered, and it was wrong.
# ---------------------------------------------------------------------------


def _mix(i: Int) -> UInt64:
    """splitmix64. A deterministic stand-in for "unstructured data".

    The fixtures below need values and null positions that are NOT an
    arithmetic progression, because an arithmetic progression is precisely
    what the blocked and strided passes are themselves made of — a fixture
    built from one tests the aliasing, not the axis under test.
    """
    var z = UInt64(i) * UInt64(0x9E3779B97F4A7C15) + UInt64(0x9E3779B97F4A7C15)
    z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
    z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    return z ^ (z >> UInt64(31))


def _nullable_i64_mod_array(
    n: Int, modulus: Int, keep_den: Int, mut nonnull_rows: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """`n` rows, non-null iff `_mix(i ^ 0xABCDEF) % keep_den == 0`.

    The k-th non-null row holds `_mix(k) % modulus`, so the column's true
    cardinality is at most `modulus` however sparse it is — the property the
    pre-estimate must not misjudge.

    ⚠ ONE PASS, and it hands back `nonnull_rows`. These fixtures run to ~1M
    rows (7% non-null still has to clear the cap by 2x, which pins
    `n_valid > ~66,000` and therefore `n > ~950,000`), and at this file's
    measured ~30 us per loop iteration every extra full-length pass is ~30
    seconds on a GATE action every consumer of `komira_parquet_writer` inherits.
    The caller derives BOTH the expected cardinality and the round-trip
    check from this list, so nothing else walks all `n` rows but the encoder
    under test.
    """
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var k = 0
    # ⚠ `ref bm` + an explicit `null_count` assignment, NOT `_set_null` per
    # row. `_set_null` re-derefs the `Optional[Bitmap]` twice and re-reads
    # the bit it is about to clear, and at 93% null that is ~910,000 of them
    # — measured 115s of a 167s suite, i.e. the fixture cost more than every
    # assertion in the file put together. The explicit assignment is the
    # idiom `PrimitiveArray._set_null`'s own docstring calls authoritative.
    ref bm = arr.validity.value()
    for i in range(n):
        if _mix(i ^ 0xABCDEF) % UInt64(keep_den) == UInt64(0):
            (ptr + i)[] = Scalar[DType.int64](
                Int64(Int(_mix(k) % UInt64(modulus)))
            )
            nonnull_rows.append(i)
            k += 1
        else:
            bm.clear(i)
    arr.null_count = n - k
    return arr^


def _distinct_mod_count(n_nonnull: Int, modulus: Int) -> Int:
    """The fixture's true cardinality, counted WITHOUT the encoder.

    A presence array over `[0, modulus)` — no hash table, no probe table,
    nothing the code under test also uses. The k-th non-null row's value is
    `_mix(k) % modulus`, so this needs only the COUNT of non-null rows, not
    another walk of the column. If this and the encoder's `dict_values`
    disagree, one of them is wrong and it is not this.
    """
    var seen = List[Bool]()
    seen.resize(modulus, False)
    var distinct = 0
    for k in range(n_nonnull):
        var v = Int(_mix(k) % UInt64(modulus))
        if not seen[v]:
            seen[v] = True
            distinct += 1
    return distinct


def _assert_kept_and_roundtrips[
    dtype: DType
](
    array: PrimitiveArray[dtype],
    nonnull_rows: List[Int],
    expected_distinct: Int,
    what: String,
) raises:
    """Kept, with a dictionary that is exactly the column's distinct set.

    Weaker than `_assert_kept_and_exact` only in that it does not pin
    first-seen ORDER — a null-interleaved fixture has no closed form for it.
    It is not weaker where it counts: `len(dict_values) == expected_distinct`
    (counted independently above) plus `dict_values[indices[i]] == value[i]`
    on EVERY non-null row forces the dictionary to hold each distinct value
    exactly once and every index to point at the right one.
    """
    var result = encode_numeric_dict_column[dtype](array)

    assert_true(
        result.success,
        what
        + ": the exact build keeps this column ("
        + String(expected_distinct)
        + " distinct, under the "
        + String(NUMERIC_DICT_MAX_CARDINALITY)
        + " cap), so the SAMPLED pre-estimate must not refuse it. Refusing"
        " writes BYTE_STREAM_SPLIT/DELTA_BINARY_PACKED where a dictionary"
        " page belonged — a silent compression regression that nothing else"
        " in the tree would catch.",
    )
    assert_equal(
        len(result.dict_values),
        expected_distinct,
        what + ": dictionary entry count",
    )
    var n_dict = len(result.dict_values)
    for r in range(len(nonnull_rows)):
        var i = nonnull_rows[r]
        var idx = Int(result.indices.get(i))
        if idx < 0 or idx >= n_dict:
            raise Error(
                what
                + ": row "
                + String(i)
                + " points at dictionary entry "
                + String(idx)
                + ", outside [0, "
                + String(n_dict)
                + ")"
            )
        if result.dict_values[idx] != array.get(i):
            raise Error(
                what
                + ": row "
                + String(i)
                + " does not round-trip through its dictionary entry"
            )


def test_half_null_column_under_the_cap_still_dict_encodes() raises:
    """200,000 rows, ~50% null, ~30,500 distinct — UNDER the 32,768 cap.

    ⛔ THE HEADLINE DEFECT. `_sample_is_near_unique` divides by
    `sample.sampled`, which is the number of NON-NULL rows the pass reached;
    the sampler skipped a null with `continue` and never visited another
    position to make it up. So at 50% null a "4,096-row sample" was ~2,050
    rows, and the 95% threshold — calibrated at 4,096 — inverted to a
    cardinality bound far BELOW the cap. Measured on this exact fixture with
    the earlier sampler: blocked 2,032/2,096 (96.9%), strided 1,940/2,005 (96.8%),
    both over 95%, so a column 2,235 values UNDER the cap was refused and
    written as DELTA_BINARY_PACKED.

    The same column with no nulls reads 93.9% and is correctly kept, which
    is what makes this the NULL axis and not the cardinality one.
    """
    var n = 200_000
    var modulus = 32_000
    var nonnull_rows = List[Int]()
    var arr = _nullable_i64_mod_array(n, modulus, 2, nonnull_rows)
    _assert_kept_and_roundtrips[DType.int64](
        arr,
        nonnull_rows,
        _distinct_mod_count(len(nonnull_rows), modulus),
        String("half-null INT64 (~30,500 distinct / 200,000 rows)"),
    )


def test_sparse_column_under_the_cap_still_dict_encodes() raises:
    """980,000 rows, ~7% non-null, ~19,400 distinct — UNDER the cap.

    The same defect at the density where it is worst: the landed sampler
    reached 278 and 301 rows on this column (not 4,096), and 278 rows drawn
    from 19,373 distinct values are 100% distinct by the birthday argument
    alone. A sample that small cannot distinguish ANY cardinality above a
    few thousand, and the gate read it as proof of 40,000+.

    ⚠ The fix is NOT "scale the threshold to the sample" — the threshold is
    not a ratio that survives rescaling. It is: fill the sample by walking
    past nulls, and if the column cannot fill it, do not refuse.
    """
    var n = 980_000
    var modulus = 20_000
    var nonnull_rows = List[Int]()
    var arr = _nullable_i64_mod_array(n, modulus, 14, nonnull_rows)
    _assert_kept_and_roundtrips[DType.int64](
        arr,
        nonnull_rows,
        _distinct_mod_count(len(nonnull_rows), modulus),
        String("sparse INT64 (~7% non-null, ~19,400 distinct / 980,000 rows)"),
    )


def test_nullable_all_distinct_column_is_still_refused_for_free() raises:
    """The other direction: nulls must not TURN THE OPTIMISATION OFF.

    A fix that simply refused to refuse whenever `null_count > 0` would pass
    both tests above and quietly give the win back on every nullable
    column in the tree. This is 200,000 rows at ~50% null with every non-null
    value distinct — ~99,800 of them, three times the cap — and it must take
    the same FREE abandon the non-null version takes: zero probe-table
    doublings, no table ever born.
    """
    var n = 200_000
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    var k = 0
    ref bm = arr.validity.value()
    for i in range(n):
        if _mix(i ^ 0xABCDEF) % UInt64(2) == UInt64(0):
            (ptr + i)[] = Scalar[DType.float64](Float64(k) * 0.25)
            k += 1
        else:
            bm.clear(i)
    arr.null_count = n - k

    var result = encode_numeric_dict_column[DType.float64](arr)

    assert_false(
        result.success,
        "~99,800 distinct non-null values are far over the cap; the encoder"
        " must abandon this column",
    )
    assert_equal(
        result.table_grows,
        0,
        String(
            "a NULLABLE all-distinct column must take the same free abandon"
            " as the non-null one — walking past nulls exists to KEEP this"
            " working, not to disable it; paid "
        )
        + String(result.table_grows)
        + " doubling(s)",
    )
    assert_equal(
        result.table_start_slots,
        0,
        "the free abandon builds no probe table at all",
    )


def test_cycling_id_column_with_coprime_period_still_dict_encodes() raises:
    """`i % 30,011` over 100,000 rows — 2,757 distinct UNDER the cap.

    ⛔ FOUND WHILE CHECKING THE ONE-SIDEDNESS CLAIM, NOT REPORTED BY REVIEW.
    Both of the landed passes are ARITHMETIC PROGRESSIONS over row index —
    blocked steps by 3,125 between runs, strided steps by 24 — so a column
    whose value period is coprime to the step reads 100% distinct under BOTH
    of them. Measured with two passes: blocked 4,096/4,096, strided
    4,096/4,096. Two spreads that agree are not two pieces of evidence when
    both are the same KIND of spread.

    The committed `test_tiled_column_still_dict_encodes` only survives
    because `gcd(24, 4096) == 8` happens to fold its stride onto one residue
    class in eight. That is luck about a fixture, not a property of the gate.
    The SCATTERED pass — one row per stratum at a hash-jittered offset — is
    the one that is not an arithmetic progression, and it reads this column
    3,904/4,096 (95.3%).
    """
    var n = 100_000
    var d = 30_011
    var values = List[Int64]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(i % d))
        expect_idx.append(Int32(i % d))
    var expect_dict = List[Scalar[DType.int64]]()
    for k in range(d):
        expect_dict.append(Scalar[DType.int64](Int64(k)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("cycling INT64 id (period 30,011, coprime to both strides)"),
    )


def test_column_sitting_on_the_cap_still_dict_encodes() raises:
    """`i % 32,000` over 100,000 rows — 768 distinct under the cap.

    ⛔ THE THRESHOLD ITSELF WAS MIS-DERIVED, and this is the shape that shows
    it with no nulls and no exotic structure. The 95% constant was inverted
    with `(1 - e^(-s/D)) / (s/D)`, the INFINITE-POPULATION occupancy
    identity. A real column has `n` rows and `n/D` copies of each value, and
    a sample of `s` POSITIONS draws them without replacement:

        E[u] = D * (1 - (1 - s/n)^(n/D))

    At `s = 4,096`, `n = 100,000`, `D = 32,768` — a column sitting EXACTLY on
    the cap, which the exact build keeps — that is 95.8%, above the old
    threshold. So the gate refused columns it was built to keep, and the
    margin the block comment claimed (`D >~ 40,960`) never existed at the
    row counts the writer actually sees.

    Measured here at the 95% threshold: blocked 4,096/4,096, strided 4,000/4,096 —
    refused. The threshold is now 98%, above the 96.8% worst case over the
    whole range where the refusal is reachable at all.
    """
    var n = 100_000
    var d = 32_000
    var values = List[Int64]()
    var expect_idx = List[Int32]()
    for i in range(n):
        values.append(Int64(i % d))
        expect_idx.append(Int32(i % d))
    var expect_dict = List[Scalar[DType.int64]]()
    for k in range(d):
        expect_dict.append(Scalar[DType.int64](Int64(k)))
    var arr = _i64_array(values)
    _assert_kept_and_exact[DType.int64](
        arr,
        expect_dict,
        expect_idx,
        String("INT64 sitting on the cap (32,000 distinct / 100,000 rows)"),
    )


# ---------------------------------------------------------------------------
# 5. START CAPACITY. `table_grows` cannot see an OVER-sized table — it grows
#    zero times — so these read `table_start_slots`.
# ---------------------------------------------------------------------------


def test_small_column_is_born_at_the_minimum_table() raises:
    """Below the sampling gate the table must be born at 64 slots.

    ⛔ THE COMMIT MESSAGE SAID IT DID NOT PRE-SIZE FROM THE ROW COUNT, TWICE,
    AND THE CODE DID. `size_hint` was initialised to `n_valid` and only the
    sampled branch overwrote it, so every column with `n_valid` below the
    sampling gate was pre-sized straight off its ROW COUNT, whatever its
    cardinality. Measured with that sizing on a column of TWO distinct values:

        1,000 rows -> 2,048 slots (24.6 KB, 32x the old 64)
        3,000 rows -> 8,192 slots (98 KB, 128x)
        4,095 rows -> 8,192 slots (98 KB, 128x)

    zero-filled, per column, per row group. With
    `DEFAULT_MAX_ROWS_PER_RG = 122,880` any file whose last row group is
    short pays it, and a file smaller than the gate pays it on EVERY column.

    ⚠ `test_tiny_column_is_unaffected` cannot catch this: n = 12 gives
    `max(24, 64) = 64`, the one value in 0..4,095 that lands back on the
    floor. That is why these three sizes are here and not a fourth tiny one.
    """
    var sizes = List[Int]()
    sizes.append(1_000)
    sizes.append(3_000)
    sizes.append(4_095)
    for s in range(len(sizes)):
        var n = sizes[s]
        var values = List[Int64]()
        for i in range(n):
            values.append(Int64(i % 2))
        var arr = _i64_array(values)
        var result = encode_numeric_dict_column[DType.int64](arr)
        assert_true(result.success, "a 2-distinct column must dict-encode")
        assert_equal(
            len(result.dict_values), 2, "exactly two distinct values"
        )
        assert_equal(
            result.table_start_slots,
            NUMERIC_DICT_TABLE_MIN_SLOTS,
            String("a ")
            + String(n)
            + "-row column with TWO distinct values was born at "
            + String(result.table_start_slots)
            + " slots instead of "
            + String(NUMERIC_DICT_TABLE_MIN_SLOTS)
            + ". It is not sampled at this size, and NOT SAMPLED means"
            " UNKNOWN — which must fall through to the floor, never"
            " pre-size off the row count.",
        )


def test_sub_cap_column_is_not_sampled_at_all() raises:
    """20,000 rows / 8,000 distinct: the band where the refusal is unreachable.

    Sampling ran from `n_valid >= DICT_PREESTIMATE_MIN_ROWS` (4,096) while
    the refusal needs `n_valid > NUMERIC_DICT_MAX_CARDINALITY` (32,768), so
    across that whole band the passes could not refuse whatever they saw.
    They were priced as "8,192 probe inserts", which omits the allocation:
    each pass builds a `_NumericDictTable` of 8,192 slots — ~96 KB of List
    capacity plus a `resize` zero-fill — so this column paid ~192 KB of
    memset (~288 KB once the scattered pass joined) to compute a number only
    the sizing could use.

    `table_start_slots == NUMERIC_DICT_TABLE_MIN_SLOTS` is how you see the
    passes did not run: sized from the sample, this column was born at 8,192 slots,
    sized from a sample nothing could act on.
    """
    var n = 20_000
    var d = 8_000
    var values = List[Int64]()
    for i in range(n):
        values.append(Int64(i % d))
    var arr = _i64_array(values)
    var result = encode_numeric_dict_column[DType.int64](arr)
    assert_true(result.success, "8,000 distinct values are under the cap")
    assert_equal(len(result.dict_values), d, "8,000 dictionary entries")
    assert_equal(
        result.table_start_slots,
        NUMERIC_DICT_TABLE_MIN_SLOTS,
        String(
            "a column below the abandon cap cannot be refused whatever the"
            " sample says, so it must not be sampled; born at "
        )
        + String(result.table_start_slots)
        + " slots means the passes ran anyway",
    )


def test_over_cap_low_cardinality_column_is_still_sized_from_the_sample() raises:
    """And the sizing win itself must survive all of that.

    The lineitem shape — 50 distinct over 100,000 rows. `n_valid` is over the
    cap so the passes DO run, they see all 50 values, and the table is born
    at 128 slots and never rehashes. This is the half of sample-based sizing
    that is right, and narrowing the sampling gate must not cost it.
    """
    var n = 100_000
    var values = List[Int64]()
    for i in range(n):
        values.append(Int64(1000) + Int64(i % 50) * Int64(7))
    var arr = _i64_array(values)
    var result = encode_numeric_dict_column[DType.int64](arr)
    assert_true(result.success, "50 distinct values must dict-encode")
    assert_equal(
        result.table_start_slots,
        128,
        String(
            "50 distinct values sampled exactly must size the table to"
            " next_pow2(2 x 50) = 128; got "
        )
        + String(result.table_start_slots),
    )
    assert_equal(result.table_grows, 0, "and it must never rehash")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
