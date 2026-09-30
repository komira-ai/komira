# =============================================================================
# BYTE-EQUIVALENCE ORACLE — `InMemorySource.structural_id()` memo
# (always on; reference fold = `structural_id(memo=False)`)
# =============================================================================
#
# WHAT THE MEMO DOES. `InMemorySource.structural_id()` folds
# `RecordBatch.content_hash` over the RAW BYTES of every backing buffer of
# every batch — an O(total bytes) scan — and it is called once per plan
# RENDER, because `plan_display` emits `inmem_id=<structural_id()>` and
# `LogicalPlan.structural_hash()` renders the whole plan to text. Without a
# memo, a plan hashed N times rescans the same immutable bytes N times.
# The memo caches the fold in a `_StructuralIdMemo` cell held behind an
# `ArcPointer` that `.copy()` shares.
#
# HOW THIS ORACLE REACHES THE REFERENCE ARM. `structural_id(memo=False)` — a
# plain defaulted parameter on the production method, not a global switch.
# Production passes nothing anywhere, so every call site takes the memo. The
# parameter is checked BEFORE the memo cell is touched, which is itself
# asserted below.
#
# WHERE IT PAYS: only plans that re-fold the same source benefit (for
# example, a query whose optimizer hashes the same in-memory leaf several
# times); a plan that folds each source once gets all misses.
#
# WHAT COULD GO WRONG (the two directions this oracle guards):
#   (A) VALUE DRIFT — the memoized value differs from the unmemoized fold, so
#       a plan hashes differently depending on the arm taken. Every
#       test below compares `structural_id()` against the reference
#       `_structural_id_compute()` (the unmemoized fold).
#   (B) IDENTITY BLEED — the shared-Arc memo leaks a value between sources
#       with DIFFERENT content. Two distinct in-mem tables that hash equal get
#       CSE'd into a self-join and OVER-PRODUCE rows. `test_memo_*
#       discriminates*` builds five pairwise-distinct sources (different
#       values / field names / row counts / null patterns / batch counts) and
#       asserts all ten ids are pairwise distinct under the memo.
#   And the contract's other half, which a naive "memo keyed on the per-ctor
#   identity" fix would break: two SEPARATELY-constructed sources over
#   IDENTICAL content MUST still hash EQUAL (subquery dedup + the Layer-1
#   plan-compile factory cache depend on it) — `test_memo_equal_content_*`.
#
# HOW TO CONFIRM THIS ORACLE CAN FAIL: flipping the memo-hit branch in
# `structural_id()` to `return self._sid_memo[].value + 1` turns tests
# 2/3/4/6 RED; making the ctor share ONE process-global memo cell turns
# test 5 RED.
#
# NOTE ON SCOPE: the arm is chosen per-CALL by the `memo` argument, so suite
# ordering cannot leak an arm between tests.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.collections.slab import Slab
from komira_core.source.in_memory_source import InMemorySource


# =============================================================================
# Fixture builders — the dtype zoo the content hash actually walks:
# fixed-width values, a validity bitmap, a var-width offsets buffer, multiple
# batches, and a zero-row batch.
# =============================================================================


def _schema_i64_str_nullable(c0: String, c1: String, c2: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, nullable=False))
    sb.add_field(Field(c1, ArrowType.STRING, nullable=False))
    sb.add_field(Field(c2, ArrowType.INT64, nullable=True))
    return sb.build()


def _batch_zoo(
    num_rows: Int,
    seed: Int,
    c0: String,
    c1: String,
    c2: String,
    null_stride: Int,
) raises -> RecordBatch:
    """One batch carrying (a) a fixed-width values buffer, (b) a var-width
    string column (values + OFFSETS buffer), and (c) a nullable int64 column
    (values + VALIDITY bitmap) — so `Column.content_hash` folds every buffer
    kind it knows about."""
    var v_arr = PrimitiveArray[DType.int64].allocate(num_rows)
    var n_arr = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
    var vp = v_arr._typed_ptr_mut()
    var np = n_arr._typed_ptr_mut()
    var strs = List[String]()
    var nulls = 0
    for i in range(num_rows):
        (vp + i)[] = Int64(seed + i)
        (np + i)[] = Int64(seed * 3 + i)
        strs.append(String("s_") + String(seed + i))
        if null_stride > 0 and (i % null_stride) == 1:
            ref vb = n_arr.validity.value()
            vb.clear(i)
            nulls += 1
    n_arr.null_count = nulls
    var s_arr = StringArray.from_strings(strs)

    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](v_arr^))
    b.add_column(Column.from_string(s_arr))
    b.add_column(Column.from_primitive[DType.int64](n_arr^))
    return b.build(_schema_i64_str_nullable(c0, c1, c2))


