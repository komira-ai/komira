# =============================================================================
# xl_fn_notes.mojo — ★ THE PROSE HALF OF THE EXCEL CENSUS. NOTHING BUT NOTES.
# =============================================================================
#
# Split out of `xl_fn_table.mojo`, when that file passed 946
# lines with the notes at roughly 40% of it. ⚠ THE SPLIT IS A MOVE AND NOTHING
# ELSE: not one character of any note below changed in the commit that created
# this file, so a `git log -p` over the census's prose reads as edits to the
# prose rather than as one wholesale relocation.
#
# ⛔ A NOTE IS NEVER A TODO. It states something TRUE about its row NOW; the
# day it stops being true it is a lie the census PRINTS to a non-Mojo caller
# through `komira_xl_functions`. That is the whole reason these are prose and
# not a status enum — a status word cannot carry "ROUND(2.675,2) is 2.68 in
# Excel and 2.67 here, because 2.675 is not exactly representable".
#
# ⚠ THEY ARE `def`s AND NOT `comptime` STRINGS, and the reason is the 78-column
# wrap: a `comptime` would have to be one literal. Each is read once per census
# render or once per row build, never in a loop.
#
# ⚠⚠ A NOTE DEFINED HERE AND ATTACHED TO NO ROW IS DEAD PROSE THAT NO CALLER
# EVER READS, and it has happened: `_plan_only_note` and `_scalar_only_note`
# are both written, both referenced by NAME in `xl_fn_table`'s banner comments
# ("`_scalar_only_note` SAYS WHY IN THE ROW"), and attached to ZERO rows — so
# the source claims an explanation the rendered TSV does not contain. Measured
# while splitting this file out; at THIS commit nothing asserts
# against it, because the split is a MOVE and the fix is its own change.
#
# This module imports NOTHING, exactly as `xl_fn_table` imports nothing.
#
# Encapsulation rule : `String` values only.
# =============================================================================


def _count_note() -> String:
    return String(
        "Excel COUNT counts NUMERIC cells. Over a selector-less binding (a 2D"
        " range) this lowers to count(*), which counts every row including"
        " nulls. Over a COLUMN binding it lowers to count(<col>), which skips"
        " nulls -- Excel's answer for a numeric column, and SQL's too."
        " FIXED: over a TEXT column Excel COUNT is 0 (a text cell"
        " is not a number) where count(<col>) returned the non-null count; a"
        " TEXT range now lowers to the literal 0 (xl_agg_identity). WARNING --"
        " COUNTIF is NOT this rule and shares this tag: it counts MATCHING"
        " cells of ANY type, so read excel_cond_value_range_is_text before"
        " touching either. Use COUNTA for the non-blank count of any type."
    )


def _counta_note() -> String:
    return String(
        "Excel COUNTA counts NON-EMPTY cells of any type, which over one typed"
        " engine column is exactly count(<col>). It REQUIRES a column"
        " selector: a selector-less COUNTA would be count(*) and could not"
        " tell a blank from a value, which is the only thing COUNTA measures."
    )


def _median_note() -> String:
    return String(
        "DIVERGENCE, and it is the ENGINE's not the binding's: AGG_MEDIAN is"
        " EXACT up to 64 contributing values and APPROXIMATE above it"
        " (first-64 retention -- agg_expr.mojo). Excel's MEDIAN is exact at"
        " every size. The SQL door's median() binds the SAME tag, so the two"
        " surfaces AGREE -- they agree on an answer Excel would not give."
    )


def _sample_stat_note() -> String:
    return String(
        "The SAMPLE statistic (ddof=1) -- Excel's STDEV.S / VAR.S and the"
        " legacy STDEV / VAR, which are the same function. It reaches BOTH"
        " doors: the ctx-free plan builder over a bound column (AGG_VAR_SAMP /"
        " AGG_STDDEV_SAMP) and, since variadic statistics were added, the"
        " scalar evaluator over a"
        " variadic argument list. Its last sentence used to read 'the"
        " POPULATION forms are ABSENT from this table rather than silently"
        " answered with the sample value' and that went FALSE the day the"
        " population forms were served on the scalar door; the surviving half"
        " of the claim is now scoped to the surface it is true of, in"
        " _population_moment_note."
    )


def _population_moment_note() -> String:
    return String(
        "The POPULATION moment (ddof=0): the sum of squared deviations divided"
        " by n, where the sample form divides by n-1. SCALAR-REACH ONLY, and"
        " the asymmetry with STDEV.S / VAR.S is a real property of this engine"
        " rather than an oversight. On the RELATIONAL plan surface the blocker"
        " STANDS and is unchanged: AGG_VAR_POP / AGG_STDDEV_POP exist at the"
        " plan-IR layer but there is no AGG_VAR_POP_F64 engine op,"
        " _merge_agg_cells RAISES on STDDEV_POP because it is not"
        " combine-stable, and ddof cannot ride an already-encoded tag (AggExpr"
        " carries func + children + alias and no options field, so an old"
        " decoder silently returns the SAMPLE statistic). NONE of that is a"
        " property of a variadic argument list, which is why the scalar door"
        " serves these four and the plan door does not. MEASURED: at n=5 the"
        " population and sample variances differ by a factor of 0.8, so a row"
        " wired to the wrong sibling answers a plausible number in the right"
        " units and nothing but its value can tell."
    )


def _devsq_note() -> String:
    return String(
        "A SUM of squared deviations, NOT a mean of them: DEVSQ == VAR.P * n"
        " == VAR.S * (n-1), so every plausible mis-wiring returns a SMALLER"
        " number of the same sign and the same units. Over {1,2,3} DEVSQ is 2"
        " where VAR.P is 0.667 and VAR.S is 1. AVEDEV is the sibling that"
        " divides AND drops the square -- the mean of |x - mean| -- which over"
        " the same three values is 0.667, numerically equal to VAR.P there by"
        " coincidence and not by identity; the corpus carries a second input"
        " where the two separate."
    )


def _nonarith_mean_note() -> String:
    return String(
        "A NON-ARITHMETIC mean, and the family's hazard is that all three lie"
        " between MIN and MAX and all three are BELOW the arithmetic mean for"
        " any non-constant positive data: HARMEAN <= GEOMEAN <= AVERAGE, with"
        " equality only when every value is the same. So a fixture of equal"
        " values cannot tell the three apart at all. Over {1,2,4} they are"
        " 1.714, 2 and 2.333. BOTH refuse with #NUM! when any value is <= 0,"
        " which is the function rather than an edge case: a geometric mean"
        " over a set containing a negative is not real, and a harmonic mean"
        " over one containing a negative can fall OUTSIDE the data range."
    )


def _shape_moment_note() -> String:
    return String(
        "A SHAPE moment, where the SCALING is the answer. SKEW is Excel's"
        " SAMPLE skewness n/((n-1)(n-2)) * sum(((x-mean)/s)^3) with s the"
        " SAMPLE deviation; SKEW.P (ODF spells it SKEWP) is the POPULATION"
        " form (1/n) * sum(((x-mean)/sigma)^3). BOTH the outer factor and the"
        " deviation inside the cube change, so the ratio is sqrt(n(n-1))/(n-2)"
        " -- 1.4907 at n=5, never 1 -- and a row wired to its sibling answers"
        " the same SIGN and the same order of magnitude. KURT is the EXCESS"
        " kurtosis: its documented form ends in a subtraction of"
        " 3(n-1)^2/((n-2)(n-3)) -- 8 at n=5, NOT 3 -- so the normal reference"
        " is 0, and a kernel that dropped the correction answers 11.152 where"
        " this answers 3.152 over {1,2,3,4,10}: still positive, still a"
        " kurtosis. All three are #DIV/0! when the sample"
        " is too small (n<3, n<3, n<4) or the deviation is zero -- Excel's"
        " answer, not #NUM! and not 0."
    )


def _plan_only_note() -> String:
    return String(
        "PLAN-ONLY, deliberately. The inline relational path's terminal is"
        " materialize_scalar_agg_plan, whose declared envelope is EXACTLY ONE"
        " SUM/COUNT/MIN/MAX/MEAN and which RAISES on anything else by design;"
        " routing this name there would turn a clean #NAME? into a Mojo"
        " exception. Through the C door it runs on materialize_plan, the"
        " general walker, which serves it."
    )


def _filter_note() -> String:
    return String(
        "The FIRST non-aggregate verb to reach the plan surface:"
        " rel_filter_build.build_filter_plan is the second extracted ctx-free"
        " builder. Envelope: FILTER(<name>, <col> <cmp> <literal>) where both"
        " names are bound to the SAME catalog table. DIVERGENCE FROM EXCEL:"
        " Excel FILTER takes an if_empty third argument and admits array"
        " conditions with AND/OR; this envelope is ONE comparison against a"
        " NUMERIC or TEXT literal, and a TEXT comparison is CASE-INSENSITIVE"
        " (Excel's rule, shared with the conditional aggregates through"
        " xl_text_compare.excel_comparison). The fold is FULL UNICODE on both"
        " sides: operand and column go through one function"
        " (komira_core.eval.unicode_case.unicode_lower_bytes, which is what the"
        " column's STRFN_LOWER kernel calls), so a NON-ASCII operand compares"
        " correctly. It was REFUSED when the fold first landed, because the"
        " operand fold was ASCII while the column's was Unicode and two"
        " disagreeing folds lose rows silently; moving the case table into"
        " komira_core left ONE fold and removed the refusal."
        " A DATE literal is not expressible -- an"
        " Excel formula writes a date as DATE(y,m,d), which is a CALL and not"
        " a literal node, so a ctx-free builder cannot fold it."
    )


def _now_note() -> String:
    return String(
        "VOLATILE, and DIVERGENT FROM EXCEL IN A STRUCTURAL WAY rather than by"
        " rounding: Excel's NOW() is a date PLUS a fractional time of day, and"
        " this engine has no clock -- SemanticsProfile captures ONE INTEGER at"
        " bind time, the same value TODAY() returns. So NOW() here is always"
        " midnight and NOW()-TODAY() is 0 where Excel gives the fraction of the"
        " day elapsed. An uncaptured serial is #VALUE!, never a guess."
        " ⚠ THIS ROW USED TO END BY SAYING HOUR / MINUTE / SECOND / TIME ARE"
        " ABSENT FOR THE SAME REASON. That was a category error and all four"
        " landed: TIME reads no serial at all (it PRODUCES a"
        " fraction from three arguments) and the other three are pure"
        " functions of whatever value they are handed. The clock degrades"
        " exactly ONE call shape -- HOUR(NOW()) is 0 here -- which is this"
        " row's divergence and not theirs."
    )


def _weekday_note() -> String:
    return String(
        "THREE return types, disagreeing on BOTH the origin and the first day:"
        " 1 (default) Sun=1..Sat=7; 2 Mon=1..Sun=7; 3 Mon=0..Sun=6. A kernel"
        " serving only the default is wrong for two thirds of real callers."
        " It round-trips through the CALENDAR rather than taking serial % 7,"
        " because Excel's serial 60 is the phantom 1900-02-29 -- a day that"
        " never existed -- so the serial-to-weekday relation is not a fixed"
        " modulus across it."
    )


def _edate_note() -> String:
    return String(
        "The day-of-month is CLAMPED to the target month's length, not rolled"
        " over: EDATE(2026-01-31, 1) is 2026-02-28, not 2026-03-03. The serial"
        " builder is linear day arithmetic and rolls an overflow FORWARD, so"
        " the clamp has to happen before the serial is built."
    )


def _days_note() -> String:
    return String(
        "Argument order is END then START -- DAYS(a,b) is a-b -- which is the"
        " reverse of what most people write first, and it is Excel's. It"
        " subtracts SERIALS, not true day counts, so across the Lotus phantom"
        " day the two disagree by one: serial 61 minus serial 59 is 2 while"
        " 1900-03-01 is only ONE day after 1900-02-28. Excel answers 2 as well;"
        " the disagreement with the calendar is Excel's, reproduced faithfully."
    )


def _scalar_only_note() -> String:
    return String(
        "SCALAR reach only, and that is a statement about WHAT IT CONSUMES"
        " rather than a missing feature: it computes over ARGUMENT VALUES, not"
        " over an engine column. So `ROUND(qty)` where `qty` names a"
        " million-row relation is NOT a vectorised round -- there is no plan"
        " node for it. What DOES work, and is the common spreadsheet shape, is"
        " a scalar wrapped around a relational aggregate: `ROUND(SUM(revenue),"
        " 2)` evaluates SUM through the relational path and rounds the one"
        " value it returns."
    )


def _round_note() -> String:
    return String(
        "HALF AWAY FROM ZERO, which is Excel's rule and NOT the IEEE"
        " half-to-even that a language `round()` gives you: ROUND(2.5,0) is 3"
        " here and 2 under half-to-even. ⛔ THIS NOTE NAMED THE WRONG INPUT"
        " AND THE CORRECTION IS THE FINDING: it used to publish"
        " 2.675 as the binary-vs-decimal divergence, and MEASURED the two"
        " readings AGREE there at 2.68, because 2.675*100 rounds UP to exactly"
        " 267.5 in binary64. A divergence stated at an input where the engine"
        " is RIGHT hides the one where it is wrong, and the value cell"
        " carrying it was annotated EXPECTED RED while passing. THE REAL ONE"
        " IS ROUND(1.005,2): 1 here and 1.01 in Excel, because 1.005*100 is"
        " 100.49999999999999. This rounds the BINARY double; Excel rounds its"
        " 15-significant-decimal-digit representation. No epsilon closes it --"
        " ROUND(1.0049999,2) is 1 in Excel too and this engine already gets"
        " that right, so a fix must separate two inputs whose doubles differ"
        " by 1e-7. ⚠ AND THE TIE TEST IS floor(x+0.5) DELIBERATELY: the"
        " textbook fraction test answers 0 for ROUND(0.49999999999999994,0)"
        " where EXCEL ANSWERS 1 (its 15-digit reading of that double is"
        " exactly 0.5), and over 400000 random (x,digits) pairs the two"
        " spellings never differed anywhere else. MROUND shares the rule and"
        " now shares the one implementation."
    )


def _int_note() -> String:
    return String(
        "INT FLOORS; it does not truncate. INT(-3.5) is -4, where a C-style"
        " cast to integer gives -3. The divergence is invisible until a"
        " negative value appears in the data. ROUNDDOWN(x,0) is the truncating"
        " one."
    )


