# =============================================================================
# test_expr_walk_unification — the duplicate-`Expr`-walker defect class, pinned
# =============================================================================
#
# ⛔ WHAT THIS TEST IS FOR, AND WHAT IT IS NOT FOR.
#
# It is NOT primarily a correctness test. A test that only checks `NOT x`
# exports correctly passes forever while the NEXT tag goes unarmed — which is
# exactly how this defect class recurs:
#
#   EXPR_WHEN        projection pushdown pruned a column used only inside
#                    `when_then_else` (TPC-H Q8)
#   EXPR_STRING_OP   string-only predicates had no descent arm, so the scan
#                    dropped the column (TPC-H q2 q9 q13 q16 q20)
#   EXPR_STRING_FN   `WHERE upper(v)='C'` decoded a ZERO-column batch and
#   + EXPR_WHEN      raised; CASE projections exported as Arrow type `null`
#
# WHAT MUST GO RED IS DRIFT: a walk gaining an arm in one place and not the
# other. Post-unification there is ONE walk of each kind
# (`plan/expr_walk.mojo`), so "the other place" now means one of three things,
# and this file pins all three:
#
#   (1) THE TWO NAME-SINK ADAPTERS. `compiler_helpers.collect_expr_cols`
#       (ordered `List`) and `plan_helpers._collect_expr_columns` (deduped
#       `Set`) must see the SAME names for EVERY tag. If either re-grows a
#       private ladder — the shape behind every one of those — they
#       diverge and `test_both_name_sinks_agree_on_every_tag` goes red.
#   (2) THE TWO FIELD-INFERENCE ADAPTERS. `compiler_helpers.field_for_expr`
#       and `logical_plan._infer_expr_field` must infer the SAME arrow_type
#       for every tag, and differ ONLY where they are documented to differ
#       (a missing column: raise vs placeholder). Both halves are pinned.
#   (3) THE TAG UNIVERSE ITSELF. The corpus is DERIVED, not hand-listed:
#       `_corpus_expr` is a ladder over `[0, EXPR_TAG_COUNT)` whose fallthrough
#       RAISES BY NAME, so adding tag 26 to `expr.mojo` fails this file until
#       someone supplies a corpus expression for it. A hand-written tag list
#       here would be the same defect one level up — it goes stale exactly
#       when a new tag lands.
#
# ⭐ THE `range(EXPR_TAG_COUNT)` + NAMED-REFUSAL SHAPE IS THE ESTABLISHED
# IDIOM FOR TAG-UNIVERSE TESTS. ⚠ It is
# adapted here in one way that matters: those walkers inspect only `.tag`, so
# a bare `Expr(UInt8(t))` with no payload is a valid probe for them. THESE
# walks DEREFERENCE PAYLOAD (`expr._when.value()`, `binary_left_ref()`), so a
# bare tag would be a null-payload crash, not an answer. The corpus therefore
# supplies a payload-BEARING expression per tag — same derivation, real input.
#
# A static check pins the arm sets, the adapters' emptiness and the
# cross-ladder typed-null ledger; this file is its runtime twin: the static
# check proves the arms EXIST, this proves they AGREE.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)
from std.collections import Set, Optional

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.partition_expr import (
    PartitionFrame,
    PF_ROW_NUMBER,
    FRAME_UNITS_ROWS,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
)
from komira_core.plan.logical_plan import (
    CORR_KIND_EXISTS,
    LogicalPlan,
    SOURCE_PARQUET,
    _infer_expr_field,
)
from komira_core.plan.agg_expr import AGG_SUM
from komira_core.plan.expr import (
    Expr,
    WhenCaseData,
    EXPR_TAG_COUNT,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    EXPR_JSON_EXTRACT,
    EXPR_EXTRACT,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    BIN_ADD,
    BIN_GT,
    UN_NOT,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
    STR_LIKE,
    REGEXP_LIKE,
    EXTRACT_YEAR,
    EXTRACT_TRUNC_MONTH,
)
from komira_core.helpers.compiler_helpers import (
    collect_expr_cols,
    dedupe_names,
    field_for_expr,
)
from komira_core.plan.plan_helpers import _collect_expr_columns


