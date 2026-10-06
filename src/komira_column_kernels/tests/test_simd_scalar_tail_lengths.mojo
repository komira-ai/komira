# =============================================================================
# test_simd_scalar_tail_lengths.mojo — SIMD kernels against a per-row scalar
# reference at every length 0..130
# =============================================================================
#
# WHAT THIS PINS. Each kernel below has an explicit SIMD body and a scalar
# tail (or a byte tail after a 64-bit block walk), and the hand-off between
# them is where an off-by-one hides: a tail that starts one row late, a lane
# weight that is wrong for one SIMD width, a partial byte left with a stray
# bit. Every kernel is run at every length 0..130 and compared row by row with
# a reference loop written here. 130 rows cross two 64-row blocks and at least
# two full vectors of every native SIMD width up to 512 bits (Int8 on AVX-512
# is 64 lanes); the checked integer kernels' 4x-native block is crossed for
# Int8 on 256-bit SIMD (128 rows) but not on 512-bit SIMD (256 rows).
#
#   §1 comparisons, column vs scalar and column vs column: `eval_{gt,lt,eq,
#      ne,le,ge}` and `eval_col_*` over Int8, Int32, Int64, UInt8, Float32 and
#      Float64; each operand is an Arrow slice at its own offset 0..9 (the
#      loads are offset-aware). Floats include NaN, -0.0, +-inf; `ne` is IEEE
#      UNORDERED (NaN != x is true), the kernels' documented contract.
#      `true_count()` must equal the reference count, so a stray bit past
#      `length` in the last byte fails too.
#   §2 arithmetic: `eval_{add,sub,mul}` and the `_scalar` forms. Floats must be
#      bit-identical to the scalar IEEE result (NaN as NaN). Integers are the
#      CHECKED kernels: over the full Int8 / Int16 range some rows overflow,
#      and the kernel must raise exactly when the reference (computed in
#      Int64) says some row leaves the type's range, and otherwise return the
#      exact values.
#   §3 Kleene `eval_and` / `eval_or` / `eval_not` over BooleanArrays with and
#      without NULLs: the 3VL table per row, data 0 under every NULL (the
#      encoding `filter_to_indices` relies on), and `true_count()` /
#      `null_count` equal to the reference.
#   §4 `filter_to_indices`, `_filter_to_indices_simd` and
#      `_filter_to_indices_scalar` at densities 0, 2%, 50%, 98% and 100%:
#      all three equal the reference index list.
#
# Seeds are fixed (splitmix64) and printed in every failure message.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_column_kernels.comparison import (
    eval_gt,
    eval_lt,
    eval_eq,
    eval_ne,
    eval_le,
    eval_ge,
    eval_col_gt,
    eval_col_lt,
    eval_col_eq,
    eval_col_ne,
    eval_col_le,
    eval_col_ge,
    filter_to_indices,
    _filter_to_indices_simd,
    _filter_to_indices_scalar,
)
from komira_column_kernels.arithmetic import (
    eval_add,
    eval_sub,
    eval_mul,
    eval_add_scalar,
    eval_sub_scalar,
    eval_mul_scalar,
    eval_rsub_scalar,
    eval_and,
    eval_or,
    eval_not,
)


comptime MAX_LEN = 130


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


# =============================================================================
# Values and columns
# =============================================================================


def _small[dt: DType](mut rng: Rng) -> Scalar[dt]:
    """A small domain (ties are common, so eq / le / ge see equal pairs);
    floats add NaN, -0.0 and +-inf about one row in four."""
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
    elif dt.is_unsigned():
        return Scalar[dt](rng.next_int(9))
    else:
        return Scalar[dt](rng.next_int(9) - 4)


def _full_range[dt: DType](mut rng: Rng) -> Scalar[dt]:
    """Any bit pattern of the (integer) type: sums and products overflow."""
    return (rng.next_u64()).cast[dt]()