def _mod_note() -> String:
    return String(
        "The result takes the DIVISOR's sign, like Python's % and UNLIKE C's"
        " fmod, which takes the dividend's: MOD(-3,2) is 1 in Excel and -1 in"
        " C. Excel defines it as n - d*INT(n/d), and that INT is a FLOOR --"
        " which is the whole mechanism. A zero divisor is #DIV/0!."
    )


def _ceiling_note() -> String:
    return String(
        "Significance is REQUIRED (arity 2), which is Excel's own arity;"
        " CEILING.MATH is the permissive one-argument form and is NOT"
        " registered, because a surface more permissive than the thing it"
        " emulates cannot be checked against it. Six sign cases: away from zero"
        " when number and significance share a sign, toward zero when they do"
        " not, 0 for a zero significance, and #NUM! for a POSITIVE number with"
        " a NEGATIVE significance."
    )


def _product_note() -> String:
    return String(
        "BLANKS ARE SKIPPED, not coerced to 0 -- a blank coerces to 0 in"
        " arithmetic, so coercing every argument would make any product"
        " containing an empty cell 0. A product of NO non-blank arguments is 0,"
        " which is Excel's answer and not the multiplicative identity."
        " SCALAR-REACH ONLY. CORRECTED: this note said 'NO PLAN-IR"
        " TAG: there is no AGG_PRODUCT' and that had gone FALSE --"
        " AGG_PRODUCT is tag 30 in agg_expr.mojo, with a plan_wire_vocabulary"
        " member, a LogicalPlan arm, a grouped executor arm and a SQL binding."
        " WHAT IS ACTUALLY MISSING IS THE 0-KEY ARM: agg_scalar_fold.mojo does"
        " not name AGG_PRODUCT at all, and a ctx-free Excel aggregate plan is"
        " exactly the 0-key shape, so binding the name on the strength of the"
        " tag would reach a fold that declines. A refusal has to name the layer"
        " its blocker is a property of; this one named the wrong layer and"
        " would have sent the next reader to add a tag that is already there."
    )


def _search_note() -> String:
    """⛔ THE DIVERGENCE THIS NOTE USED TO RECORD IS CLOSED, and
    the sentence that recorded it is gone rather than softened. It read
    *"Excel's SEARCH also accepts the WILDCARDS * and ?, and this kernel
    searches for the literal characters instead ... written down rather than
    resolved"* — true when written, and its oracle cell carried `xl_agrees = N`
    on that citation. The kernel now implements the wildcards, the cell is
    graded against EXCEL, and a new cell covers the `~` escape."""
    return String(
        "CASE-INSENSITIVE, where FIND is case-SENSITIVE, and WILDCARD-AWARE,"
        " where FIND is literal -- those are the two differences between the"
        " pair and they are why both exist. * matches any run, ? any single"
        " character, and ~ escapes either (or itself), so SEARCH(\"~*\",\"a*b\")"
        " is 2 while SEARCH(\"*\",\"a*b\") is 1. Positions are CHARACTER"
        " positions, not byte offsets."
    )


def _textba_note() -> String:
    return String(
        "TEXTBEFORE/TEXTAFTER partition the text around the Nth occurrence of"
        " a delimiter. instance_num NEGATIVE counts from the END; match_mode 1"
        " is case-INSENSITIVE; match_end 1 makes the end of the text count as"
        " an occurrence; a delimiter that is not found is #N/A unless"
        " if_not_found is supplied, and instance_num 0 is #VALUE!."
        " DIVERGENCE: an EMPTY delimiter is treated as NOT FOUND here (so the"
        " if_not_found path), because Excel's published description states no"
        " rule for it and inventing one would return a confident answer to an"
        " undefined formula. The ARRAY form of delimiter is not expressible on"
        " the scalar door."
    )


def _valuetotext_note() -> String:
    return String(
        "format 0 (CONCISE, the default) renders as a cell displays; format 1"
        " (STRICT) quotes TEXT and doubles an internal quote, leaving numbers"
        " and logicals alone. Any other format is #VALUE!. DIVERGENCE: an"
        " ERROR argument PROPAGATES here, where Excel RENDERS it as its text"
        " (Excel's VALUETOTEXT(#N/A) is the text #N/A). Rendering would mean"
        " fixing the strict-form spelling of every error value, and a wrong"
        " one is a plausible string, so the row propagates and says so."
    )


def _address_note() -> String:
    return String(
        "A reference FORMATTER, not a reference: numbers in, text out, which"
        " is why it is the one Lookup-and-reference member the scalar door can"
        " serve. abs_num 1=$C$2 2=C$2 3=$C2 4=C2 -- 2 and 3 are named after"
        " the ROW's state, so 2 puts the $ on the ROW. a1=FALSE selects R1C1,"
        " where brackets mean RELATIVE. Column letters are BIJECTIVE base-26"
        " (26=Z, 27=AA, 702=ZZ, 703=AAA). row/column below 1 or past the"
        " worksheet ceiling (1048576 x 16384), or abs_num outside 1..4, is"
        " #VALUE! -- a refusal, never a clamp. A sheet name that is not a bare"
        " identifier is single-quoted with any internal quote doubled."
    )


def _hyperlink_note() -> String:
    return String(
        "The VALUE is the friendly_name; the jump is a UI behaviour this"
        " engine has no surface for, and that is not a reason to refuse the"
        " name -- every downstream consumer of the cell (a filter, a join key,"
        " LEN) sees the friendly name, and answering the LINK instead would"
        " put a different string into all of them. With friendly_name omitted"
        " or empty the value IS the link, which is the one case where the two"
        " readings coincide."
    )


def _exact_note() -> String:
    return String(
        "CASE-SENSITIVE equality, and it exists because Excel's own = on text"
        " is case-INSENSITIVE: \"a\"=\"A\" is TRUE in a sheet, EXACT(\"a\",\"A\")"
        " is FALSE. A case-insensitive implementation would make this a synonym"
        " for = and delete the only way a sheet can ask the question."
    )


def _istype_note() -> String:
    return String(
        "A TYPE test, NOT a coercibility test. ISNUMBER(\"3\") is FALSE in"
        " Excel even though \"3\"+2 is 5 -- the implicit text-to-number"
        " coercion happens in an ARITHMETIC context and this is not one. The"
        " whole IS* family is ERRH_MANUAL: it INSPECTS error values, so"
        " ISERROR(1/0) is TRUE rather than #DIV/0!."
    )


def _isblank_note() -> String:
    return String(
        "TRUE only for the BLANK member of the value lattice. ISBLANK(\"\") is"
        " FALSE -- an empty cell and a cell holding a zero-length string are"
        " different things, and FormulaValue carries FV_BLANK separately from"
        " FV_TEXT precisely so this function can tell them apart."
    )


def _xor_note() -> String:
    return String(
        "PARITY, not \"exactly one\": XOR(TRUE,TRUE,TRUE) is TRUE. The two"
        " definitions agree at arity 2, which is the arity everyone tests, so"
        " \"exactly one\" survives a two-argument suite intact."
    )


def _correl_note() -> String:
    return String(
        "REACHABLE-BUT-UNBOUND until its Excel name was bound: AGG_CORR had a"
        " plan-IR tag, a"
        " plan-wire vocabulary member (wire 10), a 0-KEY executor arm (an ungrouped corr used to raise) and"
        " a SQL binding (`corr`). What was missing was the Excel NAME."
        " BIVARIATE, so both ranges must be COLUMNS OF THE SAME catalog table:"
        " this plan has one scan leaf and pairs the two columns by ROW, which"
        " is what Excel's positional pairing means over a table."
        " DIVERGENCE FROM EXCEL AT THE DEGENERATE SIZES, and it is the"
        " ENGINE's: over ONE pair DuckDB (and this engine) return a non-NULL"
        " NaN and over zero rows NULL, where Excel returns #DIV/0!. The 0-key"
        " vocabulary test measured that NaN against DuckDB deliberately -- a"
        " `count <= 1` arm shared with STDDEV/VAR would turn a"
        " DuckDB-MATCHING NaN into a NULL."
    )


def _condifs_note() -> String:
    return String(
        "MULTI-CRITERIA, and its two reaches answer DIFFERENT questions."
        " INLINE (SUMIFS/COUNTIFS only) binds a RESIDENT RecordBatch through"
        " fn_rel_condagg. PLAN lowers AGGREGATE <- FILTER(c1 AND c2 AND ...) <-"
        " SCAN over a CATALOG TABLE, which is the reach a non-Mojo host can"
        " drive and which the plural forms originally did not have."
        " ARGUMENT ORDER IS EXCEL'S AND IT DIFFERS FROM THE SINGULAR FORMS:"
        " the plural forms put the aggregate range FIRST (SUMIFS(sum_range,"
        " crit_range1, crit1, ...)) where SUMIF puts it LAST and optional."
        " COUNTIFS has no aggregate range at all -- it counts the rows the"
        " criteria select. EVERY range must be a column of the SAME catalog"
        " table: this plan has ONE scan leaf, and Excel's own requirement that"
        " the ranges be the same size is the same constraint. The four"
        " criteria divergences are SUMIF's -- see the singular rows."
    )


def _condif_note() -> String:
    return String(
        "PLAN-ONLY. The plan is AGGREGATE <- FILTER <- SCAN, and BOTH inline"
        " terminals refuse it -- materialize_scalar_agg_plan requires a BARE"
        " scan under the aggregate and materialize_filter_project_plan refuses"
        " an aggregate anywhere in the chain (fn_rel_dynarray."
        "lower_agg_over_filter records both). The C door runs on"
        " materialize_plan, the general walker, which serves it."
        " DIVERGENCES FROM EXCEL -- TWO fixed, ONE still live (AVERAGEIF over"
        " an empty match), two REFUSED by design, and none of them resolved by"
        " picking a side: (1) a WILDCARD criteria"
        " (*, ?) is REFUSED, not"
        " compared literally -- a literal compare answers a different question"
        " and returns a confident wrong number; (2) FIXED -- Excel"
        " text criteria are CASE-INSENSITIVE and the engine's string equality"
        " is byte-exact, so a TEXT criteria now lowers to lower(<col>) OP"
        " <folded literal> and `\"acme\"` DOES match `ACME`. ⚠ THAT FIX SHIPPED"
        " WITH AN ASCII-ONLY OPERAND FOLD AND A NON-ASCII REFUSAL; the refusal"
        " is GONE as of the same day -- the Unicode simple case table moved"
        " into komira_core.eval, so operand and column are folded by ONE"
        " function and `\"CAFÉ\"` matches `café`; (3) over ZERO matching rows"
        " Excel SUMIF is 0 and AVERAGEIF is #DIV/0! where a SQL aggregate is"
        " NULL. SUMIF is FIXED -- the lowering wraps the aggregate"
        " in CASE WHEN <a> IS NULL THEN 0 ELSE <a> END (xl_agg_identity),"
        " exact because a 0-key SUM is NULL precisely when it had no non-null"
        " input; COUNTIF was already 0 via count(*). AVERAGEIF is STILL NULL:"
        " an Excel ERROR VALUE has no columnar carrier (see komira_core.plan."
        "excel_error_code, which calls the status lane + sidecar a mapped"
        " follow-up frontier) and a plan's output type is fixed before the"
        " first row is read, so #DIV/0! is not expressible at this door --"
        " registered as a measured divergence, not rounded to 0;"
        " (4) `<>` and `=` with no operand are Excel's non-blank / blank tests"
        " and are REFUSED rather than compared against the empty string."
    )


def _dynarray_note() -> String:
    return String(
        "RELATION-returning, lowered by fn_rel_dynarray.try_dynarray_relation"
        " -- a ROOT-LEVEL router, not the FnRegistry. Its plan builder is"
        " still inside the lowering that executes it, so build_xl_plan refuses"
        " it by name; extracting its builder would let it be refused no longer."
    )


def _resident_note() -> String:
    return String(
        "Binds a RESIDENT RecordBatch, whose leaf is from_record_batch_typed"
        "(ctx, ...). There is no ctx-free builder for it EVEN IN PRINCIPLE and"
        " the plan codec refuses the source by name"
        " (PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY)."
    )


def _volatile_note() -> String:
    return String(
        "VOLATILE. With no recalc layer and no wall clock in the engine, the"
        " serial is captured ONCE at bind time into SemanticsProfile; an"
        " uncaptured TODAY() is #VALUE! rather than a guess."
    )


# =============================================================================
# ★ THE NUMERIC / TIME-OF-DAY WAVE.
#
# ⚠ EVERY NOTE BELOW STATES A DIVERGENCE THAT IS **SILENT** — a wrong answer
# that is a plausible finite number, not an error. That is the selection rule
# for what gets a note at all.
# =============================================================================
def _radians_note() -> String:
    return String(
        "THE ARGUMENT IS IN RADIANS, which is Excel's convention and the one"
        " every spreadsheet user gets wrong first: SIN(30) is -0.988, not 0.5."
        " SIN(RADIANS(30)) is 0.5. There is no degrees mode and Excel has none"
        " either. Computed through libm, the same library the SQL surface's"
        " sin/cos/tan reach, so the two doors agree bit for bit."
    )


def _atan2_note() -> String:
    return String(
        "⛔ EXCEL'S ARGUMENT ORDER IS THE REVERSE OF C'S AND OF THIS REPO'S OWN"
        " SQL atan2. Excel is ATAN2(x, y); libm and komira SQL are"
        " atan2(y, x). The kernel crosses the indices deliberately."
        " A swapped implementation is not a crash and not an error value:"
        " ATAN2(1,0) is 0 here (the point (1,0) lies along +x) and a swapped"
        " kernel answers pi/2; ATAN2(0,1) is pi/2 and a swapped kernel answers"
        " 0. ⚠ THE DIRECTION OF THAT SENTENCE USED TO BE BACKWARDS IN THIS"
        " FILE, on the one row the table calls LOAD-BEARING FOR"
        " CORRECTNESS -- it read 'ATAN2(1,0) would answer 0 instead of pi/2',"
        " which names the CORRECT answer as the bug. The executable statement"
        " is test_atan2_takes_EXCELS_argument_order_which_is_the_REVERSE_of_C."
        " ATAN2(1,1) answers the SAME 0.785 either way -- the diagonal is"
        " exactly where the bug hides and is the first case anybody tests."
        " ⚠ A CROSS-SURFACE CELL"
        " CANNOT CATCH IT EITHER: the SQL door and the Excel door take their"
        " arguments in opposite orders BY SPECIFICATION, so a matrix cell"
        " feeding both the same pair and comparing outputs is asserting that"
        " the bug exists. ATAN2(0,0) is #DIV/0! in Excel where C returns 0."
    )


