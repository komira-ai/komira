# =============================================================================
# test_kleene_comparison_properties.mojo — Kleene and comparison kernels
# against a scalar reference, on seeded inputs
# =============================================================================
#
# WHAT THIS PINS. Two kernel families, each diffed against a per-row scalar
# reference that is written out here from the truth table, never derived from
# the kernel:
#
#   §1 The Kleene primitives in `kleene.mojo`: `_kleene_{and,or,not}_chunk`
#      (SIMD lanes) and `_kleene_{and,or,not}_byte` (bit-packed bytes), and
#      `_cmp_result_validity_{chunk,byte}`. Every (valid, data) combination of
#      both operands, including DATA = 1 UNDER A NULL (garbage the helpers must
#      tolerate), is checked against the 3VL table:
#         FALSE AND x = FALSE   TRUE AND NULL = NULL   NULL AND NULL = NULL
#         TRUE  OR  x = TRUE    FALSE OR NULL = NULL   NULL OR  NULL = NULL
#         NOT NULL = NULL
#      Plus two structural claims the header of `kleene.mojo` makes: the byte
#      form equals the chunk form at W = 8, and AND / OR keep canonical inputs
#      canonical (a NULL lane that came in with data 0 goes out with data 0, the
#      encoding `filter_to_indices` relies on).
#
#   §2 The six nullable column comparisons in `comparison_kleene.mojo`
#      (`eval_col_{gt,lt,eq,ne,le,ge}_nullable`) over seeded Int8, Int32,
#      Int64, Float32 and Float64 columns of every length 0..130, with NULLs at
#      a random density and each operand an Arrow SLICE at its own offset
#      0..9. Lengths to 130 cross two 64-row blocks and every SIMD tail; Int8
#      at 130 rows is more than two full AVX-512 vectors. Floats include NaN,
#      -0.0 and +-inf. The reference: the result row is NULL iff either operand
#      row is NULL; a NULL row's data bit is 0 (filter-safe); a valid row is the
#      IEEE comparison, with `!=` UNORDERED (NaN != x is true), the documented
#      contract of these kernels; `null_count` equals the number of NULL rows.
#
# Seeds are fixed (splitmix64) and printed in every failure message.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_kernels.eval_chunks import EvalBoolChunk
from komira_kernels.kleene import (
    _kleene_and_chunk,
    _kleene_or_chunk,
    _kleene_not_chunk,
    _kleene_and_byte,
    _kleene_or_byte,
    _kleene_not_byte,
    _cmp_result_validity_byte,
    _cmp_result_validity_chunk,
)
from komira_kernels.comparison_kleene import (
    eval_col_gt_nullable,
    eval_col_lt_nullable,
    eval_col_eq_nullable,
    eval_col_ne_nullable,
    eval_col_le_nullable,
    eval_col_ge_nullable,
)


# =============================================================================
# splitmix64
# =============================================================================


struct Rng(Movable, Deinitable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var z = self.state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> UInt64(31))

    def next_int(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))

    def next_u8(mut self) -> UInt8:
        return (self.next_u64() & UInt64(0xFF)).cast[DType.uint8]()


# =============================================================================
# The 3VL reference. A tri-state is encoded 0 = FALSE, 1 = TRUE, 2 = NULL.
# =============================================================================


comptime T_FALSE = 0
comptime T_TRUE = 1
comptime T_NULL = 2


def _tri(valid: Bool, data: Bool) -> Int:
    if not valid:
        return T_NULL
    return T_TRUE if data else T_FALSE


def _ref_and(a: Int, b: Int) -> Int:
    if a == T_FALSE or b == T_FALSE:
        return T_FALSE
    if a == T_TRUE and b == T_TRUE:
        return T_TRUE
    return T_NULL


def _ref_or(a: Int, b: Int) -> Int:
    if a == T_TRUE or b == T_TRUE:
        return T_TRUE
    if a == T_FALSE and b == T_FALSE:
        return T_FALSE
    return T_NULL


def _ref_not(a: Int) -> Int:
    if a == T_NULL:
        return T_NULL
    return T_FALSE if a == T_TRUE else T_TRUE


def _bit(x: UInt8, i: Int) -> Bool:
    return ((x >> UInt8(i)) & UInt8(1)) == UInt8(1)


def _tri_name(t: Int) -> String:
    if t == T_NULL:
        return "NULL"
    return "TRUE" if t == T_TRUE else "FALSE"


# =============================================================================
# §1 — Kleene primitives
# =============================================================================