def _sliced[
    dt: DType
](mut rng: Rng, length: Int, offset: Int, full: Bool) raises -> PrimitiveArray[dt]:
    """`offset + length + 3` non-null rows, sliced to [offset, offset+length)."""
    var total = offset + length + 3
    var base = PrimitiveArray[dt].allocate(total)
    for i in range(total):
        if full:
            base.set(i, _full_range[dt](rng))
        else:
            base.set(i, _small[dt](rng))
    return base.slice(offset, length)


def _same_bits[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Bool:
    """Exact equality; for floats every NaN equals every NaN, and the sign of
    zero must match (an add / mul result is fully determined by IEEE)."""
    comptime if dt.is_floating_point():
        if a != a:
            return b != b
        if b != b:
            return False
        if a == b and a == Scalar[dt](0):
            # +0 vs -0: compare the sign through 1/x.
            return (Scalar[dt](1) / a) == (Scalar[dt](1) / b)
        return a == b
    else:
        return a == b


# =============================================================================
# §1 — comparisons
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


def _cmp_cs[dt: DType](op: Int, c: PrimitiveArray[dt], t: Scalar[dt]) -> BooleanArray:
    if op == OP_GT:
        return eval_gt[dt](c, t)
    if op == OP_LT:
        return eval_lt[dt](c, t)
    if op == OP_EQ:
        return eval_eq[dt](c, t)
    if op == OP_NE:
        return eval_ne[dt](c, t)
    if op == OP_LE:
        return eval_le[dt](c, t)
    return eval_ge[dt](c, t)


def _cmp_cc[dt: DType](op: Int, l: PrimitiveArray[dt], r: PrimitiveArray[dt]) -> BooleanArray:
    if op == OP_GT:
        return eval_col_gt[dt](l, r)
    if op == OP_LT:
        return eval_col_lt[dt](l, r)
    if op == OP_EQ:
        return eval_col_eq[dt](l, r)
    if op == OP_NE:
        return eval_col_ne[dt](l, r)
    if op == OP_LE:
        return eval_col_le[dt](l, r)
    return eval_col_ge[dt](l, r)


def _cmp_sweep[dt: DType](name: String, base_seed: UInt64) raises:
    for length in range(MAX_LEN + 1):
        var seed = base_seed + UInt64(length)
        var rng = Rng(seed)
        var loff = rng.next_int(10)
        var roff = rng.next_int(10)
        var l = _sliced[dt](rng, length, loff, False)
        var r = _sliced[dt](rng, length, roff, False)
        var t = _small[dt](rng)
        for op in range(6):
            var ctx = (
                name + " " + _op_name(op) + " seed=" + String(seed) + " len="
                + String(length) + " offsets=(" + String(loff) + ","
                + String(roff) + ")"
            )
            var cs = _cmp_cs[dt](op, l, t)
            var cc = _cmp_cc[dt](op, l, r)
            assert_true(cs.length == length and cc.length == length, ctx + ": result length")
            var n_cs = 0
            var n_cc = 0
            for i in range(length):
                var a = l.load[1](i)
                var b = r.load[1](i)
                var want_cs = _ref_cmp[dt](op, a, t)
                var want_cc = _ref_cmp[dt](op, a, b)
                if want_cs:
                    n_cs += 1
                if want_cc:
                    n_cc += 1
                assert_true(
                    cs.get(i) == want_cs,
                    ctx + " col-vs-scalar row " + String(i) + ": " + String(a) + " "
                    + _op_name(op) + " " + String(t) + " gave " + String(cs.get(i)),
                )
                assert_true(
                    cc.get(i) == want_cc,
                    ctx + " col-vs-col row " + String(i) + ": " + String(a) + " "
                    + _op_name(op) + " " + String(b) + " gave " + String(cc.get(i)),
                )
            assert_true(
                cs.true_count() == n_cs,
                ctx + ": col-vs-scalar true_count=" + String(cs.true_count())
                + " want " + String(n_cs) + " (a bit set past the last row?)",
            )
            assert_true(
                cc.true_count() == n_cc,
                ctx + ": col-vs-col true_count=" + String(cc.true_count())
                + " want " + String(n_cc) + " (a bit set past the last row?)",
            )


def test_cmp_i8_lengths() raises:
    _cmp_sweep[DType.int8]("i8", 200000)


def test_cmp_u8_lengths() raises:
    _cmp_sweep[DType.uint8]("u8", 210000)


def test_cmp_i32_lengths() raises:
    _cmp_sweep[DType.int32]("i32", 220000)


def test_cmp_i64_lengths() raises:
    _cmp_sweep[DType.int64]("i64", 230000)


def test_cmp_f32_lengths() raises:
    _cmp_sweep[DType.float32]("f32", 240000)


def test_cmp_f64_lengths() raises:
    _cmp_sweep[DType.float64]("f64", 250000)


# =============================================================================
# §2 — arithmetic
# =============================================================================


comptime AR_ADD = 0
comptime AR_SUB = 1
comptime AR_MUL = 2


def _ar_name(op: Int) -> String:
    if op == AR_ADD:
        return "add"
    if op == AR_SUB:
        return "sub"
    return "mul"


def _ar_cc[dt: DType](op: Int, l: PrimitiveArray[dt], r: PrimitiveArray[dt]) raises -> PrimitiveArray[dt]:
    if op == AR_ADD:
        return eval_add[dt](l, r)
    if op == AR_SUB:
        return eval_sub[dt](l, r)
    return eval_mul[dt](l, r)


def _ar_cs[dt: DType](op: Int, c: PrimitiveArray[dt], s: Scalar[dt]) raises -> PrimitiveArray[dt]:
    if op == AR_ADD:
        return eval_add_scalar[dt](c, s)
    if op == AR_SUB:
        return eval_sub_scalar[dt](c, s)
    return eval_mul_scalar[dt](c, s)


def _ref_ar_f[dt: DType](op: Int, a: Scalar[dt], b: Scalar[dt]) -> Scalar[dt]:
    if op == AR_ADD:
        return a + b
    if op == AR_SUB:
        return a - b
    return a * b


def _ar_float_sweep[dt: DType](name: String, base_seed: UInt64) raises:
    for length in range(MAX_LEN + 1):
        var seed = base_seed + UInt64(length)
        var rng = Rng(seed)
        var loff = rng.next_int(10)
        var roff = rng.next_int(10)
        var l = _sliced[dt](rng, length, loff, False)
        var r = _sliced[dt](rng, length, roff, False)
        var s = _small[dt](rng)
        var rsub = eval_rsub_scalar[dt](s, l)
        for op in range(3):
            var ctx = (
                name + " " + _ar_name(op) + " seed=" + String(seed) + " len="
                + String(length)
            )
            var cc = _ar_cc[dt](op, l, r)
            var cs = _ar_cs[dt](op, l, s)
            for i in range(length):
                var a = l.load[1](i)
                var b = r.load[1](i)
                assert_true(
                    _same_bits[dt](cc.load[1](i), _ref_ar_f[dt](op, a, b)),
                    ctx + " col-col row " + String(i) + ": " + String(a) + ", "
                    + String(b) + " gave " + String(cc.load[1](i)),
                )
                assert_true(
                    _same_bits[dt](cs.load[1](i), _ref_ar_f[dt](op, a, s)),
                    ctx + " col-scalar row " + String(i) + ": " + String(a) + ", "
                    + String(s) + " gave " + String(cs.load[1](i)),
                )
        for i in range(length):
            var a = l.load[1](i)
            assert_true(
                _same_bits[dt](rsub.load[1](i), s - a),
                name + " rsub seed=" + String(seed) + " row " + String(i)
                + ": " + String(s) + " - " + String(a) + " gave " + String(rsub.load[1](i)),
            )


def test_arith_f32_lengths() raises:
    _ar_float_sweep[DType.float32]("f32", 300000)


def test_arith_f64_lengths() raises:
    _ar_float_sweep[DType.float64]("f64", 310000)


def _in_range[dt: DType](v: Int64) -> Bool:
    return v >= Scalar[dt].MIN.cast[DType.int64]() and v <= Scalar[dt].MAX.cast[DType.int64]()


def _ref_ar_i(op: Int, a: Int64, b: Int64) -> Int64:
    if op == AR_ADD:
        return a + b
    if op == AR_SUB:
        return a - b
    return a * b


def _ar_int_sweep[dt: DType](name: String, base_seed: UInt64, full: Bool) raises:
    """Checked integer kernels. With `full`, operands span the whole type, so
    many inputs overflow somewhere; the kernel must raise iff the Int64
    reference leaves the type's range on some row, and be exact otherwise."""
    for length in range(MAX_LEN + 1):
        var seed = base_seed + UInt64(length)
        var rng = Rng(seed)
        var loff = rng.next_int(10)
        var roff = rng.next_int(10)
        # Full range on one length in three: the others stay small so the
        # no-overflow path (values compared) is reached at every length class.
        var use_full = full and length % 3 == 0
        var l = _sliced[dt](rng, length, loff, use_full)
        var r = _sliced[dt](rng, length, roff, use_full)
        var s = _full_range[dt](rng) if use_full else _small[dt](rng)
        for op in range(3):
            var ctx = (
                name + " " + _ar_name(op) + " seed=" + String(seed) + " len="
                + String(length) + " full=" + String(use_full)
            )
            # Column vs column.
            var want_raise = False
            for i in range(length):
                var v = _ref_ar_i(op, l.load[1](i).cast[DType.int64](), r.load[1](i).cast[DType.int64]())
                if not _in_range[dt](v):
                    want_raise = True
            var raised = False
            var cc = PrimitiveArray[dt].allocate(0)
            try:
                cc = _ar_cc[dt](op, l, r)
            except e:
                _ = e
                raised = True
            if not raised:
                for i in range(length):
                    var v = _ref_ar_i(op, l.load[1](i).cast[DType.int64](), r.load[1](i).cast[DType.int64]())
                    assert_true(
                        cc.load[1](i).cast[DType.int64]() == v,
                        ctx + " col-col row " + String(i) + ": gave "
                        + String(cc.load[1](i)) + " want " + String(v),
                    )
            assert_true(
                raised == want_raise,
                ctx + " col-col: raised=" + String(raised) + " but the reference says "
                + ("an overflow" if want_raise else "no overflow"),
            )
            # Column vs scalar.
            var want_raise_s = False
            for i in range(length):
                var v = _ref_ar_i(op, l.load[1](i).cast[DType.int64](), s.cast[DType.int64]())
                if not _in_range[dt](v):
                    want_raise_s = True
            var raised_s = False
            var cs = PrimitiveArray[dt].allocate(0)
            try:
                cs = _ar_cs[dt](op, l, s)
            except e:
                _ = e
                raised_s = True
            if not raised_s:
                for i in range(length):
                    var v = _ref_ar_i(op, l.load[1](i).cast[DType.int64](), s.cast[DType.int64]())
                    assert_true(
                        cs.load[1](i).cast[DType.int64]() == v,
                        ctx + " col-scalar row " + String(i) + ": gave "
                        + String(cs.load[1](i)) + " want " + String(v),
                    )
            assert_true(
                raised_s == want_raise_s,
                ctx + " col-scalar: raised=" + String(raised_s) + " but the reference says "
                + ("an overflow" if want_raise_s else "no overflow"),
            )


def test_arith_i8_checked_lengths() raises:
    _ar_int_sweep[DType.int8]("i8", 320000, True)


def test_arith_i16_checked_lengths() raises:
    _ar_int_sweep[DType.int16]("i16", 330000, True)


def test_arith_i32_lengths() raises:
    _ar_int_sweep[DType.int32]("i32", 340000, False)


# =============================================================================
# §3 — Kleene AND / OR / NOT over BooleanArrays
# =============================================================================


comptime T_FALSE = 0
comptime T_TRUE = 1
comptime T_NULL = 2


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


def _tri_of(arr: BooleanArray, i: Int) raises -> Int:
    if arr.is_null(i):
        return T_NULL
    return T_TRUE if arr.get(i) else T_FALSE


def _bools(mut rng: Rng, length: Int, nullable: Bool) -> BooleanArray:
    """Canonical encoding: a NULL row carries data 0."""
    var arr = BooleanArray.allocate_nullable(length) if nullable else BooleanArray.allocate(length)
    for i in range(length):
        arr.set(i, rng.next_int(2) == 0)
    if nullable:
        for i in range(length):
            if rng.next_int(3) == 0:
                arr.set(i, False)
                arr._set_null(i)
    return arr^


def _check_kleene(
    ctx: String, got: BooleanArray, want: List[Int]
) raises:
    var length = len(want)
    assert_true(got.length == length, ctx + ": result length")
    var n_true = 0
    var n_null = 0
    for i in range(length):
        var g = _tri_of(got, i)
        assert_true(
            g == want[i],
            ctx + " row " + String(i) + ": gave " + String(g) + " want " + String(want[i])
            + " (0 FALSE, 1 TRUE, 2 NULL)",
        )
        if want[i] == T_NULL:
            n_null += 1
            assert_true(not got.get(i), ctx + " row " + String(i) + ": NULL row must carry data 0")
        elif want[i] == T_TRUE:
            n_true += 1
    assert_true(
        got.true_count() == n_true,
        ctx + ": true_count=" + String(got.true_count()) + " want " + String(n_true),
    )
    if n_null > 0:
        assert_true(
            got.null_count == n_null,
            ctx + ": null_count=" + String(got.null_count) + " want " + String(n_null),
        )


def test_kleene_bool_arrays_lengths() raises:
    for length in range(MAX_LEN + 1):
        for shape in range(4):
            # shape: 0 none nullable, 1 left, 2 right, 3 both.
            var seed = UInt64(400000 + length * 4 + shape)
            var rng = Rng(seed)
            var l = _bools(rng, length, shape == 1 or shape == 3)
            var r = _bools(rng, length, shape == 2 or shape == 3)
            var ctx = String("seed=") + String(seed) + " len=" + String(length) + " shape=" + String(shape)
            var want_and = List[Int]()
            var want_or = List[Int]()
            var want_not = List[Int]()
            for i in range(length):
                var a = _tri_of(l, i)
                var b = _tri_of(r, i)
                want_and.append(_ref_and(a, b))
                want_or.append(_ref_or(a, b))
                want_not.append(_ref_not(a))
            _check_kleene(ctx + " and", eval_and(l, r), want_and)
            _check_kleene(ctx + " or", eval_or(l, r), want_or)
            _check_kleene(ctx + " not", eval_not(l), want_not)


# =============================================================================
# §4 — filter_to_indices: SIMD block walk vs scalar vs reference
# =============================================================================


def test_filter_to_indices_lengths_and_densities() raises:
    for length in range(MAX_LEN + 1):
        for d in range(5):
            # Density per mille: 0, 20, 500, 980, 1000.
            var permille = 0
            if d == 1:
                permille = 20
            elif d == 2:
                permille = 500
            elif d == 3:
                permille = 980
            elif d == 4:
                permille = 1000
            var seed = UInt64(500000 + length * 5 + d)
            var rng = Rng(seed)
            var mask = BooleanArray.allocate(length)
            var want = List[Int]()
            for i in range(length):
                var on = rng.next_int(1000) < permille
                mask.set(i, on)
                if on:
                    want.append(i)
            var ctx = String("seed=") + String(seed) + " len=" + String(length) + " permille=" + String(permille)
            var got_pub = filter_to_indices(mask)
            var got_simd = _filter_to_indices_simd(mask)
            var got_scalar = _filter_to_indices_scalar(mask)
            assert_true(
                len(got_pub) == len(want) and len(got_simd) == len(want) and len(got_scalar) == len(want),
                ctx + ": counts public=" + String(len(got_pub)) + " simd=" + String(len(got_simd))
                + " scalar=" + String(len(got_scalar)) + " want " + String(len(want)),
            )
            for k in range(len(want)):
                assert_true(
                    got_pub[k] == want[k] and got_simd[k] == want[k] and got_scalar[k] == want[k],
                    ctx + " index " + String(k) + ": public=" + String(got_pub[k]) + " simd="
                    + String(got_simd[k]) + " scalar=" + String(got_scalar[k]) + " want " + String(want[k]),
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