def _log_note() -> String:
    return String(
        "TWO ARGUMENTS IN EXCEL AND THE BASE DEFAULTS TO 10 -- LOG(n, [base])"
        " -- where this repo's SQL surface has a ONE-argument base-10 log and"
        " most languages' log is the NATURAL one. Two ways to get it silently"
        " wrong, pointing opposite ways: forwarding to ln makes LOG(100)"
        " answer 4.605 instead of 2, and ignoring the second argument makes"
        " LOG(8,2) answer 0.903 instead of 3. Both are plausible positive"
        " numbers. DIVERGENCE, STATED RATHER THAN VERIFIED: base <= 0 is #NUM!"
        " and base = 1 is #DIV/0! here, which is this kernel's reading of"
        " Excel's LN(n)/LN(base) decomposition and is not checked against a"
        " live Excel. A caller sees a REFUSAL either way; only the code could"
        " differ."
    )


def _log_domain_note() -> String:
    return String(
        "THE DEGENERATE INPUTS ARE ERRORS, NOT libm's NUMBERS, and that is the"
        " whole reason this is a kernel rather than a forward. LN(0) is #NUM!"
        " in Excel where C's log(0.0) is -inf, and LN(-1) is #NUM! where C"
        " gives NaN. Both C answers are Float64 values that KEEP TRAVELLING:"
        " -inf compares, sorts and sums; NaN makes every comparison above it"
        " FALSE without raising anything. ⚠ AN ALL-POSITIVE FIXTURE CANNOT"
        " TELL THIS GUARD FROM ITS ABSENCE."
    )


def _exp_note() -> String:
    return String(
        "⛔ FIXED, AND THE OLD NOTE IS KEPT AS THE SHAPE OF A BAD"
        " REASON. It read: 'DIVERGENCE AT OVERFLOW: EXP(1000) is +inf here and"
        " #NUM! in Excel. Refusing on isinf would be the closer answer and is"
        " deliberately NOT taken, because it cannot distinguish an overflow"
        " from a caller who passed +inf in on purpose.' Both halves were wrong."
        " A caller CANNOT pass +inf in: the formula grammar has no infinity"
        " literal and coerce_number refuses a text that parses to one, so an"
        " overflowing computation is the only way a non-finite double is ever"
        " constructed. And the +inf did not travel as +inf -- MEASURED, EXP"
        " (1000) RENDERED AS -9223372036854775808, a plausible finite NEGATIVE"
        " integer, with ISNUMBER answering TRUE on it, because Int64(inf) is an"
        " undefined conversion the optimiser folded. Six other kernels rendered"
        " the same lie (POWER, SUMSQ, PRODUCT, SINH, COSH, MROUND). EXP(1000)"
        " is now #NUM!, which is Excel's answer, and the refusal is in"
        " FormulaValue.number so no kernel can re-open it."
    )


def _trunc_note() -> String:
    return String(
        "TRUNCATES TOWARD ZERO, where INT FLOORS -- TRUNC(-8.9) is -8 and"
        " INT(-8.9) is -9. The two agree on every POSITIVE value, so a fixture"
        " with no negative numbers cannot tell these two functions apart at"
        " all. Excel ships both TRUNC and ROUNDDOWN, which compute the same"
        " thing; they are registered separately rather than aliased so that"
        " the day one gains a semantic the other lacks is a diff and not a"
        " silent divergence."
    )


def _even_odd_note() -> String:
    return String(
        "AWAY FROM ZERO TO THE NEXT INTEGER OF THAT PARITY -- it is NOT a"
        " round-to-nearest-even. EVEN(3) is 4 (an odd integer input is"
        " CHANGED), EVEN(2) is 2, EVEN(-1.5) is -2 because away from zero on"
        " the negative side means DOWN. ODD(0) is 1: zero is the one input"
        " where the rule has no direction and Excel picks +1. An"
        " implementation built on IEEE round-half-to-even gets every one of"
        " those wrong."
    )


def _quotient_note() -> String:
    return String(
        "⛔ IT TRUNCATES TOWARD ZERO WHILE MOD FLOORS, SO THE DIVISION IDENTITY"
        " DOES NOT HOLD IN EXCEL: QUOTIENT(-5,2) is -2 and MOD(-5,2) is 1, so"
        " QUOTIENT(n,d)*d + MOD(n,d) is -3 and not -5. That is Excel's own"
        " inconsistency, faithfully reproduced -- making the two agree would"
        " require picking one of them to be wrong. A zero denominator is"
        " #DIV/0!."
    )


def _inverse_trig_note() -> String:
    return String(
        "THE DOMAIN IS [-1, 1] AND OUTSIDE IT IS #NUM!, NOT NaN. C's asin(2.0)"
        " is NaN, a Float64 that keeps travelling and makes every comparison"
        " above it FALSE without raising. The result is in RADIANS."
    )


def _parity_note() -> String:
    return String(
        "TRUNCATES TOWARD ZERO BEFORE TESTING PARITY, it does not floor:"
        " ISEVEN(-1.5) truncates to -1 and is FALSE, where a floor would give"
        " -2 and answer TRUE. ⛔ AND ITS ERROR CLASS IS DOMINANCE, NOT THE"
        " ERRH_MANUAL THE REST OF THE IS* FAMILY USES: ISERROR/ISNA/ISBLANK"
        " exist to LOOK AT a value, so an error argument is their subject"
        " matter, while ISODD asks an ARITHMETIC question and Excel's"
        " ISODD(1/0) is #DIV/0!. Registering these two alongside their"
        " alphabetical neighbours would make ISODD(1/0) answer FALSE -- a"
        " confident boolean where Excel refuses."
    )


def _iserr_note() -> String:
    return String(
        "EVERY ERROR EXCEPT #N/A -- the third member of the error-predicate"
        " triple, and NOT an alias for ISERROR, which includes #N/A. The"
        " triple PARTITIONS the value space and that partition is what a test"
        " has to assert: over #N/A it is (ISERROR TRUE, ISNA TRUE, ISERR"
        " FALSE); over #DIV/0! it is (TRUE, FALSE, TRUE); over a plain number"
        " all three are FALSE. A kernel that just returned is_error() passes"
        " any test that only feeds it #DIV/0! and a number. It was ABSENT at"
        " first, on a stated reason that was a complete SPECIFICATION of"
        " the function being used as an argument for not writing it."
    )


def _time_note() -> String:
    return String(
        "RETURNS A FRACTION OF A DAY IN [0,1) AND READS NO SERIAL AND NO"
        " CLOCK: TIME(h,m,s) is (h*3600 + m*60 + s)/86400, a pure function of"
        " three arguments that PRODUCES a fraction rather than consuming one."
        " IT WRAPS AT 24 HOURS RATHER THAN REFUSING, which is Excel's rule:"
        " TIME(27,0,0) is 03:00 = 0.125, not #NUM!. Minutes and seconds beyond"
        " their ranges carry upward first, so the wrap applies ONCE to the"
        " total and not per field. A NEGATIVE component is #NUM! -- Excel"
        " refuses rather than borrowing, so TIME(1,-30,0) is an error and not"
        " 00:30. There is no date part; TIME(13,30,0)+DATE(2026,1,1) is the"
        " composition that builds a timestamp."
    )


def _time_of_day_note() -> String:
    return String(
        "READS THE FRACTIONAL PART OF THE SERIAL, which IS the time of day by"
        " definition -- 0.5 is noon, 0.75 is 18:00 -- and needs no clock."
        " DIVERGENCE, AND IT IS NOW's RATHER THAN THIS ROW's: HOUR(NOW()) is 0"
        " here because SemanticsProfile captures one INTEGER at bind time, so"
        " NOW() is always midnight; see NOW's own row. Any other value is"
        " exact: HOUR(TIME(13,30,0)) is 13. ⚠ THE SERIAL IS ROUNDED TO THE"
        " NEAREST SECOND FIRST, and without that the family is off by one at"
        " every boundary: 59/86400 times 86400 is 58.999999999999993 in"
        " binary64, so a truncating SECOND(TIME(0,0,59)) answers 58 -- a"
        " confidently wrong number no whole-minute fixture can catch. A"
        " negative serial is #NUM!."
    )

# =============================================================================
# ★ THE SECOND WAVE — integer arithmetic, text, ISO weeks, CHOOSE.
# =============================================================================
def _rept_note() -> String:
    return String(
        "number_times is TRUNCATED, not rounded: REPT(\"ab\", 2.9) is \"abab\"."
        " Zero gives the EMPTY STRING and a negative count is #VALUE!."
        " ⛔ THE 32,767-CHARACTER CEILING IS A REFUSAL, NOT A CLAMP -- Excel's"
        " cell text limit -- because a clamp returns a TRUNCATED string that"
        " looks like a successful answer, and because the refusal is what stops"
        " REPT(\"x\", 1e9) from being an allocation instead of an error."
    )


def _char_note() -> String:
    return String(
        "⛔ THE RANGE IS 1..127 ONLY AND 128..255 IS #VALUE! -- A REFUSAL WHERE"
        " EXCEL ANSWERS. Excel's CHAR maps 128..255 through the machine's ANSI"
        " CODE PAGE (Windows-1252 on a Western Windows box, MacRoman"
        " historically, something else under another locale), so CHAR(128) is"
        " the euro sign for most users and is NOT U+0080. This engine's strings"
        " are UTF-8 and have no code page, so answering with the Unicode scalar"
        " would give a plausible WRONG character for 27 of those 128 codes and"
        " a right one for the rest, indistinguishable. CHAR(0) is #VALUE! in"
        " Excel too."
    )


def _code_note() -> String:
    return String(
        "RETURNS THE UNICODE SCALAR VALUE, which is byte-identical to Excel"
        " throughout the ASCII range. Above 127 Excel returns an ANSI"
        " CODE-PAGE byte (0..255) where this returns a code point that can"
        " exceed 255 -- the same code-page divergence CHAR refuses on, in the"
        " direction where a refusal is not available because CODE must return a"
        " number. An EMPTY text is #VALUE!."
    )


def _clean_note() -> String:
    return String(
        "REMOVES THE ASCII CONTROLS 0..31 AND NOTHING ELSE -- it is NOT TRIM."
        " TRIM collapses SPACES; CLEAN removes CONTROL CHARACTERS and leaves"
        " every space exactly where it was, so reaching for the wrong one gives"
        " a string that looks cleaned and is not. DEL (127) and the C1 controls"
        " SURVIVE, which is Excel's classic definition; removing them would be"
        " the more useful function and would not be CLEAN."
    )


def _t_fn_note() -> String:
    return String(
        "⛔ IT DOES NOT COERCE, AND THAT IS THE ENTIRE FUNCTION. T(123) is the"
        " EMPTY STRING, not \"123\". A kernel built on coerce_text returns"
        " \"123\" and is wrong on every non-text input -- which is the only"
        " kind of input anybody passes it. An error passes through, so it is"
        " ERRH_MANUAL."
    )


def _n_fn_note() -> String:
    return String(
        "⛔ N(\"7\") IS 0, NOT 7, and that is exactly where it differs from the"
        " shared coerce_number: Excel parses numeric text in an ARITHMETIC"
        " context (\"3\"+2 is 5) and N is not one, so EVERY text value is 0"
        " whether it looks numeric or not. A kernel that forwarded to"
        " coerce_number gets the one input anybody tests wrong AND turns"
        " non-numeric text into #VALUE! where Excel says 0. NUMBER -> itself;"
        " TRUE -> 1; FALSE -> 0; BLANK -> 0; an error passes through."
    )


def _gcd_lcm_note() -> String:
    return String(
        "EVERY ARGUMENT IS TRUNCATED TO AN INTEGER FIRST -- GCD(12.9, 8) is"
        " GCD(12, 8) = 4 -- and a NEGATIVE argument is #NUM!: Excel REFUSES"
        " rather than taking the absolute value, so GCD(-4, 8) is an error and"
        " not 4. GCD(0,0) is 0 and any zero argument makes LCM 0. ⚠ THE"
        " CEILING IS 2**53 AND IT IS A REFUSAL: FormulaValue carries Float64,"
        " which stops representing consecutive integers there, and Excel"
        " documents the same limit. LCM's fold divides before it multiplies"
        " (a/gcd*b) so an intermediate cannot overflow on a pair whose LCM is"
        " representable."
    )


def _mround_note() -> String:
    return String(
        "⛔ number AND multiple MUST SHARE A SIGN OR IT IS #NUM!. That is"
        " Excel's rule and it is the one thing about this function nobody"
        " expects: MROUND(10, -3) is an ERROR, not -9 and not 9. A kernel that"
        " just computed round(n/m)*m answers 9 and never refuses. A ZERO"
        " multiple is 0, not #DIV/0!. The tie rule is AWAY FROM ZERO, matching"
        " ROUND and not the IEEE half-to-even a language round() gives:"
        " MROUND(1.5, 1) is 2."
    )


def _isoweeknum_note() -> String:
    return String(
        "⚠⚠ THE WEEK BELONGS TO THE YEAR OF ITS THURSDAY, which is the entire"
        " ISO 8601 rule and the only thing an implementation can get wrong."
        " 2027-01-01 is a Friday, so its week's Thursday falls in 2026 and the"
        " answer is week 53 -- NOT week 1. An implementation that divided the"
        " day-of-year by 7 returns 1 and is wrong for a few days at each end of"
        " most years: a plausible small integer on a handful of dates nobody has"
        " in a fixture. ★ WEEKNUM IS DELIBERATELY ABSENT AND ISOWEEKNUM IS NOT:"
        " WEEKNUM has TEN return_type values selecting the first day of the week"
        " and whether week 1 contains Jan 1 or the first Thursday, and a kernel"
        " serving one of ten is a surface no sheet can rely on. ISOWEEKNUM has"
        " exactly one definition and no options, so it can be right rather than"
        " partially right. It round-trips through the CALENDAR rather than"
        " taking serial % 7, because serial 60 is the phantom 1900-02-29."
    )


