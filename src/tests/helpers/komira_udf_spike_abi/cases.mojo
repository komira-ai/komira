# A conformance case, read from JSON (cases/*.json). A case is data: what to
# run (`run`), the UdfRef to run it on (entry, shape, types, modes), its
# inputs, and what must come back. Every runtime ships a fixture of the same
# entry name and meaning; the runner (conform.mojo) never names a runtime.
#
#   {"name": ..., "defect": what a failure means,
#    "run": "call_batch" | "split" | "frame" | "agg_split" | "validate" | "init_abi",
#    "entry": ..., "shape": "SCALAR" | ...,
#    "args": [{"type": "int64", "nullable": true, "name": "a"}], "result": [...],
#    "result_is_table": false, "state": {"type": ...},
#    "null_mode": "MANUAL" | "PROPAGATE", "form": "BUNDLE" | ...,
#    "descriptor_version": 0, "descriptor": [bytes],
#    "options": {"cancel": false, "cancel_during_call": false, "deadline_passed": false},
#    "input": batch, "inputs": [batch], "split_at": rows,
#    "partials": [{"input": batch, "group_ids": [...], "n_groups": n}], "n_groups": n,
#    "expect": {"status": "OK", "run_error": ..., "fault": text, "row": n,
#               "row_at_least": n, "message": "nonempty",
#               "column": column, "batches": [batch], "max_pulls_before_first_output": n},
#    "runner_fails_with": text}
#
# A batch is {"length": n, "columns": [column]}; a column is
# {"type": "int64", "values": [1, null, ...], "repeat": r, "offset": k}: the
# values r times over (default once), placed at Arrow offset k. An argument's
# "name" is its field name (for ROW, a read-set field); unnamed fields are
# c0, c1, ...
#
# "runner_fails_with" marks a case of cases_runner/: an expectation the
# runtime does not meet on purpose, or a fixture with an ownership bug, so
# the runner must fail it with a reason containing that text ("SKIP": must
# skip it). test_conform_runner holds each one to it; the cases of cases/
# have none.

from komira_json import JsonValue, parse_json_value

from .contract import (
    FORM_BUNDLE,
    FORM_PACKAGE,
    FORM_VALUE,
    IMMUTABLE,
    NULL_MANUAL,
    NULL_PROPAGATE,
    STABLE,
    VOLATILE,
    shape_from_name,
    status_from_name,
)
from .runtime import CallOptions, UdfSpec
from .values import Batch, Column, ColumnType, TYPE_FLOAT64, type_from_name


struct Partial(Copyable, Movable):
    var input: Batch
    var group_ids: List[Int32]
    var n_groups: UInt32

    def __init__(out self, var input: Batch, var group_ids: List[Int32], n_groups: UInt32):
        self.input = input^
        self.group_ids = group_ids^
        self.n_groups = n_groups


struct Expect(Copyable, Movable):
    var status: Int32
    var run_error: String
    var fault: String
    """A fragment the host fault must contain ("" when the case pins none)."""
    var row: Int64
    var row_at_least: Int64
    var message_nonempty: Bool
    var column: Optional[Column]
    var batches: Optional[List[Batch]]
    var max_pulls_before_first_output: Int

    def __init__(out self):
        self.status = 0
        self.run_error = ""
        self.fault = ""
        self.row = -2
        self.row_at_least = -2
        self.message_nonempty = False
        self.column = None
        self.batches = None
        self.max_pulls_before_first_output = -1


struct Case(Copyable, Movable):
    var name: String
    var defect: String
    var run: String
    var spec: UdfSpec
    var options: CallOptions
    var input: Batch
    var inputs: List[Batch]
    var split_at: Int
    var partials: List[Partial]
    var n_groups: UInt32
    var expect: Expect
    var runner_fails_with: String

    def __init__(out self, var name: String, var spec: UdfSpec):
        self.name = name^
        self.defect = ""
        self.run = ""
        self.spec = spec^
        self.options = CallOptions.plain()
        self.input = Batch(0)
        self.inputs = List[Batch]()
        self.split_at = 0
        self.partials = List[Partial]()
        self.n_groups = 0
        self.expect = Expect()
        self.runner_fails_with = ""


def _str(v: JsonValue, key: String, default: String) raises -> String:
    return v.get(key).as_string() if v.has(key) else default


def _int(v: JsonValue, key: String, default: Int) raises -> Int:
    return Int(v.get(key).as_int64()) if v.has(key) else default


def _bool(v: JsonValue, key: String) raises -> Bool:
    return v.get(key).as_bool() if v.has(key) else False


def _fields(v: JsonValue) raises -> List[ColumnType]:
    var out = List[ColumnType]()
    for i in range(v.array_len()):
        var f = v.element_at(i)
        out.append(ColumnType(type_from_name(f.get("type").as_string()), not f.has("nullable") or f.get("nullable").as_bool()))
    return out^


def _names(v: JsonValue) raises -> List[String]:
    """Each field's "name", or `c<i>` for one without."""
    var out = List[String]()
    for i in range(v.array_len()):
        out.append(_str(v.element_at(i), "name", "c" + String(i)))
    return out^