# ===========================================================================
# Fixtures.
# ===========================================================================


def _schema() raises -> Schema:
    """Every column any corpus expression references.

    ⚠ ALL OF THEM MUST BE HERE. `field_for_expr` resolves a column reference
    through `RaiseOnMissingColumn`, so a corpus expression naming a column
    this schema lacks would raise and mask the invariant under test. The
    missing-column behaviour has its own dedicated test below; it must not
    leak into the others.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    sb.add_field(Field(String("b"), ArrowType.INT64, True))
    sb.add_field(Field(String("c"), ArrowType.INT64, True))
    sb.add_field(Field(String("d"), ArrowType.INT64, True))
    sb.add_field(Field(String("t"), ArrowType.INT64, True))
    sb.add_field(Field(String("w"), ArrowType.INT64, True))
    sb.add_field(Field(String("o"), ArrowType.INT64, True))
    sb.add_field(Field(String("flag"), ArrowType.BOOL, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    sb.add_field(Field(String("j"), ArrowType.STRING, True))
    sb.add_field(Field(String("st"), ArrowType.INT64, True))
    sb.add_field(Field(String("m"), ArrowType.INT64, True))
    return sb.build()


def _inner_plan() raises -> LogicalPlan:
    """A minimal subquery body for the EXPR_CORRELATED_SUBQUERY corpus entry.
    Its SHAPE is irrelevant — the walks read `outer_refs`, never the plan."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    return LogicalPlan.scan(String("inner.parquet"), SOURCE_PARQUET, sb.build())