def _choose_note() -> String:
    return String(
        "⛔ ERRH_MANUAL FOR A REASON THAT IS NOT THE IS* FAMILY'S. The IS*"
        " functions are MANUAL because they INSPECT errors; CHOOSE is MANUAL"
        " because Excel does not EVALUATE the arms it does not select, so"
        " CHOOSE(1, 5, 1/0) is 5 and not #DIV/0!. Under dominance the leftmost"
        " error argument would win before the kernel ran and the answer would be"
        " a refusal where Excel returns a number. ⚠ THE RESIDUAL DIVERGENCE IS"
        " ABOUT COST, NOT VALUE: this registry evaluates EVERY argument before"
        " dispatch where Excel evaluates only the selected one, so the results"
        " agree for pure functions and the WORK does not -- and a VOLATILE"
        " unselected argument (CHOOSE(1, 5, NOW())) is still recomputed here."
        " index_num is TRUNCATED, not rounded; out of 1..n is #VALUE!."
    )

# =============================================================================
# ★ THE ONE COMPOSER. A row carries ONE note string, and some rows have TWO
#   things to say.
# =============================================================================
# =============================================================================
# ★★ THE SEVENTEEN-NAME TRANCHE. Each of these states the input that
#    separates the function from the neighbour it can be MIS-WIRED to, because
#    that is the failure this effort is named for: a registry row pointing at
#    the wrong kernel still ANSWERS, so it is not `#NAME?`, so a recognition
#    cell passes.
# =============================================================================
def _fact_note() -> String:
    return String(
        "The argument is TRUNCATED, not rounded: FACT(5.9) is 120, and a"
        " rounding kernel answers 720. FACT(0) is 1 and a negative argument is"
        " #NUM!, which is a refusal rather than an absolute value. The ceiling"
        " is 170 -- 171! overflows Float64 to +inf, a finite-looking value that"
        " would travel silently through every aggregate above it."
    )


def _factdouble_note() -> String:
    return String(
        "n!! -- the product of n, n-2, n-4 ... down to 2 or 1, which is NOT the"
        " factorial: FACTDOUBLE(6) is 48 where FACT(6) is 720, and"
        " FACTDOUBLE(7) is 105 where FACT(7) is 5040. The two AGREE at 0, 1, 2"
        " and 3, so a fixture confined to small inputs cannot tell a"
        " FACT-wired row from this one. A negative argument is #NUM! (Excel's"
        " answer, not the mathematical (-1)!! = 1); the ceiling is 300, higher"
        " than FACT's 170 because half as many factors multiply."
    )


def _combin_note() -> String:
    return String(
        "Combinations WITHOUT repetition. Both arguments are truncated, so"
        " COMBIN(5.9, 2.9) is COMBIN(5, 2) = 10. number_chosen > number is"
        " #NUM! and NOT 0 -- a 0 would sum happily into a total. The"
        " multiplicative recurrence divides at every step, so the intermediate"
        " never exceeds the answer and every result below 2**53 is exact."
    )


def _combina_note() -> String:
    return String(
        "Combinations WITH repetition, C(n + k - 1, k). It differs from COMBIN"
        " in TWO ways and both matter: COMBINA(5, 2) is 15 where COMBIN(5, 2)"
        " is 10, and number_chosen MAY exceed number (COMBINA(2, 5) is 6 where"
        " COMBIN(2, 5) is #NUM!). They AGREE for every k <= 1, which is the"
        " blind input -- COMBINA(5, 1) and COMBIN(5, 1) are both 5."
        " COMBINA(0, 0) is 1 and COMBINA(0, k>0) is #NUM!."
    )


def _sumsq_note() -> String:
    return String(
        "The sum of the SQUARES: SUMSQ(3, 4) is 25 where SUM(3, 4) is 7, and"
        " SUMSQ(-3) is 9 where a sum-of-absolute-values kernel answers 3."
        " Blanks are skipped rather than coerced to 0 -- which gives the same"
        " number here only because 0 squared is 0, an arithmetic accident and"
        " not a design, so it is spelled explicitly. NO PLAN-IR TAG: like"
        " PRODUCT this has no relational form."
    )


def _base_note() -> String:
    return String(
        "Digits above 9 are UPPER-CASE: BASE(255, 16) is 'FF', not 'ff'."
        " min_length LEFT-PADS with zeros and never truncates, so BASE(7, 2, 8)"
        " is '00000111' and a min_length shorter than the rendering is ignored"
        " rather than being an error. BASE(0, 2) is '0' -- the one input where"
        " an accumulate-digits loop that never runs returns the empty string."
        " A radix outside 2..36, a negative number, a number past 2**53 or a"
        " min_length above 255 are each #NUM!."
    )


def _decimal_note() -> String:
    return String(
        "The inverse of BASE, and CASE-INSENSITIVE: DECIMAL('ff', 16) and"
        " DECIMAL('FF', 16) are both 255. A digit that is not valid in the"
        " radix is #NUM! -- DECIMAL('2', 2) is refused, where a parser that"
        " accumulates value*radix + digit without checking reads it as 2."
        " Text longer than 255 characters is #VALUE!. AN EMPTY TEXT IS #NUM!"
        " HERE AND MICROSOFT DOES NOT STATE THAT CASE: this engine refuses"
        " rather than inventing the 0 an accumulate-from-zero loop returns, and"
        " that is a divergence RISK rather than a documented rule."
    )


def _precise_round_note() -> String:
    return String(
        "CEILING.PRECISE and FLOOR.PRECISE round toward +infinity and"
        " -infinity respectively, ALWAYS, and take the ABSOLUTE VALUE of"
        " significance -- which is the whole difference from CEILING/FLOOR,"
        " whose direction is selected by whether the two arguments SHARE a sign"
        " and which refuse a positive number with a negative significance."
        " CEILING(-2.1, -1) is -3 and CEILING.PRECISE(-2.1, -1) is -2;"
        " CEILING(2.1, -1) is #NUM! and CEILING.PRECISE(2.1, -1) is 3. They"
        " AGREE whenever both arguments are positive, which is the blind input."
        " significance is OPTIONAL here (default 1) and REQUIRED on CEILING."
    )


def _concatenate_note() -> String:
    return String(
        "The LEGACY spelling of CONCAT, and on this surface it is the same"
        " function: in Excel the two differ only in that CONCAT accepts a RANGE"
        " and CONCATENATE does not, and the scalar carrier has no array member"
        " at all, so the difference is not expressible. IF AN ARRAY VALUE EVER"
        " LANDS IN FormulaValue THIS ROW MUST STOP FORWARDING. The"
        " discriminating inputs are the coercing ones: CONCATENATE(1, 2) is the"
        " TEXT '12' where an arithmetic kernel answers 3, and no separator is"
        " inserted, where a TEXTJOIN-shaped kernel would insert one."
    )


def _unichar_note() -> String:
    return String(
        "The function CHAR could not be. CHAR refuses everything above 127"
        " because Excel maps 128..255 through the machine's ANSI code page,"
        " which this engine has not got; UNICHAR's argument IS a Unicode code"
        " point by definition on every platform, so the full range is"
        " answerable and nothing is guessed. UNICHAR(8364) is the euro sign"
        " where CHAR(8364) is #VALUE!, and both answer 'A' at 65 -- the blind"
        " input. Zero or negative is #VALUE!; above U+10FFFF or a lone"
        " SURROGATE in D800..DFFF is #N/A, the case a naive encoder turns into"
        " CESU-8 bytes that are not valid UTF-8."
    )


def _unicode_note() -> String:
    return String(
        "ON THIS ENGINE UNICODE RETURNS THE SAME NUMBER AS CODE, and saying so"
        " is the value of the row. Excel's CODE returns an ANSI code-page byte"
        " and this engine's returns a code point (see the CODE row), so on a"
        " Western Windows box CODE of the euro sign is 128 and UNICODE is 8364,"
        " while HERE both are 8364 -- UNICODE is right and CODE is the one that"
        " diverges. The pair is therefore NOT discriminating here; the"
        " discriminating cell for this family is UNICHAR(8364) against"
        " CHAR(8364). An empty text is #VALUE!."
    )


def _isnontext_note() -> String:
    return String(
        "The exact negation of ISTEXT, INCLUDING OVER ERRORS, and that last"
        " clause is why it is ERRH_MANUAL rather than a NOT(ISTEXT(x)) wrapper"
        " under dominance: ISNONTEXT(#N/A) is TRUE, and a dominance-classed row"
        " never reaches the kernel and answers #N/A. A BLANK is non-text (TRUE)"
        " and the empty STRING is text (FALSE), the same distinction ISBLANK"
        " turns on."
    )


def _type_note() -> String:
    return String(
        "The codes are 1 number, 2 text, 4 logical, 16 error, 64 array, 128"
        " compound -- a BIT-FLAG layout inherited from Excel 4 macro sheets and"
        " not a dense ordinal, so a 1,2,3,4 kernel answers 3 where Excel says 4"
        " and 4 where it says 16. A BLANK is 1: Excel has no TYPE code for an"
        " empty cell, it reads as the number 0, so TYPE cannot find blanks and"
        " ISBLANK is not redundant with it. ERRH_MANUAL, because code 16 exists"
        " only if the kernel is allowed to SEE the error. 64 and 128 are"
        " unreachable from this door -- the scalar carrier has no array member."
    )


def _error_type_note() -> String:
    return String(
        "1 #NULL!, 2 #DIV/0!, 3 #VALUE!, 4 #REF!, 5 #NAME?, 6 #NUM!, 7 #N/A."
        " A NON-ERROR argument is #N/A, not 0 and not #VALUE!, and that is the"
        " case a plausible implementation gets wrong expensively: the idiom is"
        " IF(ISERROR(x), CHOOSE(ERROR.TYPE(x), ...), x), so a 0 indexes CHOOSE"
        " out of range and a #VALUE! replaces the caller's real answer."
        " ERRH_MANUAL, and here dominance would make the function a tautology --"
        " every argument it is called with is an error, so it would return its"
        " own argument 100% of the time and look like it worked. #SPILL! and"
        " #CALC! map to 9 and 14 per Microsoft's modern table; neither is"
        " reachable from this door, so neither is graded."
    )


def _logical_constant_note() -> String:
    return String(
        "TRUE() AND FALSE() USED TO BE A PARSE ERROR, not a #NAME?."
        " formula_parser resolved the identifiers TRUE and FALSE to boolean"
        " literals BEFORE looking for the '(' that makes an identifier a call,"
        " so =TRUE() left the parens unconsumed and the trailing-token check"
        " raised out of the C door -- strictly worse than #NAME?, which is a"
        " VALUE a caller can test with ISERROR. The parser now tests for '('"
        " first and falls back to the literal only when there is none, so bare"
        " TRUE keeps its literal path and IF(FALSE,1) is unchanged."
    )


# =============================================================================
# ★★ THE COMPATIBILITY TRANCHE — Microsoft's "Compatibility"
#    category, i.e. the PRE-2010 SPELLINGS. ⛔ THEY ARE NOT ALL ALIASES.
#
# Eleven of the twenty-four return a DIFFERENT NUMBER from their 2010
# replacement at the same arguments. Each such row carries its own note below
# and names the input where the two conventions separate; the twelve that ARE
# exact renames share `_compat_rename_note`, which SAYS SO rather than leaving
# an empty note that a reader cannot distinguish from "nobody checked".
# =============================================================================
def _compat_rename_note() -> String:
    return String(
        "A PRE-2010 SPELLING that its 2010 replacement renamed and did NOT"
        " redefine: same arguments, same order, same answer at every input."
        " ⚠ THAT SENTENCE IS A MEASUREMENT AND NOT A DEFAULT -- eleven of the"
        " twenty-four names in this set DO differ from their replacement"
        " (the right-tail four, the two-tailed TINV, BETADIST's argument"
        " positions, and the four that lost a `cumulative` argument), so an"
        " empty note here would be indistinguishable from an unchecked one."
    )


def _chidist_note() -> String:
    return String(
        "⛔ RIGHT-TAILED. Its 2010 replacement is CHISQ.DIST.RT and NOT"
        " CHISQ.DIST, which is the LEFT tail: CHIDIST(1,2) is exp(-0.5) ="
        " 0.6065306597126334 where CHISQ.DIST(1,2,TRUE) is 0.3934693402873666."
        " Both are probabilities in range and a p-value read off the wrong one"
        " inverts every conclusion drawn from it. deg_freedom is TRUNCATED and"
        " must lie in [1, 1e10]; a negative x is #NUM!."
    )


def _chiinv_note() -> String:
    return String(
        "⛔ THE INVERSE OF THE RIGHT TAIL -- replacement CHISQ.INV.RT, not"
        " CHISQ.INV. CHIINV(0.05,2) is -2*ln(0.05) = 5.991464547107982, the"
        " familiar 5% critical value, where the left-tail CHISQ.INV(0.05,2) is"
        " -2*ln(0.95) = 0.10258658877510106. A critical value wrong by a factor"
        " of 58 still looks like a chi-square number. ⚠ The search inverts"
        " gamma_q DIRECTLY rather than inverting gamma_p at 1-p, because at a"
        " small right tail the complement rounds to 1.0 in Float64."
    )


def _fdist_note() -> String:
    return String(
        "⛔ RIGHT-TAILED -- replacement F.DIST.RT, not F.DIST. FDIST(3,2,2) is"
        " 1/(1+3) = 0.25 where F.DIST(3,2,2,TRUE) is 0.75. F.DIST also takes a"
        " FOURTH `cumulative` argument this name has not got, so a naive"
        " re-point is an arity error first and a wrong number after somebody"
        " widens the window to make the error go away."
    )


def _finv_note() -> String:
    return String(
        "⛔ THE INVERSE OF THE RIGHT TAIL -- replacement F.INV.RT."
        " FINV(0.25,2,2) is 3 where the left-tail F.INV(0.25,2,2) is 1/3. The"
        " two answers are RECIPROCALS, which is the most plausible-looking"
        " wrong value a critical value can take."
    )


