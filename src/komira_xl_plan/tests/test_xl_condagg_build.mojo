# =============================================================================
# test_xl_condagg_build.mojo — ★ THE THIRD AND FOURTH `build_xl_plan` ARMS:
#                                SUMIF / COUNTIF / AVERAGEIF, AND CORREL.
# =============================================================================
#
# Split out of `test_xl_plan_build.mojo` when that file passed 1000 lines. Same
# constraints, and they are not stylistic: this file is welded to
# `komira_xl_plan`, which downstream bindings link, so it is an
# INPUT to every package that links it
# gate. ⛔ NO `EngineContext`, NO FILE, NO FIXTURE — a slow or flaky member
# here blocks the shared library at random, which is the failure
# `test_iceberg_snapshot_summary` demonstrated on 2026-09-03.
#
# ★ THE TWO ARMS HERE ARE THE 2026-09-04 PLAN-REACH WIDENING, and they are
# different KINDS of change:
#
#   SUMIF / COUNTIF / AVERAGEIF   NEW. No executing twin anywhere in the tree,
#                                 so `rel_condagg_build` is the one definition.
#                                 What keeps it honest is that every PART of
#                                 the plan comes from a builder that already
#                                 existed.
#   CORREL                        REACHABLE-BUT-UNBOUND. `AGG_CORR` had a
#                                 plan-IR tag, plan-wire member 10, a SQL
#                                 binding and a 0-key executor arm. The change
#                                 was a NAME.
#
# ⚠ THE ORACLES ARE ASSEMBLED FROM `komira_core`, never read back from the
# builder. `String(built) == String(built)` is green through any mutation.
# =============================================================================

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.col_expr import col
from komira_core.plan.expr import (
    Expr, BIN_AND, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE,
    UN_IS_NULL, WhenCaseData,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
)
from komira_core.plan.agg_expr import (
    AggExpr,
    corr as agg_corr,
    sum as agg_sum,
    count as agg_count,
    mean as agg_mean,
    agg_is_bivariate,
    AGG_CORR,
    AGG_COVAR_POP,
    AGG_COVAR_SAMP,
    AGG_REGR_SLOPE,
    AGG_REGR_INTERCEPT,
    AGG_REGR_R2,
)
from komira_core.source.parquet_source import ParquetSource
from komira_core.source.source_variant import SourceVariant

from komira_xl_plan.bound_relation import BoundRelation, NamedTable
from komira_xl_plan.formula_bindings import FormulaBindings
from komira_xl_plan.formula_parser import parse_formula
from komira_xl_plan.rel_agg_build import (
    build_bivar_agg_plan,
    _bivariate_agg_func,
)
from komira_xl_plan.xl_fn_table import (
    xl_plan_agg_tag,
    xl_fn_lookup,
    xl_function_table,
    XLF_BIVAR_AGG,
    XLA_CORR,
    XLA_COVAR_POP,
    XLA_COVAR_SAMP,
    XLA_REGR_SLOPE,
    XLA_REGR_INTERCEPT,
    XLA_REGR_R2,
)
from komira_xl_plan.rel_condagg_build import (
    build_cond_agg_plan,
    build_criteria_predicate,
)
from komira_xl_plan.xl_plan_build import (
    build_xl_plan,
    XL_BUILD_NO_PLAN,
    XL_BUILD_RESIDENT,
)
from komira_xl_plan.xl_text_compare import excel_text_lower
# ⚠ THE KERNEL'S OWN FUNCTION, IMPORTED HERE ON PURPOSE. The claim under test is
# that `excel_text_lower` IS `unicode_lower_bytes` — the mapping
# `compiler_eval_column`'s `STRFN_LOWER` arm applies to the COLUMN — so the
# oracle has to be that function and not a hand-written expected string.
from komira_core.eval.unicode_case import unicode_lower_bytes


# =============================================================================
# The fixture — a SCHEMA and a PATH. The path need not exist and is never read.
# =============================================================================


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("qty", ArrowType.INT64, False))
    sb.add_field(Field("price", ArrowType.FLOAT64, False))
    sb.add_field(Field("status", ArrowType.STRING, False))
    return sb.build()


def _source() raises -> SourceVariant:
    return SourceVariant(
        ParquetSource(String("/nonexistent/door.parquet"), _schema())
    )


def _named(column: String) raises -> BoundRelation:
    return BoundRelation(
        NamedTable(String("door"), _schema(), _source()), column
    )


def _bindings() raises -> FormulaBindings:
    var b = FormulaBindings()
    b.bind_relation(String("qty"), _named(String("qty")))
    b.bind_relation(String("price"), _named(String("price")))
    b.bind_relation(String("status"), _named(String("status")))
    b.bind_relation(String("door"), _named(String("")))
    return b^


def _resident_bindings() raises -> FormulaBindings:
    var b = FormulaBindings()
    b.bind_relation(
        String("qty"), BoundRelation(ArcPointer(RecordBatch()), String("qty"))
    )
    return b^


# =============================================================================
# ⭐ THE SINGULAR CONDITIONAL AGGREGATES — SUMIF / COUNTIF / AVERAGEIF
# =============================================================================
#
# ★ WHAT MADE THESE THE HIGHEST-VALUE ROW ON THE ABSENCE LIST. The PLURAL forms
# (SUMIFS / COUNTIFS) already existed, so an OP-SPACE census reads "conditional
# aggregate: present" and sees nothing. The gap was in the NAME space, and the
# missing names are the ones ordinary sheets overwhelmingly use.
#
# ⚠ THE SHAPE IS `AGGREGATE <- FILTER <- SCAN`, WHICH IS NOT A NEW PLAN NODE.
# `fn_rel_dynarray.lower_agg_over_filter` already builds and RUNS it over a
# resident batch. What was missing on the NAMED arm was a ctx-free builder, and
# every part of it already existed: `rel_filter_build.filtered_scan` for the
# bottom two nodes and `rel_agg_build._agg_expr_for_name` for the aggregate.


def _oracle_condagg(
    var aggs: AggExprArray, var pred: Expr
) raises -> String:
    """`Aggregate([], [<agg>]) <- Filter(<pred>) <- Scan(ParquetSource)`,
    assembled out of `komira_core` and nothing else.

    ⚠ THERE IS NO `Project` IN IT, AND THAT IS AN ASSERTION AND NOT AN
    OMISSION. `build_filter_plan` projects the array's column; here the array
    is the CRITERIA range, so projecting it would drop the summed column
    underneath the aggregate — a wrong SCHEMA produced by a node whose only
    purpose was a column selector."""
    return String(
        LogicalPlan.aggregate(
            ExprArray(),
            aggs^,
            LogicalPlan.filter(
                pred^, LogicalPlan.scan_from_source(_source(), _schema())
            ),
        )
    )