def _corpus_expr(t: Int) raises -> Expr:
    """A payload-BEARING expression whose root tag is `t`.

    ⛔ THE FALLTHROUGH RAISES BY NAME, AND THAT IS THE POINT. This ladder is
    what makes the corpus DERIVED rather than hand-listed: every test below
    iterates `[0, EXPR_TAG_COUNT)` and asks for an expression, so a new tag
    added to `expr.mojo` turns this file RED until someone supplies one and,
    in supplying it, has to decide what the walks should do with it.

    A hand-written list of "the tags we test" would go stale on exactly the
    commit that introduces the next unarmed tag — the defect this whole
    change exists to delete, reproduced in the test that is supposed to
    catch it.
    """
    var tag = UInt8(t)
    if tag == EXPR_COL_REF:
        return Expr.col_ref("a")
    elif tag == EXPR_COL_IDX:
        # A column by INDEX — no NAME to collect. A true leaf for the name
        # walk, which is why it is in the stated unwalked set.
        return Expr.col_idx(0)
    elif tag == EXPR_LITERAL:
        return Expr.literal(ScalarValue.from_int(7))
    elif tag == EXPR_BINARY_OP:
        return Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    elif tag == EXPR_UNARY_OP:
        return Expr.unary(UN_NOT, Expr.col_ref("flag"))
    elif tag == EXPR_CAST:
        return Expr.cast(Expr.col_ref("a"), DType.float64)
    elif tag == EXPR_ALIAS:
        return Expr.alias(Expr.col_ref("a"), "aliased")
    elif tag == EXPR_STRING_OP:
        return Expr.string_op(STR_LIKE, Expr.col_ref("s"), "p%")
    elif tag == EXPR_WHEN:
        # THE TPC-H Q8 SHAPE: a column reachable ONLY through a CASE
        # branch. Three DISTINCT columns across condition / result / default
        # so a partially-armed WHEN cannot pass by accident.
        var cases = List[WhenCaseData]()
        cases.append(
            WhenCaseData(
                Expr.binary(
                    BIN_GT,
                    Expr.col_ref("c"),
                    Expr.literal(ScalarValue.from_int(0)),
                ),
                Expr.col_ref("t"),
            )
        )
        return Expr.when(cases^, Expr.col_ref("d"))
    elif tag == EXPR_IN_LIST:
        # `in_list_node`, NOT `in_list`: the latter folds a small list to an
        # OR-of-EQ tree at the factory and would probe EXPR_BINARY_OP instead.
        var vals = List[ScalarValue]()
        vals.append(ScalarValue.from_int(1))
        vals.append(ScalarValue.from_int(2))
        return Expr.in_list_node(Expr.col_ref("a"), vals^)
    elif tag == EXPR_BETWEEN:
        # Carries no payload struct in this IR — a bare tag IS the whole node.
        return Expr(EXPR_BETWEEN)
    elif tag == EXPR_SORT_KEY:
        return Expr(EXPR_SORT_KEY)
    elif tag == EXPR_AGG_FN:
        return Expr.agg_fn(AGG_SUM, Expr.col_ref("a"))
    elif tag == EXPR_WINDOW_FN:
        # ⚠ THE CHILDREN ARE COLUMN NAMES, NOT Exprs — `arg_col` plus the
        # OVER-clause lists. All three channels carry a DISTINCT column here
        # so an arm that reads only `arg_col` cannot pass.
        var frame = PartitionFrame(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING,
            Int64(0),
            FRAME_BOUND_CURRENT_ROW,
            Int64(0),
        )
        var pb = List[String]()
        pb.append(String("b"))
        var ob = List[String]()
        ob.append(String("c"))
        var desc = List[Bool]()
        desc.append(False)
        return Expr.window_fn(PF_ROW_NUMBER, String("w"), 0, frame^).over(
            pb^, ob^, desc^
        )
    elif tag == EXPR_CORRELATED_SUBQUERY:
        var refs = List[String]()
        refs.append(String("o"))
        return Expr.correlated_subquery(_inner_plan(), refs^, CORR_KIND_EXISTS)
    elif tag == EXPR_REGEXP:
        return Expr.regexp(REGEXP_LIKE, Expr.col_ref("s"), "p")
    elif tag == EXPR_STRUCT_FIELD:
        return Expr.struct_field(Expr.col_ref("st"), "f")
    elif tag == EXPR_STRUCT_FIELD_IDX:
        return Expr.struct_field_idx(Expr.col_ref("st"), 0)
    elif tag == EXPR_MAP_GET:
        return Expr.map_get(
            Expr.col_ref("m"), Expr.literal(ScalarValue.from_string("k"))
        )
    elif tag == EXPR_JSON_EXTRACT:
        return Expr.json_extract_string(Expr.col_ref("j"), "$.a")
    elif tag == EXPR_EXTRACT:
        return Expr.extract(EXTRACT_YEAR, Expr.col_ref("d"))
    elif tag == EXPR_MATH_FN:
        return Expr.sqrt(Expr.col_ref("a"))
    elif tag == EXPR_MATH_FN2:
        return Expr.atan2(Expr.col_ref("a"), Expr.col_ref("b"))
    elif tag == EXPR_SUBSTRING:
        return Expr.substring(Expr.col_ref("s"), 1, 2)
    elif tag == EXPR_STRING_FN:
        # THE zero-column-decode SHAPE: `upper(s)`.
        return Expr.upper(Expr.col_ref("s"))
    elif tag == EXPR_STRING_FN_N:
        # `concat(s, t)`.
        #
        # ⚠ TWO DIFFERENT COLUMN NAMES, AND THREE ARGUMENTS RATHER THAN THE
        # MINIMUM. A one-argument `concat(s)` is a legal node (the arity floor
        # is 1) and would pass a walk that only ever reads `args[0]` — which
        # is precisely the fixed-arity mistake a variadic tag invites. Three
        # distinct names make an under-collecting walk visible in the count.
        var cargs = List[Expr]()
        cargs.append(Expr.col_ref("s"))
        cargs.append(Expr.col_ref("t"))
        cargs.append(Expr.col_ref("u"))
        return Expr.concat(cargs^)
    elif tag == EXPR_UDF_CALL:
        return Expr.udf_call(
            String("f"),
            Optional[Int](None),
            ArrowType.INT64,
            ArrowType.INT64,
            Expr.col_ref("a"),
        )
    raise Error(
        "EXPR_WALK_CORPUS_MISSING_TAG: no corpus expression for tag "
        + String(t)
        + ". A new EXPR_* tag landed in expr.mojo and nothing in"
        " test_expr_walk_unification.mojo exercises it. Add one to"
        " `_corpus_expr` and, in doing so, decide what each walk should do"
        " with the tag -- that decision is the whole point of this refusal."
    )


