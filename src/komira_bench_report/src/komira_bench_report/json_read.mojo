# The strict reader of result.json. It accepts exactly what `write_result_json`
# writes: the schema string `komira-bench-result/3`, every member present and
# no other, the right kind of value in each, no object naming a member twice,
# and a summary equal to the one recomputed from the cells (counts and text
# exactly, the floats to 1e-9). A document that fails raises
# `BenchResultError: <where>: <what>`.
#
# It also reads schema `komira-bench-result/2` (the change that added
# `n_departure` and the DEPARTURE verdict), which held no runs, no page faults,
# no first run, no check runs and no first-run ratio: a side read from it has
# empty `runs_ms` and a cell has no `first_ratio`, and its summary is compared
# with the summary of that schema (`summary_json(result, 2)`). Schema 1 is
# refused by name, its numbers meaning something else. A document of either
# schema is held to that schema's members and no others.

from komira_json import JsonValue, parse_json_value, refuse_duplicate_keys

from .model import (
    BenchResult,
    Cell,
    CheckRuns,
    FirstRun,
    _close,
    DuckDbPin,
    Environment,
    RESULT_SCHEMA,
    PREVIOUS_SCHEMA,
    RESULT_SCHEMA_V2,
    RunInfo,
    Side,
    validate_result,
)
from .format import format_fixed
from .json_write import summary_json
from .verdict import StageOutcome, ValueVerdict
from std.math import isfinite


def _fail(where: String, what: String) raises:
    raise Error("BenchResultError: " + where + ": " + what)


def _names(spaced: String) -> List[String]:
    var out = List[String]()
    var b = spaced.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == 0x20:
            if i > start:
                out.append(String(spaced[byte=start:i]))
            start = i + 1
    return out^


def _object(v: JsonValue, where: String, members: String) raises -> JsonValue:
    """`v` itself, once it is an object with exactly the named members."""
    if not v.is_object():
        _fail(where, String("expected an object"))
    var want = _names(members)
    for i in range(len(want)):
        if not v.has(want[i]):
            _fail(where, "missing member '" + want[i] + "'")
    for i in range(v.num_members()):
        var key = v.key_at(i)
        var known = False
        for j in range(len(want)):
            if want[j] == key:
                known = True
        if not known:
            _fail(where, "unknown member '" + key + "'")
    return v.copy()


def _same(a: JsonValue, b: JsonValue, skip: String) raises -> Bool:
    """Whether two summaries agree: members, strings and integers exactly, and
    a number written with a fraction to within the 1e-9 the geomean is
    accurate to. The member named `skip` is left to the caller."""
    if a.is_object():
        if not b.is_object() or a.num_members() != b.num_members():
            return False
        for i in range(a.num_members()):
            if a.key_at(i) != b.key_at(i):
                return False
            if a.key_at(i) == skip:
                continue
            if not _same(a.value_at(i), b.value_at(i), skip):
                return False
        return True
    if a.is_array():
        if not b.is_array() or a.array_len() != b.array_len():
            return False
        for i in range(a.array_len()):
            if not _same(a.element_at(i), b.element_at(i), skip):
                return False
        return True
    if a.is_number():
        if not b.is_number():
            return False
        if a.is_integral_number() or b.is_integral_number():
            return (
                a.is_integral_number()
                and b.is_integral_number()
                and a.as_int64() == b.as_int64()
            )
        return _close(a.as_float64(), b.as_float64())
    return a.serialize() == b.serialize()


comptime _GEOMEAN_AT = "| steady-state geomean "
comptime _GEOMEAN_AT_V1 = "| geomean "
comptime _GEOMEAN_END = "x over "


def _geomean_figure(headline: String, at: String) -> String:
    """The figure the headline gives for the geomean (after `at`), or empty."""
    var from_at = headline.find(at)
    if from_at < 0:
        return String("")
    from_at += at.byte_length()
    var to_at = headline.find(String(_GEOMEAN_END), from_at)
    if to_at < 0:
        return String("")
    return String(headline[byte=from_at:to_at])