def _oracle_condagg_sum(
    var aggs: AggExprArray, var pred: Expr, float_typed: Bool
) raises -> String:
    """⭐ THE SUM FORMS' ORACLE, AND IT GAINED A `Project` ON 2026-09-11.

    ⚠ `float_typed` IS STATED BY THE CALLER. The literal's type follows the
    AGGREGATE's output (`price` is FLOAT64 -> `0.0`), and an oracle that read
    that type off the plan would agree with the builder by construction.

    ⛔ ASSEMBLED FROM `komira_core`, never by calling
    `xl_agg_identity.excel_zero_when_empty`."""
    var zero: ScalarValue
    if float_typed:
        zero = ScalarValue.from_float(0.0)
    else:
        zero = ScalarValue.from_int(0)
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.unary(UN_IS_NULL, Expr.col_ref(String("sum"))),
            Expr.literal(zero^),
        )
    )
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(
            Expr.when(cases^, Expr.col_ref(String("sum"))), String("sum")
        )
    )
    return String(
        LogicalPlan.project(
            exprs^,
            LogicalPlan.aggregate(
                ExprArray(),
                aggs^,
                LogicalPlan.filter(
                    pred^, LogicalPlan.scan_from_source(_source(), _schema())
                ),
            ),
        )
    )


def _gt25() raises -> Expr:
    return Expr.binary(
        BIN_GT, Expr.col_ref(String("qty")), Expr.literal(ScalarValue.from_float(25.0))
    )


def test_sumif_builds_the_aggregate_over_filter_over_scan() raises:
    """★ THE CENTRAL CLAIM FOR THE THIRD ARM, against a plan assembled
    independently from `komira_core`. A builder compared to itself is green
    through any mutation of itself."""
    var b = build_xl_plan(String('SUMIF(qty, ">25", price)'), _bindings())
    assert_true(
        b.is_built(),
        "SUMIF over two named columns of one table must build a plan."
        " detail: " + b.detail(),
    )
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("price"))))
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg_sum(aggs^, _gt25(), True),
        "SUMIF did not build PROJECT(<Excel zero identity>) <-"
        " AGGREGATE(SUM(price)) <- FILTER(qty > 25) <- SCAN token for token. A"
        " different aggregate, a predicate over the wrong column, a missing"
        " filter or a missing/extra zero-identity projection all land here",
    )


def test_the_three_names_lower_to_three_DIFFERENT_aggregates() raises:
    """A ladder that returned SUM for all three would pass the test above.

    ⭐ COUNTIF LOWERS TO `count(*)` OVER THE FILTERED ROWS, AND THIS ORACLE
    READ `count(<col>)` UNTIL 2026-09-11. The two are the SAME NUMBER — a NULL
    never satisfies a comparison, so the predicate has already removed every row
    `count(<col>)` would skip, and this docstring said so while asserting the
    other one. The expectation moved because `count(<col>)` was an UNEXECUTABLE
    plan over a non-int/float criteria range: `agg_node_exec` declines a 0-key
    `count(<col>)` outside int/float BY NAME and admits `COUNT(*)` in the same
    sentence, so `COUNTIF(status, "acme")` — the spelling real sheets use most —
    raised rather than answering. See `build_cond_agg_plan`, whose own docstring
    had claimed `count(*)` since the day it landed."""
    var a_cnt = AggExprArray()
    a_cnt.append(agg_count())
    var b_cnt = build_xl_plan(String('COUNTIF(qty, ">25")'), _bindings())
    assert_true(b_cnt.is_built(), "COUNTIF must build: " + b_cnt.detail())
    assert_equal(
        String(b_cnt.take_plan()),
        _oracle_condagg(a_cnt^, _gt25()),
        "COUNTIF must lower to COUNT, not to SUM",
    )

    var a_avg = AggExprArray()
    a_avg.append(agg_mean(col(String("price"))))
    var b_avg = build_xl_plan(
        String('AVERAGEIF(qty, ">25", price)'), _bindings()
    )
    assert_true(b_avg.is_built(), "AVERAGEIF must build: " + b_avg.detail())
    assert_equal(
        String(b_avg.take_plan()),
        _oracle_condagg(a_avg^, _gt25()),
        "AVERAGEIF must lower to MEAN, not to SUM",
    )


def test_the_value_range_defaults_to_the_criteria_range() raises:
    """Excel's rule: `SUMIF(qty, ">25")` sums `qty` itself. The two-argument and
    three-argument forms must build the SAME plan when the third names the same
    range — a default that produced a different plan would be a silent second
    meaning for the same formula."""
    var two = build_xl_plan(String('SUMIF(qty, ">25")'), _bindings())
    var three = build_xl_plan(String('SUMIF(qty, ">25", qty)'), _bindings())
    assert_true(two.is_built(), "the 2-arg form must build: " + two.detail())
    assert_true(three.is_built(), "the 3-arg form must build: " + three.detail())
    assert_equal(
        String(two.take_plan()),
        String(three.take_plan()),
        "`SUMIF(qty, crit)` and `SUMIF(qty, crit, qty)` are the same formula in"
        " Excel and must be the same plan here",
    )


def test_a_text_criteria_is_a_CASE_FOLDED_equality_against_a_TEXT_literal() raises:
    """`SUMIF(status, "shipped", price)`. ⚠ THE COLUMN IS A `STRING` ONE AND
    THAT IS WHY THE FIXTURE HAS ONE: the text and numeric arms of
    `_operand_literal` build DIFFERENT `ScalarValue`s, and a numeric column
    cannot separate them.

    ⭐ THE `lower()` IS EXCEL'S SEMANTICS AND THIS ASSERTION USED TO PIN ITS
    ABSENCE. Until 2026-09-11 this cell required
    `col("status") = 'shipped'` — byte-exact — and passed, because that is
    exactly what the builder emitted; `rel_condagg_build`'s own header called
    the divergence out as "stated, not fixed" the day it landed. A plan-shape
    test cannot tell a right row set from a wrong one, so the expectation was
    flipped deliberately rather than discovered: see
    `tests/sdk/test_xl_criteria_case_insensitive_e2e.mojo`, which measures the
    ROWS and is the reason this shape moved."""
    var b = build_xl_plan(
        String('SUMIF(status, "shipped", price)'), _bindings()
    )
    assert_true(b.is_built(), "a text criteria must build: " + b.detail())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("price"))))
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg_sum(aggs^, _eq_status(String("shipped")), True),
        "a bare text criteria must be a CASE-FOLDED equality against a text"
        " literal — `lower(status) = 'shipped'`, not `status = 'shipped'`",
    )


def test_the_criteria_operand_is_folded_too() raises:
    """★ FOLDING ONLY THE COLUMN MOVES THE DEFECT INSTEAD OF FIXING IT.
    `lower(status) = 'SHIPPED'` matches NOTHING — a new wrong answer, and a
    worse one than the old code's, which at least found the exact-case rows.
    So the two spellings must build the IDENTICAL plan."""
    var mixed = build_xl_plan(
        String('SUMIF(status, "ShIpPeD", price)'), _bindings()
    )
    var lower = build_xl_plan(
        String('SUMIF(status, "shipped", price)'), _bindings()
    )
    assert_true(mixed.is_built(), "a mixed-case criteria must build")
    assert_true(lower.is_built(), "a lower-case criteria must build")
    assert_equal(
        String(mixed.take_plan()),
        String(lower.take_plan()),
        "`\"ShIpPeD\"` and `\"shipped\"` are ONE question in Excel and must"
        " build ONE plan; a literal left unfolded makes them two",
    )


def _folded_status(op: UInt8, v: String) raises -> Expr:
    """`lower(status) <op> '<v>'` — the oracle for a TEXT criteria under any
    comparison operator. `v` is passed already-folded (see `_eq_status`)."""
    return Expr.binary(
        op,
        Expr.lower(Expr.col_ref(String("status"))),
        Expr.literal(ScalarValue.from_string(v)),
    )


