# =============================================================================
# Which SQL scalar functions run through run_sql, and which only bind
# =============================================================================
#
# What each test proves:
#   * test_function_table_is_what_the_engine_measures: every `scalar_fn` case
#     is run through run_sql over the corpus's tables T and E and compared with the
#     answer the pinned DuckDB gave it, every refused or unrowed name is
#     probed, and the resulting table (function_coverage.tsv, one line per
#     name of sql_scalar_fn_spec and of the common-analysis list) is exactly
#     the committed file. A function that starts or stops running, a row
#     added or removed, and a case added to the corpus each change a line and
#     fail it; the failure message holds each changed line (`- ` committed,
#     `+ ` measured) to apply to the file. Where the oracle runs
#     (linux-x86_64) the table is held byte for byte; elsewhere both tables
#     are first folded on the lines whose every case calls a transcendental
#     function (fold_libm_outcomes), as libm_rule holds such an answer within
#     4 ulp there.
#   * test_a_libm_fold_sums_exact_and_within_4_ulps: on a listed line,
#     `equal` and `equal_within_4_ulps` become one `equal` count in label
#     order, mixed with `differs` and alone; `differs` alone, a probe outcome,
#     an unlisted line, the comment lines and the trailing newline are
#     unchanged; a count that is not a number is refused.
#   * test_libm_lines_are_the_names_only_libm_cases_credit: a name credited
#     by cases that each call a transcendental function is listed, one also
#     credited by a case that calls none is not, and no case lists nothing.
#   * test_a_changed_table_names_each_changed_line: a changed line is its
#     committed and its measured text, an added line and a dropped line are
#     each named, and an equal table names none.
#   * test_make_date_last_day_make_timestamp_equal_duckdb: in the committed
#     function_coverage.tsv the lines of make_date, last_day and
#     make_timestamp each read equal:n, n being the number of staged cases
#     that call the name.
#   * test_the_ladder_reader_reads_each_row_shape: aliases share a line, a
#     refusal row names its family, an inline reason is named, a name held in
#     a constant is kept, and a source without the function, a row without a
#     SqlFnSpec call and a call with one argument are refused by name.
#   * test_called_names_are_the_identifiers_before_a_parenthesis: a case's
#     function names, each once, in order; a digit-led run is no name.
#   * test_the_comparison_is_not_vacuous: a case's own answer compares equal;
#     one changed value, a missing row and an added row do not, in both row
#     orders; a float one step away is equal within ulps and not exactly.
#   * test_timestamp_and_list_answers_are_compared_by_value: a TIMESTAMP
#     answer (date_trunc) and a list-of-strings answer (string_split) compare
#     equal to DuckDB's text; a timestamp one microsecond or one day off, a
#     list item changed, an item split in two, and the list of one empty
#     string read as the empty list do not.
#   * test_probe_names_the_step_that_refused: a name with no row stops at
#     bind, a name that runs answers ok.
#   * test_every_staged_case_is_run: each case has a SQL text and an answer,
#     and the run covers all of them.

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import is_oracle_host
from komira_sql_conformance.function_coverage import (
    TABLE_HEADER,
    CaseRun,
    called_names,
    case_names,
    compare_answer,
    fold_libm_outcomes,
    ladder_rows,
    libm_line_names,
    measure,
    new_context,
    probe,
    run_cases,
)
from runtime_paths import read_data
from sdk_exec.engine_sql import run_sql


def _key(line: String) -> String:
    """A line's name (its text before the first tab; a comment line is its
    own key)."""
    var tab = line.find("\t")
    if tab < 0 or line.startswith("#"):
        return line
    return String(line[byte=:tab])


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for piece in text.split("\n"):
        if piece.byte_length() > 0:
            out.append(String(piece))
    return out^


def changed_lines(committed: String, measured: String) raises -> String:
    """The lines of `measured` that are not in `committed`, each as `+ line`,
    and the lines of `committed` it drops or changes, each as `- line`, in
    the measured order (a changed line is its `- ` line then its `+ ` line;
    a dropped line comes last). The test runner prints only the end of a
    failing test's output, so the message holds these, not the whole table."""
    var old = Dict[String, String]()
    var old_lines = _lines(committed)
    for line in old_lines:
        old[_key(line)] = line
    var seen = Dict[String, Bool]()
    var out = String()
    for line in _lines(measured):
        var k = _key(line)
        seen[k] = True
        if k in old:
            if old[k] != line:
                out += "- " + old[k] + "\n+ " + line + "\n"
        else:
            out += "+ " + line + "\n"
    for line in old_lines:
        if _key(line) not in seen:
            out += "- " + line + "\n"
    return out


