# A conformance case, read from JSON (cases/*.json). A case is data: what to
# run (`run`), the UdfRef to run it on (entry, shape, types, modes), its
# inputs, and what must come back. Every runtime ships a fixture of the same
# entry name and meaning; the runner (conform.mojo) never names a runtime.
#
#   {"name": ..., "defect": what a failure means,
#    "run": "call_batch" | "split" | "frame" | "agg_split" | "validate" | "load"
#           | "init_abi" | "nested_frame" | "parallel",
#    "entry": ..., "shape": "SCALAR" | ...,
#    "args": [{"type": "int64", "nullable": true, "name": "a"}], "result": [...],
#    "result_is_table": false, "state": [{"type": ...}],
#    "null_mode": "MANUAL" | "PROPAGATE", "form": "BUNDLE" | ...,
#    "stability": "IMMUTABLE" | "STABLE" | "VOLATILE",
#    "descriptor_version": 1, "descriptor": {descriptor edit}, "descriptor_bytes": [bytes],
#    "code_root_empty": false,
#    "classes": ["NATIVE" | "MANAGED"], "needs_features": ["MEMORY_REPORT" | "CONTAINS_CRASHES" | "FORCED_STOP"],
#    "runtime_lacks_shape": false,
#    "options": {"cancel": false, "cancel_during_call": false, "deadline_passed": false,
#                "deadline_after_ns": 0, "plant_extra_child": false, "plant_struct_offset": false},
#    "input": batch, "inputs": [batch], "split_at": rows,
#    "partials": [{"input": batch, "group_ids": [...] | "group_ids_range": n, "n_groups": n}], "n_groups": n,
#    "nested": {a spec: "entry", "shape", "args", "result", ...}, "levels": 0 | 1 | 2,
#    "pull_action": {"at": k, "do": "cancel" | "cancel_keep_batch" | "advance_clock"},
#    "parallel": {"threads": n, "rows": n, "iters": n, "a": x, "b": y},
#    "expect": {"status": "OK", "run_error": ..., "fault": text, "row": n,
#               "row_at_least": n, "message": "nonempty", "message_contains": text,
#               "column": column, "batches": [batch], "concat_column": column,
#               "max_pulls_before_first_output": n, "max_calls": n, "max_outputs": n, "eio_at_least": n,
#               "frame_carries_failure": false,
#               "then": {"input": batch, "column": column} | {"inputs": [batch], "batches": [batch]}},
#    "runner_fails_with": text}
#
# A batch is {"length": n, "columns": [column]}; a column is
# {"type": "int64", "values": [1, null, ...], "repeat": r, "offset": k}: the
# values r times over (default once), placed at Arrow offset k; or
# {"type": "int64", "range": n}: 0, 1, ..., n - 1. An argument's
# "name" is its field name (for ROW and MAP_BATCHES_FRAME, the read set by
# name if set, else every input column); unnamed fields are c0, c1, ...
#
# The descriptor (descriptor.mojo): unless a case says otherwise, the one a
# producer records for its spec (runtime.descriptor_for). "descriptor" edits
# it: {"entry": ..., "shapes": ["SCALAR", ...], "args": [field], "result":
# [field], "state": field | "absent", "recorded_fields": "absent" |
# {"fields": [field], "key_fields": [field]}}, a field being {"name": ...,
# "type": "int64"} or {"name": ..., "format": "l"}; the lists are encoded in
# the order given. "descriptor_bytes" sends bytes as they are.
#
# "classes", "needs_features" and "runtime_lacks_shape" gate a case: it is
# skipped, and the skip reported, on a runtime whose describe answer has
# another class, lacks a feature bit, or (runtime_lacks_shape) reports the
# case's shape. "then" is a follow-up on the same instance after the
# expectation held: it must succeed (the context and instance stayed usable,
# design section 4.5) with the output it names.
#
# "runner_fails_with" marks a case of cases_runner/: an expectation the
# runtime does not meet on purpose, or a fixture with an ownership bug, so
# the runner must fail it with a reason containing that text ("SKIP": must
# skip it). test_conform_runner holds each one to it; the cases of cases/
# have none.

from komira_json import JsonValue, parse_json_value