def test_every_comparison_op_folds_a_text_operand_not_just_equality() raises:
    """⛔ Excel's text comparison is case-insensitive for `<` `<=` `>` `>=` and
    `<>` as well. A fold on the equality arm alone leaves `"<>Shipped"`
    selecting a LARGER row set than the correct answer — the direction an
    assertion on the `=` arm cannot see, because both answers are plausible
    counts.

    ⚠ THE ORACLE IS STRUCTURAL, NOT A SUBSTRING SEARCH. `_oracle_condagg`
    assembles the expected plan out of `komira_core`, so this cell asserts the
    NODE rather than a rendering, and a change to how an `Expr` prints cannot
    turn it green or red."""
    var ops: List[String] = [
        String("<>"), String("<"), String("<="), String(">"), String(">="),
    ]
    var bops: List[UInt8] = [BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]
    for i in range(len(ops)):
        var b = build_xl_plan(
            String('COUNTIF(status, "') + ops[i] + String('Shipped")'),
            _bindings(),
        )
        assert_true(
            b.is_built(), "`" + ops[i] + "Shipped` must build: " + b.detail()
        )
        var aggs = AggExprArray()
        aggs.append(agg_count())  # count(*) — see the note on COUNTIF's oracle.
        assert_equal(
            String(b.take_plan()),
            _oracle_condagg(
                aggs^, _folded_status(bops[i], String("shipped"))
            ),
            "the `" + ops[i] + "` arm did not fold BOTH sides of a text"
            " comparison",
        )


def test_a_non_ascii_text_operand_FOLDS_with_the_columns_OWN_mapping() raises:
    """★★ THE ENVELOPE'S EDGE, AND IT USED TO BE A REFUSAL. ⚠ EXPECTATION
    FLIPPED 2026-09-11 — the OLD assertion is stated here rather than deleted,
    because it was CORRECT for the code it was written against and reading it
    is how the reason for the change survives.

    IT USED TO REQUIRE A REFUSAL. The operand fold in `xl_text_compare` was
    ASCII while the COLUMN's fold is the engine's `STRFN_LOWER`, Unicode simple
    case mapping since 2026-09-09. On a pure-ASCII operand the two are
    byte-identical; on a non-ASCII one they are not — `lower('CAFÉ')` is
    `'café'` on the column side and an ASCII fold of the operand leaves
    `'cafÉ'`, which matches NO row. Answering 0 there is a wrong answer in the
    direction that LOSES rows, so refusing was right *given two different
    mappings*.

    ⇒ THE FIX WAS TO DELETE THE SECOND MAPPING, NOT TO IMPROVE IT.
    `komira_compiler/unicode_case{,_table}.mojo` moved down into
    `komira_core.eval` — a package `komira_xl_plan` ALREADY depends on — so
    `excel_text_lower` now calls `unicode_lower_bytes`, the SAME function
    `compiler_eval_column`'s `STRFN_LOWER` arm calls per row. The two sides
    agree BY CONSTRUCTION rather than by review, which is the only way a
    two-sided fold can be trusted: a second implementation "kept in sync" is
    free to drift, and the drift is a silently wrong ROW SET.

    ⛔ A SECOND ASCII-ONLY FOLD WOULD HAVE BEEN THE WRONG FIX for exactly that
    reason, and so would widening the ASCII fold to "handle Latin-1 too"."""
    var b = build_xl_plan(
        String('COUNTIF(status, "CAFÉ")'), _bindings()
    )
    assert_true(
        b.is_built(),
        "a non-ASCII text operand must now FOLD, not refuse: " + b.detail(),
    )
    var aggs = AggExprArray()
    aggs.append(agg_count())  # count(*) — see the note on COUNTIF's oracle.
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg(aggs^, _folded_status(BIN_EQ, String("café"))),
        "`CAFÉ` must fold to `café` — the Unicode simple lower mapping, which"
        " is what `lower(col(\"status\"))` applies on the other side. An ASCII"
        " fold would leave `cafÉ` and match nothing.",
    )


def test_the_operand_fold_is_the_ENGINES_OWN_mapping_not_a_second_copy() raises:
    """★ THE PROPERTY THE CELL ABOVE DEPENDS ON, ASSERTED DIRECTLY RATHER THAN
    INFERRED FROM ONE STRING.

    `excel_text_lower` must equal `unicode_lower_bytes` — the function
    `compiler_eval_column`'s `STRFN_LOWER` arm calls per row — for every input,
    including the ones where a "reasonable" hand-written fold diverges:

      * `İ` U+0130 lowers to a TWO-codepoint sequence in full case folding but
        to U+0069 in the SIMPLE mapping DuckDB (and therefore this engine)
        uses. A fold that reached for the full mapping answers differently.
      * `ß` U+00DF is ALREADY lower case and must be left alone — an `upper`
        round trip through `SS` would not come back.
      * a MALFORMED byte must be copied through, not replaced: a data-quality
        problem in an operand must not become a rewritten operand.

    Comparing against `unicode_lower_bytes` rather than against hand-written
    expected strings is deliberate — the claim is IDENTITY WITH THE KERNEL, and
    a hand-written expectation would let both sides drift together."""
    var probes: List[String] = [
        String("CAFÉ"), String("Café"), String("café"),
        String("ÉCLAIR"), String("İ"), String("ß"), String("STRASSE"),
        String("ACME"), String(""), String("Ünïcodé"),
    ]
    for i in range(len(probes)):
        var want = unicode_lower_bytes(probes[i])
        # ⚠ THE `String` IS BOUND FIRST. `excel_text_lower(x).as_bytes()` takes a
        # span of a TEMPORARY, which is a lifetime error waiting to happen.
        var got_s = excel_text_lower(probes[i])
        var got = got_s.as_bytes()
        assert_equal(
            len(got), len(want),
            "excel_text_lower disagrees with unicode_lower_bytes in LENGTH on"
            " probe " + String(i),
        )
        for k in range(len(want)):
            assert_equal(
                Int(got[k]), Int(want[k]),
                "excel_text_lower disagrees with unicode_lower_bytes at byte "
                + String(k) + " of probe " + String(i),
            )


def test_the_two_character_operators_are_split_before_the_one_character_ones() raises:
    """★★ THE TRAP THIS FAMILY'S PARSE EXISTS TO AVOID, ASSERTED DIRECTLY.
    `">="` starts with `">"`, so an operator ladder that tested the
    one-character forms first parses `">=25"` as `> "=25"` — a comparison
    against a TEXT operand beginning with an equals sign. That is not a
    refusal; it is a WRONG ROW SET, green through any test that only checks
    "it built"."""
    var b = build_xl_plan(String('COUNTIF(qty, ">=25")'), _bindings())
    assert_true(b.is_built(), "`>=25` must build: " + b.detail())
    var rendered = String(b.take_plan())
    assert_true(
        rendered.find(String("25")) >= 0,
        "the plan does not name 25, so the operand was mis-split: " + rendered,
    )
    assert_false(
        rendered.find(String("=25")) >= 0,
        "★ the plan compares against the STRING `=25`, which means the"
        " one-character `>` arm matched first and swallowed the `=` into the"
        " operand. Row set: wrong. Render: " + rendered,
    )
    # The control: `>25` and `>=25` must not build the SAME predicate.
    var strict = build_xl_plan(String('COUNTIF(qty, ">25")'), _bindings())
    assert_true(strict.is_built(), "`>25` must build")
    assert_true(
        String(strict.take_plan()) != rendered,
        "`>25` and `>=25` built the same plan, so one of the two operators is"
        " not reaching the predicate at all",
    )


