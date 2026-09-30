# =============================================================================
# `Table`'s ACCESSOR SURFACE, EXERCISED AT EVERY CHUNK COUNT
# =============================================================================
#
# ⭐ WHY THIS FILE IS THE POINT OF THE ACCESSOR SURFACE, NOT AN APPENDIX TO IT.
# Every `Table` accessor has TWO arms: a direct hit at `num_chunks() == 1`,
# and a prefix-sum resolve at `num_chunks() > 1`. The default build does NOT
# produce the second arm -- `materialize_plan` is wrap-only (it always holds
# exactly one chunk), and the segmenting route is reachable only through
# `materialize_plan_chunked`. So without this file the n > 1 arms are
# UNEXECUTED CODE in the default build: they would compile, ship, and first run
# on the day segments are armed, across every call site at once.
#
# ⚠ AND A VALUE TEST WOULD NOT SEE IT. A representation change is invisible
# to value assertions, and a fixture can lose the very value a test "asserts"
# (a dictionary encoder that erases `-0.0`). Both lessons are built into the
# fixture below: the float column carries `-0.0` beside `+0.0` and is compared
# BIT-EXACTLY (`-0.0 == 0.0` is True, so `==` cannot see it), and the string
# column carries an empty string, which is where an offsets buffer's
# off-by-one lives.
#
# THE METHOD: ONE FIXTURE, RE-SPLIT, COMPARED AGAINST A LITERAL MODEL
# -------------------------------------------------------------------
# `rechunk_sizes(table, sizes)` re-splits ONE 8-row fixture into any chunk
# shape with NO VALUE CHANGE, and every accessor is then asserted at every
# shape against the SAME literal model. Two tables that differ only in chunking
# are the same result; that is `num_chunks()`'s own docstring, and this file is
# what makes it an assertion.
#
# ⛔ THE HARNESS MUST NOT READ THROUGH THE SURFACE IT IS TESTING, or a bug
# cancels itself. So:
#   * `rechunk_sizes` reads the SOURCE table with `RecordBatch` accessors only
#     (`column_as_primitive_int64`, `column_as_string`, ...) -- the
#     independently-tested, pre-existing surface -- never with `Table.value_*`.
#   * its own global-row resolve, `_src_locate`, is a PLAIN LINEAR WALK, which
#     is deliberately DIFFERENT CODE from `Table._locate`'s binary search over
#     a prefix sum. A common-mode failure would have to be the same mistake
#     made twice in two different algorithms.
#   * every assertion compares against the literal `_MODEL_*` constants, not
#     against another `Table`.
#
# THE CHUNK COUNTS, AND WHY THESE ONES
# ------------------------------------
#   n == 0  the EMPTY result. `_num_rows == 0`, so every per-cell read must
#           RAISE rather than search -- and the Tier-0 accessors must still
#           answer, because "an empty result still has a schema". This is
#           also what makes the n == 0 arm of `_locate`
#           unreachable-by-construction rather than unreachable-by-hope.
#   n == 1  the DIRECT HIT. The arm every single-chunk result takes, and
#           the one that must never consult the prefix sum.
#   n == 2  the FIRST boundary. A binary search over two elements is where a
#           `(lo + hi) // 2` that should have been `(lo + hi + 1) // 2` hangs
#           or lands one chunk early; nothing larger exposes it more cheaply.
#   n == 7  UNEVEN sizes (2,1,1,1,1,1,1). A uniform stride makes every
#           `start[i]` a multiple of one number, which is precisely the shape
#           an off-by-one prefix sum can still satisfy.
#   n == 8  ONE ROW PER CHUNK -- every `start[i] == i`, so any resolve that is
#           off by one lands on the wrong chunk for EVERY row rather than for
#           an edge case.
#   n == 5  with INTERIOR, LEADING and TRAILING EMPTY chunks (0,3,0,5,0).
#           ⭐ THIS ONE IS BEYOND THE REQUIRED SET AND IS THE STRONGEST OF
#           THEM. An empty chunk makes `start[i] == start[i+1]`, so a resolve
#           written as "first i with row < start[i+1]" lands ON the empty chunk
#           and then reads row 0 of a 0-row column. `Table._locate` is written
#           as "LARGEST i with start[i] <= row" for exactly this reason; this
#           is the case that tells the two rules apart.
#
# ⭐⭐ WHAT THIS FILE CATCHES -- TWO MUTANTS, AND THEY FAIL IN TWO DIFFERENT
# WAYS. A harness nobody has falsified is a harness nobody has tested.
#
#   MUTANT-A -- `_locate`'s midpoint, `(lo + hi + 1) // 2` -> the
#     conventional `(lo + hi) // 2`. ⛔ IT DOES NOT GO RED. IT HANGS. At
#     `lo == hi - 1` the conventional midpoint gives `mid == lo` and the
#     `lo = mid` branch then assigns `lo` to itself forever. The finding is
#     recorded AT THE LINE in `table.mojo::_locate`, because the lesson belongs
#     to the person about to "simplify" the spelling: here the familiar form is
#     a WEDGE, not a slow correct answer and not a loud wrong one. ⚠ That also
#     means this file cannot claim to cover that mutation -- a hang is not a
#     detection, and no assertion in here can become one.
#
#   MUTANT-B -- Tier A's refusal threshold, `if n > 1` -> `if n > 1000000`,
#     i.e. an accessor that SHARES chunk 0 over a segmented table instead of
#     refusing. ✅ RED, at the first assertion that should see it:
#     `AssertionError: n=2: column_as_primitive must refuse n>1`. This is the
#     falsifier for the whole n > 1 arm of Tier A: it proves the refusals are
#     REACHED and ASSERTED rather than merely written, which is the property
#     the file's opening paragraph claims.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.table import Table