def _without_geomean_figure(headline: String, at: String) -> String:
    var fig = _geomean_figure(headline, at)
    if fig.byte_length() == 0:
        return headline.copy()
    return headline.replace(at + fig, at)


def _check_summary(stored: JsonValue, result: BenchResult, version: Int) raises:
    """The stored summary must be the cells' summary: counts exactly, floats
    to 1e-9, and a headline equal to the recomputed one except that its
    geomean figure may be the rounding of either the recomputed geomean or
    the stored one. An older document's summary is the one its schema wrote."""
    var at = String(_GEOMEAN_AT) if version >= 3 else String(_GEOMEAN_AT_V1)
    var want = summary_json(result, version)
    if not _same(stored, want, String("headline")):
        _fail(String("summary"), String("does not match the summary of the cells"))
    var got_line = _text(stored.get(String("headline")), String("summary.headline"))
    var want_line = _text(want.get(String("headline")), String("summary.headline"))
    if _without_geomean_figure(got_line, at) != _without_geomean_figure(want_line, at):
        _fail(String("summary.headline"), String("does not match the summary of the cells"))
    var figure = _geomean_figure(got_line, at)
    if figure != _geomean_figure(want_line, at):
        var member = stored.get(String("geomean_ratio_verified"))
        if not member.is_number() or figure != format_fixed(member.as_float64(), 2):
            _fail(String("summary.headline"), String("its geomean is not the geomean of the summary"))


def _text(v: JsonValue, where: String) raises -> String:
    if not v.is_string():
        _fail(where, String("expected a string"))
    return v.as_string()


def _int(v: JsonValue, where: String) raises -> Int64:
    if not v.is_number() or not v.is_integral_number():
        _fail(where, String("expected an integer"))
    return v.as_int64()


def _float(v: JsonValue, where: String) raises -> Float64:
    if not v.is_number():
        _fail(where, String("expected a number"))
    var x = v.as_float64()
    if not isfinite(x):
        _fail(where, String("expected a finite number"))
    return x


def _opt_float(v: JsonValue, where: String) raises -> Optional[Float64]:
    if v.is_null():
        return Optional[Float64]()
    return Optional[Float64](_float(v, where))


def _read_runs(v: JsonValue, where: String) raises -> List[List[Float64]]:
    if not v.is_array():
        _fail(where, String("expected an array of sweeps"))
    var out = List[List[Float64]]()
    for i in range(v.array_len()):
        var sweep = v.element_at(i)
        if not sweep.is_array():
            _fail(where + "[" + String(i) + "]", String("expected an array of runs"))
        var one = List[Float64]()
        for j in range(sweep.array_len()):
            one.append(_float(sweep.element_at(j), where + "[" + String(i) + "][" + String(j) + "]"))
        out.append(one^)
    return out^


def _read_counts(v: JsonValue, where: String) raises -> List[List[Int64]]:
    """The counts of each sweep, or none when the member is null (not measured)."""
    var out = List[List[Int64]]()
    if v.is_null():
        return out^
    if not v.is_array():
        _fail(where, String("expected null or an array of sweeps"))
    for i in range(v.array_len()):
        var sweep = v.element_at(i)
        if not sweep.is_array():
            _fail(where + "[" + String(i) + "]", String("expected an array of counts"))
        var one = List[Int64]()
        for j in range(sweep.array_len()):
            one.append(_int(sweep.element_at(j), where + "[" + String(i) + "][" + String(j) + "]"))
        out.append(one^)
    return out^