def _source_zoo(
    num_rows: Int,
    seed: Int,
    c0: String = String("v"),
    c1: String = String("s"),
    c2: String = String("n"),
    null_stride: Int = 5,
    num_batches: Int = 1,
) raises -> InMemorySource:
    var sl = Slab[RecordBatch].create(num_batches)
    for b in range(num_batches):
        sl.append(
            _batch_zoo(num_rows, seed + b * 100, c0, c1, c2, null_stride)
        )
    return InMemorySource.from_record_batches(sl^)


def _source_zero_row() raises -> InMemorySource:
    var sl = Slab[RecordBatch].create(1)
    sl.append(_batch_zoo(0, 7, String("v"), String("s"), String("n"), 0))
    return InMemorySource.from_record_batches(sl^)


# =============================================================================
# 0. THE DEFAULT GUARD. A plain `structural_id()` — no argument, which is what
#    every production call site writes — MUST fire the memo.
# =============================================================================


def test_memo_fires_on_the_default_call() raises:
    """THE DEFAULT CONTRACT. On the bare `structural_id()` call — the shipped
    configuration every caller runs — the FIRST
    call must FILL the memo cell, and the value must equal the reference fold.

    If the memo were opt-in, the cell would stay cold and
    `_sid_memo_is_computed()` would return False here. It is the only
    test in this file that asserts on the ARGUMENT-FREE call rather than on an
    explicitly-selected arm, so it is the one that fails if the default is ever
    silently reverted — including by someone flipping the `memo` parameter's
    default to False.

    Both directions are asserted so the test cannot pass vacuously: the memo
    fills (behavior changed) AND the value is byte-identical to the fold
    (behavior is still correct)."""
    var src = _source_zoo(64, 11, num_batches=2)
    var reference = src._structural_id_compute()
    assert_false(src._sid_memo_is_computed(), "memo cell must start cold")

    var first = src.structural_id()
    assert_equal(
        first, reference, "default cold id must equal the reference fold"
    )
    assert_true(
        src._sid_memo_is_computed(),
        "the ARGUMENT-FREE call MUST fill the memo cell — the memo is on by"
        " default",
    )
    for _ in range(3):
        assert_equal(
            src.structural_id(),
            src._structural_id_compute(),
            "default hot id must equal a fresh reference fold",
        )


# =============================================================================
# 1. `memo=False` -> the unmemoized fold; the memo cell is never touched.
# =============================================================================


def test_memo_false_is_verbatim_and_cell_stays_cold() raises:
    """REFERENCE-ARM contract: `structural_id(memo=False)` returns exactly what
    `_structural_id_compute()` returns AND the memo cell is never written —
    i.e. the parameter is checked BEFORE the only side-effecting op in the
    method.

    FAILS if the parameter is checked after the memo write (the cell would read
    computed=True), or if the reference path stops returning the reference
    fold."""
    var src = _source_zoo(64, 11)
    var reference = src._structural_id_compute()

    assert_false(
        src._sid_memo_is_computed(), "memo cell must start cold"
    )
    for _ in range(3):
        assert_equal(
            src.structural_id(memo=False),
            reference,
            "memo=False structural_id must equal the reference fold",
        )
        assert_false(
            src._sid_memo_is_computed(),
            "memo=False must NOT write the memo cell (the parameter is"
            " checked before the first side-effecting op)",
        )


# =============================================================================
# 2. Default arm -> byte-exact vs the reference fold, across the dtype zoo.
# =============================================================================


def test_memo_byte_exact_across_dtype_zoo() raises:
    """(A) VALUE DRIFT guard. For every fixture shape, the memoized id must
    equal the unmemoized fold — both on the first (cold) call and on every
    later (hot) call.

    FAILS if the memo returns anything other than the value the fold produced
    (e.g. a stale / off-by-one / uninitialized cell)."""
    var srcs = List[InMemorySource]()
    srcs.append(_source_zoo(1, 3))                      # single row
    srcs.append(_source_zoo(64, 11))                    # nulls + strings
    srcs.append(_source_zoo(64, 11, null_stride=0))     # no nulls
    srcs.append(_source_zoo(37, 5, num_batches=3))      # multi-batch
    srcs.append(_source_zero_row())                     # zero-row batch

    for i in range(len(srcs)):
        ref s = srcs[i]
        var reference = s._structural_id_compute()
        var cold = s.structural_id()
        assert_equal(
            cold, reference, "cold memoized id must equal the reference fold"
        )
        assert_true(
            s._sid_memo_is_computed(),
            "the default arm must fill the memo cell on the first call",
        )
        # Hot path: repeated calls must be stable AND still equal to a FRESH
        # recomputation of the reference (which re-reads the actual bytes).
        for _ in range(4):
            assert_equal(
                s.structural_id(),
                s._structural_id_compute(),
                "hot memoized id must equal a fresh reference fold",
            )


# =============================================================================
# 3. Default arm -> `.copy()` shares the filled cell and agrees on the value.
# =============================================================================


