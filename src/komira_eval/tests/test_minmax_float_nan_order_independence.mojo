# =============================================================================
# test_minmax_float_nan_order_independence.mojo
# =============================================================================
#
# THE DEFECT THIS PINS: `builtin_agg_fns_minmax.mojo`'s FLOAT
# cells — `MinF32`, `MinF64`, `MaxF32`, `MaxF64` — fold with
#
#     if not s.seen or v < s.value:   # MIN
#     if not s.seen or v > s.value:   # MAX
#
# and `merge` has the identical shape. Every IEEE comparison against a NaN is
# FALSE, so once `s.value` holds a NaN NOTHING can ever displace it: a NaN in
# the FIRST row of a partition poisons that partition's whole answer, while the
# same NaN arriving in any later row is silently dropped.
#
# ⚠ THAT IS NOT A PARITY GAP, IT IS AN ORDER DEPENDENCE. The answer is a
# function of WHICH ROW ARRIVED FIRST — and under fork-join, of how the workers
# happened to partition the input, since `merge` folds a per-worker partial
# whose `value` may itself be a stuck NaN. The same table, the same query, a
# different thread count: a different answer.
#
# A kernel that folds on bare `<` / `>` answers, over
# {1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}:
#
#   MIN, the 8 rotations      0.0 nan 0.0 0.0 -0.0 0.0 nan 0.0    (DuckDB 0.0)
#   MAX, the 8 rotations      inf inf inf inf  inf inf nan inf    (DuckDB nan)
#   MIN, the 9 two-worker cuts  0.0 1.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0
#   MAX, the 9 two-worker cuts  inf 1.0 inf inf inf inf inf inf inf
#   MIN{NaN,5,2} = nan  vs  MIN{5,2,NaN} = 2.0     (same multiset)
#   F32 MIN{NaN,5,2} = nan
#
# ⭐ `cut1` IS THE WHOLE DEFECT IN ONE NUMBER. The same eight rows in the same
# order, one different morsel boundary, and MAX answers `1.0` — a value that is
# neither the serial wrong answer (`inf`) nor the right one (`nan`), and that no
# serial run of this data can produce.
#
# -----------------------------------------------------------------------------
# THE CONTRACT — DuckDB v1.5.3. DuckDB orders float values as the IEEE
# values QUOTIENTED by {all NaNs are one value} and {+0.0 == -0.0}, with NaN
# ordered ABOVE +inf — so NaN is the top element, never the bottom:
#
#   min/max over {1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}  ->  0.0 / nan
#   min/max over {nan, nan}                                  ->  nan / nan
#   min/max over {nan, -nan}                                 ->  nan / nan
#   min/max over {-0.0, 0.0}                                 -> -0.0 / -0.0
#   min/max over {0.0, -0.0}                                 ->  0.0 /  0.0
#
# The last two are the SAME VALUE under the quotient; DuckDB keeps the
# first-seen bit pattern, which is a free choice of representative inside one
# equivalence class. This file therefore compares under the quotient
# (`_same_f64`), never on the sign bit.
#
# -----------------------------------------------------------------------------
# THIS TEST DRIVES THE REAL KERNEL — it imports `MinF64` / `MaxF64` / `MinF32`
# / `MaxF32` from `komira_eval.builtin_agg_fns_minmax` and calls `init` /
# `update_scalar` / `merge` / `finalize`. Nothing is transcribed.
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_eval.builtin_agg_fns_minmax import MinF32, MinF64, MaxF32, MaxF64


# -----------------------------------------------------------------------------
# fixture values + the quotient comparator
# -----------------------------------------------------------------------------
def _nan_f64() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _neg_nan_f64() -> Float64:
    return -(Float64(0.0) / Float64(0.0))


def _neg_zero_f64() -> Float64:
    return Float64(0.0) * Float64(-1.0)


def _inf_f64() -> Float64:
    return Float64(1.0) / Float64(0.0)


def _nan_f32() -> Float32:
    return Float32(0.0) / Float32(0.0)


