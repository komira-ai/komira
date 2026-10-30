# The strict reader of result.json. It accepts exactly what `write_result_json`
# writes: the schema string `komira-bench-result/2`, every member present and
# no other, the right kind of value in each, no object naming a member twice,
# and a summary equal to the one recomputed from the cells (counts and text
# exactly, the floats to 1e-9). A document that fails raises
# `BenchResultError: <where>: <what>`.

from komira_json import JsonValue, parse_json_value, refuse_duplicate_keys

from .model import (
    BenchResult,
    Cell,
    _close,
    DuckDbPin,
    Environment,
    PREVIOUS_SCHEMA,
    RESULT_SCHEMA,
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


comptime _GEOMEAN_AT = "| geomean "
comptime _GEOMEAN_END = "x over "


def _geomean_figure(headline: String) -> String:
    """The figure the headline gives for the geomean, or empty."""
    var from_at = headline.find(String(_GEOMEAN_AT))
    if from_at < 0:
        return String("")
    from_at += String(_GEOMEAN_AT).byte_length()
    var to_at = headline.find(String(_GEOMEAN_END), from_at)
    if to_at < 0:
        return String("")
    return String(headline[byte=from_at:to_at])


def _without_geomean_figure(headline: String) -> String:
    var fig = _geomean_figure(headline)
    if fig.byte_length() == 0:
        return headline.copy()
    return headline.replace(String(_GEOMEAN_AT) + fig, String(_GEOMEAN_AT))


def _check_summary(stored: JsonValue, result: BenchResult) raises:
    """The stored summary must be the cells' summary: counts exactly, floats
    to 1e-9, and a headline equal to the recomputed one except that its
    geomean figure may be the rounding of either the recomputed geomean or
    the stored one."""
    var want = summary_json(result)
    if not _same(stored, want, String("headline")):
        _fail(String("summary"), String("does not match the summary of the cells"))
    var got_line = _text(stored.get(String("headline")), String("summary.headline"))
    var want_line = _text(want.get(String("headline")), String("summary.headline"))
    if _without_geomean_figure(got_line) != _without_geomean_figure(want_line):
        _fail(String("summary.headline"), String("does not match the summary of the cells"))
    var figure = _geomean_figure(got_line)
    if figure != _geomean_figure(want_line):
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


def _read_side(v: JsonValue, where: String) raises -> Optional[Side]:
    if v.is_null():
        return Optional[Side]()
    var o = _object(v, where, String("rows ms ms_per_sweep spread_pct"))
    var arr = o.get(String("ms_per_sweep"))
    if not arr.is_array():
        _fail(where + ".ms_per_sweep", String("expected an array"))
    var sweeps = List[Float64]()
    for i in range(arr.array_len()):
        sweeps.append(
            _float(arr.element_at(i), where + ".ms_per_sweep[" + String(i) + "]")
        )
    return Optional[Side](
        Side(
            _int(o.get(String("rows")), where + ".rows"),
            _float(o.get(String("ms")), where + ".ms"),
            sweeps^,
            _float(o.get(String("spread_pct")), where + ".spread_pct"),
        )
    )


def _read_cell(v: JsonValue, where: String) raises -> Cell:
    var o = _object(
        v,
        where,
        String("id suite reps stage komira duckdb value ratio verdict"),
    )
    return Cell(
        _text(o.get(String("id")), where + ".id"),
        _text(o.get(String("suite")), where + ".suite"),
        Int(_int(o.get(String("reps")), where + ".reps")),
        StageOutcome.parse(_text(o.get(String("stage")), where + ".stage")),
        _read_side(o.get(String("komira")), where + ".komira"),
        _read_side(o.get(String("duckdb")), where + ".duckdb"),
        ValueVerdict.parse(_text(o.get(String("value")), where + ".value")),
        _opt_float(o.get(String("ratio")), where + ".ratio"),
        _text(o.get(String("verdict")), where + ".verdict"),
    )


def _read_run(v: JsonValue) raises -> RunInfo:
    var o = _object(
        v,
        String("run"),
        String("mode scale sweeps reps statistic threads pass_max"),
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
    if schema == String(PREVIOUS_SCHEMA):
        _fail(
            String("schema"),
            "this is '" + schema + "', which this reader no longer reads: it reads '"
            + String(RESULT_SCHEMA)
            + "' only (the shape changed: n_departure and the DEPARTURE verdict); run the benchmark again",
        )
    if schema != String(RESULT_SCHEMA):
        _fail(String("schema"), "expected '" + String(RESULT_SCHEMA) + "', got '" + schema + "'")
    var run = _read_run(top.get(String("run")))
    var env = _read_env(top.get(String("env")))
    var arr = top.get(String("cells"))
    if not arr.is_array():
        _fail(String("cells"), String("expected an array"))
    var cells = List[Cell]()
    for i in range(arr.array_len()):
        cells.append(_read_cell(arr.element_at(i), "cells[" + String(i) + "]"))
    var result = BenchResult(run^, env^, cells^)
    validate_result(result)
    _check_summary(top.get(String("summary")), result)
    return result^