def test_function_table_is_what_the_engine_measures() raises:
    var m = measure(read_data("sql_fn_table.mojo"))
    var measured = m.table.copy()
    var committed = read_data("function_coverage.tsv")
    var where = String("")
    if not is_oracle_host():
        measured = fold_libm_outcomes(measured, m.libm_names)
        committed = fold_libm_outcomes(committed, m.libm_names)
        where = " (measured off the oracle host: commit a table measured on linux-x86_64)"
    if measured != committed:
        assert_true(
            False,
            "function_coverage.tsv is not what the engine measures" + where + "; the"
            " lines that change it are\n<<<<\n"
            + changed_lines(committed, measured) + ">>>>",
        )


def test_a_libm_fold_sums_exact_and_within_4_ulps() raises:
    var table = (
        "# a comment\tequal_within_4_ulps:1\n"
        "sin\tFNK_MATH_FN\t-\tyes\t1\tequal_within_4_ulps:1\n"
        "cos\tFNK_MATH_FN\t-\tyes\t3\tequal:1,equal_within_4_ulps:2\n"
        "ln\tFNK_MATH_FN\t-\tyes\t3\tdiffers:1,equal:1,equal_within_4_ulps:1\n"
        "exp\tFNK_MATH_FN\t-\tyes\t1\tdiffers:1\n"
        "nextafter\tFNK_REFUSED\t_R_MATH2\t-\t1\tprobe:refused_bind\n"
        "tan\tFNK_MATH_FN\t-\tyes\t1\tequal_within_4_ulps:1\n"
    )
    var names: List[String] = ["sin", "cos", "ln", "exp", "nextafter"]
    assert_equal(
        fold_libm_outcomes(table, names),
        "# a comment\tequal_within_4_ulps:1\n"
        "sin\tFNK_MATH_FN\t-\tyes\t1\tequal:1\n"
        "cos\tFNK_MATH_FN\t-\tyes\t3\tequal:3\n"
        "ln\tFNK_MATH_FN\t-\tyes\t3\tdiffers:1,equal:2\n"
        "exp\tFNK_MATH_FN\t-\tyes\t1\tdiffers:1\n"
        "nextafter\tFNK_REFUSED\t_R_MATH2\t-\t1\tprobe:refused_bind\n"
        "tan\tFNK_MATH_FN\t-\tyes\t1\tequal_within_4_ulps:1\n",
    )
    assert_equal(fold_libm_outcomes(table, List[String]()), table)
    var caught = False
    try:
        _ = fold_libm_outcomes("sin\tFNK_MATH_FN\t-\tyes\t1\tequal:x\n", names)
    except:
        caught = True
    assert_true(caught, "an equal count that is not a number is refused")


def test_libm_lines_are_the_names_only_libm_cases_credit() raises:
    var runs = List[CaseRun]()
    runs.append(CaseRun("sin", ["sin", "round"], True, "equal"))
    runs.append(CaseRun("cos", ["cos"], True, "equal_within_4_ulps"))
    runs.append(CaseRun("round", ["round"], False, "equal"))
    runs.append(CaseRun("sin_again", ["sin"], True, "equal"))
    var names = libm_line_names(runs)
    assert_equal(len(names), 2)
    assert_equal(names[0], "sin")
    assert_equal(names[1], "cos")
    assert_equal(len(libm_line_names(List[CaseRun]())), 0)


def test_a_changed_table_names_each_changed_line() raises:
    var committed = "# h\na\tFNK_X\tno_case\nb\tFNK_X\tequal:1\nc\tFNK_X\tequal:1\n"
    var measured = "# h\na\tFNK_X\tequal:2\nb\tFNK_X\tequal:1\nd\tFNK_X\tdiffers:1\n"
    assert_equal(
        changed_lines(committed, measured),
        "- a\tFNK_X\tno_case\n+ a\tFNK_X\tequal:2\n+ d\tFNK_X\tdiffers:1\n- c\tFNK_X\tequal:1\n",
    )
    assert_equal(changed_lines(committed, committed), "")