def _read_side(v: JsonValue, where: String, legacy: Bool) raises -> Optional[Side]:
    if v.is_null():
        return Optional[Side]()
    var members = String("rows ms ms_per_sweep spread_pct")
    if not legacy:
        members += String(" runs_ms minor_faults major_faults first_run")
    var o = _object(v, where, members)
    var arr = o.get(String("ms_per_sweep"))
    if not arr.is_array():
        _fail(where + ".ms_per_sweep", String("expected an array"))
    var sweeps = List[Float64]()
    for i in range(arr.array_len()):
        sweeps.append(
            _float(arr.element_at(i), where + ".ms_per_sweep[" + String(i) + "]")
        )
    var runs = List[List[Float64]]()
    var minor = List[List[Int64]]()
    var major = List[List[Int64]]()
    var first = Optional[Float64]()
    var first_minor = Optional[Int64]()
    var first_major = Optional[Int64]()
    if not legacy:
        runs = _read_runs(o.get(String("runs_ms")), where + ".runs_ms")
        if len(runs) == 0:
            _fail(where + ".runs_ms", String("a side of schema 2 holds its runs"))
        minor = _read_counts(o.get(String("minor_faults")), where + ".minor_faults")
        major = _read_counts(o.get(String("major_faults")), where + ".major_faults")
        var f = _object(o.get(String("first_run")), where + ".first_run", String("ms minor_faults major_faults"))
        first = Optional[Float64](_float(f.get(String("ms")), where + ".first_run.ms"))
        var fm = f.get(String("minor_faults"))
        var fj = f.get(String("major_faults"))
        if fm.is_null() != fj.is_null():
            _fail(where + ".first_run", String("minor_faults and major_faults are both counts or both null"))
        if not fm.is_null():
            first_minor = Optional[Int64](_int(fm, where + ".first_run.minor_faults"))
            first_major = Optional[Int64](_int(fj, where + ".first_run.major_faults"))
    return Optional[Side](
        Side(
            _int(o.get(String("rows")), where + ".rows"),
            _float(o.get(String("ms")), where + ".ms"),
            sweeps^,
            _float(o.get(String("spread_pct")), where + ".spread_pct"),
            runs^,
            minor^,
            major^,
            first^,
            first_minor^,
            first_major^,
        )
    )


def _read_first_run(v: JsonValue, where: String) raises -> Optional[FirstRun]:
    if v.is_null():
        return Optional[FirstRun]()
    var f = _object(v, where, String("ms minor_faults major_faults"))
    var fm = f.get(String("minor_faults"))
    var fj = f.get(String("major_faults"))
    if fm.is_null() != fj.is_null():
        _fail(where, String("minor_faults and major_faults are both counts or both null"))
    var minor = Optional[Int64]()
    var major = Optional[Int64]()
    if not fm.is_null():
        minor = Optional[Int64](_int(fm, where + ".minor_faults"))
        major = Optional[Int64](_int(fj, where + ".major_faults"))
    return Optional[FirstRun](FirstRun(_float(f.get(String("ms")), where + ".ms"), minor^, major^))


def _read_cell(v: JsonValue, where: String, legacy: Bool) raises -> Cell:
    var members = String("id suite reps stage komira duckdb value ratio verdict")
    if not legacy:
        members += String(" first_ratio check_runs")
    var o = _object(v, where, members)
    var first_ratio = Optional[Float64]()
    var check_runs = Optional[CheckRuns]()
    if not legacy:
        first_ratio = _opt_float(o.get(String("first_ratio")), where + ".first_ratio")
        var cr = o.get(String("check_runs"))
        if not cr.is_null():
            var c = _object(cr, where + ".check_runs", String("komira duckdb"))
            check_runs = Optional[CheckRuns](CheckRuns(
                _read_first_run(c.get(String("komira")), where + ".check_runs.komira"),
                _read_first_run(c.get(String("duckdb")), where + ".check_runs.duckdb"),
            ))
    return Cell(
        _text(o.get(String("id")), where + ".id"),
        _text(o.get(String("suite")), where + ".suite"),
        Int(_int(o.get(String("reps")), where + ".reps")),
        StageOutcome.parse(_text(o.get(String("stage")), where + ".stage")),
        _read_side(o.get(String("komira")), where + ".komira", legacy),
        _read_side(o.get(String("duckdb")), where + ".duckdb", legacy),
        ValueVerdict.parse(_text(o.get(String("value")), where + ".value")),
        _opt_float(o.get(String("ratio")), where + ".ratio"),
        _text(o.get(String("verdict")), where + ".verdict"),
        first_ratio^,
        check_runs^,
    )