# =============================================================================
# THE LITERAL MODEL -- the only thing any assertion compares against.
# =============================================================================
#
# Column order is (i64, f64, i32, bool, str) so that the five per-cell
# accessors map one-to-one onto column indices 0..4.

comptime N_ROWS = 8
comptime C_I64 = 0
comptime C_F64 = 1
comptime C_I32 = 2
comptime C_BOOL = 3
comptime C_STR = 4


def _model_i64() -> List[Scalar[DType.int64]]:
    var v = List[Scalar[DType.int64]](capacity=N_ROWS)
    v.append(10)
    v.append(-20)
    v.append(0)
    v.append(-40)
    v.append(50)
    v.append(-60)
    v.append(9223372036854775807)
    v.append(-9223372036854775808)
    return v^


def _model_f64() -> List[Scalar[DType.float64]]:
    # ⭐ ROW 2 IS `+0.0` AND ROW 3 IS `-0.0`, AND THEY COMPARE EQUAL UNDER `==`.
    # That is why every float assertion below goes through `_f64_bits`. A
    # fixture that carries only ordinary values cannot tell a correct read from
    # a read that silently normalised the sign -- which is exactly what a
    # dictionary encoder that erases `-0.0` would do.
    var v = List[Scalar[DType.float64]](capacity=N_ROWS)
    v.append(1.5)
    v.append(-2.5)
    v.append(0.0)
    v.append(-0.0)
    v.append(4.25)
    v.append(-8.125)
    v.append(1.0e308)
    v.append(-1.0e-308)
    return v^


def _model_i32() -> List[Scalar[DType.int32]]:
    var v = List[Scalar[DType.int32]](capacity=N_ROWS)
    v.append(1)
    v.append(-2)
    v.append(3)
    v.append(-4)
    v.append(5)
    v.append(-6)
    v.append(2147483647)
    v.append(-2147483648)
    return v^


def _model_bool() -> List[Bool]:
    var v = List[Bool](capacity=N_ROWS)
    v.append(True)
    v.append(False)
    v.append(True)
    v.append(True)
    v.append(False)
    v.append(False)
    v.append(True)
    v.append(False)
    return v^


def _model_str() -> List[String]:
    # ⚠ ROW 1 IS THE EMPTY STRING. A var-len offsets buffer's off-by-one is
    # invisible on every non-empty value and visible only here.
    var v = List[String](capacity=N_ROWS)
    v.append(String("alpha"))
    v.append(String(""))
    v.append(String("gamma"))
    v.append(String("delta"))
    v.append(String("e"))
    v.append(String("zeta"))
    v.append(String("eta"))
    v.append(String("theta"))
    return v^


def _f64_bits(v: Scalar[DType.float64]) -> Scalar[DType.uint64]:
    """The bit pattern of a float64, so `+0.0` and `-0.0` are distinguishable.

    Same technique and same reason as `record_batch_compare._diff_primitive`:
    `-0.0 == 0.0` is True in IEEE-754, so an `==` assertion on a float cannot
    see a sign that was lost.
    """
    return bitcast[DType.uint64, width=1](v)


def _fixture_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    sb.add_field(Field("n", ArrowType.INT32, False))
    sb.add_field(Field("b", ArrowType.BOOL, False))
    sb.add_field(Field("s", ArrowType.STRING, False))
    return sb.build()


def _fixture_batch(lo: Int, hi: Int) raises -> RecordBatch:
    """Rows `[lo, hi)` of the model as ONE `RecordBatch`. `lo == hi` is a
    legal 0-row batch and is used to build the empty-chunk shapes."""
    var mi = _model_i64()
    var mf = _model_f64()
    var mn = _model_i32()
    var mb = _model_bool()
    var ms = _model_str()

    var vi = List[Scalar[DType.int64]](capacity=hi - lo)
    var vf = List[Scalar[DType.float64]](capacity=hi - lo)
    var vn = List[Scalar[DType.int32]](capacity=hi - lo)
    var vs = List[String](capacity=hi - lo)
    var bb = BooleanArray.allocate(hi - lo)
    for r in range(lo, hi):
        vi.append(mi[r])
        vf.append(mf[r])
        vn.append(mn[r])
        vs.append(ms[r])
        bb.set(r - lo, mb[r])

    var rbb = RecordBatchBuilder()
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(vi^)
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(vf^)
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(vn^)
        )
    )
    rbb.add_column(Column.from_boolean(bb^))
    rbb.add_column(Column.from_string(StringArray.from_strings(vs^)))
    var schema = _fixture_schema()
    return rbb.build(schema^)


# =============================================================================
# ⭐ THE HARNESS -- `rechunk`. Re-split ONE table, change NO value.
# =============================================================================


def _src_locate(table: Table, row: Int) raises -> Tuple[Int, Int]:
    """Global row -> `(chunk, local)` by a PLAIN LINEAR WALK.

    ⛔ DELIBERATELY NOT `Table._locate`. This is the harness's own resolve, and
    it is written as a straight accumulate-and-compare precisely so that it
    shares no logic with the binary search it exists to check. If both were the
    same algorithm the test would confirm the implementation against itself.
    """
    var seen = 0
    for c in range(table.num_chunks()):
        var n = table.chunks()[c].num_rows()
        if row < seen + n:
            return (c, row - seen)
        seen += n
    raise Error(
        "_src_locate: row "
        + String(row)
        + " past the end of a "
        + String(seen)
        + "-row table"
    )