def test_memo_shared_through_copy() raises:
    """A `.copy()` shares the `data` Arc, so it MUST report the same
    structural id — and it should inherit the already-filled memo (that
    sharing is the whole point: the optimizer clones plan trees between
    hashes).

    FAILS if `copy()` forgets to forward the memo Arc (the copy's cell would
    be cold), or if the shared cell hands the copy a value that disagrees with
    the copy's own reference fold."""
    var src = _source_zoo(48, 21, num_batches=2)
    var original = src.structural_id()
    assert_true(src._sid_memo_is_computed())

    var clone = src.copy()
    assert_true(
        clone._sid_memo_is_computed(),
        "copy() must forward the filled memo Arc (refcount bump)",
    )
    assert_equal(
        clone.structural_id(),
        original,
        "a copy shares `data`, so it must report the same structural id",
    )
    assert_equal(
        clone.structural_id(),
        clone._structural_id_compute(),
        "the shared memo value must equal the copy's own reference fold",
    )
    # And a copy taken BEFORE any structural_id call must agree too.
    var src2 = _source_zoo(48, 21, num_batches=2)
    var clone2 = src2.copy()
    assert_equal(clone2.structural_id(), src2.structural_id())
    assert_equal(clone2.structural_id(), clone2._structural_id_compute())


# =============================================================================
# 4. Default arm -> equal content still hashes EQUAL across distinct ctors.
# =============================================================================


def test_memo_equal_content_distinct_sources_hash_equal() raises:
    """The contract half a per-ctor-keyed memo would break: two SEPARATELY
    constructed sources over byte-identical content must hash EQUAL, so the
    subquery dedup cache + the Layer-1 plan-compile factory cache still fire.

    FAILS if the memo is keyed on (or folds in) the per-ctor `_identity`."""
    var a = _source_zoo(64, 11)
    var b = _source_zoo(64, 11)
    assert_not_equal(
        a.fingerprint(),
        b.fingerprint(),
        "two ctors must still have DISTINCT per-ctor identities",
    )
    assert_equal(
        a.structural_id(),
        b.structural_id(),
        "identical content must hash EQUAL under the memo",
    )
    assert_equal(a.structural_id(), a._structural_id_compute())
    assert_equal(b.structural_id(), b._structural_id_compute())


# =============================================================================
# 5. Default arm -> DIFFERENT content still hashes DIFFERENTLY (identity bleed).
# =============================================================================


def test_memo_still_discriminates_distinct_content() raises:
    """(B) IDENTITY-BLEED guard — the direction a shared-Arc memo can break,
    and the one with a real correctness consequence: if two distinct in-mem
    tables hash equal, plan CSE merges them into a SELF-JOIN and
    over-produces rows.

    Five pairwise-distinct sources — differing by VALUES, by FIELD NAMES (the
    `left_val`/`right_val` case), by ROW COUNT, by NULL
    PATTERN, and by BATCH COUNT. All ten pairs must differ.

    FAILS RED if the memo cell is shared across sources that do not share
    `data` (e.g. a process-global cell, or a cell forwarded by a ctor that is
    not `copy()`)."""
    var srcs = List[InMemorySource]()
    srcs.append(_source_zoo(64, 11))                                   # base
    srcs.append(_source_zoo(64, 12))                                   # values
    srcs.append(
        _source_zoo(64, 11, c0=String("left_val"), c1=String("s"),
                    c2=String("n"))
    )                                                                  # names
    srcs.append(_source_zoo(63, 11))                                   # rows
    srcs.append(_source_zoo(64, 11, null_stride=3))                    # nulls
    srcs.append(_source_zoo(64, 11, num_batches=2))                    # batches

    var ids = List[UInt64]()
    for i in range(len(srcs)):
        ref s = srcs[i]
        var v = s.structural_id()
        assert_equal(
            v,
            s._structural_id_compute(),
            "each distinct source's memoized id must equal its own fold",
        )
        ids.append(v)

    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            assert_not_equal(
                ids[i],
                ids[j],
                "distinct in-memory content MUST hash apart under the memo"
                " (identity bleed would CSE two tables into a self-join)",
            )


# =============================================================================
# 6. Default arm then `memo=False` on the SAME source -> the two arms agree.
# =============================================================================


def test_memo_true_then_false_agree_on_same_source() raises:
    """Cross-arm equivalence on one source: prime the memo with the default
    call, then ask the SAME source for `memo=False`. The reference arm
    recomputes from the bytes; it must produce the identical value.

    The two arms are interleaved on one live source with the cell ALREADY
    filled, so a memo that stored a wrong value cannot be hidden by the second
    arm re-priming it.

    FAILS if the memo ever stored something the fold would not produce."""
    var src = _source_zoo(64, 11, num_batches=2)
    var hot = src.structural_id()
    assert_true(src._sid_memo_is_computed())

    assert_equal(
        src.structural_id(memo=False),
        hot,
        "the unmemoized arm must reproduce the memoized value exactly",
    )
    assert_true(
        src._sid_memo_is_computed(),
        "memo=False must not CLEAR an already-filled cell either",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