def _check_byte_lanes(
    label: String,
    lv: UInt8,
    ld: UInt8,
    rv: UInt8,
    rd: UInt8,
    out_d: UInt8,
    out_v: UInt8,
    op: Int,
) raises:
    """op: 0 = AND, 1 = OR, 2 = NOT (right operand ignored)."""
    for i in range(8):
        var l = _tri(_bit(lv, i), _bit(ld, i))
        var r = _tri(_bit(rv, i), _bit(rd, i))
        var want: Int
        if op == 0:
            want = _ref_and(l, r)
        elif op == 1:
            want = _ref_or(l, r)
        else:
            want = _ref_not(l)
        var got = _tri(_bit(out_v, i), _bit(out_d, i))
        assert_true(
            got == want,
            label + " lane " + String(i) + ": l=" + _tri_name(l) + " r="
            + _tri_name(r) + " (l.data=" + String(_bit(ld, i)) + " r.data="
            + String(_bit(rd, i)) + ") gave " + _tri_name(got) + ", want "
            + _tri_name(want),
        )


def test_kleene_byte_exhaustive() raises:
    """All 16 (valid, data) x (valid, data) pairs sit in the 8 lanes of two
    byte pairs; every one is checked for AND, OR and NOT, garbage data under
    NULL included."""
    # Lane i of (lv, ld) walks i = 0..7 over valid = i & 1, data = (i >> 1) & 1
    # twice; (rv, rd) holds the 4 combinations in lanes 0-3 and again in 4-7,
    # shifted so that across the two passes every left meets every right.
    for pass_ in range(4):
        var lv = UInt8(0)
        var ld = UInt8(0)
        var rv = UInt8(0)
        var rd = UInt8(0)
        for i in range(8):
            var lcombo = i & 3
            var rcombo = (i + pass_) & 3
            if (lcombo & 1) != 0:
                lv |= UInt8(1) << UInt8(i)
            if (lcombo & 2) != 0:
                ld |= UInt8(1) << UInt8(i)
            if (rcombo & 1) != 0:
                rv |= UInt8(1) << UInt8(i)
            if (rcombo & 2) != 0:
                rd |= UInt8(1) << UInt8(i)
        var a = _kleene_and_byte(lv, ld, rv, rd)
        _check_byte_lanes("and_byte pass " + String(pass_), lv, ld, rv, rd, a[0], a[1], 0)
        var o = _kleene_or_byte(lv, ld, rv, rd)
        _check_byte_lanes("or_byte pass " + String(pass_), lv, ld, rv, rd, o[0], o[1], 1)
        var n = _kleene_not_byte(lv, ld)
        _check_byte_lanes("not_byte pass " + String(pass_), lv, ld, rv, rd, n[0], n[1], 2)


def test_kleene_byte_seeded() raises:
    for seed in range(2000):
        var rng = Rng(UInt64(77000 + seed))
        var lv = rng.next_u8()
        var ld = rng.next_u8()
        var rv = rng.next_u8()
        var rd = rng.next_u8()
        var ctx = String("seed=") + String(77000 + seed)
        var a = _kleene_and_byte(lv, ld, rv, rd)
        _check_byte_lanes(ctx + " and_byte", lv, ld, rv, rd, a[0], a[1], 0)
        var o = _kleene_or_byte(lv, ld, rv, rd)
        _check_byte_lanes(ctx + " or_byte", lv, ld, rv, rd, o[0], o[1], 1)
        var n = _kleene_not_byte(lv, ld)
        _check_byte_lanes(ctx + " not_byte", lv, ld, rv, rd, n[0], n[1], 2)
        assert_true(
            _cmp_result_validity_byte(lv, rv) == (lv & rv),
            ctx + ": comparison validity must be lv & rv",
        )


def _chunk_from_bytes[W: Int](v: UInt64, d: UInt64) -> EvalBoolChunk[W]:
    var vals = SIMD[DType.bool, W](fill=False)
    var valid = SIMD[DType.bool, W](fill=False)
    comptime for i in range(W):
        vals[i] = ((d >> UInt64(i)) & UInt64(1)) == UInt64(1)
        valid[i] = ((v >> UInt64(i)) & UInt64(1)) == UInt64(1)
    return EvalBoolChunk[W](values=vals, validity=valid)