def _ordered_names(expr: Expr) raises -> List[String]:
    var out = List[String]()
    collect_expr_cols(expr, out)
    return out^


def _unique_names(expr: Expr) raises -> Set[String]:
    var cols = Set[String]()
    _collect_expr_columns(expr, cols)
    return cols^


def _joined(names: List[String]) -> String:
    var s = String("")
    for i in range(len(names)):
        if i > 0:
            s += ","
        s += names[i]
    return s^


# ===========================================================================
# (3) THE CORPUS ITSELF IS DERIVED — the refusal must be live.
# ===========================================================================


def test_every_expr_tag_has_a_corpus_expression() raises:
    """EVERY tag in `[0, EXPR_TAG_COUNT)` must be constructible here.

    Goes red the moment tag 26 is added to `expr.mojo` with no corpus entry,
    which is what stops the tag list in this file from going stale exactly
    when a new tag lands."""
    for t in range(EXPR_TAG_COUNT):
        var e = _corpus_expr(t)
        assert_equal(
            Int(e.tag),
            t,
            "corpus expression for tag "
            + String(t)
            + " has root tag "
            + String(Int(e.tag))
            + " -- it probes a DIFFERENT arm than the one it claims to",
        )
        _ = e^


def test_corpus_refuses_an_unmodelled_tag() raises:
    """THE REFUSAL ARM IS LIVE.

    Without this, the exhaustiveness test above could pass against a corpus
    whose fallthrough silently returned a bare `Expr(tag)` — i.e. against the
    fail-open shape this file exists to replace. `EXPR_TAG_COUNT` is by
    construction one past the last real tag."""
    with assert_raises(contains="EXPR_WALK_CORPUS_MISSING_TAG"):
        _ = _corpus_expr(EXPR_TAG_COUNT)


# ===========================================================================
# (1) THE TWO NAME-SINK ADAPTERS AGREE — the primary drift falsifier.
# ===========================================================================


def test_both_name_sinks_agree_on_every_tag() raises:
    """★ THE PRIMARY FALSIFIER. The ORDERED adapter and the UNIQUE adapter
    must see the SAME set of column names, for EVERY tag.

    Two independent `if/elif` ladders made this assertion FALSE for
    `EXPR_WHEN`, `EXPR_STRING_OP` and `EXPR_STRING_FN` in turn — each time
    silently, each time until production. They are two sinks over ONE walk,
    so it holds by construction; this test is what makes re-growing a
    private ladder in either adapter RED at development time rather than in
    a parquet decode.
    """
    for t in range(EXPR_TAG_COUNT):
        var e = _corpus_expr(t)
        var ordered = _ordered_names(e)
        var unique = _unique_names(e)
        var deduped = dedupe_names(ordered.copy())
        assert_equal(
            len(deduped),
            len(unique),
            "tag "
            + String(t)
            + ": the ordered sink found ["
            + _joined(ordered)
            + "] ("
            + String(len(deduped))
            + " distinct) and the unique sink found "
            + String(len(unique))
            + " -- the two adapters have DRIFTED, which is the defect class"
            " this file exists for",
        )
        for i in range(len(deduped)):
            assert_true(
                deduped[i] in unique,
                "tag "
                + String(t)
                + ": '"
                + deduped[i]
                + "' was found by the ordered sink and NOT by the unique"
                " sink -- the adapters have drifted",
            )
        _ = e^