def _tdist_note() -> String:
    return String(
        "⛔ THREE DIVERGENCES FROM THE MODERN SPELLINGS, AND EVERY ONE RETURNS"
        " A NUMBER. (1) T.DIST(x,df,TRUE) is the LEFT tail: TDIST(1,1,1) is"
        " 0.25 and T.DIST(1,1,TRUE) is 0.75. (2) The `tails` selector DOUBLES"
        " the answer -- TDIST(1,1,2) is 0.5 -- so a kernel that ignored it is"
        " wrong by exactly 2x, in range, every time. (3) ⚠ x < 0 is #NUM! here"
        " and ACCEPTED by T.DIST, so a re-pointed row turns a documented"
        " refusal into a confident probability."
    )


def _tinv_note() -> String:
    return String(
        "⛔ TWO-TAILED -- replacement T.INV.2T, not T.INV. TINV(0.5,1) is"
        " tan(pi/4) = 1 where the one-tailed T.INV(0.5,1) is 0, because the"
        " median of a symmetric distribution is its centre. A t critical value"
        " of 0 passes every significance test ever run against it."
    )


def _betadist_note() -> String:
    return String(
        "⛔ THE ARGUMENT POSITIONS ARE THE DIVERGENCE. BETADIST(x,alpha,beta,"
        "[A],[B]) has NO `cumulative` argument; its 2010 replacement"
        " BETA.DIST(x,alpha,beta,cumulative,[A],[B]) INSERTED one at position"
        " 4, exactly where this name has the lower bound A. So"
        " BETADIST(2,1,1,1,3) -- which is (2-1)/(3-1) = 0.5 -- reads under the"
        " modern signature as cumulative=TRUE with A=3, a different call that"
        " still answers. ⚠ And there is no density form: BETADIST is"
        " cumulative by definition."
    )


def _betainv_note() -> String:
    return String(
        "AN EXACT RENAME to BETA.INV, and saying so is the point: BETA.INV did"
        " NOT gain the `cumulative` argument that shifted BETADIST's bounds,"
        " because an inverse has no density form to select. A reader who"
        " generalised BETADIST's argument shift onto its inverse would move A"
        " and B by one position for no reason."
    )


def _lognormdist_note() -> String:
    return String(
        "⛔ CUMULATIVE ONLY, ARITY 3. LOGNORM.DIST(x,mean,sd,cumulative) added"
        " a fourth argument in 2010; this name has no density form at all. A"
        " row wired to the modern kernel with a defaulted flag returns the"
        " DENSITY whenever that default is FALSE -- 0.1569 against the true"
        " 0.7559 at (2,0,1). ⚠ x <= 0 is #NUM!: the lognormal has no mass"
        " there and log(0) is -inf, which would travel as a number."
    )


def _normsdist_note() -> String:
    return String(
        "⛔ ARITY 1 AND ALWAYS CUMULATIVE. NORM.S.DIST(z,cumulative) takes TWO"
        " arguments and REFUSES one; this name takes exactly one. A row wired"
        " to a two-argument kernel is an arity error, which is VISIBLE; a row"
        " wired to the DENSITY answers 0.2420 where the truth is 0.8413 at"
        " z=1, which is not."
    )


def _negbinomdist_note() -> String:
    return String(
        "⛔ PROBABILITY MASS ONLY, ARITY 3. NEGBINOM.DIST added a `cumulative`"
        " fourth argument in 2010. At (2,3,0.5) the mass is C(4,2)/32 = 0.1875"
        " and the cumulative is 0.6875 -- still a probability, still monotone"
        " in its arguments, and 3.7x too large. ⚠ number_s < 1 is #NUM!: zero"
        " successes is not a waiting time."
    )


def _hypgeomdist_note() -> String:
    return String(
        "⛔ PROBABILITY MASS ONLY, ARITY 4 -- HYPGEOM.DIST added a fifth"
        " `cumulative` argument. ⚠ THE FEASIBILITY BOUNDS ARE TWO-SIDED AND"
        " BOTH ARE #NUM!: a sample cannot hold more successes than it has"
        " draws or than the population contains, and it cannot hold FEWER than"
        " n-(N-M) once the failures run out. A kernel checking only the upper"
        " bound returns exp() of a negative-argument log-binomial for the"
        " lower one, which is a positive number."
    )


def _norminv_category_note() -> String:
    return String(
        "⭐ THE 2010 SPELLING, SERVED FROM THE COMPATIBILITY SLICE BECAUSE"
        " MICROSOFT'S OWN PUBLISHED LIST HAS THIS PAIR'S CATEGORIES SWAPPED:"
        " it files NORM.INV under `Compatibility` and NORMINV under"
        " `Statistical`, the only one of eleven legacy/modern pairs on that"
        " page where that happens (NORMDIST/NORM.DIST, NORMSDIST/NORM.S.DIST,"
        " LOGNORMDIST/LOGNORM.DIST and the rest are all filed the right way"
        " round). The defect is in the upstream function reference;"
        " the pre-2010 NORMINV is left to whoever owns the Statistical block."
    )


def _encodeurl_note() -> String:
    return String(
        "⭐ THE ONE MEMBER OF EXCEL'S `Web` CATEGORY THAT NEEDS NO NETWORK --"
        " it percent-encodes a string and performs no I/O. ⚠ IT ENCODES THE"
        " UTF-8 BYTES, not the code points: ENCODEURL of a-umlaut is %C3%A4 and"
        " not %E4, and an ASCII-only fixture cannot tell those apart. The"
        " unreserved set here is RFC 3986's (A-Z a-z 0-9 - . _ ~); Microsoft's"
        " published example pins only the alphanumerics, `.`, `:`, `/` and"
        " SPACE, so ⛔ `~` IS NOT VERIFIED AGAINST A LIVE EXCEL and no value"
        " cell grades it. Hex digits are UPPER-CASE. WEBSERVICE and FILTERXML"
        " are refused by name."
    )


# =============================================================================
#
# ⛔ EVERY NOTE BELOW NAMES AN INPUT AT WHICH A PLAUSIBLE-BUT-WRONG KERNEL
#    ANSWERS A NUMBER OF THE RIGHT SIGN AND THE RIGHT MAGNITUDE. That is the
#    selection rule for this family and it is stricter than the rest of the
#    census's, because money is the domain where a plausible answer is the
#    dangerous outcome.
# =============================================================================
def _annuity_note() -> String:
    return String(
        "One relation, six names. Excel publishes exactly one equation --"
        " pv*(1+rate)^nper + pmt*(1+rate*type)*((1+rate)^nper - 1)/rate + fv ="
        " 0 -- and PV, FV, PMT, NPER, RATE and the IPMT/PPMT split are all"
        " rearrangements of it. THE SIGN CONVENTION IS PART OF THE CONTRACT:"
        " money you PAY is NEGATIVE, so PMT(0.1, 10, 1000) is -162.745 and a"
        " kernel returning the magnitude agrees with every mental arithmetic"
        " check and disagrees with Excel on every cell. `type` selects when the"
        " payment lands -- 0 (default) END of period, 1 BEGINNING -- and buys"
        " every payment one more period of interest: FV(0.1,2,-100,0,1) is 231"
        " where FV(0.1,2,-100) is 210. AT rate = 0 THE GENERAL FORM IS 0/0 and"
        " the LIMIT arm is what makes an interest-free loan computable at all;"
        " it is also the input where FV and PV COINCIDE (both 200 for"
        " (0,2,-100)), so a fixture confined to it cannot tell them apart."
    )


def _rate_solver_note() -> String:
    return String(
        "THE ITERATION IS THE CONTRACT, NOT AN IMPLEMENTATION DETAIL. Microsoft"
        " publishes all four halves and this engine grades against all four:"
        " Newton seeded at `guess` (default 0.1), 20 iterations, convergence"
        " 0.0000001 on successive results, and #NUM! when it does not converge."
        " A kernel iterating to machine precision would ANSWER where Excel"
        " refuses. AND THE ROOT IS NOT UNIQUE -- Microsoft: 'RATE is calculated"
        " by iteration and can have zero or more solutions.' RATE(2,-2.8,1,4.72)"
        " has the residual r^2 - 0.8r + 0.12, whose roots 0.2 and 0.6 are BOTH"
        " exact solutions; the default guess finds 0.2 and guess = 0.5 finds"
        " 0.6. A solver that ignored the guess answers the same number twice."
        " RATE(3,100,100) has cash flows that never change sign, so there is no"
        " root and the answer is #NUM! rather than whatever 20 steps drifted to."
    )


def _ipmt_ppmt_note() -> String:
    return String(
        "THE MOST DANGEROUS PAIR IN THE FAMILY: both are negative, both are the"
        " same order of magnitude, both vary smoothly with the period, and a"
        " schedule built from the wrong one still sums to the right TOTAL over"
        " the full term. At period 1 of a 10-period 10% loan on 1000 they are"
        " -100 and -62.745; by period 10 they have CROSSED, to -14.795 and"
        " -147.950. IPMT + PPMT == PMT exactly, for every period. Period 1 is"
        " the cell a wrong kernel passes -- -100 is just -pv*rate and falls out"
        " of several wrong formulas -- where period 2 (-93.7254605116) needs the"
        " balance rolled forward. WITH type = 1 THE FIRST PERIOD'S INTEREST IS"
        " EXACTLY 0, because the payment is made before any interest accrues;"
        " that is not an off-by-one of the type = 0 arm. A period outside"
        " 1..nper is #NUM! rather than an extrapolated number."
    )


def _ispmt_note() -> String:
    return String(
        "ONE LETTER FROM IPMT AND A DIFFERENT MODEL. IPMT splits a LEVEL"
        " payment; ISPMT assumes the principal is repaid in equal slices, so its"
        " interest falls LINEARLY: pv*rate*(per/nper - 1). On the published"
        " example (0.1/12, 1, 36, 8000000) ISPMT is -64814.8148 and IPMT is"
        " -66666.667 -- both negative five-figure numbers 2.8% apart, and only"
        " one is right. nper = 0 is #DIV/0! and not #NUM!, because the formula"
        " divides by it directly."
    )


def _cum_note() -> String:
    return String(
        "CUMIPMT and CUMPRINC sum IPMT/PPMT over an INCLUSIVE period range, and"
        " all SIX arguments are required -- `type` has no default here where it"
        " has one on PMT and IPMT. Over one period CUMIPMT IS IPMT (-937.50 at"
        " period 1 of a 30-year 9% mortgage on 125000), which is the control"
        " that says the sum sums the right thing. Over the SECOND YEAR the two"
        " are -11135.23 and -934.107, an order of magnitude apart because early"
        " payments are almost all interest; over the LAST year the ordering"
        " reverses, so a fixture at one end of the schedule proves nothing."
        " FIVE REFUSALS, ALL #NUM!: rate <= 0, nper <= 0, pv <= 0, start > end,"
        " and a `type` outside {0,1} -- that last one is #NUM! and NOT #VALUE!,"
        " which is the opposite of what a bad-argument instinct produces."
    )


def _npv_note() -> String:
    return String(
        "THE FIRST VALUE IS DISCOUNTED ONE FULL PERIOD, NOT ZERO. NPV(0.1, 100)"
        " is 90.9090909, not 100: Excel's NPV assumes every cash flow arrives at"
        " the END of its period, so an investment made TODAY is added outside"
        " the call as NPV(rate, ...) + C0. A kernel starting the exponent at 0"
        " answers 100 -- a round number that looks like a correct answer."
        " NPV(0.1, 100, 200) is 256.198, i.e. 100/1.1 + 200/1.21; a kernel"
        " discounting every term by one period answers 272.7. IT IS VARIADIC"
        " OVER LOOSE SCALARS, which is why it is served here and IRR / MIRR /"
        " XIRR / XNPV / FVSCHEDULE are not: their published signatures take an"
        " ARRAY OR RANGE, and this door has neither an array literal nor a range"
        " binding. rate = -1 is #DIV/0! -- the first discount factor is zero."
    )


def _effect_nominal_note() -> String:
    return String(
        "EFFECT and NOMINAL are exact inverses: NOMINAL(EFFECT(r, n), n) == r"
        " for every r and n, the way DECIMAL(BASE(x, b), b) == x is for the"
        " radix pair. THE BLIND INPUT IS npery = 1, where BOTH are the identity"
        " and a fixture confined to annual compounding cannot tell them apart at"
        " all; at npery = 4 on a 100% nominal rate they are 1.44140625 and"
        " 0.75682846, on OPPOSITE sides of the input. npery is TRUNCATED rather"
        " than rounded, so EFFECT(0.0525, 4.9) is the QUARTERLY answer -- a"
        " rounding kernel computes a five-period-per-year rate nobody can spot"
        " as wrong. npery < 1 and a non-positive rate are both #NUM!."
    )


def _rri_pduration_note() -> String:
    return String(
        "RRI and PDURATION are inverses and the round trip grades both:"
        " RRI(2, 100, 121) is 0.1 and PDURATION(0.1, 100, 121) is 2. Neither"
        " number is producible by a kernel with the exponent the wrong way up --"
        " (121/100)^2 - 1 is 0.4641. RRI refuses nper <= 0 and pv = 0 with"
        " #NUM! rather than returning an infinity; PDURATION refuses rate <= 0,"
        " pv <= 0 and fv <= 0, where libm would hand back -inf for the second"
        " and nan for the third and both would travel."
    )


def _dollar_fraction_note() -> String:
    return String(
        "THE FRACTIONAL PART IS A NUMERATOR IN A FIXED-WIDTH FIELD, NOT A"
        " DECIMAL. DOLLARDE(1.02, 16) is 1.125 -- one dollar and two SIXTEENTHS"
        " -- because the .02 is scaled by 10^ceil(log10(16)) = 100 FIRST and"
        " only then divided by 16. A kernel reading .02 as two hundredths"
        " answers 1.00125, a dollar-shaped number wrong by a factor of 100."
        " DOLLARFR is the exact inverse (1.125 in sixteenths is 1.02) and the"
        " two AGREE on every whole number -- DOLLARDE(2,16) and DOLLARFR(2,16)"
        " are both 2 -- which is the blind input. THE FIELD WIDTH IS COMPUTED BY"
        " AN INTEGER LOOP and not by pow(10, ceil(log10(n))), because log10 of"
        " an exact power of ten can land a hair below it and the pair would then"
        " divide by the wrong power for exactly the denominators (10, 100, 1000)"
        " a price is most likely to use. fraction = 0 is #DIV/0! and a negative"
        " one is #NUM! -- two different errors for two different reasons."
    )


