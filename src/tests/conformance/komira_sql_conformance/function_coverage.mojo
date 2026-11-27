"""Which scalar functions run through `run_sql`, and which do not.

`sql.sql_fn_table.sql_scalar_fn_spec` names every SQL function the binder has
a row for. A row can mean four different things, and counting the lines of the
table (or its rows) says none of them:

  * a row that lowers (`FNK_MATH_FN` and the other lowering kinds) and a case
    of the `scalar_fn` corpus calls it: the case is run through `run_sql` over
    the corpus's tables T and E and its rows are compared with the committed answer
    of the pinned DuckDB (`equal`, `equal_within_4_ulps`, `differs`), or the
    run refuses at a step (`refused_<step>`: the name bound or did not, and
    the step says where it stopped);
  * a row that lowers and no case calls it (`no_case`): bound by the table,
    never run by this measurement;
  * a refusal row (`FNK_REFUSED`): `SELECT <name>(k) FROM T` is run, and the
    step that refused it is recorded (`probe:refused_bind` is the row
    working as written; `probe:ok` would be a refused name that runs);
  * a name with no row at all (`NO_ROW`), probed the same way.

Two limits of what a line says. A case is credited to every function it
calls (`called_names` reads every identifier before a parenthesis), so a count
is per case, not per function. `unreadable` is any raise of the comparison
(render, parse or compare): a result type the answer parser does not read
(it reads timestamps and lists of strings, komira_plan_harness/duckdb_tsv.mojo),
or a cell spelt as DuckDB does not write it. `measure` returns the table as text, one line per name; the test holds
it to the committed file, so the file cannot say more or less than the engine
does. The rows are read from the table's source text, not from a list kept
beside it: a row added to the table is a new line here and fails the test
until the committed file has it.

The committed file is measured where the pinned DuckDB runs (linux-x86_64,
glibc's libm). Elsewhere a transcendental function's answer is held to the
oracle within 4 ulp, not bit for bit (komira_plan_harness.libm_rule), so on a
line whose every case calls one, `equal` and `equal_within_4_ulps` say the
same there: `fold_libm_outcomes` counts them as one `equal`, in the measured
and the committed table alike. `differs` stays `differs`.
"""