def _neg_zero_f32() -> Float32:
    return Float32(0.0) * Float32(-1.0)


def _same_f64(a: Float64, b: Float64) -> Bool:
    """Equality under DuckDB's quotient: all NaNs are one value, +-0.0 are one
    value, everything else is IEEE `==`."""
    if a != a:
        return b != b
    if b != b:
        return False
    return a == b


def _same_f32(a: Float32, b: Float32) -> Bool:
    if a != a:
        return b != b
    if b != b:
        return False
    return a == b


# -----------------------------------------------------------------------------
# kernel drivers — the REAL AggFn cells, two shapes: one accumulator (serial),
# and an N-way split merged through `merge` (the fork-join shape).
# -----------------------------------------------------------------------------
def _min_serial(imm vals: List[Float64]) raises -> Float64:
    var f = MinF64()
    var s = f.init()
    for i in range(len(vals)):
        f.update_scalar(s, vals[i])
    return f.finalize(s)


def _max_serial(imm vals: List[Float64]) raises -> Float64:
    var f = MaxF64()
    var s = f.init()
    for i in range(len(vals)):
        f.update_scalar(s, vals[i])
    return f.finalize(s)


def _min_split(imm vals: List[Float64], cut: Int) raises -> Float64:
    """Two workers: rows [0,cut) and [cut,n), folded independently then joined
    through the real `merge`. This is the fork-join shape."""
    var f = MinF64()
    var a = f.init()
    var b = f.init()
    for i in range(len(vals)):
        if i < cut:
            f.update_scalar(a, vals[i])
        else:
            f.update_scalar(b, vals[i])
    return f.finalize(f.merge(a, b))


def _max_split(imm vals: List[Float64], cut: Int) raises -> Float64:
    var f = MaxF64()
    var a = f.init()
    var b = f.init()
    for i in range(len(vals)):
        if i < cut:
            f.update_scalar(a, vals[i])
        else:
            f.update_scalar(b, vals[i])
    return f.finalize(f.merge(a, b))


def _rotate(imm base: List[Float64], k: Int) -> List[Float64]:
    var n = len(base)
    var out = List[Float64]()
    for i in range(n):
        out.append(base[(i + k) % n])
    return out^


def _duckdb_fixture() -> List[Float64]:
    """{1.0, NaN, 2.0, +0.0, -0.0, inf, NaN, 1.0}. DuckDB: min 0.0, max nan."""
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(_nan_f64())
    v.append(Float64(2.0))
    v.append(Float64(0.0))
    v.append(_neg_zero_f64())
    v.append(_inf_f64())
    v.append(_nan_f64())
    v.append(Float64(1.0))
    return v^


# =============================================================================
# §1 — THE HEADLINE: ONE multiset, every arrival order, ONE answer. The failure
# message carries the WHOLE spread, because the spread IS the finding.
# =============================================================================
def test_min_f64_is_rotation_invariant() raises:
    var base = _duckdb_fixture()
    var report = String("")
    var bad = 0
    for k in range(8):
        var got = _min_serial(_rotate(base, k))
        if not _same_f64(got, Float64(0.0)):
            bad += 1
        report = report + "rot" + String(k) + "=" + String(got) + " "
    assert_true(
        bad == 0,
        String(
            "MIN over {1,NaN,2,+0,-0,inf,NaN,1} must be 0.0 in every arrival"
            " order (DuckDB v1.5.3 = 0.0); "
        )
        + String(bad)
        + " of 8 rotations disagreed: "
        + report,
    )


def test_max_f64_is_rotation_invariant() raises:
    var base = _duckdb_fixture()
    var want = _nan_f64()
    var report = String("")
    var bad = 0
    for k in range(8):
        var got = _max_serial(_rotate(base, k))
        if not _same_f64(got, want):
            bad += 1
        report = report + "rot" + String(k) + "=" + String(got) + " "
    assert_true(
        bad == 0,
        String(
            "MAX over {1,NaN,2,+0,-0,inf,NaN,1} must be nan in every arrival"
            " order (DuckDB v1.5.3 = nan — NaN IS the max); "
        )
        + String(bad)
        + " of 8 rotations disagreed: "
        + report,
    )