def _sln_syd_note() -> String:
    return String(
        "THE SUM-OF-YEARS SCHEDULE CROSSES THE STRAIGHT LINE EXACTLY AT"
        " per = (life+1)/2, so SLN(3000,0,3) and SYD(3000,0,3,2) are BOTH 1000"
        " and a fixture that only ever asks about the middle period cannot tell"
        " an accelerating schedule from a flat one. At the ends SYD is 1500 and"
        " 500 -- a 3:1 ratio that pins the acceleration to the documented rate"
        " rather than to some other one. The +1 in (life - per + 1) is the whole"
        " function: without it the LAST period depreciates nothing. SYD refuses"
        " per > life with #NUM! and not 0, because the formula would otherwise"
        " return a NEGATIVE depreciation; SLN's life = 0 is #DIV/0!."
    )


def _db_rate_rounding_note() -> String:
    return String(
        "A DOCUMENTED ROUNDING WART, AND IT IS WHAT MAKES DB A DIFFERENT"
        " FUNCTION RATHER THAN A FLOATING-POINT VARIATION ON A CONTINUOUS"
        " DECLINING BALANCE. Microsoft defines the rate as"
        " ROUND(1 - (salvage/cost)^(1/life), 3). On the published example"
        " (1000000, 100000, 6, 1, 7) the unrounded rate is 0.3187079309 and the"
        " rounded one is 0.319: 186083.33333333334 against 185912.95971618922, a"
        " 0.09% difference that looks exactly like accumulated float error and"
        " is not. `month` is the number of months in the FIRST year (default 12),"
        " so period 1 is pro-rated by month/12 and the asset depreciates over"
        " life + 1 periods with the last pro-rated by (12 - month)/12; a kernel"
        " ignoring it is wrong from period 2 onward because the running total is"
        " wrong. DB AND DDB COINCIDE at (1000, 107.3741824, 10, 1) -- 0.8^10 is"
        " exactly that salvage ratio, so both rates are 2/10 and both answer 200"
        " -- which is the blind input; `month` is the sharp one."
    )


def _ddb_clip_note() -> String:
    return String(
        "THE SALVAGE FLOOR IS A MIN, NOT A SUBTRACTION, AND IT ONLY BITES IN THE"
        " PERIODS A FIXTURE OMITS. The declining-balance curve never reaches the"
        " salvage value on its own, so Excel CLIPS the last productive period"
        " and every later one depreciates 0: DDB(2400,300,10,10) is 22.1225"
        " where the unclipped curve gives 64.4245, and period 11 is 0 where the"
        " curve gives 51.5396. An unclipped kernel agrees with Excel for the"
        " first NINE periods. `factor` defaults to 2 and NOT to 1 or 0 -- a"
        " kernel defaulting it to zero answers 0 for every period, which looks"
        " like a fully-depreciated asset rather than like a bug -- and"
        " factor = 1 is a 1/life declining balance, NOT the straight line SLN"
        " gives (240 against 210 on (2400, 300, 10, 1))."
    )





def _also(specific: String, shared: String) -> String:
    """`specific` followed by a shared clause — `_plan_only_note()` or
    `_scalar_only_note()`.

    ⚠ IT EXISTS BECAUSE `XlFnRow.note` IS ONE FIELD AND THAT IS THE RIGHT
    SHAPE. A second note column would have to be carried by the TSV, by every
    reader parsing it, and by every future row; a row whose whole truth is two
    sentences can just say two sentences. The join is a single space, so the
    result stays the one-paragraph, TAB-free, newline-free string
    `test_no_note_contains_a_tab_or_newline` requires.

    ⚠ AND THE SHARED HALF GOES **SECOND**. The census is read row-first: what
    is peculiar to THIS name is what a reader is looking for, and the class-wide
    caveat is context for it."""
    return specific + String(" ") + shared

# =============================================================================
# ★ THE ROSTER — every note in this file, in ONE list, so that a note attached
#   to no row can be DETECTED rather than merely regretted.
# =============================================================================
# =============================================================================
# ⭐⭐ THE STATISTICAL DISTRIBUTION FAMILY. Forty-three rows, and
# the notes below are what keep the census from printing forty-three
# interchangeable "a statistical function" entries for a family in which the
# WRONG answer is still a probability.
# =============================================================================


def _stat_scalar_note() -> String:
    return String(
        "A SCALAR statistical function: it consumes ARGUMENT VALUES, not engine"
        " columns, so it needs no plan, no aggregate tag and no relation."
        " ⛔ THAT IS WHY IT IS HERE AND THE RANGE STATISTICS ARE NOT. LARGE,"
        " SMALL, PERCENTILE.*, QUARTILE.*, PERCENTRANK.*, RANK.*, TRIMMEAN,"
        " MODE.MULT, FREQUENCY, CORREL/COVARIANCE/SLOPE/INTERCEPT/RSQ/STEYX,"
        " LINEST and TREND each take an ARRAY argument, and FormulaValue has"
        " five kinds -- BLANK / NUMBER / TEXT / LOGICAL / ERROR -- and no array"
        " kind, so LARGE(array, k) cannot be SPELLED on this door. That is a"
        " missing primitive, not a missing kernel."
    )


def _dist_tail_note() -> String:
    return String(
        "⛔ THE TAIL CONVENTION IS THE FUNCTION. A .DIST is LEFT-tailed, a"
        " .DIST.RT is RIGHT-tailed (and takes no `cumulative` argument, so its"
        " arity is one SMALLER), and a .2T is the two-tailed mass -- EXACTLY"
        " TWICE the right tail for a positive argument. All three return a"
        " number in [0,1] for the same input, so a wiring swap is not #NAME?,"
        " is not out of range, and looks like a tolerance problem. The graded"
        " cells pin all three at one point."
    )


def _dist_inv_note() -> String:
    return String(
        "⚠ GRADED AGAINST A PUBLISHED TABLE VALUE, NOT AGAINST A ROUND TRIP."
        " An inverse implemented as a search over its OWN forward function"
        " agrees with itself at every tolerance and diverges from Excel"
        " wherever the forward function is wrong. The oracle cell for this row"
        " carries a value from the standard chi-square / t / F tables or from"
        " Microsoft's own documented worked example."
    )


def _special_fn_note() -> String:
    return String(
        "Rests on `xl_special_fn.mojo`: log-gamma, the REGULARIZED incomplete"
        " gamma P(a,x)/Q(a,x), the REGULARIZED incomplete beta I_x(a,b), and"
        " their inverses -- five primitives under the whole distribution"
        " family. ⚠ REGULARIZED, not raw: the unnormalised gamma differs by a"
        " factor of Gamma(a) and still lands in [0,1] for many arguments."
        " ⚠ The right tail is taken from Q directly and never as 1-P, which"
        " returns exactly 0.0 in the far tail -- a p-value of zero being the"
        " most consequential wrong answer this family can produce."
    )


def _gammaln_note() -> String:
    return String(
        "⛔ THE TWIN IS `LN`, WHICH IS A LIVE ROW IN THIS TABLE: same shape"
        " (one positive argument, a refusal at zero), so a mis-wired row"
        " reaches a real kernel and answers a plausible number. They separate"
        " at the first integer -- GAMMALN(4) is 1.791759469 = ln(3!) and LN(4)"
        " is 1.386294361. GAMMALN.PRECISE is the SAME function, deliberately:"
        " Microsoft introduced the spelling for consistency with"
        " CEILING.PRECISE, where the suffix DOES change behaviour."
    )


def _gamma_fn_note() -> String:
    return String(
        "⛔ THE TWIN IS `FACT`, A LIVE ROW IN THIS TABLE, AND THEY AGREE AT"
        " EVERY POSITIVE INTEGER: Gamma(n) = (n-1)!, so GAMMA(5) is 24 ="
        " FACT(4) and an integer fixture cannot tell a shifted factorial from"
        " this. They separate at 2.5 -- 1.329340388 against FACT's truncating"
        " 2. ⚠ NEGATIVE NON-INTEGERS ARE DEFINED and served via the reflection"
        " formula (GAMMA(-1.5) is +2.363271801); exp(lgamma(x)) alone is always"
        " positive and cannot produce the alternating sign. Zero and the"
        " negative integers are the poles and are #NUM!."
    )


def _permut_note() -> String:
    return String(
        "⛔ THE TWIN IS `COMBIN`, A LIVE ROW IN THIS TABLE: PERMUT(5,2) is 20"
        " and COMBIN(5,2) is 10, and they AGREE at k<=1. PERMUTATIONA is n^k --"
        " PERMUTATIONA(3,2) is 9 where PERMUT(3,2) is 6 -- and it ACCEPTS k>n,"
        " which PERMUT refuses with #NUM!. That arity-domain difference is the"
        " discriminator a numeric-only fixture misses."
    )


def _norm_s_dist_note() -> String:
    return String(
        "⚠ ARITY 2, AND `cumulative` IS REQUIRED. That is the whole difference"
        " from the legacy NORMSDIST(z), which has arity 1 and is always"
        " cumulative -- a Compatibility-category name this row is NOT an alias"
        " for, and which has to be graded separately. A kernel ignoring the"
        " flag answers 0.5 for NORM.S.DIST(0, FALSE) where Excel says"
        " 0.3989422804."
    )


def _norm_dist_note() -> String:
    return String(
        "⚠ THE DENSITY ARM DIVIDES BY standard_dev. NORM.DIST(x,m,s,FALSE) is"
        " phi((x-m)/s)/s; dropping the Jacobian gives a curve integrating to s"
        " instead of 1, and AT s=1 THE TWO ARE IDENTICAL -- which is the only"
        " place a lazy fixture looks. ⚠ standard_dev = 0 is #NUM!, not a"
        " division producing inf and then a plausible 0 or 1. ⚠ NORM.INV takes"
        " the PROBABILITY first where NORM.DIST takes the value first."
    )


def _beta_rescale_note() -> String:
    return String(
        "⚠ THE OPTIONAL A AND B RESCALE THE SUPPORT from [0,1]. Microsoft's own"
        " example BETA.DIST(2,8,10,TRUE,1,3) is 0.685470581, which is"
        " I_0.5(8,10); a kernel ignoring A and B evaluates at x=2, outside"
        " [0,1], and answers exactly 1. ⚠ AND THE DENSITY ARM CARRIES THE"
        " 1/(B-A) JACOBIAN -- the documented 1.4837646 is the unit-interval"
        " density halved. x outside [A,B] is #NUM!, not a clamp."
    )


def _binom_range_note() -> String:
    return String(
        "⛔ BINOM.DIST.RANGE TAKES TRIALS FIRST WHERE BINOM.DIST TAKES SUCCESSES"
        " FIRST, so a shared argument-unpacking helper answers a plausible"
        " probability from the wrong distribution. ⚠ WITH number_s2 OMITTED IT"
        " IS THE POINT MASS, not a cumulative. ⚠ The cumulative binomial here"
        " is the incomplete-beta identity rather than a sum of terms: the sum"
        " is O(k) and loses the far tail."
    )


def _hypgeom_note() -> String:
    return String(
        "⚠ FIVE ARGUMENTS IN AN ORDER NOTHING ELSE IN THIS FAMILY SHARES"
        " (sample successes, sample size, population successes, population"
        " size, cumulative) and EVERY permutation returns a plausible"
        " probability. Microsoft's own example HYPGEOM.DIST(1,4,8,20,FALSE) is"
        " 0.363261. ⚠ The cumulative arm is a SUM -- there is no closed form --"
        " bounded by the sample size."
    )


def _confidence_note() -> String:
    return String(
        "⛔ THE PAIR'S DISCRIMINATOR IS AN ERROR CODE, NOT A VALUE."
        " CONFIDENCE.NORM and CONFIDENCE.T agree asymptotically in size, so a"
        " large-n fixture cannot tell them apart; at size = 1 CONFIDENCE.T is"
        " #DIV/0! (zero degrees of freedom) and CONFIDENCE.NORM answers a"
        " number. Microsoft's documented examples are at size = 50:"
        " CONFIDENCE.NORM(0.05,2.5,50) = 0.692951912 and"
        " CONFIDENCE.T(0.05,1,50) = 0.284196855."
    )


def _rate_not_mean_note() -> String:
    return String(
        "⚠ THE PARAMETER IS NOT THE MEAN. EXPON.DIST's lambda is a RATE"
        " (EXPON.DIST(0.2,10,TRUE) is 1-e^-2 = 0.864665; a mean-parameter"
        " kernel answers 0.0198), GAMMA.DIST's beta is a SCALE (a rate-reading"
        " kernel answers 1.0 to nine digits for Microsoft's own example), and"
        " WEIBULL.DIST is SHAPE then SCALE (swapped it answers 1.0 instead of"
        " 0.929581). ⚠ A density arm may EXCEED 1 -- EXPON.DIST(0.2,10,FALSE)"
        " is 1.3533528 -- so a kernel clamping to a probability is wrong and"
        " looks safe."
    )


# =============================================================================
# ⭐⭐ THE MATH / DATE / LOGICAL / INFORMATION TRANCHE.
# =============================================================================
def _reciprocal_trig_note() -> String:
    return String(
        "SEC / CSC / COT / SECH / CSCH / COTH are RECIPROCALS, and the family"
        " splits on the ERROR CLASS rather than on the maths. cos and cosh have"
        " no exact zero in binary64, so SEC and SECH are TOTAL. sin(0), sinh(0)"
        " and tanh(0) are exactly 0.0, so CSC(0), CSCH(0), COT(0) and COTH(0)"
        " are all #DIV/0!. ⛔ A BLIND 1.0/libm(x) KERNEL RETURNS +inf THERE"
        " instead, which until this same commit rendered as a finite negative"
        " integer. ⚠ THE GUARD IS ON THE DENOMINATOR, NOT THE ARGUMENT:"
        " sin(PI()) is 1.22e-16 and not 0, so CSC(PI()) is a large finite"
        " number in Excel too, and an x==0 test would refuse the wrong set."
        " ⚠ COT is spelled cos/sin rather than 1/tan -- near pi/2 the two"
        " differ, because tan overflows to 1.6e16 first."
    )