def _read_run(v: JsonValue) raises -> RunInfo:
    var o = _object(
        v, String("run"), String("mode scale sweeps reps statistic threads pass_max")
    )
    var scale = o.get(String("scale"))
    if not scale.is_object() or scale.num_members() != 1:
        _fail(String("run.scale"), String("expected an object with one member, sf or rows"))
    var kind = scale.key_at(0)
    if kind != String("sf") and kind != String("rows"):
        _fail(String("run.scale"), String("the member must be sf or rows"))
    return RunInfo(
        _text(o.get(String("mode")), String("run.mode")),
        kind.copy(),
        _int(scale.value_at(0), "run.scale." + kind),
        Int(_int(o.get(String("sweeps")), String("run.sweeps"))),
        Int(_int(o.get(String("reps")), String("run.reps"))),
        _text(o.get(String("statistic")), String("run.statistic")),
        _int(o.get(String("threads")), String("run.threads")),
        _float(o.get(String("pass_max")), String("run.pass_max")),
    )


def _read_env(v: JsonValue) raises -> Environment:
    var o = _object(
        v,
        String("env"),
        String(
            "hostclass cpu_model cores mem_total_bytes os komira_version"
            " duckdb dataset_lock_sha256"
        ),
    )
    var d = _object(
        o.get(String("duckdb")),
        String("env.duckdb"),
        String("version sha256 pin"),
    )
    var pin = DuckDbPin(
        _text(d.get(String("version")), String("env.duckdb.version")),
        _text(d.get(String("sha256")), String("env.duckdb.sha256")),
        _text(d.get(String("pin")), String("env.duckdb.pin")),
    )
    return Environment(
        _text(o.get(String("hostclass")), String("env.hostclass")),
        _text(o.get(String("cpu_model")), String("env.cpu_model")),
        _int(o.get(String("cores")), String("env.cores")),
        _int(o.get(String("mem_total_bytes")), String("env.mem_total_bytes")),
        _text(o.get(String("os")), String("env.os")),
        _text(o.get(String("komira_version")), String("env.komira_version")),
        pin^,
        _text(o.get(String("dataset_lock_sha256")), String("env.dataset_lock_sha256")),
    )


def parse_result_json(text: String) raises -> BenchResult:
    """The result `text` holds. Raises on malformed JSON, on any departure
    from the schema, and on a summary that is not the one the cells give."""
    var doc = parse_json_value(text)
    refuse_duplicate_keys(doc)
    var top = _object(doc, String("result"), String("schema run env cells summary"))
    var schema = _text(top.get(String("schema")), String("schema"))
    var version = 3
    if schema == String(PREVIOUS_SCHEMA):
        _fail(
            String("schema"),
            "this is '" + schema + "', which this reader no longer reads (its numbers mean something else): it reads '"
            + String(RESULT_SCHEMA) + "' and the older '" + String(RESULT_SCHEMA_V2) + "'; run the benchmark again",
        )
    elif schema == String(RESULT_SCHEMA_V2):
        version = 2
    elif schema != String(RESULT_SCHEMA):
        _fail(
            String("schema"),
            "expected '" + String(RESULT_SCHEMA) + "' (or the older '" + String(RESULT_SCHEMA_V2) + "'), got '" + schema + "'",
        )
    var legacy = version < 3
    var run = _read_run(top.get(String("run")))
    var env = _read_env(top.get(String("env")))
    var arr = top.get(String("cells"))
    if not arr.is_array():
        _fail(String("cells"), String("expected an array"))
    var cells = List[Cell]()
    for i in range(arr.array_len()):
        cells.append(_read_cell(arr.element_at(i), "cells[" + String(i) + "]", legacy))
    var result = BenchResult(run^, env^, cells^)
    validate_result(result)
    _check_summary(top.get(String("summary")), result, version)
    return result^