def test_a_numeric_looking_TEXT_criteria_is_a_NUMBER() raises:
    """Excel's coercion: `COUNTIF(qty, "25")` matches the numeric cell 25, not
    a text cell "25". So the quoted and unquoted spellings must build the SAME
    plan."""
    var quoted = build_xl_plan(String('COUNTIF(qty, "25")'), _bindings())
    var bare = build_xl_plan(String("COUNTIF(qty, 25)"), _bindings())
    assert_true(quoted.is_built(), "a quoted number must build")
    assert_true(bare.is_built(), "a bare number must build")
    assert_equal(
        String(quoted.take_plan()),
        String(bare.take_plan()),
        'COUNTIF(qty, "25") and COUNTIF(qty, 25) are the same question in'
        " Excel and must be the same plan here",
    )


def test_a_WILDCARD_criteria_is_REFUSED_and_not_compared_literally() raises:
    """⛔ THE DIVERGENCE THAT HAD TO BE A REFUSAL. Excel matches `"ship*"` as a
    PATTERN. Comparing it as a literal string is not a smaller answer — it is a
    DIFFERENT question, answered confidently, and nothing downstream can tell.
    A `NO_PLAN` sends the caller to rewrite; a wrong count is a number someone
    acts on."""
    for crit in [String('"ship*"'), String('"a?c"'), String('">2*"')]:
        var b = build_xl_plan(
            String("SUMIF(status, ") + crit + String(", price)"), _bindings()
        )
        assert_false(
            b.is_built(),
            "a wildcard criteria " + crit + " built a plan, which means it was"
            " compared as a literal string and is answering a different"
            " question than the formula asks",
        )
        assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_an_operator_with_no_operand_is_refused() raises:
    """`"<>"` and `"="` alone are Excel's non-blank / blank tests. Comparing
    against the empty string selects a different set of rows, so they refuse."""
    for crit in [String('"<>"'), String('"="'), String('">"')]:
        var b = build_xl_plan(
            String("COUNTIF(status, ") + crit + String(")"), _bindings()
        )
        assert_false(
            b.is_built(),
            "the bare operator " + crit + " built a plan; it would compare"
            " against the empty string, which is not what Excel means by it",
        )


def test_a_criteria_that_is_not_a_literal_is_refused() raises:
    """A call, an arithmetic expression or a bound name each need an EVALUATOR
    to fold — the same reason `build_filter_predicate` refuses `DATE(y,m,d)` on
    its right-hand side."""
    for crit in [String("DATE(2026,1,1)"), String("1+1"), String("qty")]:
        var b = build_xl_plan(
            String("SUMIF(qty, ") + crit + String(", price)"), _bindings()
        )
        assert_false(
            b.is_built(),
            "a non-literal criteria `" + crit + "` built a plan, so something"
            " folded it without an evaluator",
        )


def test_a_cross_table_value_range_is_refused() raises:
    """★ ONE SCAN LEAF, SO ONE TABLE. A value range over a different catalog
    table would be aggregated out of rows the predicate never filtered — a
    wrong NUMBER, not a wrong shape, and invisible to a schema check."""
    var sb = SchemaBuilder()
    sb.add_field(Field("amt", ArrowType.INT64, False))
    var other_schema = sb.build()
    var other = BoundRelation(
        NamedTable(
            String("other"),
            other_schema.copy(),
            SourceVariant(
                ParquetSource(String("/nonexistent/other.parquet"), other_schema.copy())
            ),
        ),
        String("amt"),
    )
    var b2 = _bindings()
    b2.bind_relation(String("amt"), other^)
    var b = build_xl_plan(String('SUMIF(qty, ">25", amt)'), b2)
    assert_false(
        b.is_built(),
        "a criteria range and a value range over DIFFERENT tables built one"
        " plan, which can only mean one of the two ranges was discarded",
    )
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_resident_sumif_is_the_resident_status_not_an_envelope_refusal() raises:
    """The arm order, asserted for the third arm too: a resident binding sends
    the caller to REBIND, an out-of-envelope criteria sends them to REWRITE."""
    var b = build_xl_plan(String('SUMIF(qty, ">25")'), _resident_bindings())
    assert_false(b.is_built())
    assert_equal(b.status(), XL_BUILD_RESIDENT)


def test_SUMIF_is_not_dispatched_to_the_plain_aggregate_arm() raises:
    """★★ THE DISPATCH SEPARATION, ASSERTED AS A BEHAVIOUR. `SUMIF` carries the
    aggregate tag `XLA_SUM` — it really does apply a sum — so the tag-keyed
    `_is_rel_agg_name` that served this file until 2026-09-04 would have
    claimed it FIRST and then refused it in `_build_rel_agg`'s "exactly one
    relation argument" guard. `xl_plan_family` is what keeps them apart.

    The observable consequence is simply that the THREE-argument form BUILDS,
    which no arity-1 arm can do."""
    var b = build_xl_plan(String('SUMIF(qty, ">25", price)'), _bindings())
    assert_true(
        b.is_built(),
        "★ a three-argument SUMIF refused. If the detail below says `takes"
        " exactly one relation argument`, SUMIF was dispatched to the plain"
        " aggregate arm on its tag. detail: " + b.detail(),
    )


def test_COUNTIF_refuses_a_third_argument_because_the_TABLE_says_so() raises:
    """The arity guard reads `XlFnRow.arity_ok`, so it cannot disagree with the
    census `komira_xl_functions` renders. COUNTIF's window is 2..2 — Excel has
    no COUNTIF value range, because COUNTIF counts the criteria range."""
    var b = build_xl_plan(String('COUNTIF(qty, ">25", price)'), _bindings())
    assert_false(b.is_built(), "COUNTIF takes no third argument")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)
    var one = build_xl_plan(String("SUMIF(qty)"), _bindings())
    assert_false(one.is_built(), "SUMIF needs a criteria")