def _check_chunk[W: Int](seed: UInt64) raises:
    var rng = Rng(seed)
    var lvb = rng.next_u64()
    var ldb = rng.next_u64()
    var rvb = rng.next_u64()
    var rdb = rng.next_u64()
    var l = _chunk_from_bytes[W](lvb, ldb)
    var r = _chunk_from_bytes[W](rvb, rdb)
    var a = _kleene_and_chunk[W](l, r)
    var o = _kleene_or_chunk[W](l, r)
    var n = _kleene_not_chunk[W](l)
    var cv = _cmp_result_validity_chunk[W](l.validity, r.validity)
    var ctx = String("W=") + String(W) + " seed=" + String(seed)
    for i in range(W):
        var l_v = Bool(l.validity[i])
        var l_d = Bool(l.values[i])
        var r_v = Bool(r.validity[i])
        var r_d = Bool(r.values[i])
        var lt = _tri(l_v, l_d)
        var rt = _tri(r_v, r_d)
        var at = _tri(Bool(a.validity[i]), Bool(a.values[i]))
        var ot = _tri(Bool(o.validity[i]), Bool(o.values[i]))
        var nt = _tri(Bool(n.validity[i]), Bool(n.values[i]))
        assert_true(
            at == _ref_and(lt, rt),
            ctx + " and_chunk lane " + String(i) + ": " + _tri_name(lt) + " AND "
            + _tri_name(rt) + " gave " + _tri_name(at),
        )
        assert_true(
            ot == _ref_or(lt, rt),
            ctx + " or_chunk lane " + String(i) + ": " + _tri_name(lt) + " OR "
            + _tri_name(rt) + " gave " + _tri_name(ot),
        )
        assert_true(
            nt == _ref_not(lt),
            ctx + " not_chunk lane " + String(i) + ": NOT " + _tri_name(lt)
            + " gave " + _tri_name(nt),
        )
        assert_true(
            Bool(cv[i]) == (l_v and r_v),
            ctx + " cmp validity lane " + String(i) + " must be lv & rv",
        )
        # Canonical in, canonical out (AND / OR): a NULL lane whose inputs
        # carry data 0 under NULL must come out with data 0.
        if (l_v or not l_d) and (r_v or not r_d):
            if not Bool(a.validity[i]):
                assert_true(
                    not Bool(a.values[i]),
                    ctx + " and_chunk lane " + String(i)
                    + ": canonical inputs gave a NULL with data 1",
                )
            if not Bool(o.validity[i]):
                assert_true(
                    not Bool(o.values[i]),
                    ctx + " or_chunk lane " + String(i)
                    + ": canonical inputs gave a NULL with data 1",
                )


def test_kleene_chunk_seeded_widths() raises:
    for s in range(400):
        _check_chunk[1](UInt64(91000 + s))
        _check_chunk[4](UInt64(92000 + s))
        _check_chunk[8](UInt64(93000 + s))
        _check_chunk[16](UInt64(94000 + s))
        _check_chunk[32](UInt64(95000 + s))


def test_kleene_byte_equals_chunk_at_w8() raises:
    """The header's layering claim: one byte is eight lanes, and both forms
    give the same bits (data AND validity, garbage lanes included)."""
    for s in range(1000):
        var rng = Rng(UInt64(96000 + s))
        var lv = rng.next_u8()
        var ld = rng.next_u8()
        var rv = rng.next_u8()
        var rd = rng.next_u8()
        var l = _chunk_from_bytes[8](UInt64(lv), UInt64(ld))
        var r = _chunk_from_bytes[8](UInt64(rv), UInt64(rd))
        var ab = _kleene_and_byte(lv, ld, rv, rd)
        var ac = _kleene_and_chunk[8](l, r)
        var ob = _kleene_or_byte(lv, ld, rv, rd)
        var oc = _kleene_or_chunk[8](l, r)
        var nb = _kleene_not_byte(lv, ld)
        var nc = _kleene_not_chunk[8](l)
        for i in range(8):
            var same = (
                _bit(ab[0], i) == Bool(ac.values[i])
                and _bit(ab[1], i) == Bool(ac.validity[i])
                and _bit(ob[0], i) == Bool(oc.values[i])
                and _bit(ob[1], i) == Bool(oc.validity[i])
                and _bit(nb[0], i) == Bool(nc.values[i])
                and _bit(nb[1], i) == Bool(nc.validity[i])
            )
            assert_true(
                same,
                String("seed=") + String(96000 + s) + " lane " + String(i)
                + ": byte and chunk forms disagree",
            )


# =============================================================================
# §2 — nullable column comparisons vs the scalar reference
# =============================================================================


comptime OP_GT = 0
comptime OP_LT = 1
comptime OP_EQ = 2
comptime OP_NE = 3
comptime OP_LE = 4
comptime OP_GE = 5


def _op_name(op: Int) -> String:
    if op == OP_GT:
        return "gt"
    if op == OP_LT:
        return "lt"
    if op == OP_EQ:
        return "eq"
    if op == OP_NE:
        return "ne"
    if op == OP_LE:
        return "le"
    return "ge"