def test_known_unarmed_shapes_collect_their_column() raises:
    """The three shapes that lose a column when an arm is missing, by name.

    Regression-locks the specific arms, so a refactor that keeps the two
    sinks AGREEING but drops an arm from BOTH — the one failure the
    agreement test above cannot see — still goes red."""
    # TPC-H Q8: a column reachable only inside a CASE branch.
    var when_cols = _unique_names(_corpus_expr(Int(EXPR_WHEN)))
    assert_true("c" in when_cols, "EXPR_WHEN must collect the CONDITION's col")
    assert_true("t" in when_cols, "EXPR_WHEN must collect the RESULT's col")
    assert_true("d" in when_cols, "EXPR_WHEN must collect the DEFAULT's col")

    # TPC-H string predicates: `col.like(...)` with no descent arm.
    var strop_cols = _unique_names(_corpus_expr(Int(EXPR_STRING_OP)))
    assert_true(
        "s" in strop_cols,
        "EXPR_STRING_OP must collect its child's column -- its absence"
        " dropped p_name/p_type/o_comment/s_comment from five scans",
    )

    # `WHERE upper(v) = 'C'` decoding a zero-column batch.
    var strfn_cols = _unique_names(_corpus_expr(Int(EXPR_STRING_FN)))
    assert_true(
        "s" in strfn_cols,
        "EXPR_STRING_FN must collect its child's column -- its absence made"
        " the late-mat route decode a ZERO-column batch",
    )


def test_window_fn_collects_all_three_name_channels() raises:
    """`EXPR_WINDOW_FN` carries column NAMES, not child Exprs, in THREE
    separate channels. An arm that reads only `arg_col` passes a one-column
    test and still drops the OVER-clause columns from the scan."""
    var cols = _unique_names(_corpus_expr(Int(EXPR_WINDOW_FN)))
    assert_true("w" in cols, "arg_col must reach the scan")
    assert_true("b" in cols, "partition_by must reach the scan")
    assert_true("c" in cols, "order_by must reach the scan")


# ===========================================================================
# (2) THE LATE-MAT COLUMN ORDER — its own assertion, deliberately.
# ===========================================================================


def test_late_mat_column_order_is_first_seen_left_to_right() raises:
    """⛔ THE ORDER IS THE WHOLE REASON THE TWO COPIES EXISTED, AND AN ORDER
    REGRESSION HERE IS A SILENT WRONG ANSWER, NOT A CRASH.

    `ParquetMultiConsumerSource.next_morsel` and
    `streaming_late_mat.compute_late_materialization` decode EXACTLY the
    names `collect_expr_cols` returns, IN THIS ORDER, and then evaluate the
    decode filter over the resulting batch. Reorder them and downstream
    positional indexing reads the wrong column — no exception, just different
    numbers.

    This assertion is deliberately SEPARATE from the set-equality test above:
    the set test would pass on a reordered walk. It pins the SEQUENCE.
    """
    # ((a + b) > c) AND (d + a) -- a deliberately asymmetric tree whose
    # left-to-right, depth-first reading is unambiguous, with `a` repeated so
    # a set-based implementation cannot satisfy it.
    var left = Expr.binary(
        BIN_GT,
        Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")),
        Expr.col_ref("c"),
    )
    var right = Expr.binary(BIN_ADD, Expr.col_ref("d"), Expr.col_ref("a"))
    var e = Expr.binary(BIN_ADD, left^, right^)

    var names = _ordered_names(e)
    assert_equal(
        _joined(names),
        String("a,b,c,d,a"),
        "the late-mat decode order must be first-seen, left-to-right,"
        " depth-first, WITH duplicates -- got [" + _joined(names) + "]",
    )
    _ = e^


def test_ordered_sink_keeps_duplicates_and_unique_sink_folds_them() raises:
    """The two sinks differ in EXACTLY one way, and that difference is the
    reason the walk is parameterized instead of merged. Pin it, so a
    "cleanup" that makes `collect_expr_cols` dedupe internally — which looks
    harmless — goes red instead of quietly changing the decode order."""
    var e = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("a"))
    assert_equal(
        len(_ordered_names(e)),
        2,
        "the ORDERED sink must keep duplicates (the caller dedupes)",
    )
    assert_equal(
        len(_unique_names(e)), 1, "the UNIQUE sink must fold duplicates"
    )
    _ = e^


def test_when_branch_order_is_condition_then_result_then_default() raises:
    """CASE is the arm TPC-H Q8 needs, and it is also the arm with the most
    freedom to emit names in a different order. Pin the traversal."""
    var names = _ordered_names(_corpus_expr(Int(EXPR_WHEN)))
    assert_equal(
        _joined(names),
        String("c,t,d"),
        "CASE must walk condition, then result, then default -- got ["
        + _joined(names)
        + "]",
    )