def test_the_built_plan_carries_NO_projection_UNDER_the_aggregate() raises:
    """★ THE NODE WHOSE PRESENCE WOULD BE A WRONG SCHEMA. `build_filter_plan`
    projects the array's column selector; the conditional aggregates share its
    `filtered_scan` and must NOT, because their array is the CRITERIA range and
    projecting it drops the summed column underneath the aggregate.

    ⚠ THE WORD "UNDER" ENTERED THIS NAME ON 2026-09-11 AND IT IS THE WHOLE
    CHANGE. `build_xl_plan` now puts a projection ABOVE the aggregate — Excel's
    empty-range zero identity — so *"the plan carries no Project"* became false
    for a reason that has nothing to do with the schema hazard this cell is
    about. The hazard is a projection BELOW the aggregate, and that is what is
    asserted now: the RELATIONAL builder's own plan has none at all, and the
    door's single projection is the ROOT.

    ⛔ IT ASKS `build_cond_agg_plan` DIRECTLY for the first half. Asking the
    door and then reasoning about which Project is which is how an assertion
    stops discriminating."""
    var src = parse_formula(String('SUMIF(qty, ">25", price)'))
    var root = src.get(src.root)
    var crit = _named(String("qty"))
    var pred = build_criteria_predicate(src, root.args[1], crit)
    assert_true(Bool(pred), "the criteria predicate builds")
    var plan_opt = build_cond_agg_plan(
        String("SUMIF"), crit, _named(String("price")), pred.take()
    )
    assert_true(Bool(plan_opt), "the relational plan builds")
    var relational = String(plan_opt.take())
    assert_false(
        relational.find(String("Project")) >= 0,
        "the conditional-aggregate plan projects, which would leave the summed"
        " column out of the aggregate's input: " + relational,
    )

    # ★ AND THE DOOR'S ONE PROJECTION IS THE ROOT — i.e. ABOVE the aggregate,
    # where it changes a VALUE and not a schema.
    var b = build_xl_plan(String('SUMIF(qty, ">25", price)'), _bindings())
    assert_true(b.is_built())
    var rendered = String(b.take_plan())
    assert_equal(
        rendered.find(String("Project")),
        0,
        "the door's plan does not START with its Project, so the zero-identity"
        " projection is not the root: " + rendered,
    )
    assert_equal(
        rendered.find(String("Project"), 1),
        -1,
        "the door's plan carries a SECOND Project. Exactly one — the Excel"
        " zero identity — belongs here: " + rendered,
    )

    # The CONTROL: `FILTER(price, qty>1)` over the same fixture DOES project,
    # so the assertion above is about this plan and not about the renderer.
    var f = build_xl_plan(String("FILTER(price, qty>1)"), _bindings())
    assert_true(f.is_built())
    assert_true(
        String(f.take_plan()).find(String("Project")) >= 0,
        "the control lost its projection, so the assertion above proves"
        " nothing about the renderer",
    )


def test_build_cond_agg_plan_needs_no_engine_constructed_at_all() raises:
    """★ THE SIGNATURE IS THE CLAIM. This function COMPILES with no
    `EngineContext` in scope. A landing that adds a context parameter to
    `build_cond_agg_plan` or `build_criteria_predicate` breaks this file at
    COMPILE time, which is the only way the ABSENCE of an argument can be
    asserted."""
    var src = parse_formula(String('SUMIF(qty, ">25", price)'))
    var root = src.get(src.root)
    var crit = _named(String("qty"))
    var value = _named(String("price"))
    var pred = build_criteria_predicate(src, root.args[1], crit)
    assert_true(Bool(pred), "the criteria predicate builds with no engine")
    var plan_opt = build_cond_agg_plan(
        String("SUMIF"), crit, value, pred.take()
    )
    assert_true(Bool(plan_opt), "the plan builds with no engine")
    var rendered = String(plan_opt.take())
    assert_true(rendered.find(String("Filter(")) >= 0)
    assert_true(rendered.find(String("Aggregate")) >= 0)


def test_a_column_less_value_range_is_refused_before_any_plan_exists() raises:
    """`SUMIF(qty, ">25", door)` names the WHOLE table as its value range, and
    there is nothing to sum. Refused by `build_cond_agg_plan` — the same
    column-less `#NAME?` the unconditional aggregates return."""
    var b = build_xl_plan(String('SUMIF(qty, ">25", door)'), _bindings())
    assert_false(b.is_built(), "a whole-table value range has no column to sum")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


# =============================================================================
# ⭐ THE PLURAL FORMS — SUMIFS / COUNTIFS / AVERAGEIFS, and the REVERSED layout
# =============================================================================


def _and(var a: Expr, var b: Expr) raises -> Expr:
    return Expr.binary(BIN_AND, a^, b^)


def _eq_status(v: String) raises -> Expr:
    """⭐ THE ORACLE CHANGED SHAPE ON 2026-09-11 AND THE OLD ONE WAS PINNING A
    DEFECT. It read `Expr.binary(BIN_EQ, Expr.col_ref("status"), <literal>)` —
    a BYTE-EXACT comparison — which is what the builder emitted and what Excel
    does NOT mean. Excel's text comparison is case-INSENSITIVE (`"acme"`
    matches `ACME`), so the criteria lowers to `lower(<col>) OP <folded
    literal>`; `rel_condagg_build`'s header carried that divergence written
    down and unfixed until then.

    ⚠ `v` IS PASSED ALREADY-FOLDED BY EVERY CALLER (`"shipped"`, `"x"`), so
    this helper does not fold it — a helper that folded would agree with a
    builder that folded the literal TWICE. `test_the_criteria_operand_is_folded
    _too` is the cell that pins the operand side, with a MIXED-case literal."""
    return Expr.binary(
        BIN_EQ,
        Expr.lower(Expr.col_ref(String("status"))),
        Expr.literal(ScalarValue.from_string(v)),
    )


def test_sumifs_conjoins_two_criteria_over_one_scan() raises:
    """★ THE CENTRAL CLAIM FOR THE PLURAL LAYOUT, against a plan assembled from
    `komira_core` alone. Two pairs, ANDed left-associatively, one scan leaf, and
    the aggregate over the range named FIRST."""
    var b = build_xl_plan(
        String('SUMIFS(price, qty, ">25", status, "shipped")'), _bindings()
    )
    assert_true(b.is_built(), "SUMIFS must build: " + b.detail())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col(String("price"))))
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg_sum(
            aggs^, _and(_gt25(), _eq_status(String("shipped"))), True
        ),
        "SUMIFS did not build AGGREGATE(SUM(price)) <- FILTER(qty > 25 AND"
        " status = 'shipped') <- SCAN token for token",
    )


def test_the_PLURAL_layout_puts_the_aggregate_range_FIRST() raises:
    """⛔⛔ THE FAILURE THIS TEST EXISTS FOR IS NOT A REFUSAL. Excel reversed the
    argument order between the two families: `SUMIF(crit, criteria, values)` and
    `SUMIFS(values, crit, criteria)` name the SAME question with the ranges
    swapped. A builder that read one layout for both would aggregate the
    CRITERIA column and filter on the VALUE column — a well-formed plan
    returning a wrong number, which nothing downstream can see.

    So the assertion is that the two spellings build the SAME plan."""
    var singular = build_xl_plan(
        String('SUMIF(qty, ">25", price)'), _bindings()
    )
    var plural = build_xl_plan(
        String('SUMIFS(price, qty, ">25")'), _bindings()
    )
    assert_true(singular.is_built(), "SUMIF: " + singular.detail())
    assert_true(plural.is_built(), "SUMIFS: " + plural.detail())
    assert_equal(
        String(plural.take_plan()),
        String(singular.take_plan()),
        "★ `SUMIFS(price, qty, crit)` and `SUMIF(qty, crit, price)` are the"
        " same question in Excel. A difference here means one of the two read"
        " the other's layout: the aggregate is over the wrong column, or the"
        " predicate is",
    )


def test_countifs_takes_no_aggregate_range_in_either_layout() raises:
    """COUNTIFS counts the rows the criteria select, so EVERY argument is part
    of a pair — `pair_start` is 0 for it even though it is plural. Getting that
    wrong would consume the first criteria RANGE as an aggregate range and then
    fail the parity check, refusing a formula Excel accepts."""
    var b = build_xl_plan(
        String('COUNTIFS(qty, ">25", status, "shipped")'), _bindings()
    )
    assert_true(b.is_built(), "COUNTIFS must build: " + b.detail())
    var aggs = AggExprArray()
    aggs.append(agg_count())  # count(*) — see the note on COUNTIF's oracle.
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg(aggs^, _and(_gt25(), _eq_status(String("shipped")))),
        "COUNTIFS must count over the FIRST criteria range with both criteria"
        " conjoined",
    )