def parse_column(v: JsonValue) raises -> Column:
    var col = Column(type_from_name(v.get("type").as_string()))
    col.offset = _int(v, "offset", 0)
    var vals = v.get("values")
    var repeat = _int(v, "repeat", 1)
    if repeat < 1:
        raise Error("UDF_CASE_MALFORMED: repeat " + String(repeat))
    for _ in range(repeat):
        for i in range(vals.array_len()):
            var x = vals.element_at(i)
            if x.is_null():
                col.append_null()
            elif col.type_id == TYPE_FLOAT64:
                col.append_float(x.as_float64())
            else:
                col.append_int(x.as_int64())
    return col^


def parse_batch(v: JsonValue) raises -> Batch:
    var b = Batch(Int(v.get("length").as_int64()))
    var cols = v.get("columns")
    for i in range(cols.array_len()):
        var c = parse_column(cols.element_at(i))
        if len(c) != b.length:
            raise Error("UDF_CASE_MALFORMED: a column of " + String(len(c)) + " rows in a batch of " + String(b.length))
        b.columns.append(c^)
    return b^


def _batches(v: JsonValue) raises -> List[Batch]:
    var out = List[Batch]()
    for i in range(v.array_len()):
        out.append(parse_batch(v.element_at(i)))
    return out^


def _form(name: String) raises -> Int32:
    if name == "PACKAGE":
        return FORM_PACKAGE
    if name == "BUNDLE":
        return FORM_BUNDLE
    if name == "VALUE":
        return FORM_VALUE
    if name == "UNSPECIFIED":
        return 0
    raise Error("UDF_CASE_MALFORMED: form " + name)


def _stability(name: String) raises -> Int32:
    if name == "IMMUTABLE":
        return IMMUTABLE
    if name == "STABLE":
        return STABLE
    if name == "VOLATILE":
        return VOLATILE
    raise Error("UDF_CASE_MALFORMED: stability " + name)


def _expect(v: JsonValue) raises -> Expect:
    var e = Expect()
    e.status = status_from_name(_str(v, "status", "OK"))
    e.run_error = _str(v, "run_error", "")
    e.fault = _str(v, "fault", "")
    e.row = Int64(_int(v, "row", -2))
    e.row_at_least = Int64(_int(v, "row_at_least", -2))
    e.message_nonempty = _str(v, "message", "") == "nonempty"
    if v.has("column"):
        e.column = parse_column(v.get("column"))
    if v.has("batches"):
        e.batches = _batches(v.get("batches"))
    e.max_pulls_before_first_output = _int(v, "max_pulls_before_first_output", -1)
    return e^


def parse_case(text: String) raises -> Case:
    """One case from its JSON text; UDF_CASE_MALFORMED (or the JSON
    parser's error) when it does not follow the format above."""
    var v = parse_json_value(text)
    var spec = UdfSpec(
        shape_from_name(_str(v, "shape", "SCALAR")),
        _str(v, "entry", ""),
        _fields(v.get("args")) if v.has("args") else List[ColumnType](),
        _fields(v.get("result")) if v.has("result") else List[ColumnType](),
    )
    if v.has("args"):
        spec.arg_names = _names(v.get("args"))
    spec.result_is_table = _bool(v, "result_is_table")
    if v.has("state"):
        spec.state = _fields(v.get("state"))[0].copy()
    spec.null_mode = NULL_PROPAGATE if _str(v, "null_mode", "MANUAL") == "PROPAGATE" else NULL_MANUAL
    spec.stability = _stability(_str(v, "stability", "IMMUTABLE"))
    spec.form = _form(_str(v, "form", "BUNDLE"))
    spec.descriptor_version = UInt32(_int(v, "descriptor_version", 0))
    if v.has("descriptor"):
        var d = v.get("descriptor")
        for i in range(d.array_len()):
            spec.descriptor.append(UInt8(d.element_at(i).as_int64()))
    var c = Case(v.get("name").as_string(), spec^)
    c.defect = v.get("defect").as_string()
    c.run = v.get("run").as_string()
    if v.has("options"):
        var o = v.get("options")
        c.options = CallOptions(_bool(o, "cancel"), _bool(o, "cancel_during_call"), _bool(o, "deadline_passed"))
    if v.has("input"):
        c.input = parse_batch(v.get("input"))
    if v.has("inputs"):
        c.inputs = _batches(v.get("inputs"))
    c.split_at = _int(v, "split_at", 0)
    c.n_groups = UInt32(_int(v, "n_groups", 0))
    if v.has("partials"):
        var ps = v.get("partials")
        for i in range(ps.array_len()):
            var p = ps.element_at(i)
            var gids = List[Int32]()
            var g = p.get("group_ids")
            for k in range(g.array_len()):
                gids.append(Int32(g.element_at(k).as_int64()))
            c.partials.append(Partial(parse_batch(p.get("input")), gids^, UInt32(p.get("n_groups").as_int64())))
    c.expect = _expect(v.get("expect"))
    c.runner_fails_with = _str(v, "runner_fails_with", "")
    return c^