# =============================================================================
# §2 — WORKER PARTITIONING. Same rows, same order, every 2-worker split point,
# joined through the real `merge`. A fork-join aggregate may not depend on how
# the morsels were cut.
# =============================================================================
def test_min_f64_is_partition_invariant() raises:
    var base = _duckdb_fixture()
    var report = String("")
    var bad = 0
    for cut in range(len(base) + 1):
        var got = _min_split(base, cut)
        if not _same_f64(got, Float64(0.0)):
            bad += 1
        report = report + "cut" + String(cut) + "=" + String(got) + " "
    assert_true(
        bad == 0,
        String("MIN must be 0.0 at every 2-worker split point: ") + report,
    )


def test_max_f64_is_partition_invariant() raises:
    var base = _duckdb_fixture()
    var want = _nan_f64()
    var report = String("")
    var bad = 0
    for cut in range(len(base) + 1):
        var got = _max_split(base, cut)
        if not _same_f64(got, want):
            bad += 1
        report = report + "cut" + String(cut) + "=" + String(got) + " "
    assert_true(
        bad == 0,
        String("MAX must be nan at every 2-worker split point: ") + report,
    )


# =============================================================================
# §3 — THE MECHANISM, ISOLATED. A FIRST-ROW NaN is the named failure; the same
# NaN LAST is the arm that silently drops it. Both are the same one-line bug
# seen from its two sides.
# =============================================================================
def test_first_row_nan_does_not_stick() raises:
    var first: List[Float64] = [_nan_f64(), Float64(5.0), Float64(2.0)]
    var last: List[Float64] = [Float64(5.0), Float64(2.0), _nan_f64()]
    var mn_first = _min_serial(first)
    var mn_last = _min_serial(last)
    assert_true(
        _same_f64(mn_first, Float64(2.0)) and _same_f64(mn_last, Float64(2.0)),
        String("MIN{NaN,5,2} and MIN{5,2,NaN} must both be 2.0: first=")
        + String(mn_first)
        + " last="
        + String(mn_last),
    )
    var mx_first = _max_serial(first)
    var mx_last = _max_serial(last)
    var want = _nan_f64()
    assert_true(
        _same_f64(mx_first, want) and _same_f64(mx_last, want),
        String("MAX{NaN,5,2} and MAX{5,2,NaN} must both be nan: first=")
        + String(mx_first)
        + " last="
        + String(mx_last),
    )


def test_all_nan_group_is_nan() raises:
    """An all-NaN group has NO non-NaN value to fall back to. DuckDB answers
    nan for BOTH min and max — not a sentinel, and not NULL."""
    var v: List[Float64] = [_nan_f64(), _neg_nan_f64(), _nan_f64()]
    var want = _nan_f64()
    var mn = _min_serial(v)
    var mx = _max_serial(v)
    assert_true(
        _same_f64(mn, want),
        String("MIN over an all-NaN group must be nan: got ") + String(mn),
    )
    assert_true(
        _same_f64(mx, want),
        String("MAX over an all-NaN group must be nan: got ") + String(mx),
    )


def test_nan_outranks_positive_infinity() raises:
    """NaN is ordered ABOVE +inf, so it wins MAX and loses MIN against it."""
    var v: List[Float64] = [_inf_f64(), _nan_f64()]
    var w: List[Float64] = [_nan_f64(), _inf_f64()]
    var want_max = _nan_f64()
    assert_true(
        _same_f64(_max_serial(v), want_max)
        and _same_f64(_max_serial(w), want_max),
        String("MAX{inf,NaN} must be nan in both orders: ")
        + String(_max_serial(v))
        + " / "
        + String(_max_serial(w)),
    )
    assert_true(
        _same_f64(_min_serial(v), _inf_f64())
        and _same_f64(_min_serial(w), _inf_f64()),
        String("MIN{inf,NaN} must be inf in both orders: ")
        + String(_min_serial(v))
        + " / "
        + String(_min_serial(w)),
    )