def rechunk_sizes(table: Table, sizes: List[Int]) raises -> Table:
    """Re-split `table` into chunks of exactly `sizes`, preserving every value.

    ⚠ THE VALUES ARE READ WITH `RecordBatch` ACCESSORS ONLY. Nothing here calls
    a `Table.value_*` / `Table.column_value` accessor, because those are what
    this file exists to falsify; reading the source through them would let a
    bug in the resolve cancel against itself in the rebuild.

    ⚠ `sizes` MUST SUM TO `table.num_rows()`. A zero entry is legal and
    deliberate -- it produces a 0-row chunk, which is the shape that makes
    `start[i] == start[i+1]` and separates a "largest index with start <= row"
    resolve from a "first index with row < next start" one.

    Supports the five types this fixture carries; anything else RAISES rather
    than being silently dropped, so a widened fixture cannot quietly lose a
    column here.
    """
    var want = 0
    for k in range(len(sizes)):
        if sizes[k] < 0:
            raise Error("rechunk_sizes: negative size at " + String(k))
        want += sizes[k]
    if want != table.num_rows():
        raise Error(
            "rechunk_sizes: sizes sum to "
            + String(want)
            + " but the table has "
            + String(table.num_rows())
            + " rows"
        )

    var ncols = table.num_columns()
    var out = List[RecordBatch]()
    var lo = 0
    for k in range(len(sizes)):
        var hi = lo + sizes[k]
        var rbb = RecordBatchBuilder()
        for c in range(ncols):
            var t = table.schema().field_arrow_type(c)
            if t == ArrowType.INT64:
                var vi = List[Scalar[DType.int64]](capacity=hi - lo)
                for g in range(lo, hi):
                    var li = _src_locate(table, g)
                    vi.append(
                        table.chunks()[li[0]]
                        .column_as_primitive_int64(c)
                        .get(li[1])
                    )
                rbb.add_column(
                    Column.from_primitive[DType.int64](
                        PrimitiveArray[DType.int64].from_list(vi^)
                    )
                )
            elif t == ArrowType.FLOAT64:
                var vf = List[Scalar[DType.float64]](capacity=hi - lo)
                for g in range(lo, hi):
                    var lf = _src_locate(table, g)
                    vf.append(
                        table.chunks()[lf[0]]
                        .column_as_primitive_float64(c)
                        .get(lf[1])
                    )
                rbb.add_column(
                    Column.from_primitive[DType.float64](
                        PrimitiveArray[DType.float64].from_list(vf^)
                    )
                )
            elif t == ArrowType.INT32:
                var vn = List[Scalar[DType.int32]](capacity=hi - lo)
                for g in range(lo, hi):
                    var ln = _src_locate(table, g)
                    vn.append(
                        table.chunks()[ln[0]]
                        .column_as_primitive_int32(c)
                        .get(ln[1])
                    )
                rbb.add_column(
                    Column.from_primitive[DType.int32](
                        PrimitiveArray[DType.int32].from_list(vn^)
                    )
                )
            elif t == ArrowType.BOOL:
                var bb = BooleanArray.allocate(hi - lo)
                for g in range(lo, hi):
                    var lb = _src_locate(table, g)
                    bb.set(
                        g - lo,
                        table.chunks()[lb[0]].column_as_boolean(c).get(lb[1]),
                    )
                rbb.add_column(Column.from_boolean(bb^))
            elif t == ArrowType.STRING:
                var vs = List[String](capacity=hi - lo)
                for g in range(lo, hi):
                    var ls = _src_locate(table, g)
                    vs.append(
                        table.chunks()[ls[0]].column_as_string(c).get(ls[1])
                    )
                rbb.add_column(
                    Column.from_string(StringArray.from_strings(vs^))
                )
            else:
                raise Error(
                    "rechunk_sizes: unsupported column type "
                    + String(t)
                    + " at index "
                    + String(c)
                )
        var sch = table.schema().copy()
        out.append(rbb.build(sch^))
        lo = hi
    return Table.from_chunks(out^, table.schema().copy())


def rechunk(table: Table, stride: Int) raises -> Table:
    """Re-split `table` into chunks of `stride` rows (the last one shorter).

    The requested spelling; `rechunk_sizes` is the primitive it derives, and
    the uneven / empty-chunk shapes this file needs are expressible only
    through that one.
    """
    if stride <= 0:
        raise Error("rechunk: stride must be positive, got " + String(stride))
    var sizes = List[Int]()
    var left = table.num_rows()
    while left > 0:
        var take = stride if stride < left else left
        sizes.append(take)
        left -= take
    if len(sizes) == 0:
        sizes.append(0)
    return rechunk_sizes(table, sizes^)