def _acot_note() -> String:
    return String(
        "⛔ ACOT'S RANGE IS (0, pi), SO THE OBVIOUS SPELLING IS WRONG ON EVERY"
        " NEGATIVE ARGUMENT AND RIGHT ON EVERY POSITIVE ONE. ATAN(1/x) answers"
        " -pi/4 for ACOT(-1) where Excel answers 3pi/4 -- off by exactly pi,"
        " no error, no infinity, and invisible to any fixture without a"
        " negative argument. It also divides by zero at ACOT(0), where the"
        " answer is pi/2. The identity implemented is pi/2 - ATAN(x), which"
        " holds on both sides and is total."
    )


def _inverse_hyperbolic_note() -> String:
    return String(
        "THE THREE INVERSE HYPERBOLICS HAVE THREE DIFFERENT DOMAINS AND THAT IS"
        " THE WHOLE POINT: ASINH is TOTAL, ACOSH needs x >= 1, ATANH needs"
        " |x| < 1 STRICTLY, and ACOTH needs |x| > 1 STRICTLY -- the exact"
        " MIRROR of ATANH's. ⛔ SO ATANH(0.5) IS A NUMBER AND ACOTH(0.5) IS"
        " #NUM!, while ATANH(1) IS #NUM! AND ACOTH(2) IS A NUMBER. The two are"
        " the same formula reading (1+x)/(1-x) and (x+1)/(x-1); a kernel that"
        " copied one guard into the other answers plausible numbers on exactly"
        " the inputs the other refuses. libm gives NaN or +inf for all four"
        " out-of-domain cases -- finite-looking travellers, never errors."
        " ⚠ ACOSH(1), ASINH(0) and ATANH(0) are ALL 0, so a zero fixture"
        " collapses three distinct functions onto one value."
    )


def _sqrtpi_note() -> String:
    return String(
        "SQRT(number * pi), and a NEGATIVE argument is #NUM! rather than NaN --"
        " the same guard SQRT carries. ⚠ SQRTPI(0) IS 0, WHICH IS ALSO WHAT A"
        " KERNEL THAT FORGOT THE PI ANSWERS; SQRTPI(1) is sqrt(pi) ="
        " 1.7724538509055159 where a pi-less kernel answers 1, so that is the"
        " discriminating cell."
    )


def _multinomial_note() -> String:
    return String(
        "(sum n)! / (n1! * n2! * ...), and BOTH plausible misreadings return a"
        " NUMBER rather than an error: for (2,3) the answer is 10, a PRODUCT of"
        " factorials is 12 and a SUM of them is 8. Only a VALUE cell separates"
        " the three. ⚠ EVERY ARGUMENT IS TRUNCATED and a negative one is #NUM!."
        " ⚠ COMPUTED AS A RUNNING BINOMIAL PRODUCT, not fact(total)/prod(fact):"
        " the direct spelling is +inf at a total of 171 while the ANSWER is"
        " still small -- MULTINOMIAL(170,170) is ~1e102."
    )


def _roman_note() -> String:
    return String(
        "CLASSIC (form 0) ONLY, AND FORMS 1..4 ARE REFUSED WITH #VALUE! RATHER"
        " THAN SERVED WRONG. Excel's form argument selects one of five"
        " progressively more CONCISE renderings -- ROMAN(499) is CDXCIX at form"
        " 0, LDVLIV at 1, XDIX at 2, VDIV at 3 and ID at 4 -- each with its own"
        " subtraction rules, a table nobody can verify against a live Excel"
        " from here. A kernel that accepted the argument and rendered form 0"
        " anyway returns a CONFIDENT WRONG STRING for every non-zero form."
        " ⚠ DIVERGENCE: Excel treats form=FALSE as form 4; here FALSE coerces"
        " to 0 and is served as classic. ⚠ ROMAN(0) is the EMPTY STRING, and"
        " above 3999 or below 0 is #NUM!. ⚠ THE SUBTRACTIVE PAIRS ARE TABLE"
        " ENTRIES: a greedy kernel over I V X L C D M alone renders 4 as IIII."
    )


def _arabic_note() -> String:
    return String(
        "⛔ NOT THE INVERSE OF ROMAN AND MUST NOT BE WRITTEN AS ONE. Excel's"
        " ARABIC reads every CONCISE form too -- ARABIC(\"ID\") is 499, which"
        " ROMAN(499) never emits -- so a kernel that round-tripped through a"
        " canonical renderer would refuse exactly the inputs this function"
        " exists to read. The rule is positional: a letter worth LESS than the"
        " one to its right is SUBTRACTED, and that single rule reads every"
        " form. ⚠ A leading '-' is accepted, the empty string is 0, and a"
        " non-roman character is #VALUE!."
    )


def _iso_ceiling_note() -> String:
    return String(
        "THE SAME FUNCTION AS CEILING.PRECISE, AND SAYING SO IS THE POINT:"
        " ECMA-376 defines ISO.CEILING and Excel documents CEILING.PRECISE with"
        " identical wording, so the honest implementation is the SAME KERNEL"
        " and not a second one that can drift. ⛔ WHAT IT IS NOT IS CEILING,"
        " whose direction comes from SIGN AGREEMENT: ISO.CEILING(-2.1,-1) is -2"
        " where CEILING(-2.1,-1) is -3. Both answer 3 for (2.1,1), the cell"
        " every fixture starts with, so only the negative one tells them apart."
    )


def _days360_note() -> String:
    return String(
        "TWO METHODS THAT DISAGREE ON REAL DATES, so a kernel that served one"
        " and ignored the argument returns a confident wrong integer."
        " DAYS360(2026-01-15, 2026-03-31) is 76 US and 75 EUROPEAN;"
        " (2026-01-31, 2026-02-28) is 30 US and 28 EUROPEAN; (2026-02-28,"
        " 2026-03-31) is 30 US and 32 EUROPEAN. ⛔ THE TWO RULES ARE NOT"
        " 'CLAMP EVERYTHING TO 30'. US says LAST DAY OF A MONTH (so 28 February"
        " counts, where EUROPEAN tests only for 31); US's end-date adjustment"
        " READS the already-adjusted start day; and US can push the end date to"
        " the 1st of the NEXT month, an adjustment that ADDS days where every"
        " other clause removes them. Microsoft's documented wording is"
        " implemented verbatim, because there is no live Excel to check against"
        " from here."
    )


def _timevalue_note() -> String:
    return String(
        "HH:MM AND HH:MM:SS ONLY, 24-HOUR, AND THE NARROWING IS DELIBERATE."
        " Excel also reads '1:30 PM' and whatever the system locale's time"
        " separator is; both are LOCALE state this engine does not carry, and a"
        " kernel that guessed would read '1:30' as 13:30 for one user and 01:30"
        " for another. A #VALUE! for a form we cannot read is honest; a"
        " plausible number for the wrong reading is not. ⚠ TIMEVALUE(\"13:30\")"
        " is 0.5625, the same value TIME(13,30,0) produces, which is what makes"
        " the two cross-checkable. ⚠ '27:00' is #VALUE! here where"
        " TIME(27,0,0) WRAPS -- that one does arithmetic, this one parses a"
        " clock reading."
    )


def _datevalue_note() -> String:
    return String(
        "ISO YYYY-MM-DD ONLY, AND IT IS A NARROWING WITH A REASON. Excel's"
        " DATEVALUE reads whatever the SYSTEM LOCALE calls a date, so"
        " '03/04/2026' is 4 March in the UK and 3 April in the US -- the SAME"
        " STRING, two serials, 30 days apart, neither an error. This engine"
        " carries no locale, so serving MM/DD/YYYY would pick one country's"
        " answer for everybody and look right in every US fixture. ISO 8601 is"
        " the one spelling unambiguous in every locale. ⚠ THE RESULT IS THE"
        " 1900 SERIAL, LOTUS BUG INCLUDED: DATEVALUE(\"1900-03-01\") is 61, not"
        " 60, because that is what every other date function here consumes."
        " ⚠ '2026-02-30' is #VALUE! and NOT a rolled-over 2026-03-02, which is"
        " what DATE(2026,2,30) deliberately returns."
    )



# =============================================================================
# =============================================================================
def _base_width_note() -> String:
    return String(
        "TWO'S COMPLEMENT AT THREE DIFFERENT WIDTHS, all rendered in at most"
        " TEN characters: binary is 10 bits ([-512, 511]), octal 30 bits and"
        " hex 40 bits. THE SIGN IS DECIDED BY THE VALUE AND NOT BY THE DIGIT"
        " COUNT -- HEX2DEC(\"FFFFFFFFFF\") is -1 and HEX2DEC(\"FFFFFFFF\")"
        " is +4294967295, and a 32-bit-minded kernel answers -1 for both while"
        " agreeing with this one on every positive literal a reader tries by"
        " hand. `places` is IGNORED when the value is NEGATIVE: DEC2BIN(-9,4)"
        " is 1111110111, full width. The cross conversions range-check against"
        " the DESTINATION width, so OCT2BIN and HEX2BIN NARROW and refuse"
        " #NUM! outside [-512, 511]. THE ONE RULE HERE THAT IS THIS ENGINE'S"
        " AND NOT MICROSOFT'S: a `places` above ten characters is #NUM!"
        " rather than a wider rendering -- Microsoft's page does not state the"
        " case, so it is refused rather than extended, and it is graded in the"
        " Mojo kernel test rather than in the Excel-agreeing value oracle."
    )


def _bitwise_domain_note() -> String:
    return String(
        "THE DOMAIN IS 2^48, NOT 2^32 AND NOT 2^53. Each operand must be a"
        " non-negative INTEGER strictly below 2^48 or the answer is #NUM! --"
        " and for BITLSHIFT/BITRSHIFT the RESULT is range-checked too, so"
        " BITLSHIFT(1,48) is #NUM! where BITLSHIFT(1,47) is 140737488355328."
        " A NEGATIVE shift_amount SHIFTS THE OTHER WAY (BITRSHIFT(13,-2) is"
        " 52), which is why the two shift names are one kernel; |shift| > 53"
        " is #NUM!. The coercion failure and the domain failure are DIFFERENT"
        " codes: BITAND(\"x\",1) is #VALUE! and BITAND(-1,1) is #NUM!."
    )


def _erf_arity_note() -> String:
    return String(
        "ERF TAKES AN OPTIONAL UPPER LIMIT AND ERF.PRECISE DOES NOT, and that"
        " arity difference is the ENTIRE difference between the two names:"
        " ERF(1,2) is erf(2)-erf(1) = 0.152621472 where a kernel that ignores"
        " the second argument answers erf(1) = 0.842700793, a number of"
        " exactly the shape a reader expects. ERFC is computed as libm `erfc`"
        " and never as 1-erf(x) -- the subtraction cancels in the right tail"
        " -- and it accepts a NEGATIVE argument (ERFC(-1) = 1.842700793),"
        " which Excel before 2010 refused with #NUM!. All four share"
        " `xl_special_fn.xs_erf`/`xs_erfc` with `norm_s_cdf`, so the normal"
        " CDF and ERFC are the same libm call by construction."
    )


def _complex_form_note() -> String:
    return String(
        "A MALFORMED COMPLEX LITERAL IS #NUM! AND NOT #VALUE! -- Microsoft"
        " states that code on every consumer (\"If inumber is not in the form"
        " x+yi or x+yj\"), and #VALUE! is both the guess a reader makes and"
        " what a text-coercion failure gives, so the two complaints are"
        " reachable separately. THE SUFFIX IS PART OF THE VALUE: it rides"
        " through an operation (IMSUM(\"3+4j\",\"1+2j\") is \"4+6j\") and"
        " MIXING suffixes in one call is #VALUE!, where a kernel that always"
        " emits `i` returns the right complex number under the wrong spelling"
        " and passes any check that parses its answer back. THE COEFFICIENT 1"
        " IS OMITTED on render: COMPLEX(3,1) is \"3+i\", COMPLEX(0,-1) is"
        " \"-i\", COMPLEX(3,0) is \"3\". IMARGUMENT is atan2 and never"
        " atan(b/a) -- IMARGUMENT(\"-1\") is pi and the quotient form answers"
        " 0 -- and IMARGUMENT(\"0\") is #DIV/0! where IMDIV by zero is #NUM!:"
        " the two codes really do differ inside one category."
    )