# ===========================================================================
# (2b) THE TWO FIELD-INFERENCE ADAPTERS AGREE — except where documented.
# ===========================================================================


def test_both_field_inference_entry_points_agree_on_every_tag() raises:
    """★ THE SECOND DRIFT FALSIFIER. `field_for_expr` (execution-time) and
    `_infer_expr_field` (plan-build-time) must infer the SAME arrow_type for
    every tag when every referenced column IS present.

    Two separate copies drift (6 arms against 17 is the measured shape), and
    such a gap exports every CASE projection as Arrow type `null`. They are one
    walk under two `ColRefFieldPolicy` values, and the policies differ ONLY
    on a MISSING column — which this schema does not have, so equality must
    hold on every tag.
    """
    var schema = _schema()
    for t in range(EXPR_TAG_COUNT):
        var e = _corpus_expr(t)
        var exec_field = field_for_expr(e, schema)
        var plan_field = _infer_expr_field(e, schema)
        assert_true(
            exec_field.arrow_type == plan_field.arrow_type,
            "tag "
            + String(t)
            + ": field_for_expr says "
            + String(exec_field.arrow_type)
            + " and _infer_expr_field says "
            + String(plan_field.arrow_type)
            + " -- the two field-inference entry points have DRIFTED",
        )
        _ = e^


def test_the_one_deliberate_difference_survives_unification() raises:
    """⭐ THE AUDIT RESULT, PINNED.

    `compiler_helpers.mojo` claimed the two field-inference copies differed
    "on two arms ON PURPOSE". Exactly ONE of the two was real:

      * EXPR_COL_REF on a MISSING column -- REAL. Execution-time raises
        (an operator over a live batch cannot continue and there is no later
        validator); plan-build-time returns a NULL placeholder (the plan
        VALIDATOR owns that diagnostic, and it can name the node and the
        available columns where this function could only name the string).
        Preserved as `ColRefFieldPolicy`, and pinned here.

      * The comparison BinaryOp type -- NOT REAL. It was unmirrored drift
        and is converged; see `test_comparison_binary_op_is_bool_everywhere`.

    If a future change collapses the policies, THIS is the test that says
    which behaviour was lost.
    """
    var schema = _schema()
    var missing = Expr.col_ref("no_such_column")

    with assert_raises(contains="no_such_column"):
        _ = field_for_expr(missing, schema)

    var placeholder = _infer_expr_field(missing, schema)
    assert_true(
        placeholder.arrow_type == ArrowType.NULL,
        "the plan-build-time policy must return a NULL placeholder, not"
        " raise -- the plan validator owns that diagnostic",
    )
    assert_equal(
        placeholder.name,
        String("no_such_column"),
        "the placeholder must carry the requested name so the validator can"
        " report it",
    )
    _ = missing^


# ===========================================================================
# THE UNARY / JSON / EXTRACT ARMS — each unwalked arm is an unexportable column.
# ===========================================================================


def test_unary_op_output_types() raises:
    """★ `EXPR_UNARY_OP` MUST BE WALKED FOR ITS TYPE.

    Unwalked, `NOT x` / `-x` / `x IS NULL` in a projection lands on the
    `null` fallback and the Arrow C-ABI export refuses the whole result with
    `UnsupportedArrowCABIType: Arrow type 'null' (export)`.

    The type is PER-OP (like EXPR_STRING_FN, unlike EXPR_MATH_FN which is
    FLOAT64 whatever its op), so every op is pinned separately."""
    var schema = _schema()

    var e_not = Expr.unary(UN_NOT, Expr.col_ref("flag"))
    assert_true(
        field_for_expr(e_not, schema).arrow_type == ArrowType.BOOL,
        "`NOT x` is BOOL, not null",
    )

    var e_isnull = Expr.unary(UN_IS_NULL, Expr.col_ref("a"))
    var f_isnull = field_for_expr(e_isnull, schema)
    assert_true(f_isnull.arrow_type == ArrowType.BOOL, "`x IS NULL` is BOOL")
    assert_false(
        f_isnull.nullable,
        "`x IS NULL` is TOTAL -- it answers true/false for a NULL x as"
        " readily as for a present one, so it has no null slot to declare."
        " This is the one arm where a nullable input yields a non-nullable"
        " output, and getting it wrong costs a spurious validity bitmap on"
        " every row",
    )

    var e_isnotnull = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("a"))
    var f_nn = field_for_expr(e_isnotnull, schema)
    assert_true(f_nn.arrow_type == ArrowType.BOOL, "`x IS NOT NULL` is BOOL")
    assert_false(f_nn.nullable, "`x IS NOT NULL` is total too")

    # NEGATE is the odd one: it preserves the operand's type rather than
    # producing a boolean.
    var e_neg = Expr.unary(UN_NEGATE, Expr.col_ref("a"))
    assert_true(
        field_for_expr(e_neg, schema).arrow_type == ArrowType.INT64,
        "`-x` preserves the operand's type (INT64 here), it does not"
        " promote and it is certainly not BOOL",
    )
    _ = e_not^
    _ = e_isnull^
    _ = e_isnotnull^
    _ = e_neg^