def _table_line(table: String, name: String) -> String:
    """The line of `table` for `name`, or an empty string."""
    for line in table.split("\n"):
        if String(line).startswith(name + "\t"):
            return String(line)
    return String("")


def _staged_cases_calling(name: String) raises -> Int:
    var n = 0
    var names = case_names()
    for i in range(len(names)):
        var query = String("")
        for line in read_data("sql/" + names[i] + ".sql").split("\n"):
            if not String(line).startswith("--"):
                query += String(line) + "\n"
        var calls = called_names(query)
        for j in range(len(calls)):
            if calls[j] == name:
                n += 1
                break
    return n


def test_make_date_last_day_make_timestamp_equal_duckdb() raises:
    var committed = read_data("function_coverage.tsv")
    var wanted = List[String]()
    wanted.append("make_date")
    wanted.append("last_day")
    wanted.append("make_timestamp")
    for i in range(len(wanted)):
        var line = _table_line(committed, wanted[i])
        var n = _staged_cases_calling(wanted[i])
        assert_true(n > 0, wanted[i] + " has staged cases")
        var fields = line.split("\t")
        var outcome = String(fields[len(fields) - 1]) if len(fields) > 0 else String("")
        if outcome != "equal:" + String(n):
            assert_true(
                False,
                wanted[i]
                + " is not equal to DuckDB over its "
                + String(n)
                + " staged cases in function_coverage.tsv; its line is: "
                + line,
            )


def _def_source(rows: String) -> String:
    return (
        "x\ndef sql_scalar_fn_spec(name: String) -> SqlFnSpec:\n"
        + rows
        + "    return SqlFnSpec()\ndef sql_date_part_unit(name: String):\n"
    )


def test_the_ladder_reader_reads_each_row_shape() raises:
    var rows = ladder_rows(
        _def_source(
            "    if name == \"upper\" or name == \"ucase\": return SqlFnSpec(FNK_STRING_FN, STRFN_UPPER, 1, 1)\n"
            "    # if name == \"commented\": return SqlFnSpec(FNK_STRING_FN, X, 1, 1)\n"
            "    if name == \"nextafter\": return SqlFnSpec(FNK_REFUSED, _R_MATH2)\n"
            "    if name == \"odd\": return SqlFnSpec(FNK_REFUSED, \"inline reason\")\n"
            "    if name == CAST_DESUGAR_NAME: return SqlFnSpec(FNK_DESUGAR, DSG_CAST, 1, 2)\n"
        )
    )
    assert_equal(len(rows), 4)
    assert_equal(len(rows[0].names), 2)
    assert_equal(rows[0].names[0], "upper")
    assert_equal(rows[0].names[1], "ucase")
    assert_equal(rows[0].kind, "FNK_STRING_FN")
    assert_equal(rows[0].family, "-")
    assert_equal(rows[1].names[0], "nextafter")
    assert_equal(rows[1].kind, "FNK_REFUSED")
    assert_equal(rows[1].family, "_R_MATH2")
    assert_equal(rows[2].family, "inline")
    assert_equal(rows[3].names[0], "$CAST_DESUGAR_NAME")
    assert_equal(rows[3].kind, "FNK_DESUGAR")

    var caught = False
    try:
        _ = ladder_rows("no table here")
    except e:
        caught = "sql_scalar_fn_spec is not in the source text" in String(e)
    assert_true(caught, "a source without the function is refused")
    caught = False
    try:
        _ = ladder_rows(_def_source("    if name == \"x\": return 1\n"))
    except e:
        caught = "a row without a SqlFnSpec call" in String(e)
    assert_true(caught, "a row without a SqlFnSpec call is refused")
    caught = False
    try:
        _ = ladder_rows(_def_source("    if name == \"x\": return SqlFnSpec()\n"))
    except e:
        caught = "one argument" in String(e)
    assert_true(caught, "a call with one argument is refused")


def test_called_names_are_the_identifiers_before_a_parenthesis() raises:
    var names = called_names(
        "SELECT k, Date_Part('dow', t), upper(s), upper(u), 2(x), a_1(y) FROM T WHERE k IN(1,2)"
    )
    assert_equal(len(names), 4)
    assert_equal(names[0], "date_part")
    assert_equal(names[1], "upper")
    assert_equal(names[2], "a_1")
    assert_equal(names[3], "in")
    assert_equal(len(called_names("SELECT k FROM T")), 0)