def test_averageifs_lowers_to_MEAN_and_is_the_plan_only_one() raises:
    """AVERAGEIFS has no inline lowering at all (`fn_rel_condagg` serves SUMIFS
    and COUNTIFS only), so this builder is its ONLY definition anywhere."""
    var b = build_xl_plan(
        String('AVERAGEIFS(price, qty, ">25", status, "shipped")'), _bindings()
    )
    assert_true(b.is_built(), "AVERAGEIFS must build: " + b.detail())
    var aggs = AggExprArray()
    aggs.append(agg_mean(col(String("price"))))
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg(aggs^, _and(_gt25(), _eq_status(String("shipped")))),
        "AVERAGEIFS must lower to MEAN, not to SUM",
    )


def test_three_criteria_pairs_conjoin_LEFT_associatively() raises:
    """The fold direction is observable in the render, and a right-associative
    fold would build a DIFFERENT tree for the same formula. Asserting it pins
    the shape a wire consumer sees."""
    var b = build_xl_plan(
        String('COUNTIFS(qty, ">25", status, "shipped", status, "x")'),
        _bindings(),
    )
    assert_true(b.is_built(), "three pairs must build: " + b.detail())
    var aggs = AggExprArray()
    aggs.append(agg_count())  # count(*) — see the note on COUNTIF's oracle.
    assert_equal(
        String(b.take_plan()),
        _oracle_condagg(
            aggs^,
            _and(
                _and(_gt25(), _eq_status(String("shipped"))),
                _eq_status(String("x")),
            ),
        ),
        "the criteria did not conjoin LEFT-associatively",
    )


def test_an_ODD_argument_count_is_refused_for_the_plural_forms() raises:
    """A dangling criteria RANGE with no criteria is a formula Excel rejects,
    and silently dropping it would filter on fewer conditions than the user
    wrote — a LARGER row set and a wrong number."""
    var b = build_xl_plan(
        String('SUMIFS(price, qty, ">25", status)'), _bindings()
    )
    assert_false(b.is_built(), "an odd pair list must refuse")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)
    var c = build_xl_plan(String('COUNTIFS(qty, ">25", status)'), _bindings())
    assert_false(c.is_built(), "COUNTIFS with a dangling range must refuse")


def test_a_THREE_argument_SUMIF_is_not_read_as_a_pair_list() raises:
    """★ THE BUG THE TWO-WINDOW SPLIT PREVENTS, ASSERTED. If the singular forms
    paired to the END of the argument list like the plural ones do, a
    three-argument `SUMIF` would have THREE pair arguments, fail the parity
    check and be refused — a formula Excel accepts, reported as malformed. It
    must BUILD, and its third argument must be the aggregate range."""
    var b = build_xl_plan(String('SUMIF(qty, ">25", price)'), _bindings())
    assert_true(
        b.is_built(),
        "★ a three-argument SUMIF refused. If the detail mentions PAIRS, the"
        " singular arm is pairing to the end of the argument list. detail: "
        + b.detail(),
    )
    assert_true(
        String(b.take_plan()).find(String("SUM(ColRef(price))")) >= 0,
        "the third argument is the AGGREGATE range, so the sum is over price",
    )


def test_plural_criteria_ranges_must_be_ONE_catalog_table() raises:
    """One scan leaf, so one table — a cross-table pair would filter rows that
    were never scanned together."""
    var sb = SchemaBuilder()
    sb.add_field(Field("amt", ArrowType.INT64, False))
    var other_schema = sb.build()
    var other = BoundRelation(
        NamedTable(
            String("other"),
            other_schema.copy(),
            SourceVariant(
                ParquetSource(
                    String("/nonexistent/other.parquet"), other_schema.copy()
                )
            ),
        ),
        String("amt"),
    )
    var b2 = _bindings()
    b2.bind_relation(String("amt"), other^)
    var b = build_xl_plan(
        String('COUNTIFS(qty, ">25", amt, ">1")'), b2
    )
    assert_false(b.is_built(), "two tables cannot be filtered as one")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_resident_sumifs_is_the_resident_status() raises:
    var b = build_xl_plan(String('SUMIFS(qty, qty, ">25")'), _resident_bindings())
    assert_false(b.is_built())
    assert_equal(b.status(), XL_BUILD_RESIDENT)


# =============================================================================
# ⭐ CORREL — the BIVARIATE aggregate, and the reachable-but-unbound finding
# =============================================================================


def test_correl_builds_a_two_child_aggregate_over_one_scan() raises:
    """★★ THE WHOLE CHANGE WAS A NAME. `AGG_CORR` had a plan-IR tag, plan-wire
    member 10, a SQL binding and — since a NULL-semantics change on
    2026-09-01 — a working 0-KEY executor arm, which is the arm this plan uses
    and which RAISED before that change. Excel had no name pointing at it.

    The oracle is assembled from `komira_core` alone, so a builder that dropped
    the second child, swapped the two, or built a unary aggregate lands here.

    ⛔⛔ THE ORACLE IS `agg_corr(price, qty)` AND THE FORMULA IS
    `CORREL(qty, price)`. THE SLOTS ARE REVERSED RELATIVE TO THE EXCEL
    ARGUMENT LIST, ON PURPOSE, AS OF 2026-09-15 (slice
    `xl-reachable-unbound`) — this line said `agg_corr(qty, price)` before
    that day and the change is VALUE-NEUTRAL FOR THIS NAME AND LOAD-BEARING
    FOR ITS FAMILY.

    ⚠ THE VALUE CELLS FOR `CORREL` DID NOT MOVE AND ARE THE PROOF THAT THIS IS
    A PLAN-SHAPE CHANGE AND NOT A SEMANTIC ONE —
    `test_the_conditional_aggregates_and_CORREL_agree_with_sql_ON_VALUES`
    still grades 14.5/17.5 through the C door, unedited."""
    var b = build_xl_plan(String("CORREL(qty, price)"), _bindings())
    assert_true(
        b.is_built(), "CORREL over two columns of one table must build: "
        + b.detail(),
    )
    var aggs = AggExprArray()
    aggs.append(agg_corr(col(String("price")), col(String("qty"))))
    assert_equal(
        String(b.take_plan()),
        String(
            LogicalPlan.aggregate(
                ExprArray(),
                aggs^,
                LogicalPlan.scan_from_source(_source(), _schema()),
            )
        ),
        "CORREL(qty, price) did not build AGGREGATE(CORR(price, qty)) <- SCAN"
        " token for token against a plan assembled from komira_core alone."
        " NOTE THE REVERSAL: child slot 0 is the SECOND Excel argument, which"
        " is the engine's bivariate convention -- see this test's docstring"
        " before 'fixing' it by swapping the oracle.",
    )


def test_correl_argument_ORDER_reaches_the_plan() raises:
    """The control for the cell above: `CORREL(qty, price)` and
    `CORREL(price, qty)` must build DIFFERENT plans. A builder that put the
    same column in both slots — or ignored the second argument — passes every
    single-order test."""
    var a = build_xl_plan(String("CORREL(qty, price)"), _bindings())
    var b = build_xl_plan(String("CORREL(price, qty)"), _bindings())
    assert_true(a.is_built() and b.is_built(), "both orders build")
    assert_true(
        String(a.take_plan()) != String(b.take_plan()),
        "the two argument orders built the SAME plan, so one of the two"
        " children is not reaching the AggExpr",
    )