def _sizes(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> List[Int]:
    var v = List[Int](capacity=7)
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    v.append(e)
    v.append(f)
    v.append(g)
    return v^


# =============================================================================
# THE ASSERTIONS -- run in full at EVERY chunk shape.
# =============================================================================


def _assert_tier0(table: Table, where: String) raises:
    """The chunk-invariant surface. Must answer identically at every n,
    INCLUDING n == 0, because it reads the authoritative table schema."""
    assert_equal(table.num_columns(), 5, where + ": num_columns")

    assert_equal(table.column_index(String("i")), C_I64, where + ": idx i")
    assert_equal(table.column_index(String("f")), C_F64, where + ": idx f")
    assert_equal(table.column_index(String("n")), C_I32, where + ": idx n")
    assert_equal(table.column_index(String("b")), C_BOOL, where + ": idx b")
    assert_equal(table.column_index(String("s")), C_STR, where + ": idx s")

    # `column_by_name` is `RecordBatch`'s spelling of the same question; a
    # migrating call site must be able to keep its call text.
    assert_equal(table.column_by_name(String("i")), C_I64, where + ": byname i")
    assert_equal(table.column_by_name(String("s")), C_STR, where + ": byname s")

    assert_true(
        table.column_arrow_type(C_I64) == ArrowType.INT64, where + ": type i"
    )
    assert_true(
        table.column_arrow_type(C_F64) == ArrowType.FLOAT64, where + ": type f"
    )
    assert_true(
        table.column_arrow_type(C_I32) == ArrowType.INT32, where + ": type n"
    )
    assert_true(
        table.column_arrow_type(C_BOOL) == ArrowType.BOOL, where + ": type b"
    )
    assert_true(
        table.column_arrow_type(C_STR) == ArrowType.STRING, where + ": type s"
    )

    # The REFUSALS. `Schema.field_arrow_type` does not bounds-check, so the
    # guard has to be the accessor's own.
    var raised_lo = False
    try:
        _ = table.column_arrow_type(-1)
    except:
        raised_lo = True
    assert_true(raised_lo, where + ": column_arrow_type(-1) must raise")

    var raised_hi = False
    try:
        _ = table.column_arrow_type(5)
    except:
        raised_hi = True
    assert_true(raised_hi, where + ": column_arrow_type(5) must raise")

    var raised_name = False
    try:
        _ = table.column_index(String("no_such_column"))
    except:
        raised_name = True
    assert_true(raised_name, where + ": column_index(unknown) must raise")


def _assert_every_cell(table: Table, where: String) raises:
    """Every per-cell accessor, every row, against the LITERAL model.

    ⛔ The comparison target is `_model_*`, never another `Table`. Comparing
    one chunking against another would pass for two implementations that are
    wrong the same way.
    """
    var mi = _model_i64()
    var mf = _model_f64()
    var mn = _model_i32()
    var mb = _model_bool()
    var ms = _model_str()

    assert_equal(table.num_rows(), N_ROWS, where + ": num_rows")

    for r in range(N_ROWS):
        var at = where + " row " + String(r)

        # `column_value` -- DuckDB's `GetValue`, signature-identical to
        # `RecordBatch.column_value`.
        assert_equal(
            Int(table.column_value(C_I64, r)), Int(mi[r]), at + ": column_value"
        )

        assert_equal(Int(table.value_i64(C_I64, r)), Int(mi[r]), at + ": i64")
        assert_equal(Int(table.value_i32(C_I32, r)), Int(mn[r]), at + ": i32")
        assert_equal(table.value_bool(C_BOOL, r), mb[r], at + ": bool")
        assert_equal(table.value_str(C_STR, r), ms[r], at + ": str")

        # ⭐ BIT-EXACT. `-0.0 == 0.0` is True, so an `==` here would pass on a
        # read that dropped the sign. Row 3 of the model is `-0.0`.
        assert_equal(
            Int(_f64_bits(table.value_f64(C_F64, r))),
            Int(_f64_bits(mf[r])),
            at + ": f64 (bit-exact)",
        )

        # The ONE parametric method. Exercising it here is what instantiates
        # it at all -- the library deliberately does not, so that `komira_core`
        # pays no compile for widths nobody reads.
        assert_equal(
            Int(table.value_primitive[DType.int64](C_I64, r)),
            Int(mi[r]),
            at + ": value_primitive[int64]",
        )
        assert_equal(
            Int(_f64_bits(table.value_primitive[DType.float64](C_F64, r))),
            Int(_f64_bits(mf[r])),
            at + ": value_primitive[float64] (bit-exact)",
        )

    # The row REFUSALS, at both ends.
    var raised_lo = False
    try:
        _ = table.value_i64(C_I64, -1)
    except:
        raised_lo = True
    assert_true(raised_lo, where + ": row -1 must raise")

    var raised_hi = False
    try:
        _ = table.value_i64(C_I64, N_ROWS)
    except:
        raised_hi = True
    assert_true(raised_hi, where + ": row num_rows() must raise")


comptime TIER_A_ACCESSORS = 7
"""How many Tier-A accessors exist. `_assert_tier_a` refuses to pass unless
EXACTLY this many refusals fired at n > 1 -- see its docstring.

⚠ HAND-WRITTEN, AND THEREFORE NOT SELF-CHECKING. Raising this number does not
make a new accessor covered; it makes the count agree with a helper that does
not test it. The real figure is derived from `table.mojo`'s Tier-A region;
this literal is the thing that derivation checks, not the authority."""


def _assert_chunk_accessor(table: Table, n_chunks: Int, where: String) raises:
    """`Table.chunk(i)` -- the per-segment BORROW, at every chunk count.

    ⭐ THIS IS THE METHOD THE `List` -> `Slab` FIELD SWAP EXISTS TO MAKE
    EXPRESSIBLE, so it is the one whose absence would make the swap pointless.
    Over the old `List` field a per-element `ref` accessor could not be
    SPELLED: the derived origin was `origin_of(self._chunks["element"])`, which
    has no syntax. Over the `Slab` field it is `origin_of(self._chunks._bytes)`
    -- a real field path. What is asserted here is therefore not just the
    values but the three properties that made the spike conclusive.
    """
    # (1) TWO DOORS, ONE ANSWER. `chunk(i)` and `chunks()[i]` must agree, or
    #     the new accessor is reading a different container than the old one.
    assert_equal(table.num_chunks(), n_chunks, where + ": chunk/num_chunks")
    var total = 0
    for i in range(n_chunks):
        assert_equal(
            table.chunk(i).num_rows(),
            table.chunks()[i].num_rows(),
            where + ": chunk(" + String(i) + ") vs chunks()[" + String(i) + "]",
        )
        total += table.chunk(i).num_rows()
    assert_equal(total, table.num_rows(), where + ": chunk rows sum to num_rows")

    # (2) THE BORROW SURVIVES AN ALLOCATING STATEMENT AND A RE-READ. This is
    #     the property a `ref` accessor is FOR, and the one a copy would fake:
    #     bind, allocate (which is what would move or free a stale buffer),
    #     then read through the SAME binding.
    if n_chunks > 0:
        ref held = table.chunk(0)
        var first_rows = held.num_rows()
        var churn = List[Int](capacity=1024)
        for k in range(1024):
            churn.append(k)
        assert_equal(len(churn), 1024, where + ": churn allocated")
        assert_equal(
            held.num_rows(), first_rows, where + ": ref survives an allocation"
        )
        _ = churn^

    # (3) THE ONE-HOP CHAIN. `t.chunk(i).column_at(c)` is the sanctioned
    #     spelling for a column, because the 2-deep `Table.column_at(i, c)`
    #     is inexpressible (it derives `origin_of(self._chunks._bytes
    #     ._columns._bytes)`, which the compiler prints but cannot parse).
    #     ⛔ The chain is asserted here so that a future attempt to "simplify"
    #     it into a 2-deep accessor has a test to answer to.
    if n_chunks > 0:
        for i in range(n_chunks):
            assert_equal(
                table.chunk(i).column_at(C_I64).length(),
                table.chunk(i).num_rows(),
                where + ": chained column_at length, chunk " + String(i),
            )

    # (4) ⛔⛔ THE BOUNDS.
    #     If `chunk(i)`'s only bound were the `debug_assert` inside
    #     `Slab.__getitem__`, an out-of-range index would be a read past the
    #     slab's allocation reinterpreted as a `RecordBatch`: a plausible
    #     neighbouring segment, returned as an answer, nothing red. ⛔ NOT
    #     MERELY A RELEASE-BUILD HOLE: with the check in `Table.chunk` deleted,
    #     `Slab` does NOT panic in a default (fastbuild) test build either --
    #     `chunk(1)` on a ONE-chunk table returns and `.num_rows()` answers off
    #     the end. So the `debug_assert` protects nothing in the configuration
    #     that actually builds.
    #     ⚠ A HAPPY-PATH-ONLY TEST CANNOT SEE THIS. Every assertion above
    #     passes identically whether or not the bound exists. The check is
    #     unconditional and RAISES (see `Table.chunk`'s docstring for why
    #     raise and not `abort()`), so it is assertable in every build.
    #     ⛔ BOTH ENDS, AND `i == num_chunks()` IS THE LOAD-BEARING ONE: it is
    #     the off-by-one a `for i in range(n + 1)` produces, it is IN the
    #     allocation whenever the slab has spare capacity, and so it is the
    #     index most likely to return a readable wrong answer rather than to
    #     segfault. `-1` is the other end and is cheap to hold.
    var raised_hi = False
    try:
        _ = table.chunk(n_chunks).num_rows()
    except:
        raised_hi = True
    assert_true(
        raised_hi, where + ": chunk(num_chunks()) must raise, not read past"
    )

    var raised_lo = False
    try:
        _ = table.chunk(-1).num_rows()
    except:
        raised_lo = True
    assert_true(raised_lo, where + ": chunk(-1) must raise")

    # ⛔ FAR OUT OF RANGE TOO. `n_chunks + 1024` is well past any spare
    #     capacity, so a bound implemented against the slab's CAPACITY rather
    #     than its LENGTH would still pass the `n_chunks` case above and fail
    #     here. The two indices test different mistakes.
    var raised_far = False
    try:
        _ = table.chunk(n_chunks + 1024).num_rows()
    except:
        raised_far = True
    assert_true(raised_far, where + ": chunk(num_chunks()+1024) must raise")

    # ⛔ REFUSED, NOT DAMAGED. The same assertion Tier A makes after its
    #     refusals: a bound that raised having already moved or freed
    #     something would still have "raised" above.
    assert_equal(
        table.num_chunks(), n_chunks, where + ": intact after chunk refusals"
    )


def _assert_tier_a(table: Table, n_chunks: Int, where: String) raises -> Int:
    """TIER A -- the contiguous typed array. SHARES at n <= 1, RAISES at n > 1,
    NEVER concatenates. Returns HOW MANY REFUSALS FIRED.

    ⭐⭐ THE RETURN VALUE IS THE POINT, AND IT IS WHY THIS HELPER IS NOT `void`.
    The n > 1 arm of every Tier-A accessor is a RAISE, and a raise nobody
    triggers is unexecuted code that compiles, ships, and first runs on the day
    segments are armed -- the exact failure mode this whole file is written
    against (see the header). Asserting "it raised" per accessor is not enough
    on its own: an accessor deleted from this helper, or one that stops being
    reached, removes an assertion SILENTLY. So the count is returned and the
    caller asserts it equals `TIER_A_ACCESSORS`.

    ⛔⛔ WHAT THAT COUNT DOES NOT BUY. `TIER_A_ACCESSORS` is a HAND-WRITTEN
    literal. Add an eighth accessor to `Table`, touch nothing here, and the
    helper still fires seven, the constant still says seven, and the suite is
    GREEN -- with the new accessor's n > 1 RAISE never executed.

    ⭐ SO THE GUARANTEE IS SPLIT, AND EACH HALF NAMES ITS OWN MECHANISM:
      * DELETION / a stopped-being-reached assertion -- covered HERE, by the
        returned count against `TIER_A_ACCESSORS`. `fired` drops below the
        constant and the caller's `assert_equal` goes red.
      * ADDITION of an accessor -- covered by a repository lint that DERIVES
        the accessor set from `table.mojo`'s Tier-A region, requires every
        member to be called in the arm below, and requires both the
        `fired += 1` count and `TIER_A_ACCESSORS` to equal it.
    ⇒ If you add a Tier-A accessor, add its arm here. Do not raise
    `TIER_A_ACCESSORS` without adding the arm -- the constant is the thing
    being checked, not the authority.
    """
    var mi = _model_i64()
    var mf = _model_f64()
    var mn = _model_i32()
    var mb = _model_bool()
    var ms = _model_str()

    if n_chunks > 1:
        # ---- THE REFUSAL ARM -------------------------------------------
        var fired = 0

        var r_param = False
        try:
            _ = table.column_as_primitive[DType.int64](C_I64)
        except:
            r_param = True
        if r_param:
            fired += 1
        assert_true(r_param, where + ": column_as_primitive must refuse n>1")

        var r_i64 = False
        try:
            _ = table.column_as_primitive_int64(C_I64)
        except:
            r_i64 = True
        if r_i64:
            fired += 1
        assert_true(r_i64, where + ": column_as_primitive_int64 must refuse")

        var r_i32 = False
        try:
            _ = table.column_as_primitive_int32(C_I32)
        except:
            r_i32 = True
        if r_i32:
            fired += 1
        assert_true(r_i32, where + ": column_as_primitive_int32 must refuse")

        var r_f64 = False
        try:
            _ = table.column_as_primitive_float64(C_F64)
        except:
            r_f64 = True
        if r_f64:
            fired += 1
        assert_true(r_f64, where + ": column_as_primitive_float64 must refuse")

        var r_f32 = False
        try:
            _ = table.column_as_primitive_float32(C_F64)
        except:
            r_f32 = True
        if r_f32:
            fired += 1
        assert_true(r_f32, where + ": column_as_primitive_float32 must refuse")

        var r_str = False
        try:
            _ = table.column_as_string(C_STR)
        except:
            r_str = True
        if r_str:
            fired += 1
        assert_true(r_str, where + ": column_as_string must refuse n>1")

        var r_bool = False
        try:
            _ = table.column_as_boolean(C_BOOL)
        except:
            r_bool = True
        if r_bool:
            fired += 1
        assert_true(r_bool, where + ": column_as_boolean must refuse n>1")

        # ⛔ REFUSED, NOT CONSUMED. A refusal that damaged the table would
        # still have "raised" above. The table must be exactly as readable
        # after seven refusals as before them -- which is also the assertion
        # that would catch a refusal implemented by concatenating first and
        # raising afterwards.
        assert_equal(table.num_chunks(), n_chunks, where + ": intact after refusals")
        _assert_every_cell(table, where + " [after Tier-A refusals]")
        return fired

    # ---- THE SHARE ARM (n == 0 and n == 1) -----------------------------
    # n == 0 is a 0-row typed array off the schema-carrying empty batch
    # (the schema survives an empty result); n == 1 is straight through to the one chunk.
    var expect = table.num_rows()

    var a_i64 = table.column_as_primitive_int64(C_I64)
    assert_equal(a_i64.length, expect, where + ": i64 array length")
    var a_param = table.column_as_primitive[DType.int64](C_I64)
    assert_equal(a_param.length, expect, where + ": parametric array length")
    var a_i32 = table.column_as_primitive_int32(C_I32)
    assert_equal(a_i32.length, expect, where + ": i32 array length")
    var a_f64 = table.column_as_primitive_float64(C_F64)
    assert_equal(a_f64.length, expect, where + ": f64 array length")
    var a_str = table.column_as_string(C_STR)
    assert_equal(len(a_str), expect, where + ": string array length")
    var a_bool = table.column_as_boolean(C_BOOL)
    assert_equal(len(a_bool), expect, where + ": boolean array length")

    for r in range(expect):
        var at = where + " row " + String(r)
        assert_equal(Int(a_i64.get(r)), Int(mi[r]), at + ": tierA i64")
        assert_equal(Int(a_param.get(r)), Int(mi[r]), at + ": tierA parametric")
        assert_equal(Int(a_i32.get(r)), Int(mn[r]), at + ": tierA i32")
        assert_equal(a_bool.get(r), mb[r], at + ": tierA bool")
        assert_equal(a_str.get(r), ms[r], at + ": tierA str")
        # ⭐ BIT-EXACT, for the same reason the per-cell arm is: `-0.0 == 0.0`
        # is True, so `==` cannot see a read that dropped the sign. Row 3 of
        # the model is `-0.0`, and a whole-column read is MORE exposed to this
        # than a per-cell one -- a buffer-level copy is exactly where a sign
        # bit gets normalised away.
        assert_equal(
            Int(_f64_bits(a_f64.get(r))),
            Int(_f64_bits(mf[r])),
            at + ": tierA f64 (bit-exact)",
        )

    # ⭐ THE MONOMORPHIC float32 DELEGATION IS EXERCISED HERE, AND IT REFUSES.
    # The fixture has no float32 column, so asking for one over the FLOAT64
    # column must raise out of `Column.as_primitive`. That is deliberate
    # coverage rather than a gap: a delegation nobody calls is unexecuted code,
    # and this is the only call that reaches `column_as_primitive_float32`'s
    # body at n <= 1. It also pins that the refusal comes from the TYPE, not
    # from the chunk count -- the n > 1 arm above raises for the other reason.
    var r_f32_type = False
    try:
        _ = table.column_as_primitive_float32(C_F64)
    except:
        r_f32_type = True
    assert_true(
        r_f32_type, where + ": float32 over a float64 column must raise"
    )

    # ⛔ AND THE OUT-OF-RANGE COLUMN REFUSALS, which must come from the
    # delegate's own bounds check -- `Table` adds none of its own.
    var r_lo = False
    try:
        _ = table.column_as_primitive_int64(-1)
    except:
        r_lo = True
    assert_true(r_lo, where + ": tierA column -1 must raise")

    var r_hi = False
    try:
        _ = table.column_as_string(5)
    except:
        r_hi = True
    assert_true(r_hi, where + ": tierA column 5 must raise")

    return 0


def _assert_shape(table: Table, n_chunks: Int, where: String) raises:
    assert_equal(table.num_chunks(), n_chunks, where + ": num_chunks")
    _assert_tier0(table, where)
    _assert_every_cell(table, where)
    _assert_chunk_accessor(table, n_chunks, where)
    # ⭐ THE REFUSAL COUNT IS ASSERTED, NOT JUST THE REFUSALS. See
    # `_assert_tier_a`'s docstring: at n > 1 all seven Tier-A accessors must
    # refuse, and the count is what makes a DELETED assertion go red instead
    # of quietly reducing coverage.
    var fired = _assert_tier_a(table, n_chunks, where)
    if n_chunks > 1:
        assert_equal(
            fired,
            TIER_A_ACCESSORS,
            where + ": every Tier-A accessor must refuse at n>1",
        )
    else:
        assert_equal(fired, 0, where + ": no refusals expected at n<=1")


# --- the chunk counts ------------------------------------------------------


def test_n1_direct_hit() raises:
    """ONE CHUNK -- the arm every single-chunk result takes.

    `Table.from_batch` is the wrap `materialize_plan` performs on EVERY
    result, so this shape is the one whose answers must be free: `_locate`
    returns `(0, row)` without reading the prefix sum, which is also why the
    prefix sum is not built here at all (asserted in
    `test_prefix_sum_is_not_built_at_one_chunk`).
    """
    var t = Table.from_batch(_fixture_batch(0, N_ROWS))
    _assert_shape(t, 1, String("n=1"))


def test_n2_first_boundary() raises:
    """TWO CHUNKS -- the smallest search, and where a `(lo + hi) // 2` that
    should have been `(lo + hi + 1) // 2` fails first."""
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var t = rechunk(base, 4)
    assert_equal(t.num_chunks(), 2, "n=2: rechunk(4) shape")
    _assert_shape(t, 2, String("n=2"))


def test_n7_uneven() raises:
    """SEVEN CHUNKS at UNEVEN sizes (2,1,1,1,1,1,1).

    A uniform stride makes every `start[i]` a multiple of one number; an
    off-by-one prefix sum can still satisfy that pattern. Uneven sizes cannot
    be satisfied by any arithmetic progression.
    """
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var t = rechunk_sizes(base, _sizes(2, 1, 1, 1, 1, 1, 1))
    _assert_shape(t, 7, String("n=7 uneven"))


def test_n8_one_row_per_chunk() raises:
    """EIGHT CHUNKS, one row each, so `start[i] == i`.

    Any resolve that is off by one lands on the wrong chunk for EVERY row
    rather than for an edge case, which makes this the loudest shape.
    """
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var t = rechunk(base, 1)
    assert_equal(t.num_chunks(), N_ROWS, "n=8: rechunk(1) shape")
    _assert_shape(t, N_ROWS, String("n=8"))


def test_empty_chunks_interior_leading_and_trailing() raises:
    """⭐ THE STRONGEST SHAPE: (0,3,0,5,0) -- an empty chunk first, between,
    and last.

    An empty chunk makes `start[i] == start[i+1]`. A resolve written as "the
    FIRST i with row < start[i+1]" lands ON the empty chunk and then reads row
    0 of a 0-row column -- an out-of-range read on a buffer that is present,
    which is the quiet kind. `Table._locate` is written as "the LARGEST i with
    start[i] <= row", which steps past it. This case is what tells the two
    rules apart, and it is why the bound check has to come FIRST: it is what
    guarantees the chosen chunk is non-empty.
    """
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(3)
    sizes.append(0)
    sizes.append(5)
    sizes.append(0)
    var t = rechunk_sizes(base, sizes^)
    _assert_shape(t, 5, String("n=5 with empty chunks"))


def test_n0_empty_result_still_answers_tier0_and_refuses_every_cell() raises:
    """ZERO CHUNKS -- the EMPTY result.

    TIER 0 must still answer: "an empty result still has a schema", the
    property whose absence makes a downstream Project raise
    `Schema.column_index: no field named '<k>'`. Every per-cell read must
    RAISE, and that is also what makes `_locate`'s search unreachable at n == 0
    -- `_num_rows == 0`, so the bound check rejects every row before the
    search can read an empty `_chunk_starts`.
    """
    var t = Table.from_chunks(List[RecordBatch](), _fixture_schema())
    assert_equal(t.num_chunks(), 0, "n=0: num_chunks")
    assert_equal(t.num_rows(), 0, "n=0: num_rows")
    _assert_tier0(t, String("n=0"))

    var raised_zero = False
    try:
        _ = t.value_i64(C_I64, 0)
    except:
        raised_zero = True
    assert_true(raised_zero, "n=0: value_i64(0, 0) must raise")

    var raised_str = False
    try:
        _ = t.value_str(C_STR, 0)
    except:
        raised_str = True
    assert_true(raised_str, "n=0: value_str(4, 0) must raise")

    var raised_cv = False
    try:
        _ = t.column_value(C_I64, 0)
    except:
        raised_cv = True
    assert_true(raised_cv, "n=0: column_value(0, 0) must raise")

    # ⭐ TIER A ANSWERS AT n == 0 -- IT DOES NOT RAISE, AND THE ASYMMETRY WITH
    # THE PER-CELL ARM ABOVE IS DELIBERATE. A per-cell read at n == 0 names a
    # row that does not exist, so it must raise. A whole-COLUMN read names a
    # column that DOES exist -- the schema is authoritative and survives an
    # empty result -- so the honest answer is a 0-row typed
    # array, not an error. Getting this backwards would make an empty result
    # unreadable through the very surface added to read results with.
    var fired0 = _assert_tier_a(t, 0, String("n=0"))
    assert_equal(fired0, 0, "n=0: Tier A shares, it does not refuse")
    _assert_chunk_accessor(t, 0, String("n=0"))


# --- the invariants the accessors rest on ----------------------------------


def test_prefix_sum_is_not_built_at_one_chunk() raises:
    """⛔ THE ZERO-COST-WRAP INVARIANT, AS AN ASSERTION.

    `_chunk_starts` must be EMPTY at `num_chunks() <= 1` and exactly
    `num_chunks()` long above it. This is not a tuning preference: a
    one-element `List[Int]` is a heap allocation, and `Table.from_batch` is on
    the path of EVERY single-chunk result (`materialize_plan` is
    wrap-only). Building a prefix sum there would put a fresh malloc on every
    result to serve a search the n == 1 arm never performs.

    ⚠ THIS TEST READS A PRIVATE FIELD ON PURPOSE. The invariant is not
    observable through the public surface -- a table answers identically
    whether or not the list exists -- so the only way to keep it from being
    "simplified" into an unconditional build is to assert it directly.
    """
    var one = Table.from_batch(_fixture_batch(0, N_ROWS))
    assert_equal(len(one._chunk_starts), 0, "from_batch must not allocate one")
    assert_equal(one.num_chunks(), 1, "from_batch is one chunk")

    var empty = Table.from_chunks(List[RecordBatch](), _fixture_schema())
    assert_equal(len(empty._chunk_starts), 0, "n=0 has no prefix sum")

    var single = List[RecordBatch]()
    single.append(_fixture_batch(0, N_ROWS))
    var one_via_chunks = Table.from_chunks(single^, _fixture_schema())
    assert_equal(
        len(one_via_chunks._chunk_starts),
        0,
        "from_chunks at n=1 must not allocate one either",
    )

    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var many = rechunk(base, 1)
    assert_equal(len(many._chunk_starts), N_ROWS, "n=8 prefix sum length")
    assert_equal(many._chunk_starts[0], 0, "prefix sum starts at 0")
    for i in range(N_ROWS):
        assert_equal(
            many._chunk_starts[i], i, "n=8 prefix sum entry " + String(i)
        )


def test_take_chunks_clears_the_prefix_sum() raises:
    """`take_chunks` leaves the table observable, so it must leave it
    CONSISTENT -- a populated prefix sum beside zero chunks breaks the
    "non-empty IFF num_chunks() > 1" invariant `_locate` reads."""
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))
    var t = rechunk(base, 2)
    assert_equal(len(t._chunk_starts), 4, "n=4 prefix sum before take")
    var got = t.take_chunks()
    assert_equal(len(got), 4, "take_chunks returns the segments")
    assert_equal(t.num_chunks(), 0, "table is empty after take")
    assert_equal(t.num_rows(), 0, "row count is zeroed after take")
    assert_equal(len(t._chunk_starts), 0, "prefix sum is cleared after take")

    # And the table is still USABLE: Tier 0 answers off the surviving schema.
    _assert_tier0(t, String("after take_chunks"))