# =============================================================================
# §4 — THE F32 TWIN. `MinF32`/`MaxF32` are a separate copy of the same four
# lines, so they are a separate claim.
# =============================================================================
def test_min_max_f32_first_row_nan_does_not_stick() raises:
    var fmin = MinF32()
    var smin = fmin.init()
    fmin.update_scalar(smin, _nan_f32())
    fmin.update_scalar(smin, Float32(5.0))
    fmin.update_scalar(smin, Float32(2.0))
    var mn = fmin.finalize(smin)
    assert_true(
        _same_f32(mn, Float32(2.0)),
        String("F32 MIN{NaN,5,2} must be 2.0: got ") + String(mn),
    )

    var fmax = MaxF32()
    var smax = fmax.init()
    fmax.update_scalar(smax, Float32(5.0))
    fmax.update_scalar(smax, _nan_f32())
    fmax.update_scalar(smax, Float32(2.0))
    var mx = fmax.finalize(smax)
    assert_true(
        _same_f32(mx, _nan_f32()),
        String("F32 MAX{5,NaN,2} must be nan: got ") + String(mx),
    )

    var fmin2 = MinF32()
    var s2 = fmin2.init()
    fmin2.update_scalar(s2, _neg_zero_f32())
    fmin2.update_scalar(s2, Float32(0.0))
    assert_true(
        _same_f32(fmin2.finalize(s2), Float32(0.0)),
        String("F32 MIN{-0.0,0.0} must be zero: got ")
        + String(fmin2.finalize(s2)),
    )


# =============================================================================
# §5 — CONTROLS. These must pass on BOTH sides of the fix; they bound the
# change to the NaN / signed-zero corner and nothing else.
# =============================================================================
def test_control_nan_free_min_max_unchanged() raises:
    var v: List[Float64] = [3.0, -7.5, 0.25, 100.0, -0.5]
    var report = String("")
    var bad = 0
    for k in range(5):
        var r = _rotate(v, k)
        var mn = _min_serial(r)
        var mx = _max_serial(r)
        if not (_same_f64(mn, Float64(-7.5)) and _same_f64(mx, Float64(100.0))):
            bad += 1
        report = (
            report
            + "rot"
            + String(k)
            + "=("
            + String(mn)
            + ","
            + String(mx)
            + ") "
        )
    assert_true(
        bad == 0,
        String("CONTROL: NaN-free MIN/MAX must be -7.5 / 100.0 always: ")
        + report,
    )


def test_control_unseen_state_is_unseen() raises:
    """CONTROL: an empty group is still reported by `seen == False`; the fix may
    change WHAT the untouched sentinel holds, but never whether it is flagged."""
    var fmin = MinF64()
    var smin = fmin.init()
    assert_true(not smin.seen, "MinF64.init() must be unseen")
    var fmax = MaxF64()
    var smax = fmax.init()
    assert_true(not smax.seen, "MaxF64.init() must be unseen")
    var merged = fmin.merge(smin, fmin.init())
    assert_true(
        not merged.seen, "merging two unseen MIN states must stay unseen"
    )


def test_control_infinities_are_ordinary_values() raises:
    """CONTROL: +-inf are ORDINARY values here — only NaN is re-ranked."""
    var v: List[Float64] = [
        _inf_f64(), Float64(-1.0) / Float64(0.0), Float64(3.0)
    ]
    var mn = _min_serial(v)
    var mx = _max_serial(v)
    assert_true(
        _same_f64(mn, Float64(-1.0) / Float64(0.0)),
        String("MIN{inf,-inf,3} must be -inf: got ") + String(mn),
    )
    assert_true(
        _same_f64(mx, _inf_f64()),
        String("MAX{inf,-inf,3} must be inf: got ") + String(mx),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
