# =============================================================================
# test_xl_fn_table.mojo — ★ THE GATE ON THE EXCEL FUNCTION CENSUS.
# =============================================================================
#
# Welded to `komira_xl_plan`, which downstream bindings link —
# so like its sibling `test_xl_plan_build.mojo` it constructs NO
# `EngineContext`, opens no file and reads no fixture. Every assertion is a
# pure function of the table.
#
# ⛔ WHAT THIS FILE IS ACTUALLY FOR. `xl_fn_table.mojo` replaced FOUR
# hand-written ladders over one set of names, in packages that cannot be
# compiled together. The value of that is only real if the table is the ONE
# definition — so the assertions below are about IDENTITY between the table and
# its consumers, not about the table's contents in isolation.
#
# ⚠ AND THE ABSENCE LIST IS ASSERTED IN THE DIRECTION THAT MAKES IT SHRINK.
# `xl_absent_common_names` claims a name does NOT resolve; the day someone
# implements one, this file goes RED and the line is deleted. Red on good news
# is the only thing that keeps an absence list from becoming a lie — the same
# argument `tests/known_failing_targets.txt` makes for itself.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_xl_plan.agg_memo import (
    xl_agg_kind,
    XL_AGG_NONE,
    XL_AGG_SUM,
    XL_AGG_COUNT,
    XL_AGG_MIN,
    XL_AGG_MAX,
    XL_AGG_AVERAGE,
)
from komira_xl_plan.xl_fn_notes import xl_all_notes
from komira_xl_plan.xl_fn_table import (
    XlFnRow,
    xl_function_table,
    xl_fn_lookup,
    xl_plan_agg_tag,
    xl_agg_needs_column,
    xl_absent_common_names,
    xl_function_census,
    xl_family_name,
    XLR_SCALAR,
    XLR_INLINE_REL,
    XLR_PLAN,
    XLF_AGG,
    XLF_BIVAR_AGG,
    XLF_CONDAGG,
    XLF_DYNARRAY,
    XLF_MATH,
    XLF_INFO,
    XLA_CORR,
    xl_plan_reaches,
    xl_plan_family,
    xl_condagg_is_plural,
    XLA_SUM,
    XLA_MEAN,
    XLA_NONE,
    XLA_COUNT,
    XLA_COUNT_NONBLANK,
    XLA_MEDIAN,
    XLA_STDDEV_SAMP,
    XLA_VAR_SAMP,
)


def _names() -> List[String]:
    var t = xl_function_table()
    var out = List[String]()
    for i in range(len(t)):
        out.append(t[i].canonical.copy())
    return out^