from .contract import (
    CLASS_MANAGED,
    CLASS_NATIVE,
    FEATURE_CONTAINS_CRASHES,
    FEATURE_FORCED_STOP,
    FEATURE_MEMORY_REPORT,
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
from .descriptor import DescField, DescriptorEdit
from .spec import CallOptions, UdfSpec
from .values import Batch, Column, ColumnType, TYPE_FLOAT64, type_format, type_from_name


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
    var message_contains: String
    var column: Optional[Column]
    var batches: Optional[List[Batch]]
    var concat_column: Optional[Column]
    var max_pulls_before_first_output: Int
    var max_calls: Int
    var max_outputs: Int
    var eio_at_least: Int
    var frame_carries_failure: Bool
    """nested_frame: the waiting frame's own error carries the failure's
    message, which it read from get_last_error (design section 4.3)."""
    var then_input: Optional[Batch]
    var then_column: Optional[Column]
    var then_inputs: Optional[List[Batch]]
    var then_batches: Optional[List[Batch]]

    def __init__(out self):
        self.status = 0
        self.run_error = ""
        self.fault = ""
        self.row = -2
        self.row_at_least = -2
        self.message_nonempty = False
        self.message_contains = ""
        self.column = None
        self.batches = None
        self.concat_column = None
        self.max_pulls_before_first_output = -1
        self.max_calls = -1
        self.max_outputs = -1
        self.eio_at_least = -1
        self.frame_carries_failure = False
        self.then_input = None
        self.then_column = None
        self.then_inputs = None
        self.then_batches = None


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
    var classes: List[UInt32]
    """The UDF classes the case runs on; empty: every class."""
    var needs_features: UInt32
    var runtime_lacks_shape: Bool
    """The case is about a shape the runtime lacks: skipped on one that has it."""
    var code_root_empty: Bool
    """The spec's code root is a path with no code object in it, and its
    digests name none a runtime opened, after a suite's code set is applied."""
    var nested: Optional[UdfSpec]
    var levels: Int
    var pull_at: Int
    var pull_do: Int
    """_nested.PULL_* (0: none)."""
    var threads: Int
    var rows: Int
    var iters: Int
    var a: Float64
    var b: Float64

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
        self.classes = List[UInt32]()
        self.needs_features = 0
        self.runtime_lacks_shape = False
        self.code_root_empty = False
        self.nested = None
        self.levels = 1
        self.pull_at = -1
        self.pull_do = 0
        self.threads = 0
        self.rows = 0
        self.iters = 0
        self.a = 0
        self.b = 0


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
    if v.has("range"):
        for i in range(_int(v, "range", 0)):
            col.append_int(Int64(i))
        return col^
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


def _desc_fields(v: JsonValue) raises -> List[DescField]:
    var out = List[DescField]()
    for i in range(v.array_len()):
        var f = v.element_at(i)
        var fmt = _str(f, "format", "")
        if fmt == "":
            fmt = type_format(type_from_name(f.get("type").as_string()))
        out.append(DescField(_str(f, "name", ""), fmt))
    return out^


def _descriptor_edit(v: JsonValue) raises -> DescriptorEdit:
    var keys: List[String] = ["entry", "shapes", "args", "result", "state", "recorded_fields"]
    for i in range(v.num_members()):
        var k = v.key_at(i)
        if k not in keys:
            raise Error("UDF_CASE_MALFORMED: descriptor key " + k)
    var e = DescriptorEdit()
    if v.has("entry"):
        e.entry = v.get("entry").as_string()
    if v.has("shapes"):
        var bits = UInt32(0)
        var l = v.get("shapes")
        for i in range(l.array_len()):
            bits |= shape_from_name(l.element_at(i).as_string())
        e.shapes = bits
    if v.has("args"):
        e.args = _desc_fields(v.get("args"))
    if v.has("result"):
        e.result = _desc_fields(v.get("result"))
    if v.has("state"):
        var st = v.get("state")
        if st.is_string() and st.as_string() == "absent":
            e.state_absent = True
        else:
            var one = JsonValue.empty_array()
            one.push(st.copy())
            e.state = _desc_fields(one)[0].copy()
    if v.has("recorded_fields"):
        var r = v.get("recorded_fields")
        if r.is_string():
            if r.as_string() != "absent":
                raise Error("UDF_CASE_MALFORMED: recorded_fields " + r.as_string())
            e.recorded = 1
        else:
            e.recorded = 2
            if r.has("fields"):
                e.fields = _desc_fields(r.get("fields"))
            if r.has("key_fields"):
                e.key_fields = _desc_fields(r.get("key_fields"))
    return e^


def _class(name: String) raises -> UInt32:
    if name == "NATIVE":
        return CLASS_NATIVE
    if name == "MANAGED":
        return CLASS_MANAGED
    raise Error("UDF_CASE_MALFORMED: class " + name)


def _feature(name: String) raises -> UInt32:
    if name == "MEMORY_REPORT":
        return FEATURE_MEMORY_REPORT
    if name == "CONTAINS_CRASHES":
        return FEATURE_CONTAINS_CRASHES
    if name == "FORCED_STOP":
        return FEATURE_FORCED_STOP
    raise Error("UDF_CASE_MALFORMED: feature " + name)


def _pull_do(name: String) raises -> Int:
    if name == "cancel":
        return 1
    if name == "cancel_keep_batch":
        return 2
    if name == "advance_clock":
        return 3
    raise Error("UDF_CASE_MALFORMED: pull_action " + name)


def _expect(v: JsonValue) raises -> Expect:
    var e = Expect()
    e.status = status_from_name(_str(v, "status", "OK"))
    e.run_error = _str(v, "run_error", "")
    e.fault = _str(v, "fault", "")
    e.row = Int64(_int(v, "row", -2))
    e.row_at_least = Int64(_int(v, "row_at_least", -2))
    e.message_nonempty = _str(v, "message", "") == "nonempty"
    e.message_contains = _str(v, "message_contains", "")
    if v.has("column"):
        e.column = parse_column(v.get("column"))
    if v.has("batches"):
        e.batches = _batches(v.get("batches"))
    if v.has("concat_column"):
        e.concat_column = parse_column(v.get("concat_column"))
    e.max_pulls_before_first_output = _int(v, "max_pulls_before_first_output", -1)
    e.max_calls = _int(v, "max_calls", -1)
    e.max_outputs = _int(v, "max_outputs", -1)
    e.eio_at_least = _int(v, "eio_at_least", -1)
    e.frame_carries_failure = _bool(v, "frame_carries_failure")
    if v.has("then"):
        var t = v.get("then")
        if t.has("input"):
            e.then_input = parse_batch(t.get("input"))
        if t.has("column"):
            e.then_column = parse_column(t.get("column"))
        if t.has("inputs"):
            e.then_inputs = _batches(t.get("inputs"))
        if t.has("batches"):
            e.then_batches = _batches(t.get("batches"))
        if not e.then_input and not e.then_inputs:
            raise Error("UDF_CASE_MALFORMED: a follow-up with no input")
    return e^


def _spec_of(v: JsonValue) raises -> UdfSpec:
    """The UdfRef a case (or its nested call) names."""
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
        var st = _fields(v.get("state"))
        if len(st) != 1:
            raise Error("UDF_CASE_MALFORMED: state is a list of one field")
        spec.state = st[0].copy()
    spec.null_mode = NULL_PROPAGATE if _str(v, "null_mode", "MANUAL") == "PROPAGATE" else NULL_MANUAL
    spec.stability = _stability(_str(v, "stability", "IMMUTABLE"))
    spec.form = _form(_str(v, "form", "BUNDLE"))
    spec.descriptor_version = UInt32(_int(v, "descriptor_version", Int(spec.descriptor_version)))
    if v.has("descriptor"):
        spec.edit = _descriptor_edit(v.get("descriptor"))
    if v.has("descriptor_bytes"):
        spec.descriptor_raw = True
        var d = v.get("descriptor_bytes")
        for i in range(d.array_len()):
            spec.descriptor.append(UInt8(d.element_at(i).as_int64()))
    return spec^


def parse_case(text: String) raises -> Case:
    """One case from its JSON text; UDF_CASE_MALFORMED (or the JSON
    parser's error) when it does not follow the format above."""
    var v = parse_json_value(text)
    var c = Case(v.get("name").as_string(), _spec_of(v))
    c.defect = v.get("defect").as_string()
    c.run = v.get("run").as_string()
    if v.has("options"):
        var o = v.get("options")
        c.options = CallOptions(
            _bool(o, "cancel"), _bool(o, "cancel_during_call"), _bool(o, "deadline_passed"),
            Int64(_int(o, "deadline_after_ns", 0)), _bool(o, "plant_extra_child"), _bool(o, "plant_struct_offset"),
        )
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
            if p.has("group_ids_range"):
                for k in range(_int(p, "group_ids_range", 0)):
                    gids.append(Int32(k))
            else:
                var g = p.get("group_ids")
                for k in range(g.array_len()):
                    gids.append(Int32(g.element_at(k).as_int64()))
            c.partials.append(Partial(parse_batch(p.get("input")), gids^, UInt32(p.get("n_groups").as_int64())))
    c.expect = _expect(v.get("expect"))
    c.runner_fails_with = _str(v, "runner_fails_with", "")
    if v.has("classes"):
        var l = v.get("classes")
        for i in range(l.array_len()):
            c.classes.append(_class(l.element_at(i).as_string()))
    if v.has("needs_features"):
        var l = v.get("needs_features")
        for i in range(l.array_len()):
            c.needs_features |= _feature(l.element_at(i).as_string())
    c.code_root_empty = _bool(v, "code_root_empty")
    c.runtime_lacks_shape = _bool(v, "runtime_lacks_shape")
    if v.has("nested"):
        c.nested = _spec_of(v.get("nested"))
    c.levels = _int(v, "levels", 1)
    if v.has("pull_action"):
        var pa = v.get("pull_action")
        c.pull_at = _int(pa, "at", 0)
        c.pull_do = _pull_do(pa.get("do").as_string())
    if v.has("parallel"):
        var pp = v.get("parallel")
        c.threads = _int(pp, "threads", 4)
        c.rows = _int(pp, "rows", 64)
        c.iters = _int(pp, "iters", 10)
        c.a = pp.get("a").as_float64() if pp.has("a") else 1.0
        c.b = pp.get("b").as_float64() if pp.has("b") else 0.0
    return c^