def xl_all_notes() -> List[String]:
    """Every note this module defines, rendered.

    ⛔ IT EXISTS BECAUSE TWO NOTES WERE DEAD AND NOTHING NOTICED.
    `_plan_only_note` and `_scalar_only_note` were written, were named by
    BANNER COMMENTS in `xl_fn_table` ("`_scalar_only_note` SAYS WHY IN THE
    ROW"), and were attached to ZERO rows — so the source claimed an
    explanation the rendered TSV did not contain, and a caller with no Mojo
    read a row with an empty note where the code said there was prose.
    `test_every_defined_note_is_attached_to_some_row` walks this list against
    `xl_function_census()` and REDs on any member the census does not print.

    ⚠ THE RESIDUAL, STATED RATHER THAN HIDDEN: this list is hand-maintained,
    so a note added to this file and NOT added here escapes the check. That is
    a one-line omission RIGHT NEXT TO the definition, where the old failure was
    a note and its row drifting apart across two files. The check catches the
    direction the two orphans actually failed in — a note that is defined and
    goes unattached — and it cannot catch a note that was never enrolled.

    ⚠ AND IT IS NOT A SET OF NAMES BUT OF **TEXTS**, deliberately. A name list
    would need reflection this language does not have; the text is what the
    census actually prints, so `note in census` is a check of the rendered
    artefact rather than of an intention."""
    var out = List[String]()
    out.append(_ceiling_note())
    out.append(_condif_note())
    out.append(_condifs_note())
    out.append(_correl_note())
    out.append(_address_note())
    out.append(_count_note())
    out.append(_counta_note())
    out.append(_hyperlink_note())
    out.append(_textba_note())
    out.append(_valuetotext_note())
    out.append(_days_note())
    out.append(_dynarray_note())
    out.append(_edate_note())
    out.append(_exact_note())
    out.append(_filter_note())
    out.append(_int_note())
    out.append(_isblank_note())
    out.append(_istype_note())
    out.append(_median_note())
    out.append(_mod_note())
    out.append(_now_note())
    out.append(_plan_only_note())
    out.append(_product_note())
    out.append(_resident_note())
    out.append(_round_note())
    out.append(_sample_stat_note())
    out.append(_scalar_only_note())
    out.append(_search_note())
    out.append(_volatile_note())
    out.append(_weekday_note())
    out.append(_xor_note())
    out.append(_atan2_note())
    out.append(_even_odd_note())
    out.append(_exp_note())
    out.append(_inverse_trig_note())
    out.append(_iserr_note())
    out.append(_log_domain_note())
    out.append(_log_note())
    out.append(_parity_note())
    out.append(_quotient_note())
    out.append(_radians_note())
    out.append(_time_note())
    out.append(_time_of_day_note())
    out.append(_trunc_note())
    out.append(_char_note())
    out.append(_choose_note())
    out.append(_clean_note())
    out.append(_code_note())
    out.append(_gcd_lcm_note())
    out.append(_isoweeknum_note())
    out.append(_mround_note())
    out.append(_n_fn_note())
    out.append(_rept_note())
    out.append(_t_fn_note())
    out.append(_base_note())
    out.append(_combin_note())
    out.append(_combina_note())
    out.append(_concatenate_note())
    out.append(_decimal_note())
    out.append(_error_type_note())
    out.append(_fact_note())
    out.append(_factdouble_note())
    out.append(_isnontext_note())
    out.append(_logical_constant_note())
    out.append(_precise_round_note())
    out.append(_sumsq_note())
    out.append(_type_note())
    out.append(_unichar_note())
    out.append(_unicode_note())
    out.append(_betadist_note())
    out.append(_betainv_note())
    out.append(_chidist_note())
    out.append(_chiinv_note())
    out.append(_compat_rename_note())
    out.append(_encodeurl_note())
    out.append(_fdist_note())
    out.append(_finv_note())
    out.append(_hypgeomdist_note())
    out.append(_lognormdist_note())
    out.append(_negbinomdist_note())
    out.append(_norminv_category_note())
    out.append(_normsdist_note())
    out.append(_tdist_note())
    out.append(_tinv_note())
    out.append(_annuity_note())
    out.append(_cum_note())
    out.append(_db_rate_rounding_note())
    out.append(_ddb_clip_note())
    out.append(_dollar_fraction_note())
    out.append(_effect_nominal_note())
    out.append(_ipmt_ppmt_note())
    out.append(_ispmt_note())
    out.append(_npv_note())
    out.append(_rate_solver_note())
    out.append(_rri_pduration_note())
    out.append(_sln_syd_note())
    # ---- ⭐⭐ the STATISTICAL DISTRIBUTION family ----
    out.append(_beta_rescale_note())
    out.append(_binom_range_note())
    out.append(_confidence_note())
    out.append(_dist_inv_note())
    out.append(_dist_tail_note())
    out.append(_gamma_fn_note())
    out.append(_gammaln_note())
    out.append(_hypgeom_note())
    out.append(_norm_dist_note())
    out.append(_norm_s_dist_note())
    out.append(_permut_note())
    out.append(_rate_not_mean_note())
    out.append(_special_fn_note())
    out.append(_stat_scalar_note())
    out.append(_acot_note())
    out.append(_arabic_note())
    out.append(_datevalue_note())
    out.append(_days360_note())
    out.append(_inverse_hyperbolic_note())
    out.append(_iso_ceiling_note())
    out.append(_multinomial_note())
    out.append(_reciprocal_trig_note())
    out.append(_roman_note())
    out.append(_sqrtpi_note())
    out.append(_timevalue_note())
    out.append(_devsq_note())
    out.append(_nonarith_mean_note())
    out.append(_population_moment_note())
    out.append(_shape_moment_note())
    out.append(_base_width_note())
    out.append(_bitwise_domain_note())
    out.append(_erf_arity_note())
    out.append(_complex_form_note())
    out.append(_yearfrac_note())
    out.append(_daycount_security_note())
    return out^


def _odf_only_note() -> String:
    return String(
        "⚠ NOT A MICROSOFT WORKSHEET FUNCTION. This name is in the published"
        " 532-name union because OOXML and/or ODF OpenFormula define it, and"
        " Microsoft's alphabetical list does not contain it at all -- the"
        " reference TSV's category column says '(not in Microsoft's list)' for"
        " exactly these. ⛔ SERVING ONE IS A DECISION AND NOT A DEFAULT: each"
        " served here is defined BY THE STANDARD in terms of a kernel this"
        " table already has, so the row adds a SPELLING and not a second"
        " opinion about the mathematics. The ones that are NOT served (DDE,"
        " FORMULA, MULTIPLE.OPERATIONS, TABLE, MVALUE) are refused BY NAME with"
        " the reason, in xl_absent_common_names()."
    )


def _maxifs_note() -> String:
    return String(
        "⭐ SERVED, AND THE RECORDED BLOCKER FOR IT WAS FALSE."
        " `gen_excel_function_reference.py` carried 'blocked on a"
        " criteria-string parser that no slice has built';"
        " rel_condagg_build.build_criteria_predicate -- which SUMIFS, COUNTIFS"
        " and AVERAGEIFS already use -- was already there. The whole"
        " change was this row plus a rel_fn_descriptor registration, because"
        " _agg_expr_for_name is keyed on the XLA_* TAG THIS ROW CARRIES and"
        " xl_plan_build dispatches on the FAMILY: neither knows the name."
        " ⚠ PLAN-ONLY IN SUBSTANCE. The XLR_SCALAR bit is there because a"
        " SCALAR descriptor IS registered (the _condagg_placeholder, which"
        " answers #VALUE! for any scalar arguments) and the census must say so;"
        " the answer comes from the PLAN door. ⛔ AND NOT XLR_INLINE_REL:"
        " fn_rel_condagg lowers SUMIFS and COUNTIFS only."
    )


# =============================================================================
# =============================================================================
def _yearfrac_note() -> String:
    return String(
        "★★ FIVE DAY-COUNT BASES AND THE TWO THAT CARRY END-OF-MONTH RULES ARE"
        " WHERE IMPLEMENTATIONS DIVERGE. 0 = US (NASD) 30/360, 1 ="
        " actual/actual, 2 = actual/360, 3 = actual/365, 4 = European 30E/360;"
        " basis DEFAULTS TO 0, not to 1, so a kernel defaulting to"
        " actual/actual is wrong on every call that omits the argument."
        " ⛔ THIS IS NOT DAYS360/360 AND UNIFYING THE TWO BREAKS ONE OF THEM:"
        " measured, 2018-01-31 -> 2018-02-28 is 30 under DAYS360 US and 28"
        " under YEARFRAC basis 0, and 2021-02-28 -> 2021-03-31 is 30 under"
        " DAYS360 US and 31 under YEARFRAC basis 0 -- DAYS360 sits BETWEEN the"
        " two YEARFRAC answers, so one implementation cannot serve both."
        " ⚠ THE BASIS-0 CLAUSE ORDER IS A STATED, UNVERIFIED CHOICE ("
        " there is no live Excel reachable from this tree, so"
        " the rule implemented is ODF 1.2 part 2 (OpenFormula) 4.11.7 as"
        " implemented in LibreOffice GetYearFrac() at the pinned tag"
        " libreoffice-25.2.5.2 -- the same tag this repo already cites as its"
        " published OOXML/ODFF name source. Day1 31 -> 30; THEN day1 30 and"
        " day2 31 -> day2 30; ELSE the February arm, with day2's end-of-Feb"
        " adjustment NESTED INSIDE day1's. Flattening that nesting makes"
        " YEARFRAC(2020-02-29, 2021-02-28, 0) answer 358/360 instead of"
        " EXACTLY 1.0, which is a plausible year fraction and not an error."
        " ⚠ BASIS 1 CARRIES A LEAP-SPANNING RULE whose absence answers EXACTLY"
        " 1.0: YEARFRAC(2019-07-01, 2020-06-30, 1) is 365/366 because"
        " 2020-02-29 lies inside the span -- neither end is in February and"
        " 2019 is not a leap year, so a kernel reading the START year's length"
        " reports a full year for a span one day short of one."
        " ⚠ SYMMETRIC, where DAYS360 is a SIGNED difference: ODF orders the"
        " dates before counting, so YEARFRAC(b, a) == YEARFRAC(a, b)."
        " GRADED against Microsoft's own published page, all three cells"
        " (0.58055556 / 0.57650273 / 0.57808219 for 2012-01-01 -> 2012-07-30"
        " on bases 0, 1 and 3)."
    )


def _daycount_security_note() -> String:
    return String(
        "A CLOSED FORM OVER yearfrac(d1, d2, basis) AND NOTHING ELSE -- no"
        " second day count, no rounding wart, no iteration. Microsoft defines"
        " all eight of these names as a ratio of 'number of days between' to"
        " 'B = number of days in a year, depending on the year basis', i.e."
        " over ONE day-count fraction, and that is how they are implemented."
        " ⚠ LIBREOFFICE DOES NOT: it calls GetYearFrac()"
        " (the ODF 4.11.7 routine) from DISC, PRICEMAT, YIELDDISC and YIELDMAT"
        " but an older GetYearDiff() -- a DIFFERENT basis-0 rule, and a basis-1"
        " denominator that is simply the START year's length -- from ACCRINTM,"
        " RECEIVED, PRICEDISC and INTRATE. Every one of the eight here"
        " reproduces its OWN Microsoft published worked example EXACTLY,"
        " including the four LibreOffice routes through GetYearDiff, which is"
        " the evidence for following the published formula rather than the"
        " implementation. ⛔ ONE PUBLISHED EXAMPLE IS ITSELF WRONG AND IT IS"
        " RECORDED RATHER THAN CHASED: Microsoft's DISC page"
        " prints maturity 01/01/2048 with Result 0.001038, which is"
        " not reachable from those inputs under any basis (the span is 29.5"
        " years and 0.02025/29.5 is 0.000686) and IS reproduced to all seven"
        " published digits at maturity 01/01/2038 -- the date the same page's"
        " Remarks, and PRICEMAT's and YIELDMAT's, describe. The page's prose"
        " and data were re-dated 2008 -> 2018 and the result cell was not"
        " recomputed. ⚠ THE ERROR THRESHOLDS ARE NOT UNIFORM and the pages say"
        " so: rate < 0 is #NUM! on PRICEMAT and YIELDMAT (rate = 0 is a legal"
        " zero-coupon call) while pr <= 0 is #NUM! because pr is a divisor;"
        " basis outside 0..4 is #NUM! and an invalid serial is #VALUE!."
    )


# =============================================================================
# =============================================================================
#
# ⚠ THE NOTE BELOW IS SHARED BY EVERY ROW IN THE TRANCHE AND SAYS THE THING
# THAT IS TRUE OF ALL OF THEM; the per-name divergences (population vs sample
# divisor, argument ORDER) get their OWN note, because a shared note that tried
# to carry both would be read as applying to whichever row the reader landed
# on.
def _bivar_unbound_note() -> String:
    return String(
        "REACHABLE-BUT-UNBOUND until its Excel name was bound, the same finding"
        " as CORREL,"
        " one tag over: the AGG_* tag this name needs already had a"
        " plan-IR constant (agg_expr.mojo), a plan_wire_vocabulary member, a"
        " LogicalPlan arm, a 0-key scalar-fold arm (agg_scalar_fold.mojo) and a"
        " grouped executor arm (agg_extended_grouped.mojo), plus a SQL binding"
        " in sql_binder._bivariate_agg_tag. What was missing was ONLY the Excel"
        " NAME and the XLA_* -> AGG_* arm in rel_agg_build. BIVARIATE, so both"
        " ranges must be COLUMNS OF THE SAME catalog table: this plan has one"
        " scan leaf and pairs the columns by ROW, which is what Excel's"
        " positional pairing means over a table."
    )


def _covar_divisor_note() -> String:
    return String(
        "POPULATION vs SAMPLE IS THE WHOLE POINT OF THE PAIR AND THEY ARE NOT"
        " ALIASES. COVARIANCE.P and the legacy COVAR divide the sum of cross"
        " deviations by n (AGG_COVAR_POP); COVARIANCE.S divides by n-1"
        " (AGG_COVAR_SAMP). Over the six-row regression fixture the two answer"
        " 5.333333333333333 and 6.4 -- a name aliased onto its neighbour"
        " returns a plausible number of the right sign and magnitude, which is"
        " the exact defect shape (var_pop aliased to var_samp) this effort"
        " has already shipped once. NULL RULES DIFFER TOO, and they are the"
        " engine's rather than Excel's: covar_pop is 0.0 over a single pair"
        " where covar_samp is NULL, and Excel's own COVARIANCE.S is #DIV/0!"
        " there."
    )


def _regr_arg_order_note() -> String:
    return String(
        "ARGUMENT ORDER IS LOAD-BEARING AND EXCEL'S ORDER IS THE ENGINE'S."
        " Microsoft publishes SLOPE/INTERCEPT/RSQ as F(known_ys, known_xs) --"
        " DEPENDENT FIRST -- and komira_core's regr_* tags are documented"
        " regr_slope(y, x), dependent first, so the two Excel arguments pass"
        " through in the order written. A builder that swapped them would"
        " answer C/Sy instead of C/Sx: a real number from a well-formed plan."
        " The value cell for this row is graded over a fixture whose Sxx and"
        " Syy DIFFER (17.5 vs 70), because the older `pairs` fixture has y a"
        " PERMUTATION of x -- Sxx == Syy -- so a swapped SLOPE is numerically"
        " indistinguishable there. RSQ is symmetric in its two arguments and"
        " cannot discriminate order at all; SLOPE and INTERCEPT are what cover"
        " it. DIVERGENCE FROM EXCEL AT THE DEGENERATE SIZES is the engine's, as"
        " for CORREL: over a constant-x group regr_slope is a non-NULL NaN and"
        " regr_intercept is NULL (both MEASURED on DuckDB v1.5.3), where Excel"
        " is #DIV/0!."
    )


def _pearson_note() -> String:
    return String(
        "PEARSON IS CORREL. Microsoft documents the two as returning the same"
        " Pearson product-moment correlation coefficient, so this row carries"
        " XLA_CORR -- the identical tag, the identical plan, the identical"
        " AGG_CORR kernel -- rather than a second implementation of the same"
        " mathematics. It is an ALIAS BY TAG and not by string rewriting: no"
        " site rewrites PEARSON to CORREL, so a divergence between them is not"
        " expressible. Read _correl_note for the degenerate-size divergence"
        " from Excel, which this row inherits exactly."
    )