def test_correl_is_not_dispatched_to_the_plain_aggregate_arm() raises:
    """★ THE FAMILY SEPARATION AGAIN, OBSERVED AS A BEHAVIOUR: a TWO-argument
    aggregate builds, which `_build_rel_agg`'s "exactly one relation argument"
    guard cannot do. And a ONE-argument CORREL refuses — it is bivariate."""
    var two = build_xl_plan(String("CORREL(qty, price)"), _bindings())
    assert_true(two.is_built(), "detail: " + two.detail())
    var one = build_xl_plan(String("CORREL(qty)"), _bindings())
    assert_false(one.is_built(), "CORREL needs two ranges")
    assert_equal(one.status(), XL_BUILD_NO_PLAN)


def test_a_cross_table_correl_is_refused() raises:
    """One scan leaf, so one table: the two columns are paired by ROW, and two
    tables have no row correspondence at all. Excel's own CORREL is `#N/A` when
    the arrays differ in size, for the same reason."""
    var sb = SchemaBuilder()
    sb.add_field(Field("amt", ArrowType.INT64, False))
    var other_schema = sb.build()
    var other = BoundRelation(
        NamedTable(
            String("other"),
            other_schema.copy(),
            SourceVariant(
                ParquetSource(
                    String("/nonexistent/other.parquet"), other_schema.copy()
                )
            ),
        ),
        String("amt"),
    )
    var b2 = _bindings()
    b2.bind_relation(String("amt"), other^)
    var b = build_xl_plan(String("CORREL(qty, amt)"), b2)
    assert_false(b.is_built(), "two tables cannot be row-paired")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_a_column_less_correl_range_is_refused() raises:
    """A correlation of one 2D range against another has no meaning here."""
    var b = build_xl_plan(String("CORREL(door, price)"), _bindings())
    assert_false(b.is_built(), "a whole-table range has no column to correlate")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)


def test_build_bivar_agg_plan_needs_no_engine_constructed_at_all() raises:
    """★ THE SIGNATURE IS THE CLAIM, for the fourth builder too."""
    var plan_opt = build_bivar_agg_plan(
        String("CORREL"), _named(String("qty")), _named(String("price"))
    )
    assert_true(Bool(plan_opt), "the bivariate plan builds with no engine")
    assert_true(String(plan_opt.take()).find(String("CORR")) >= 0)


def test_build_bivar_agg_plan_refuses_a_name_that_is_not_bivariate() raises:
    """The guard is `xl_plan_agg_tag(up) != XLA_CORR`, so handing it `SUM`
    returns None rather than building a correlation labelled SUM."""
    var plan_opt = build_bivar_agg_plan(
        String("SUM"), _named(String("qty")), _named(String("price"))
    )
    assert_false(
        Bool(plan_opt),
        "a unary aggregate name must not build a two-child AggExpr",
    )


# =============================================================================
# =============================================================================


def _bivar_oracle(func: UInt8, slot0: String, slot1: String) raises -> String:
    """`Aggregate([], [<func>(slot0, slot1)]) <- Scan(ParquetSource)`, out of
    `komira_core` and nothing else.

    ⚠ `slot0` / `slot1` ARE **CHILD SLOTS**, NOT EXCEL ARGUMENTS, and the
    callers below pass them REVERSED relative to the formula they write. See
    `build_bivar_agg_plan`'s body: slot 0 is the INDEPENDENT variable, which is
    Excel's SECOND argument."""
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(func, col(slot0).copy_expr(), col(slot1).copy_expr(), None)
    )
    return String(
        LogicalPlan.aggregate(
            ExprArray(),
            aggs^,
            LogicalPlan.scan_from_source(_source(), _schema()),
        )
    )


def _built_plan_str(formula: String) raises -> String:
    """`build_xl_plan(formula).take_plan()` rendered — with the `XlPlanBuild`
    bound to a NAME first. ⚠ `take_plan` is `mut self`, so calling it on the
    rvalue of `build_xl_plan(...)` is a COMPILE error; this exists so the cells
    below read as one expression each."""
    var b = build_xl_plan(formula, _bindings())
    assert_true(b.is_built(), formula + String(" did not build: ") + b.detail())
    return String(b.take_plan())


def test_every_bivariate_xla_tag_maps_to_a_bivariate_agg_func() raises:
    """★★ THE CROSS-CHECK BETWEEN TWO FILES THAT MUST AGREE AND CANNOT SEE
    EACH OTHER. `_bivariate_agg_func` maps an Excel `XLA_*` tag onto an
    `AGG_*` code BY HAND; `agg_is_bivariate` (`agg_expr.mojo`) is the
    authority on which `AGG_*` codes fold TWO columns through
    `CorrelationState`. A hand mapping onto a UNIVARIATE code would compile,
    bind, plan, and then fold slot 0 with slot 1 SILENTLY DISCARDED — which is
    the failure `agg_is_bivariate`'s own docstring was written about.

    ⚠ IT WALKS THE CENSUS TABLE RATHER THAN A LIST WRITTEN HERE, so a seventh
    bivariate row added tomorrow is covered without editing this test.

    ⚠ AND IT IS NOT A SET EQUALITY. `agg_is_bivariate` recognises twelve
    codes; Excel names five of them. Asserting equality would demand Excel
    names for `regr_sxx` and friends, which is a different decision."""
    var table = xl_function_table()
    var n_biv = 0
    for i in range(len(table)):
        var row = table[i].copy()
        if row.family != XLF_BIVAR_AGG:
            continue
        n_biv += 1
        var mapped = _bivariate_agg_func(row.agg_tag)
        assert_true(
            Bool(mapped),
            String("census row `") + row.canonical + String(
                "` is XLF_BIVAR_AGG and `_bivariate_agg_func` has no arm for"
                " its XLA tag; `build_bivar_agg_plan` will refuse it as if the"
                " formula were at fault"
            ),
        )
        assert_true(
            agg_is_bivariate(mapped.value()),
            String("census row `") + row.canonical + String(
                "` maps to an AGG code `agg_is_bivariate` does not recognise."
                " A univariate code here folds slot 0 and DISCARDS the second"
                " column -- a plausible number from a well-formed plan."
            ),
        )
    # ⛔ AN EMPTY WALK IS NOT A PASS. If the family ever stops being used the
    # loop above asserts nothing and this file prints green.
    assert_true(
        n_biv >= 7,
        String("only ") + String(n_biv) + String(
            " XLF_BIVAR_AGG rows in the census; CORREL plus the six bound on"
            " 2026-09-15 is seven, so this walk is reading a table it does not"
            " understand and every assertion above it was vacuous"
        ),
    )