def _has(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


# =============================================================================
# The table is well-formed
# =============================================================================


def test_every_name_is_upper_cased_and_unique() raises:
    """Every dispatch site upper-cases before looking up, so a lower-cased row
    would be UNREACHABLE — present in the census and matched by nothing. A
    duplicate row is worse: `xl_fn_lookup` returns the FIRST, so the second
    would be dead with no diagnostic."""
    var t = xl_function_table()
    assert_true(len(t) > 0, "the census table is empty")
    for i in range(len(t)):
        assert_equal(
            t[i].canonical,
            t[i].canonical.upper(),
            "a census row is not upper-cased, so no lookup can ever reach it",
        )
        for j in range(i + 1, len(t)):
            assert_true(
                t[i].canonical != t[j].canonical,
                "duplicate census row for `" + t[i].canonical
                + "`: xl_fn_lookup returns the first and the second is dead",
            )


def test_every_row_has_a_sane_arity_and_at_least_one_reach() raises:
    """A row reaching NOTHING is a name in the census that no surface
    recognises — a claim of support that is false."""
    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        assert_true(
            r.reach != UInt8(0),
            "`" + r.canonical + "` reaches no dispatch surface at all",
        )
        if r.max_arity != UInt8(255):
            assert_true(
                r.min_arity <= r.max_arity,
                "`" + r.canonical + "` has min_arity > max_arity",
            )


def test_every_plan_reaching_row_is_DISPATCHABLE_by_build_xl_plan() raises:
    """`XLR_PLAN` means `build_xl_plan` has an arm for the name, and a row that
    claims it with nothing to dispatch on is a census that promises a verb the
    door will refuse.

    ⚠ THIS ASSERTION USED TO READ *"a plan-reaching row carries an aggregate
    tag"*, AND IT WENT RED ON GOOD NEWS on 2026-09-04 when FILTER became the
    first plan-reaching verb that is NOT an aggregate. The old form was true
    only while `xl_plan_agg_tag != XLA_NONE` doubled as the dispatch predicate
    — which is the exact conflation `xl_plan_reaches` exists to undo. What it
    is really about is DISPATCHABILITY, so that is what it now says.

    ⚠⚠ AND IT IS KEYED ON THE **FAMILY** SINCE 2026-09-04, NOT ON THE TAG.
    `SUMIF` carries `XLA_SUM` as its payload while needing a completely
    different builder, so `agg_tag != XLA_NONE` had stopped meaning "the plain
    aggregate arm serves it". Keeping the old form would have called SUMIF
    dispatchable for the wrong reason, and the row that was actually mis-routed
    would have gone unnoticed.

    The four arms, and they must stay in step with `build_xl_plan`'s:
      * XLF_AGG + an aggregate tag -> `_build_rel_agg`
      * XLF_CONDAGG               -> `_build_cond_agg`
      * XLF_BIVAR_AGG             -> `_build_bivar_agg`
      * XLF_DYNARRAY              -> the per-verb arm (`FILTER` today)
    """
    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        if not r.reaches(XLR_PLAN):
            continue
        var dispatchable = (
            (r.family == XLF_AGG and r.agg_tag != XLA_NONE)
            or r.family == XLF_CONDAGG
            or r.family == XLF_BIVAR_AGG
            or r.family == XLF_DYNARRAY
        )
        assert_true(
            dispatchable,
            "`" + r.canonical + "` claims XLR_PLAN but its FAMILY is not one"
            " `build_xl_plan` has an arm for (or it is XLF_AGG with no"
            " aggregate tag), so the census promises a verb the door will"
            " refuse",
        )
        assert_equal(
            xl_plan_family(r.canonical),
            Int(r.family),
            "xl_plan_family disagrees with the table for `" + r.canonical + "`",
        )
        assert_true(
            xl_plan_reaches(r.canonical),
            "`" + r.canonical + "` has XLR_PLAN in the table and"
            " `xl_plan_reaches` disagrees",
        )


def test_filter_reaches_the_plan_surface_WITHOUT_an_aggregate_tag() raises:
    """★ THE ROW THAT BROKE THE OLD INVARIANT, asserted positively so the
    relaxation above cannot be read as weakening it. FILTER is the second
    extracted ctx-free builder (`rel_filter_build.build_filter_plan`) and the
    first non-aggregate verb the C door can drive."""
    assert_true(xl_plan_reaches(String("FILTER")), "FILTER must reach the door")
    assert_equal(
        Int(xl_plan_agg_tag(String("FILTER"))),
        Int(XLA_NONE),
        "FILTER is not an aggregate; a tag here would send it to _build_rel_agg",
    )
    var row = xl_fn_lookup(String("FILTER")).value().copy()
    assert_true(
        row.reaches(XLR_INLINE_REL),
        "FILTER must keep its INLINE reach — the extraction was a MOVE, so the"
        " evaluator still lowers it and now shares the builder",
    )


def test_a_verb_with_no_extracted_builder_does_not_claim_the_plan_reach() raises:
    """The control for the cell above: the other named arms whose
    builders are not yet extracted are NOT extracted, and a table
    that claimed them would make `build_xl_plan` refuse names its own census
    advertises."""
    for name in [
        String("CHOOSECOLS"), String("GROUPBY"), String("SORT"),
        String("TAKE"), String("MERGE"), String("UNIQUE"),
    ]:
        assert_false(
            xl_plan_reaches(name),
            "`" + name + "` has no extracted ctx-free builder, so it must not"
            " claim XLR_PLAN",
        )


def test_no_note_contains_a_tab_or_newline() raises:
    """The census crosses the C boundary as TSV. A TAB in a note shifts every
    later column of that row; a newline splits it into two rows, one of which
    is not a function."""
    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        var bs = r.note.as_bytes()
        for k in range(len(bs)):
            assert_true(
                bs[k] != UInt8(0x09) and bs[k] != UInt8(0x0A),
                "`" + r.canonical + "`'s note contains a TAB or newline, which"
                " corrupts the TSV census a non-Mojo caller parses",
            )


def test_every_defined_note_is_attached_to_some_row() raises:
    """★ A NOTE THAT NO ROW CARRIES IS PROSE NO CALLER EVER READS, and this
    repo shipped two of them.

    `_plan_only_note` and `_scalar_only_note` were both written, were both
    named BY NAME in `xl_fn_table`'s banner comments — "⚠ SCALAR REACH ONLY,
    AND `_scalar_only_note` SAYS WHY IN THE ROW" — and were attached to ZERO
    rows from the day they were written until 2026-09-04. So the source claimed
    an explanation the rendered TSV did not contain, and a non-Mojo caller
    reading `komira_xl_functions` got an EMPTY note column for ABS, SIGN,
    POWER, SQRT, ROUNDUP and ROUNDDOWN while the code said otherwise.

    ⛔ THE OLD DIRECTION OF CHECKING COULD NOT SEE IT. Every existing assertion
    here walks the TABLE and asks about its rows; a note nothing points at is
    invisible from that side, exactly as `xl_absent_common_names` is invisible
    to a test that only walks resolvable names. This walks the NOTES and asks
    the census about each one — the other direction, which is where the defect
    lived.

    ⚠ IT COMPARES RENDERED TEXT, NOT NAMES. There is no reflection in this
    language, so `xl_all_notes()` is the roster and it is hand-maintained; the
    residual is stated in its own docstring. What this catches is the failure
    that actually happened — a note defined, enrolled, and then attached to
    nothing."""
    var notes = xl_all_notes()
    assert_true(len(notes) > 0, "the note roster is empty; it did not run")
    var census = xl_function_census()
    for i in range(len(notes)):
        assert_true(
            notes[i] in census,
            "a note defined in xl_fn_notes is attached to NO row, so the"
            " census never prints it. Attach it (see `_also`) or delete it —"
            " dead prose in a file whose whole job is prose is the one defect"
            " this file can have. Orphan text begins: "
            + notes[i][byte=0:60],
        )


# =============================================================================
# ★★ THE TABLE IS THE ONE DEFINITION — identity with every consumer
# =============================================================================


def test_xl_plan_agg_tag_agrees_with_the_table_on_every_name() raises:
    """`xl_plan_agg_tag` is what `xl_plan_build._is_rel_agg_name` and
    `rel_agg_build._agg_expr_for_name` both dispatch on. If it could answer
    something the table does not say, the four-ladder problem is back with one
    extra layer of indirection."""
    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        var want = r.agg_tag if r.reaches(XLR_PLAN) else XLA_NONE
        assert_equal(
            Int(xl_plan_agg_tag(r.canonical)),
            Int(want),
            "xl_plan_agg_tag disagrees with the table for `" + r.canonical + "`",
        )


def test_agg_memo_batchable_set_is_exactly_the_full_reach_five() raises:
    """★ THE ASYMMETRY, ASSERTED. The graph lowering batches onto
    `materialize_scalar_agg_plan`, whose envelope is EXACTLY
    SUM/COUNT/MIN/MAX/MEAN — so `xl_agg_kind` must answer a kind for those five
    and `XL_AGG_NONE` for every other name in the table, INCLUDING the
    plan-only aggregates. A batched MEDIAN would reach that terminal and RAISE
    where the un-batched path returns `#NAME?`."""
    assert_equal(xl_agg_kind(String("SUM")), Int(XL_AGG_SUM))
    assert_equal(xl_agg_kind(String("COUNT")), Int(XL_AGG_COUNT))
    assert_equal(xl_agg_kind(String("MIN")), Int(XL_AGG_MIN))
    assert_equal(xl_agg_kind(String("MAX")), Int(XL_AGG_MAX))
    assert_equal(xl_agg_kind(String("AVERAGE")), Int(XL_AGG_AVERAGE))

    var t = xl_function_table()
    for i in range(len(t)):
        var r = t[i].copy()
        if (
            r.family == XLF_AGG
            and r.reaches(XLR_INLINE_REL)
            and r.reaches(XLR_PLAN)
        ):
            continue  # the full-reach five, asserted above
        assert_equal(
            xl_agg_kind(r.canonical),
            XL_AGG_NONE,
            "`" + r.canonical + "` is not a full-reach UNCONDITIONAL aggregate"
            " but xl_agg_kind offered to BATCH it onto a terminal that raises."
            " ⚠ SUMIF/COUNTIF/AVERAGEIF land here when the family guard in"
            " xl_agg_kind is removed: they carry a real aggregate tag and a"
            " shape that terminal refuses",
        )


def test_correl_was_REACHABLE_BUT_UNBOUND_and_now_has_a_name() raises:
    """★★ THE SAME FINDING AS MEDIAN'S, ONE LAYER OVER. `AGG_CORR` already had
    a plan-IR tag, a plan-wire vocabulary member (wire 10 — no vocabulary bump
    was needed for this landing), a SQL binding (`corr`) and a 0-KEY executor
    arm that a NULL-semantics change fixed on 2026-09-01, having found that
    ungrouped `corr(x,y)` RAISED. The only missing layer was an Excel name."""
    assert_equal(Int(xl_plan_agg_tag(String("CORREL"))), Int(XLA_CORR))
    assert_equal(
        xl_plan_family(String("CORREL")),
        Int(XLF_BIVAR_AGG),
        "CORREL must dispatch on the BIVARIATE arm — `_build_rel_agg` reads"
        " ONE relation argument and `_agg_expr_for_name` builds a UNARY"
        " AggExpr, so routing it to XLF_AGG refuses it for its arity",
    )
    var row = xl_fn_lookup(String("CORREL")).value().copy()
    assert_equal(Int(row.min_arity), 2, "CORREL is bivariate")
    assert_equal(Int(row.max_arity), 2, "and exactly bivariate")
    assert_false(
        row.reaches(XLR_INLINE_REL),
        "the inline terminal serves exactly SUM/COUNT/MIN/MAX/MEAN; a CORREL"
        " routed there would RAISE",
    )


def test_the_new_families_all_have_printable_names() raises:
    """A family code with no name renders as an empty census column, which
    reads as a function with no family rather than as a defect. Three families
    were added on 2026-09-04 and each needs an arm in `xl_family_name`."""
    assert_equal(xl_family_name(XLF_MATH), String("math"))
    assert_equal(xl_family_name(XLF_INFO), String("info"))
    assert_equal(xl_family_name(XLF_BIVAR_AGG), String("bivar_agg"))
    var t = xl_function_table()
    for i in range(len(t)):
        assert_true(
            xl_family_name(t[i].family) != String("UNRECOGNISED-FAMILY"),
            "`" + t[i].canonical + "` carries a family code with no name, so"
            " the census renders it as a defect",
        )


def test_the_scalar_breadth_wave_is_present_and_SCALAR_ONLY() raises:
    """★ THE 2026-09-04 BREADTH WAVE, ASSERTED AS A SET. Twenty-eight names
    left the absence list at once; naming them here is what makes the deletion
    from `xl_absent_common_names` checkable rather than a bulk edit nobody can
    review.

    ⚠ AND THEY ARE `XLR_SCALAR` ONLY, WHICH IS A CLAIM ABOUT WHAT THEY CONSUME.
    A row that gained `XLR_PLAN` here would promise the C door a verb
    `build_xl_plan` has no arm for."""
    for name in [
        String("ROUND"), String("ROUNDUP"), String("ROUNDDOWN"), String("ABS"),
        String("INT"), String("SIGN"), String("MOD"), String("POWER"),
        String("SQRT"), String("CEILING"), String("FLOOR"), String("PRODUCT"),
        String("UPPER"), String("LOWER"), String("PROPER"), String("FIND"),
        String("SEARCH"), String("REPLACE"), String("EXACT"), String("VALUE"),
        String("ISBLANK"), String("ISNUMBER"), String("ISTEXT"),
        String("ISLOGICAL"), String("ISERROR"), String("ISNA"), String("NA"),
        String("XOR"),
    ]:
        var row_opt = xl_fn_lookup(name)
        assert_true(Bool(row_opt), "`" + name + "` must resolve")
        var row = row_opt.value().copy()
        assert_true(
            row.reaches(XLR_SCALAR),
            "`" + name + "` must reach the scalar registry",
        )
        assert_false(
            row.reaches(XLR_PLAN),
            "`" + name + "` claims XLR_PLAN and build_xl_plan has no arm for a"
            " scalar function — the census would promise a verb the door"
            " refuses",
        )


def test_TEXT_is_still_absent_and_ISERR_no_longer_is() raises:
    """⛔ THE ABSENCE LIST MUST KEEP NAMING WHAT IS GENUINELY MISSING OR ITS RED
    MEANS NOTHING — and this test is the record of ONE OF ITS TWO ENTRIES
    HAVING BEEN A BAD REASON ALL ALONG.

    `TEXT(value, format)` STANDS: it needs a FORMAT-CODE parser and renderer
    ("0.00", "yyyy-mm-dd", "#,##0;(#,##0)"), and a partial one that handled two
    codes and ignored the rest returns a plausibly-formatted WRONG string,
    which is worse than `#NAME?`. That is a reason — it names a thing that does
    not exist and says what building half of it would cost.

    ⛔ `ISERR`'s DID NOT. It read: "every error EXCEPT #N/A. Deliberately NOT
    aliased onto ISERROR, which includes it." Every word of that is TRUE and it
    is a complete SPECIFICATION of the function, doing duty as an argument for
    not writing it. `xl_isna` already computed `is_error() and error_code ==
    XL_ERR_NA`; `ISERR` was the same three lines with `==` changed to `!=`.
    It landed 2026-09-04.

    ★ THE SHAPE TO RECOGNISE: "not an alias for X" is an argument against ONE
    WRONG IMPLEMENTATION. It is never an argument for absence."""
    var absent = xl_absent_common_names()
    assert_true(_has(absent, String("TEXT")), "TEXT needs a format engine")
    assert_false(Bool(xl_fn_lookup(String("TEXT"))), "TEXT must not resolve")
    assert_false(
        _has(absent, String("ISERR")),
        "★ ISERR left the absence list on 2026-09-04 — a specification is not"
        " a reason",
    )
    assert_true(Bool(xl_fn_lookup(String("ISERR"))), "ISERR resolves now")
    assert_true(Bool(xl_fn_lookup(String("ISERROR"))), "ISERROR does resolve")
    assert_true(Bool(xl_fn_lookup(String("ISNA"))), "and so does ISNA")


def test_lookup_is_case_insensitive_because_a_sheet_sends_what_was_typed() raises:
    assert_true(Bool(xl_fn_lookup(String("sum"))), "`sum` must resolve")
    assert_true(Bool(xl_fn_lookup(String("Median"))), "`Median` must resolve")
    assert_true(Bool(xl_fn_lookup(String("stdev.s"))), "`stdev.s` must resolve")
    assert_false(
        Bool(xl_fn_lookup(String("cherry"))),
        "a name this engine has never heard of must not resolve",
    )


# =============================================================================
# ★ THE WIDENED SET — what 2026-09-04 added, named
# =============================================================================


def test_the_four_new_plan_aggregates_reach_the_plan_surface() raises:
    """MEDIAN / STDEV / VAR / COUNTA were REACHABLE-BUT-UNBOUND: a plan-IR tag,
    a wire vocabulary member, a 0-key executor arm and a SQL binding each, and
    no Excel NAME. This is the assertion that the name now exists."""
    assert_equal(Int(xl_plan_agg_tag(String("MEDIAN"))), Int(XLA_MEDIAN))
    assert_equal(Int(xl_plan_agg_tag(String("STDEV"))), Int(XLA_STDDEV_SAMP))
    assert_equal(Int(xl_plan_agg_tag(String("STDEV.S"))), Int(XLA_STDDEV_SAMP))
    assert_equal(Int(xl_plan_agg_tag(String("VAR"))), Int(XLA_VAR_SAMP))
    assert_equal(Int(xl_plan_agg_tag(String("VAR.S"))), Int(XLA_VAR_SAMP))
    assert_equal(Int(xl_plan_agg_tag(String("COUNTA"))), Int(XLA_COUNT_NONBLANK))


def test_the_dotted_modern_spellings_are_not_the_legacy_ones_by_accident() raises:
    """`STDEV.S` parses as ONE identifier because `formula_parser._is_ident_cont`
    admits `.` (0x2E). That is what makes the modern Excel spellings reachable
    at all — assert it here so a parser change that drops the dot is caught by
    a test that says WHY it mattered, not only by a lookup miss."""
    var dotted = xl_fn_lookup(String("VAR.S"))
    assert_true(Bool(dotted), "the dotted spelling must be a distinct row")
    assert_equal(dotted.value().canonical, String("VAR.S"))


def test_count_is_the_one_aggregate_with_no_column_requirement() raises:
    """★ AND COUNTA IS **NOT**, WHICH IS THE ASYMMETRY WORTH READING TWICE.
    COUNT over a selector-less binding is `count(*)`, the row count of a 2D
    range — legal Excel. A selector-less COUNTA would also be `count(*)`, a
    number that cannot tell a blank from a value, which is the one thing COUNTA
    reports."""
    assert_false(
        xl_agg_needs_column(XLA_COUNT),
        "COUNT must be exempt from the column-selector guard",
    )
    assert_true(
        xl_agg_needs_column(XLA_COUNT_NONBLANK),
        "COUNTA measures blank-vs-not, so a selector-less form is meaningless",
    )
    assert_true(xl_agg_needs_column(XLA_MEDIAN))


# =============================================================================
# ★★ THE ABSENCE LIST — RED ON GOOD NEWS
# =============================================================================


def test_no_absent_name_resolves() raises:
    """⛔ THE INVERSION IS THE POINT. When someone implements `ROUND`, this test
    FAILS, and the fix is to delete the line from `xl_absent_common_names` —
    not to weaken the assertion. An absence list that keeps naming an
    implemented function is the stale-reason failure
    `plan_matrix_doors._NO_0KEY_PANDAS` already cost this tree."""
    var absent = xl_absent_common_names()
    assert_true(len(absent) > 0, "the absence census is empty; it did not run")
    for i in range(len(absent)):
        assert_false(
            Bool(xl_fn_lookup(absent[i])),
            "`" + absent[i] + "` is listed as ABSENT but now RESOLVES. Delete"
            " the line from xl_absent_common_names — the census must not keep"
            " telling a caller that a function it has is missing.",
        )


def test_the_singular_conditional_aggregates_LEFT_the_absence_list() raises:
    """★ RED ON GOOD NEWS, AND THIS IS THE FLIP. This test used to assert that
    SUMIF and COUNTIF were listed ABSENT — the finding being that the PLURAL
    forms existed and the SINGULAR ones did not, which an OP-SPACE census
    cannot see because it reads `conditional aggregate: present`.

    On 2026-09-04 `rel_condagg_build` landed and the assertion INVERTED rather
    than being deleted, because the flip is the evidence: the same names, the
    same file, now asserted present. Deleting it would leave nothing saying the
    gap was ever closed.

    ⚠ `AVERAGEIFS` WENT THE SAME WAY LATER THE SAME DAY. This test's first
    revision asserted it was STILL absent, on the ground that no multi-criteria
    builder existed; generalising the criteria list to an AND-conjunction made
    that false within the hour. The line was FLIPPED rather than deleted, for
    the same reason as the three above."""
    var absent = xl_absent_common_names()
    for name in [
        String("SUMIF"), String("COUNTIF"), String("AVERAGEIF"),
        String("AVERAGEIFS"),
    ]:
        assert_false(
            _has(absent, name), "`" + name + "` is implemented now"
        )
        assert_true(Bool(xl_fn_lookup(name)), "`" + name + "` must resolve")
    assert_true(Bool(xl_fn_lookup(String("SUMIFS"))), "SUMIFS exists")
    assert_true(Bool(xl_fn_lookup(String("COUNTIFS"))), "COUNTIFS exists")


def test_the_PLURAL_conditional_aggregates_gained_a_reach_they_never_had() raises:
    """★ SUMIFS AND COUNTIFS ALREADY EXISTED AND WERE STILL A GAP, which is the
    finding an OP-space census cannot make twice. Their INLINE lowering
    (`fn_rel_condagg`) binds a RESIDENT `RecordBatch` — a leaf that needs an
    engine and that the plan codec refuses BY NAME — so neither had ever been
    drivable from a non-Mojo host. They now carry `XLR_PLAN` as well, over a
    CATALOG table.

    ⚠ AND `AVERAGEIFS` IS PLAN-ONLY, WHICH IS THE ASYMMETRY IN THIS GROUP:
    `fn_rel_condagg` lowers SUMIFS and COUNTIFS only, so there is no inline
    form to claim. A blanket "the plural family reaches both" would advertise a
    verb the evaluator answers with `#NAME?`."""
    for name in [String("SUMIFS"), String("COUNTIFS")]:
        var row = xl_fn_lookup(name).value().copy()
        assert_true(row.reaches(XLR_PLAN), "`" + name + "` must reach the door")
        assert_true(
            row.reaches(XLR_INLINE_REL),
            "`" + name + "` must KEEP its inline reach — the plan arm is an"
            " addition, not a migration, and the resident lowering still runs",
        )
    var avgs = xl_fn_lookup(String("AVERAGEIFS")).value().copy()
    assert_true(avgs.reaches(XLR_PLAN), "AVERAGEIFS reaches the door")
    assert_false(
        avgs.reaches(XLR_INLINE_REL),
        "AVERAGEIFS has NO inline lowering — fn_rel_condagg serves SUMIFS and"
        " COUNTIFS only",
    )
    for name in [
        String("SUMIFS"), String("COUNTIFS"), String("AVERAGEIFS"),
    ]:
        assert_equal(
            xl_plan_family(name),
            Int(XLF_CONDAGG),
            "`" + name + "` must dispatch on the CONDAGG arm",
        )


def test_the_plural_layout_flag_is_the_reversed_argument_order() raises:
    """⛔ EXCEL REALLY DID REVERSE THE ORDER BETWEEN THE TWO FAMILIES, and a
    builder that read one layout for both would AGGREGATE the criteria column
    and FILTER on the value column — a number, confidently wrong, out of a
    well-formed plan.

        SUMIF(crit_range, criteria, [sum_range])     aggregate range LAST
        SUMIFS(sum_range, crit_range, criteria, ...) aggregate range FIRST
    """
    assert_true(xl_condagg_is_plural(String("SUMIFS")))
    assert_true(xl_condagg_is_plural(String("COUNTIFS")))
    assert_true(xl_condagg_is_plural(String("AVERAGEIFS")))
    assert_false(xl_condagg_is_plural(String("SUMIF")))
    assert_false(xl_condagg_is_plural(String("COUNTIF")))
    assert_false(xl_condagg_is_plural(String("AVERAGEIF")))
    assert_true(
        xl_condagg_is_plural(String("sumifs")),
        "a sheet sends whatever the user typed, so the test upper-cases first",
    )
    assert_false(
        xl_condagg_is_plural(String("IF")),
        "a name SHORTER than the suffix must not index out of range",
    )
    assert_false(xl_condagg_is_plural(String("")), "nor must the empty name")


def test_the_singular_conditional_aggregates_are_PLAN_ONLY() raises:
    """⚠ THE ASYMMETRY, ASSERTED, because it is the whole reason the reach is a
    BITMASK. SUMIF's plan is `AGGREGATE <- FILTER <- SCAN`, and BOTH inline
    terminals refuse that shape — `materialize_scalar_agg_plan` requires a BARE
    scan under the aggregate, `materialize_filter_project_plan` refuses an
    aggregate anywhere in the chain. Giving these names `XLR_INLINE_REL` would
    route a formula at a terminal that RAISES, which is strictly worse than the
    clean `#NAME?` the evaluator returns today."""
    for name in [String("SUMIF"), String("COUNTIF"), String("AVERAGEIF")]:
        var row = xl_fn_lookup(name).value().copy()
        assert_true(row.reaches(XLR_PLAN), "`" + name + "` must reach the door")
        assert_false(
            row.reaches(XLR_INLINE_REL),
            "`" + name + "` claims the INLINE relational reach, whose terminal"
            " refuses an aggregate over a filter and would RAISE",
        )
        assert_false(
            row.reaches(XLR_SCALAR),
            "`" + name + "` is inherently relational; it has no scalar form",
        )
        assert_equal(
            xl_plan_family(name),
            Int(XLF_CONDAGG),
            "`" + name + "` must dispatch on the CONDAGG arm",
        )


def test_the_condagg_TAG_is_the_payload_and_the_FAMILY_is_the_arm() raises:
    """★★ THE SEPARATION THAT THE THIRD ARM FORCED, ASSERTED FROM BOTH SIDES.

    `SUMIF` carries `XLA_SUM` — it really does apply a sum, and
    `rel_agg_build._agg_expr_for_name` is what maps that tag, so there is no
    second aggregate ladder. But it is NOT dispatched on that tag: a tag-keyed
    `_is_rel_agg_name` would send it to `_build_rel_agg`, which refuses any
    arity but one. The FAMILY is the arm selector; the TAG is the payload."""
    assert_equal(Int(xl_plan_agg_tag(String("SUMIF"))), Int(XLA_SUM))
    assert_equal(Int(xl_plan_agg_tag(String("AVERAGEIF"))), Int(XLA_MEAN))
    assert_equal(Int(xl_plan_agg_tag(String("COUNTIF"))), Int(XLA_COUNT))
    assert_true(
        xl_plan_family(String("SUMIF")) != xl_plan_family(String("SUM")),
        "SUMIF and SUM carry the same tag and MUST NOT carry the same family,"
        " or one of the two is being built by the wrong arm",
    )
    assert_equal(xl_plan_family(String("SUM")), Int(XLF_AGG))
    # ⚠ THIS CONTROL WAS `SUMIFS` AND IT WENT RED ON GOOD NEWS WITHIN THE HOUR:
    # SUMIFS gained `XLR_PLAN` when the criteria list was generalised to an
    # AND-conjunction. The replacement is a name whose plan-reach is blocked by
    # something no widening of THIS family can lift — `XLOOKUP` binds a
    # RESIDENT batch, whose leaf needs an engine and which the plan codec
    # refuses by name. A control drawn from the "not yet" pile expires the day
    # the pile shrinks.
    assert_equal(
        xl_plan_family(String("XLOOKUP")),
        -1,
        "XLOOKUP binds a resident batch and cannot reach the plan surface, so"
        " it has no arm",
    )
    assert_equal(
        xl_plan_family(String("cherry")),
        -1,
        "a name this engine never heard of has no arm",
    )


# =============================================================================
# The render
# =============================================================================


def test_the_census_render_carries_every_row_and_the_absence_section() raises:
    """The render is what `komira_xl_functions` hands a non-Mojo caller. A row
    lost between the table and the render is a function the census does not
    report — the exact failure this whole file exists to prevent."""
    var text = xl_function_census()
    var names = _names()
    for i in range(len(names)):
        assert_true(
            (names[i] + String("\t")) in text,
            "`" + names[i] + "` is in the table and NOT in the rendered census",
        )
    assert_true(String("#absent\n") in text, "the absence section is missing")
    # ⚠ DERIVED, NOT PINNED, AND IT WENT RED ON GOOD NEWS FIRST. This line read
    # `"ROUND\n" in text` and failed on 2026-09-04 when ROUND was implemented —
    # correctly, but for a reason that has nothing to do with the RENDER, which
    # is this test's subject. A strawman drawn from the "not yet" pile expires
    # the day the pile shrinks; the same lesson `test_an_unknown_aggregate_
    # name_is_refused` records about its own MEDIAN strawman. Every absent name
    # must render, so assert exactly that.
    var absent_render = xl_absent_common_names()
    assert_true(len(absent_render) > 0, "the absence census is empty")
    for i in range(len(absent_render)):
        assert_true(
            (absent_render[i] + String("\n")) in text,
            "`" + absent_render[i] + "` is on the absence list and NOT in the"
            " rendered census, so a caller cannot see the gap",
        )
    assert_true(
        String("+plan") in text or String("plan\t") in text,
        "no row renders the `plan` reach, so a caller cannot grep the set the"
        " C door actually serves",
    )


def test_the_family_namer_is_total_and_says_so_on_an_unknown_code() raises:
    """A family code with no name would render as an empty column, which reads
    as a function with no family rather than as a defect."""
    assert_equal(xl_family_name(UInt8(3)), String("agg"))
    assert_equal(xl_family_name(UInt8(200)), String("UNRECOGNISED-FAMILY"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