def test_comparison_binary_op_is_bool_everywhere() raises:
    """⭐ THE CONVERGED ARM — the difference that was NOT on purpose.

    `_infer_expr_field` returns BOOL for BIN_EQ/NE/LT/LE/GT/GE/AND/OR (a
    `str_col = 'X'` labelled STRING is lowered with the wrong runtime_dtype,
    as TPC-H q19's CSE projection showed). A `field_for_expr` that falls
    through to the LEFT operand's type instead is drift.

    Three things show that was drift rather than design:
      * `field_for_expr`'s own INT32 arm said the arm "already MISREPORTS"
        the comparison type — misreports, not deliberately reports;
      * its INTERVAL_MDN arm said BIN_EQ should "fall through to the Bool
        default", and there was no Bool default in that function — the
        comment described the sibling and was false of its own function;
      * `_eval_column_expr`'s INTERVAL_MDN eq/ne arms really do return
        `Column.from_boolean(...)`, so the batch carried a BOOL column under
        a field declaring INTERVAL_MDN.
    """
    var schema = _schema()
    var cmp_expr = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.col_ref("b"))
    assert_true(
        field_for_expr(cmp_expr, schema).arrow_type == ArrowType.BOOL,
        "`a > b` is BOOL at BOTH entry points now -- returning the left"
        " operand's INT64 is the pre-convergence bug",
    )
    assert_true(
        _infer_expr_field(cmp_expr, schema).arrow_type == ArrowType.BOOL,
        "`a > b` must stay BOOL on the plan side",
    )
    _ = cmp_expr^


def test_arithmetic_binary_op_still_promotes() raises:
    """The convergence above must not have swallowed the ARITHMETIC path:
    comparisons leave the ladder early now, so the promotion rules below
    them have to still be reachable."""
    var schema = _schema()
    var arith = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    assert_true(
        field_for_expr(arith, schema).arrow_type == ArrowType.INT64,
        "`a + b` over two INT64 columns is INT64",
    )
    _ = arith^


def test_extract_and_json_extract_are_typed_not_null() raises:
    """★ `EXPR_JSON_EXTRACT` and `EXPR_EXTRACT` MUST DECLARE THEIR TYPES.

    `_eval_column_expr` evaluates `j -> '$.a'` and `extract(year from d)` in
    a projection; a type ladder without those arms computes CORRECT DATA and
    then declares it `null`, and the Arrow C-ABI export refuses the whole
    result. Only a comparison of the TYPE ladder against the DATA ladder
    (the cross-ladder ledger) surfaces that.
    """
    var schema = _schema()

    var e_extract = _corpus_expr(Int(EXPR_EXTRACT))
    # ⭐ INT64, NOT INT32. The row path (`row_streaming_segment`) translates
    # the same node into `EXPR_EXTRACT_I64`, so an INT32 column path would
    # answer `year(d)` as INT32 through the column executor and INT64 through
    # the row one, chosen by whether the projection happened to be
    # row-servable. DuckDB v1.5.3 declares BIGINT for every member of the
    # family (per `duckdb_functions()` and by evaluation), so the COLUMN path
    # and this ladder follow it. ⛔ Do NOT narrow it back to match a
    # `Column.from_primitive[int32]` — this ladder disagreeing with the data
    # ladder about the SAME executor is strictly worse.
    assert_true(
        field_for_expr(e_extract, schema).arrow_type == ArrowType.INT64,
        "`extract(year from d)` is INT64 -- the eval arm returns"
        " Column.from_primitive[int64] for every field-extract unit, which"
        " is DuckDB's BIGINT and this engine's ROW executor",
    )

    var e_json = _corpus_expr(Int(EXPR_JSON_EXTRACT))
    assert_false(
        field_for_expr(e_json, schema).arrow_type == ArrowType.NULL,
        "`j ->> '$.a'` must carry the output type the node declares, not"
        " `null` -- a `null` column is refused by the Arrow C-ABI export",
    )
    _ = e_extract^
    _ = e_json^