from std.os import listdir
from arrow.schema import RecordBatch
from komira_plan_harness import (
    CanonPolicy,
    FloatTolerance,
    calls_transcendental,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql

comptime TABLE_HEADER: String = (
    "# What each line measured (src/tests/conformance/komira_sql_conformance/README.md).\n"
    "# name\trow\tdetail\tcommon\tcases\toutcome\n"
)

comptime _ROW_NONE: String = "NO_ROW"
comptime _CALL_PREFIX: String = ": return SqlFnSpec("

comptime _COMMON: String = (
    "upper lower trim ltrim rtrim length substring substr replace concat concat_ws "
    "split_part string_split regexp_matches regexp_replace regexp_extract left right "
    "lpad rpad repeat reverse contains starts_with ends_with strpos position instr "
    "format printf md5 sha256 ascii chr levenshtein initcap "
    "abs round ceil ceiling floor sqrt pow power exp ln log log2 log10 sign trunc mod "
    "greatest least random isnan isinf isfinite bit_count gcd lcm factorial pi sin cos "
    "tan cbrt degrees radians "
    "year month day hour minute second quarter week dayofweek dayofyear date_part "
    "date_trunc date_diff date_add make_date make_timestamp strftime strptime epoch "
    "epoch_ms to_timestamp age last_day dayname monthname current_date "
    "current_timestamp now time_bucket to_days to_years to_months to_hours "
    "to_minutes to_seconds yearweek "
    "coalesce nullif ifnull typeof "
    "list_value list_sort list_distinct list_contains list_aggregate len cardinality "
    "struct_pack map array_length element_at list_transform list_filter flatten "
    "json_extract json_extract_string json_array_length hash uuid gen_random_uuid"
)


struct FnRow(Copyable, Movable):
    """One `if name == ...` line of `sql_scalar_fn_spec`: the names it
    answers (aliases share it), the lowering kind, and for a refusal its
    reason family."""

    var names: List[String]
    var kind: String
    var family: String

    def __init__(out self, var names: List[String], kind: String, family: String):
        self.names = names^
        self.kind = kind
        self.family = family


def common_analysis_names() -> List[String]:
    """The scalar functions an analysis script commonly calls: a hand-kept
    list, so that a name the table has no row for still gets a line."""
    var out = List[String]()
    for w in String(_COMMON).split(" "):
        out.append(String(w))
    return out^


def _quoted(left: String) -> List[String]:
    """The double-quoted literals of `left`, in order."""
    var out = List[String]()
    var at = 0
    while True:
        var q = left.find("\"", at)
        if q < 0:
            break
        var e = left.find("\"", q + 1)
        if e < 0:
            break
        out.append(String(left[byte = q + 1 : e]))
        at = e + 1
    return out^


def ladder_rows(source: String) raises -> List[FnRow]:
    """The rows of `sql_scalar_fn_spec` in `source`, in file order.

    Raises:
        When the function is not in `source`, or a line of it that starts a
        row has no `SqlFnSpec(` call (a row shape this reader would skip).
    """
    var start = source.find("def sql_scalar_fn_spec(")
    var stop = source.find("def sql_date_part_unit(")
    if start < 0 or stop <= start:
        raise Error("sql_scalar_fn_spec is not in the source text")
    var body = String(source[byte = start : stop])
    var rows = List[FnRow]()
    for line in body.split("\n"):
        var raw = String(line)
        var l = String(raw.strip())
        if not l.startswith("if name == "):
            continue
        var ret = l.find(_CALL_PREFIX)
        if ret < 0:
            raise Error("a row without a SqlFnSpec call: " + l)
        var left = String(l[byte = 0 : ret])
        var right = String(
            l[byte = ret + String(_CALL_PREFIX).byte_length() : l.byte_length()]
        )
        var names = _quoted(left)
        if len(names) == 0:
            # a name held in a constant: `if name == CAST_DESUGAR_NAME`
            var token = String(left[byte = String("if name == ").byte_length() : left.byte_length()])
            names.append(String("$") + token)
        var comma = right.find(",")
        if comma < 0:
            raise Error("a SqlFnSpec call with one argument: " + l)
        var kind = String(right[byte = 0 : comma])
        var family = String("-")
        if kind == "FNK_REFUSED":
            var rest = String(
                String(right[byte = comma + 1 : right.byte_length()]).strip()
            )
            if rest.startswith("\""):
                family = String("inline")
            else:
                var close = rest.find(")")
                if close < 0:
                    raise Error("a refusal row without a reason: " + l)
                family = String(rest[byte = 0 : close])
        rows.append(FnRow(names^, kind, family))
    return rows^


def called_names(query: String) -> List[String]:
    """Every identifier of `query`, lower-cased, that is directly followed by
    `(`: the function names a case calls, and keywords written `IN(`. Each
    name once, in order of first appearance."""
    var low = query.lower()
    var bytes = low.as_bytes()
    var out = List[String]()
    var run_start = -1
    for i in range(len(bytes)):
        var c = Int(bytes[i])
        var ident = (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 95
        if ident:
            if run_start < 0:
                run_start = i
            continue
        if c == 40 and run_start >= 0:
            var first = Int(bytes[run_start])
            if first < 48 or first > 57:
                var name = String(low[byte = run_start : i])
                var seen = False
                for j in range(len(out)):
                    if out[j] == name:
                        seen = True
                if not seen:
                    out.append(name^)
        run_start = -1
    return out^


def _query_of(text: String) -> String:
    """A case's SELECT: its file without the comment lines."""
    var out = String("")
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith("--") or l == "":
            continue
        out += l + " "
    return out^


def compare_answer(
    batch: RecordBatch, tsv: String, ordered: Bool, ulps: Int
) raises -> String:
    """"" when `batch` is the DuckDB answer `tsv` (in row order when
    `ordered`, as a multiset otherwise, floats within `ulps`), else the
    report."""
    var policy = CanonPolicy.total() if ordered else CanonPolicy.unordered()
    policy.set_tolerance(FloatTolerance.of_ulps(ulps))
    var actual = render_batch(batch, policy^)
    # The comparison is of values: the header is the batch's own column
    # names, because the name a column is given is not what is measured here.
    var header = String("")
    for c in range(batch.num_columns()):
        if c > 0:
            header += "\t"
        header += batch.schema.field_name(c)
    var body_at = tsv.find("\n")
    if body_at < 0:
        raise Error("an answer without a header line")
    var expected = duckdb_tsv_canon(
        parse_duckdb_tsv(header + String(tsv[byte = body_at : tsv.byte_length()])),
        actual,
    )
    var report = compare_canon(expected, actual)
    if report.ok():
        return String("")
    return String(report)


def _outcome(mut ctx: EngineContext, sql: String, tsv: String, ordered: Bool) -> String:
    """How one case ended: `equal`, `equal_within_4_ulps`, `differs`,
    `refused_<step>`, `batches_<n>` (not one result batch) or `unreadable`."""
    var out = run_sql(ctx, sql)
    if out.refusal:
        return String("refused_") + out.refusal.value().step
    if len(out.batches) != 1:
        return String("batches_") + String(len(out.batches))
    try:
        if compare_answer(out.batches[0], tsv, ordered, 0) == "":
            return String("equal")
        if compare_answer(out.batches[0], tsv, ordered, 4) == "":
            return String("equal_within_4_ulps")
        return String("differs")
    except:
        return String("unreadable")


def probe(mut ctx: EngineContext, name: String) -> String:
    """How `SELECT <name>(k) FROM T` ends: `refused_<step>` or `ok`."""
    var out = run_sql(ctx, "SELECT " + name + "(k) FROM T")
    if out.refusal:
        return String("refused_") + out.refusal.value().step
    return String("ok")


def new_context() raises -> EngineContext:
    """A context with the corpus's tables T and E registered as `t` and
    `e`."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    register_parquet(ctx, "t", data_path("scalar_fn_t.parquet"))
    register_parquet(ctx, "e", data_path("scalar_fn_e.parquet"))
    return ctx^


def case_names() raises -> List[String]:
    """The `scalar_fn` cases staged as `sql/<case>.sql`, sorted."""
    var out = List[String]()
    for entry in listdir(data_path("sql")):
        var f = String(entry)
        if f.endswith(".sql"):
            out.append(String(f[byte = 0 : f.byte_length() - 4]))
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            var tmp = out[j - 1]
            out[j - 1] = out[j]
            out[j] = tmp
            j -= 1
    return out^


struct CaseRun(Copyable, Movable):
    """One case: the names it calls, whether it calls a transcendental
    function (libm_rule.calls_transcendental) and how it ended."""

    var name: String
    var calls: List[String]
    var calls_libm: Bool
    var outcome: String

    def __init__(out self, name: String, var calls: List[String], calls_libm: Bool, outcome: String):
        self.name = name
        self.calls = calls^
        self.calls_libm = calls_libm
        self.outcome = outcome


def run_cases(mut ctx: EngineContext) raises -> List[CaseRun]:
    var runs = List[CaseRun]()
    var names = case_names()
    for i in range(len(names)):
        var text = read_data("sql/" + names[i] + ".sql")
        var sql = _query_of(text)
        var ordered = text.startswith("-- order: query")
        var tsv = read_data("duckdb/" + names[i] + ".tsv")
        runs.append(CaseRun(names[i], called_names(sql), calls_transcendental(sql), _outcome(ctx, sql, tsv, ordered)))
    return runs^


def _count_text(outcomes: List[String]) -> String:
    """`outcome:n` for each distinct outcome, sorted by outcome."""
    var distinct = List[String]()
    for i in range(len(outcomes)):
        var seen = False
        for j in range(len(distinct)):
            if distinct[j] == outcomes[i]:
                seen = True
        if not seen:
            distinct.append(outcomes[i])
    for i in range(1, len(distinct)):
        var j = i
        while j > 0 and distinct[j - 1] > distinct[j]:
            var tmp = distinct[j - 1]
            distinct[j - 1] = distinct[j]
            distinct[j] = tmp
            j -= 1
    var out = String("")
    for i in range(len(distinct)):
        var n = 0
        for j in range(len(outcomes)):
            if outcomes[j] == distinct[i]:
                n += 1
        if i > 0:
            out += ","
        out += distinct[i] + ":" + String(n)
    return out^


def _line(
    mut ctx: EngineContext,
    runs: List[CaseRun],
    common: List[String],
    name: String,
    kind: String,
    family: String,
) -> String:
    var is_common = String("-")
    for i in range(len(common)):
        if common[i] == name:
            is_common = String("yes")
    var outcomes = List[String]()
    for i in range(len(runs)):
        for j in range(len(runs[i].calls)):
            if runs[i].calls[j] == name:
                outcomes.append(runs[i].outcome)
    var outcome: String
    if name.startswith("$"):
        outcome = String("internal")
    elif kind == "FNK_REFUSED" or kind == _ROW_NONE:
        outcome = String("probe:") + probe(ctx, name)
    elif len(outcomes) == 0:
        outcome = String("no_case")
    else:
        outcome = _count_text(outcomes)
    return (
        name + "\t" + kind + "\t" + family + "\t" + is_common + "\t"
        + String(len(outcomes)) + "\t" + outcome
    )


def libm_line_names(runs: List[CaseRun]) -> List[String]:
    """The names every case of which calls a transcendental function, in the
    order first credited; a name credited by one case that calls none is not
    one of them."""
    var credited = List[String]()
    var mixed = List[Bool]()
    for i in range(len(runs)):
        for j in range(len(runs[i].calls)):
            var at = -1
            for k in range(len(credited)):
                if credited[k] == runs[i].calls[j]:
                    at = k
            if at < 0:
                credited.append(runs[i].calls[j])
                mixed.append(not runs[i].calls_libm)
            elif not runs[i].calls_libm:
                mixed[at] = True
    var out = List[String]()
    for k in range(len(credited)):
        if not mixed[k]:
            out.append(credited[k])
    return out^


def _folded_outcome(outcome: String) raises -> String:
    """`outcome` (`label:n` parts sorted by label) with the `equal` and
    `equal_within_4_ulps` counts summed into one `equal` part, in its sorted
    place; unchanged when it has neither."""
    var equal = 0
    var any_equal = False
    var parts = List[String]()
    for part in outcome.split(","):
        var p = String(part)
        var colon = p.rfind(":")
        var label = String(p[byte = 0 : colon]) if colon >= 0 else p
        if label == "equal" or label == "equal_within_4_ulps":
            if colon < 0:
                raise Error("an outcome count without a number: " + outcome)
            equal += Int(String(p[byte = colon + 1 : p.byte_length()]))
            any_equal = True
        else:
            parts.append(p)
    if not any_equal:
        return outcome
    var folded = String("equal:") + String(equal)
    var at = 0
    while at < len(parts) and parts[at] < folded:
        at += 1
    parts.insert(at, folded)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += ","
        out += parts[i]
    return out^


def fold_libm_outcomes(table: String, names: List[String]) raises -> String:
    """`table` with, on each line of a name in `names`, the `equal` and
    `equal_within_4_ulps` counts of its outcome summed into one `equal` part
    (in label order, as `_count_text` writes it). Comment lines, other names
    and outcomes with neither count are unchanged. Raises on an `equal` count
    that is not a number."""
    var out = String("")
    var lines = table.split("\n")
    for li in range(len(lines)):
        var line = String(lines[li])
        if li > 0:
            out += "\n"
        var fields = line.split("\t")
        var listed = False
        if not line.startswith("#") and len(fields) == 6:
            for n in range(len(names)):
                if names[n] == String(fields[0]):
                    listed = True
        if not listed:
            out += line
            continue
        for f in range(5):
            out += String(fields[f]) + "\t"
        out += _folded_outcome(String(fields[5]))
    return out^


struct Measurement(Movable):
    """The measured table and the names whose every case calls a
    transcendental function (`libm_line_names`)."""

    var table: String
    var libm_names: List[String]

    def __init__(out self, var table: String, var libm_names: List[String]):
        self.table = table^
        self.libm_names = libm_names^


def measure(source: String) raises -> Measurement:
    """The committed table's text: a line per name of the table's rows and of
    the common-analysis list, sorted by name; with the names a host other
    than the oracle's folds (`fold_libm_outcomes`)."""
    var ctx = new_context()
    var runs = run_cases(ctx)
    var rows = ladder_rows(source)
    var common = common_analysis_names()
    var names = List[String]()
    var kinds = List[String]()
    var families = List[String]()
    for r in range(len(rows)):
        for k in range(len(rows[r].names)):
            names.append(rows[r].names[k])
            kinds.append(rows[r].kind)
            families.append(rows[r].family)
    for c in range(len(common)):
        var found = False
        for n in range(len(names)):
            if names[n] == common[c]:
                found = True
        if not found:
            names.append(common[c])
            kinds.append(String(_ROW_NONE))
            families.append(String("-"))
    var order = List[Int]()
    for i in range(len(names)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and names[order[j - 1]] > names[order[j]]:
            var tmp = order[j - 1]
            order[j - 1] = order[j]
            order[j] = tmp
            j -= 1
    var text = String(TABLE_HEADER)
    for i in range(len(order)):
        var at = order[i]
        text += _line(ctx, runs, common, names[at], kinds[at], families[at]) + "\n"
    return Measurement(text^, libm_line_names(runs))