def test_rechunk_preserves_the_chunk_row_counts_it_was_asked_for() raises:
    """The harness's own falsifier. If `rechunk_sizes` silently produced a
    different shape than requested, every "n == k" test above would be testing
    some other k and still pass."""
    var base = Table.from_batch(_fixture_batch(0, N_ROWS))

    var t7 = rechunk_sizes(base, _sizes(2, 1, 1, 1, 1, 1, 1))
    assert_equal(t7.num_chunks(), 7, "rechunk_sizes: 7 chunks")
    assert_equal(t7.chunks()[0].num_rows(), 2, "chunk 0 holds 2 rows")
    for i in range(1, 7):
        assert_equal(
            t7.chunks()[i].num_rows(), 1, "chunk " + String(i) + " holds 1 row"
        )
    assert_equal(t7.num_rows(), N_ROWS, "rows are conserved")

    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(3)
    sizes.append(0)
    sizes.append(5)
    sizes.append(0)
    var t5 = rechunk_sizes(base, sizes^)
    assert_equal(t5.num_chunks(), 5, "rechunk_sizes: 5 chunks")
    assert_equal(t5.chunks()[0].num_rows(), 0, "leading chunk is empty")
    assert_equal(t5.chunks()[2].num_rows(), 0, "interior chunk is empty")
    assert_equal(t5.chunks()[4].num_rows(), 0, "trailing chunk is empty")
    assert_equal(t5.num_rows(), N_ROWS, "rows are conserved across empties")

    # A size vector that does NOT sum to the row count must be refused, or the
    # harness could silently drop rows and every assertion above would be over
    # a shorter table.
    var bad = List[Int]()
    bad.append(3)
    bad.append(3)
    var raised = False
    try:
        _ = rechunk_sizes(base, bad^)
    except:
        raised = True
    assert_true(raised, "rechunk_sizes must refuse a short size vector")


def main() raises:
    test_n1_direct_hit()
    test_n2_first_boundary()
    test_n7_uneven()
    test_n8_one_row_per_chunk()
    test_empty_chunks_interior_leading_and_trailing()
    test_n0_empty_result_still_answers_tier0_and_refuses_every_cell()
    test_prefix_sum_is_not_built_at_one_chunk()
    test_take_chunks_clears_the_prefix_sum()
    test_rechunk_preserves_the_chunk_row_counts_it_was_asked_for()
    print("test_arrow_table_accessors: OK")