def test_date_trunc_preserves_the_child_type() raises:
    """`date_trunc` and the field-extracts share a tag and split on
    `_is_trunc_unit` — the SAME predicate `_eval_column_expr` branches on,
    which is why the rule is delegated rather than restated. The eval arm
    explicitly re-stamps `col_out.arrow_type` to the source temporal type,
    so the declared type must follow the CHILD, not the Int32/Int64 storage
    the kernel returned."""
    var schema = _schema()
    var e = Expr.extract(EXTRACT_TRUNC_MONTH, Expr.col_ref("d"))
    assert_true(
        field_for_expr(e, schema).arrow_type == ArrowType.INT64,
        "date_trunc must report the CHILD's type (INT64 here), not INT32",
    )
    _ = e^

    # ★★ AND EVERY OTHER SLOT OF THE CHILD FIELD, NOT ONLY `arrow_type`.
    # An arm that builds its answer with the bare 3-arg
    # `Field(name, arrow_type, nullable)` ctor zeroes `_tz`,
    # `_dict_index_type`, `_flags`, decimal (p,s), kv-metadata and nested
    # children. So `date_trunc('month', ts_utc)` would DECLARE a tz-LESS
    # timestamp over a column whose tz the eval arm preserves — the same
    # mistake an EXPR_ALIAS arm can make with the same ctor. `arrow_type`
    # alone stays green through all of it, which is why this second
    # assertion exists at all.
    var tz_sb = SchemaBuilder()
    tz_sb.add_field(
        Field.timestamp(
            String("tz"), ArrowType.TIMESTAMP_US, String("UTC"), True
        )
    )
    var tz_schema = tz_sb.build()
    var e_tz = Expr.extract(EXTRACT_TRUNC_MONTH, Expr.col_ref("tz"))
    var f_tz = field_for_expr(e_tz, tz_schema)
    assert_true(
        f_tz.arrow_type == ArrowType.TIMESTAMP_US,
        "date_trunc over a TIMESTAMP_US column reports TIMESTAMP_US",
    )
    assert_equal(
        f_tz.timezone(),
        String("UTC"),
        "date_trunc must carry the child field's TIMEZONE, not drop it",
    )
    _ = e_tz^


def main() raises:
    var ts = TestSuite()
    ts.test[test_every_expr_tag_has_a_corpus_expression]()
    ts.test[test_corpus_refuses_an_unmodelled_tag]()
    ts.test[test_both_name_sinks_agree_on_every_tag]()
    ts.test[test_known_unarmed_shapes_collect_their_column]()
    ts.test[test_window_fn_collects_all_three_name_channels]()
    ts.test[test_late_mat_column_order_is_first_seen_left_to_right]()
    ts.test[test_ordered_sink_keeps_duplicates_and_unique_sink_folds_them]()
    ts.test[test_when_branch_order_is_condition_then_result_then_default]()
    ts.test[test_both_field_inference_entry_points_agree_on_every_tag]()
    ts.test[test_the_one_deliberate_difference_survives_unification]()
    ts.test[test_unary_op_output_types]()
    ts.test[test_comparison_binary_op_is_bool_everywhere]()
    ts.test[test_arithmetic_binary_op_still_promotes]()
    ts.test[test_extract_and_json_extract_are_typed_not_null]()
    ts.test[test_date_trunc_preserves_the_child_type]()
    ts^.run()