def test_the_comparison_is_not_vacuous() raises:
    var ctx = new_context()
    var upper = run_sql(ctx, "SELECT k, upper(s) FROM T")
    assert_true(not upper.refusal)
    assert_equal(len(upper.batches), 1)
    ref batch = upper.batches[0]
    var tsv = read_data("duckdb/upper.tsv")
    assert_equal(compare_answer(batch, tsv, False, 0), "")
    assert_true(compare_answer(batch, tsv.replace("ABC", "ABD"), False, 0) != "", "a value changed")
    assert_true(compare_answer(batch, tsv.replace("12\tABCDEFGH\n", ""), False, 0) != "", "a row missing")
    assert_true(compare_answer(batch, tsv + "99\tZ\n", False, 0) != "", "a row added")
    var sorted_tsv = read_data("duckdb/upper.tsv")
    var by_k = run_sql(ctx, "SELECT k, upper(s) FROM T ORDER BY k")
    assert_equal(len(by_k.batches), 1)
    assert_true(compare_answer(by_k.batches[0], sorted_tsv, True, 0) != "", "ordered: DuckDB's rows are in text order, not k order")
    assert_equal(compare_answer(by_k.batches[0], sorted_tsv, False, 0), "")
    var sqrt = run_sql(ctx, "SELECT k, sqrt(d) FROM T WHERE k = 2")
    assert_equal(len(sqrt.batches), 1)
    assert_equal(compare_answer(sqrt.batches[0], "k\tsqrt(d)\n2\t10.0\n", False, 0), "")
    assert_true(
        compare_answer(sqrt.batches[0], "k\tsqrt(d)\n2\t10.000000000000002\n", False, 0) != "",
        "one step away is not equal exactly",
    )
    assert_equal(
        compare_answer(sqrt.batches[0], "k\tsqrt(d)\n2\t10.000000000000002\n", False, 4), ""
    )


def test_timestamp_and_list_answers_are_compared_by_value() raises:
    var ctx = new_context()
    var trunc = run_sql(ctx, "SELECT k, date_trunc('hour', t) FROM T")
    assert_equal(len(trunc.batches), 1)
    ref tb = trunc.batches[0]
    var hour = read_data("duckdb/date_trunc_hour.tsv")
    assert_equal(compare_answer(tb, hour, False, 0), "")
    assert_true(
        compare_answer(tb, hour.replace("0\t2015-09-04 12:00:00", "0\t2015-09-04 12:00:00.000001"), False, 0) != "",
        "a timestamp one microsecond off",
    )
    assert_true(
        compare_answer(tb, hour.replace("0\t2015-09-04 12:00:00", "0\t2015-09-05 12:00:00"), False, 0) != "",
        "a timestamp one day off",
    )
    var split = run_sql(ctx, "SELECT k, string_split(s, ',') FROM T")
    assert_equal(len(split.batches), 1)
    ref sb = split.batches[0]
    var lists = read_data("duckdb/string_split_comma.tsv")
    assert_equal(compare_answer(sb, lists, False, 0), "")
    assert_true(compare_answer(sb, lists.replace("[a, b]", "[a, c]"), False, 0) != "", "an item changed")
    assert_true(compare_answer(sb, lists.replace("[a, b]", "['a, b']"), False, 0) != "", "two items read as one")
    assert_true(compare_answer(sb, lists.replace("[abc]", "[ab, c]"), False, 0) != "", "one item read as two")
    assert_true(compare_answer(sb, lists.replace("0\t['']", "0\t[]"), False, 0) != "", "[''] is not []")


def test_probe_names_the_step_that_refused() raises:
    var ctx = new_context()
    assert_equal(probe(ctx, "zzz_not_a_function"), "refused_bind")
    assert_equal(probe(ctx, "abs"), "ok")


def test_every_staged_case_is_run() raises:
    var names = case_names()
    assert_true(len(names) > 250, "the scalar_fn corpus is staged")
    for i in range(len(names)):
        assert_true(read_data("sql/" + names[i] + ".sql").byte_length() > 0, names[i])
        assert_true(read_data("duckdb/" + names[i] + ".tsv").byte_length() > 0, names[i])
    var ctx = new_context()
    assert_equal(len(run_cases(ctx)), len(names))
    assert_true(String(TABLE_HEADER).startswith("#"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