def test_the_covariance_pair_are_DIFFERENT_tags_not_an_alias() raises:
    """⛔ THE `var_pop` -> `var_samp` DEFECT SHAPE, CAUGHT AT THE TAG. Excel's
    COVARIANCE.P divides by n and COVARIANCE.S by n-1; the legacy COVAR is the
    POPULATION one. A row aliased onto its neighbour returns a number of the
    right sign and magnitude, so the plan is where it is cheapest to see."""
    assert_equal(xl_plan_agg_tag(String("COVARIANCE.P")), XLA_COVAR_POP)
    assert_equal(xl_plan_agg_tag(String("COVARIANCE.S")), XLA_COVAR_SAMP)
    assert_equal(xl_plan_agg_tag(String("COVAR")), XLA_COVAR_POP)
    assert_true(
        XLA_COVAR_POP != XLA_COVAR_SAMP,
        "the population and sample covariance share a tag, so one of the two"
        " Excel names is computing the other's answer",
    )
    assert_equal(
        _built_plan_str(String("COVARIANCE.P(qty, price)")),
        _bivar_oracle(AGG_COVAR_POP, String("price"), String("qty")),
    )
    assert_equal(
        _built_plan_str(String("COVARIANCE.S(qty, price)")),
        _bivar_oracle(AGG_COVAR_SAMP, String("price"), String("qty")),
    )
    # ⚠ AND THE TWO PLANS MUST DIFFER FROM EACH OTHER. The two oracle
    # comparisons above would BOTH pass if `_bivar_oracle` were broken in the
    # same direction as the builder.
    assert_true(
        _built_plan_str(String("COVAR(qty, price)"))
        != _built_plan_str(String("COVARIANCE.S(qty, price)")),
        "COVAR and COVARIANCE.S built the SAME plan; COVAR is the POPULATION"
        " covariance and COVARIANCE.S is the SAMPLE one",
    )


def test_PEARSON_is_CORREL_by_TAG_and_builds_the_identical_plan() raises:
    """PEARSON and CORREL are documented by Microsoft as the same coefficient.
    ⚠ THE ALIAS IS BY TAG, NOT BY STRING REWRITING: no site rewrites PEARSON to
    CORREL, so this cell is what says the two cannot diverge."""
    assert_equal(xl_plan_agg_tag(String("PEARSON")), XLA_CORR)
    assert_equal(
        _built_plan_str(String("PEARSON(qty, price)")),
        _built_plan_str(String("CORREL(qty, price)")),
    )


def test_SLOPE_and_INTERCEPT_put_the_INDEPENDENT_variable_in_slot_ZERO() raises:
    """⛔⛔ THE ARGUMENT-ORDER CELL, AND IT IS THE ONE THIS TRANCHE CAN GET
    SILENTLY WRONG.

    Excel writes `SLOPE(known_ys, known_xs)` -- DEPENDENT FIRST. The `AggExpr`
    child slots are the other way round: `agg_extended_grouped._ext_finalize`
    states that slot 0 is what `update_bivariate` receives as `x`, i.e. the
    INDEPENDENT variable, which is what makes `st.corr.Sx` equal `regr_sxx`.
    `sql_binder` performs the identical swap.

    ⇒ `SLOPE(qty, price)` must build `REGR_SLOPE(price, qty)`. A pass-through
    answers `C / Sy` instead of `C / Sx` -- a real number of a plausible
    magnitude from a well-formed plan, which no recognition cell can see.

    ⚠ CORREL COULD NOT HAVE PINNED THIS. It, `covar_*` and `regr_r2` are all
    SYMMETRIC in their two arguments; SLOPE and INTERCEPT are the only members
    of the family that can tell."""
    assert_equal(
        _built_plan_str(String("SLOPE(qty, price)")),
        _bivar_oracle(AGG_REGR_SLOPE, String("price"), String("qty")),
    )
    assert_equal(
        _built_plan_str(String("INTERCEPT(qty, price)")),
        _bivar_oracle(AGG_REGR_INTERCEPT, String("price"), String("qty")),
    )
    assert_equal(
        _built_plan_str(String("RSQ(qty, price)")),
        _bivar_oracle(AGG_REGR_R2, String("price"), String("qty")),
    )
    # ⛔ THE CONTROL: the two orders must build DIFFERENT plans. Without it a
    # builder that dropped one argument and used the other twice passes every
    # assertion above.
    assert_true(
        _built_plan_str(String("SLOPE(qty, price)"))
        != _built_plan_str(String("SLOPE(price, qty)")),
        "SLOPE(qty, price) and SLOPE(price, qty) built the SAME plan, so one"
        " of the two children is not reaching the AggExpr",
    )


def test_the_new_bivariate_names_refuse_the_unary_arm_LOUDLY() raises:
    """★ A BIVARIATE NAME REACHING `_agg_expr_for_name` IS A DISPATCH DEFECT,
    NOT A `#NAME?`, and it RAISES rather than returning None.

    ⚠ THE ARM ASKS `_bivariate_agg_func`, NOT `tag == XLA_CORR`. Before
    2026-09-15 it named one tag, and the five added that day would each have
    fallen through to the trailing *"no arm for that tag -- add the arm here"*
    raise, which sends the next reader to build a UNARY aggregate out of a
    bivariate name. This cell drives it through the public builder: a
    ONE-argument call to each of the six must refuse, not build."""
    var names = List[String]()
    names.append(String("COVAR"))
    names.append(String("COVARIANCE.P"))
    names.append(String("COVARIANCE.S"))
    names.append(String("SLOPE"))
    names.append(String("INTERCEPT"))
    names.append(String("RSQ"))
    names.append(String("PEARSON"))
    for i in range(len(names)):
        var one = build_xl_plan(names[i] + String("(qty)"), _bindings())
        assert_false(
            one.is_built(),
            names[i] + String(" built a plan from ONE range; it is bivariate"),
        )
        assert_equal(one.status(), XL_BUILD_NO_PLAN)
    assert_equal(len(names), 7)


def test_a_cross_table_or_column_less_bivariate_is_refused() raises:
    """The same five refusals CORREL has, over the new names -- one scan leaf,
    so one table, and both ranges must carry a COLUMN selector."""
    var b = build_xl_plan(String("SLOPE(door, price)"), _bindings())
    assert_false(b.is_built(), "a whole-table range has no column to regress")
    assert_equal(b.status(), XL_BUILD_NO_PLAN)
    var c = build_xl_plan(String("COVARIANCE.S(qty, price, qty)"), _bindings())
    assert_false(c.is_built(), "bivariate takes exactly two ranges")
    assert_equal(c.status(), XL_BUILD_NO_PLAN)


def test_STEYX_and_FORECAST_are_refused_BY_NAME_at_the_census() raises:
    """⛔ THE GRADED REFUSAL, AT THE LAYER THAT OWNS IT. `regr_sxx` /
    `regr_sxy` / `regr_syy` are fully layered, so STEYX's ARITHMETIC is
    reachable; what is missing is a POST-AGGREGATE SCALAR PROJECTION on this
    door. `build_bivar_agg_plan` emits `AGGREGATE(<one AggExpr>) <- SCAN` and
    the terminal reads one scalar cell, so `sqrt((Syy - Sxy^2/Sxx)/(n-2))` has
    nowhere to live -- and the `n-2` divisor is finalized by no aggregate in
    this tree, so binding it onto a neighbour returns a plausible number."""
    assert_false(Bool(xl_fn_lookup(String("STEYX"))), "STEYX must not be a row")
    assert_false(Bool(xl_fn_lookup(String("FORECAST"))), "FORECAST must not be a row")
    var b = build_xl_plan(String("STEYX(qty, price)"), _bindings())
    assert_false(b.is_built(), "STEYX must not build")
    var c = build_xl_plan(String("FORECAST(qty, price)"), _bindings())
    assert_false(c.is_built(), "FORECAST must not build")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