def _ref_cmp[dt: DType](op: Int, a: Scalar[dt], b: Scalar[dt]) -> Bool:
    """IEEE comparisons, written per row. `ne` is UNORDERED: NaN != x is true,
    which is `not (a == b)`, not Mojo's ordered `!=`."""
    if op == OP_GT:
        return a > b
    if op == OP_LT:
        return a < b
    if op == OP_EQ:
        return a == b
    if op == OP_NE:
        return not (a == b)
    if op == OP_LE:
        return a <= b
    return a >= b


def _value[dt: DType](mut rng: Rng) -> Scalar[dt]:
    """A small value domain, so equal pairs are common and `eq` / `le` / `ge`
    are exercised on ties; floats add NaN, -0.0 and +-inf."""
    comptime if dt.is_floating_point():
        var k = rng.next_int(16)
        if k == 0:
            return (Float64(0.0) / Float64(0.0)).cast[dt]()
        if k == 1:
            return (Float64(0.0) * Float64(-1.0)).cast[dt]()
        if k == 2:
            return (Float64(1.0) / Float64(0.0)).cast[dt]()
        if k == 3:
            return (Float64(-1.0) / Float64(0.0)).cast[dt]()
        return Scalar[dt](rng.next_int(9) - 4) / Scalar[dt](2)
    else:
        return Scalar[dt](rng.next_int(9) - 4)


def _column[
    dt: DType
](mut rng: Rng, length: Int, offset: Int, null_pct: Int) raises -> PrimitiveArray[dt]:
    """`offset + length + 3` rows with NULLs at `null_pct` percent, sliced to
    [offset, offset + length): data AND validity stay in absolute coordinates."""
    var total = offset + length + 3
    var base = PrimitiveArray[dt].allocate_nullable(total)
    for i in range(total):
        base.set(i, _value[dt](rng))
    for i in range(total):
        if rng.next_int(100) < null_pct:
            base._set_null(i)
    return base.slice(offset, length)


def _run_op[dt: DType](op: Int, l: PrimitiveArray[dt], r: PrimitiveArray[dt]) raises -> BooleanArray:
    if op == OP_GT:
        return eval_col_gt_nullable[dt](l, r)
    if op == OP_LT:
        return eval_col_lt_nullable[dt](l, r)
    if op == OP_EQ:
        return eval_col_eq_nullable[dt](l, r)
    if op == OP_NE:
        return eval_col_ne_nullable[dt](l, r)
    if op == OP_LE:
        return eval_col_le_nullable[dt](l, r)
    return eval_col_ge_nullable[dt](l, r)


def _cmp_sweep[dt: DType](name: String, base_seed: UInt64) raises:
    for length in range(131):
        var seed = base_seed + UInt64(length)
        var rng = Rng(seed)
        var loff = rng.next_int(10)
        var roff = rng.next_int(10)
        var pct = 0 if length % 5 == 0 else (100 if length % 17 == 0 else 30)
        var l = _column[dt](rng, length, loff, pct)
        var r = _column[dt](rng, length, roff, pct)
        for op in range(6):
            var got = _run_op[dt](op, l, r)
            var ctx = (
                name + " " + _op_name(op) + " seed=" + String(seed) + " len="
                + String(length) + " offsets=(" + String(loff) + ","
                + String(roff) + ")"
            )
            assert_true(got.length == length, ctx + ": result length")
            var nulls = 0
            for i in range(length):
                var is_null = l.is_null(i) or r.is_null(i)
                if is_null:
                    nulls += 1
                    assert_true(got.is_null(i), ctx + " row " + String(i) + ": must be NULL")
                    assert_true(
                        not got.get(i),
                        ctx + " row " + String(i) + ": a NULL row must carry data 0",
                    )
                else:
                    var want = _ref_cmp[dt](op, l.load[1](i), r.load[1](i))
                    assert_true(not got.is_null(i), ctx + " row " + String(i) + ": must be valid")
                    assert_true(
                        got.get(i) == want,
                        ctx + " row " + String(i) + ": " + String(l.load[1](i)) + " "
                        + _op_name(op) + " " + String(r.load[1](i)) + " gave "
                        + String(got.get(i)) + ", want " + String(want),
                    )
            if nulls > 0:
                assert_true(
                    got.null_count == nulls,
                    ctx + ": null_count=" + String(got.null_count) + " want " + String(nulls),
                )


def test_cmp_nullable_i8_sweep() raises:
    _cmp_sweep[DType.int8]("i8", 110000)


def test_cmp_nullable_i32_sweep() raises:
    _cmp_sweep[DType.int32]("i32", 120000)


def test_cmp_nullable_i64_sweep() raises:
    _cmp_sweep[DType.int64]("i64", 130000)


def test_cmp_nullable_f32_sweep() raises:
    _cmp_sweep[DType.float32]("f32", 140000)


def test_cmp_nullable_f64_sweep() raises:
    _cmp_sweep[DType.float64]("f64", 150000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
