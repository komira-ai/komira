# =============================================================================
# src/kci_api/result_deploy.mojo -- the deploy keys of a result document's
#   step row (`steps[]`), rendered, parsed and checked.
# =============================================================================
#
# The keys sit on the step row, not at the top level: a stage can hold
# DEPLOY steps for several cells, and a top-level list could not say which
# cell a node is in. Every key was added inside major 1 (formats.mojo):
#
#   cell           the cell the step acts on; "" for a step with none
#   cloud          the cell's cloud; non-empty exactly when cell is
#   landed[]       {node, verb}: after an apply, the nodes that are live in
#                  the cell
#   pending[]      node ids in apply order, after an apply that stopped; the
#                  first is the node that failed
#   failed         {fault_domain, message, node, verb}: after an apply with
#                  an engine error; ABSENT otherwise. The message never holds
#                  a credential
#   outputs[]      {output, resource, value}: after an apply, the declared
#                  outputs that are not secret
#   plan_hash      64 lowercase hex characters (sha256 over the canonical
#                  JSON of the change actions), or ""
#   leftover[]     node ids: objects owned by resources the file no longer
#                  names. Reported, never deleted
#   left_behind[]  node ids: retained objects the file no longer lowers.
#                  Reported, never deleted
#   released[]     node ids: adopted objects whose resource left the list,
#                  released (or, under --plan, that an apply would release)
#
# A row whose cell is "" holds none of them, and the renderer writes none of
# them for it, so a BUILD or PUBLISH row without a cell reads byte for byte
# as before. A reader of a document written before these keys takes an
# absent key as empty.
#
# What the checks refuse (the renderer and the parser alike, result.mojo):
#   * a deploy value, or a cloud, on a row whose cell is "";
#   * a cell without its cloud;
#   * a landed node on a row whose outcome's exit number promises that no
#     effect landed (exit_codes.mojo `promises_no_effect`: REFUSED, FAILED).
#     FAILED is exit 4, "re-running is safe"; a row that lists what landed
#     cannot say so;
#   * a plan_hash that is not 64 lowercase hex characters;
#   * any of these names at the TOP level of the document
#     (`refuse_top_level_deploy_keys`): it is refused, never ignored.
#
# Pure functions over owned values; no pointer, no file I/O.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue

from kci_api.exit_codes import exit_code_of, promises_no_effect
from kci_api.result_json import (
    _is_sha256_hex,
    _keys,
    _need,
    _no_dup_keys,
    _note_unknown,
    _Obj,
    _refuse,
    _s,
    _s_absent_empty,
    _str_array,
)


def deploy_step_keys() -> List[String]:
    """The deploy keys of a step row (file header), sorted bytewise."""
    return _keys(String("cell cloud failed landed left_behind leftover outputs pending plan_hash released"))


struct ResultLanded(Copyable, Movable):
    """`landed[]`: a node live in the cell after the apply, and the verb that
    put it there.

    Layout: owned Strings. No pointer field."""

    var node: String
    var verb: String

    def __init__(out self, var node: String, var verb: String):
        self.node = node^
        self.verb = verb^


struct ResultFailedNode(Copyable, Movable):
    """`failed`: the node an engine error stopped the apply at.

    Layout: owned Strings. No pointer field."""

    var node: String
    var verb: String
    var fault_domain: String
    var message: String

    def __init__(out self, var node: String, var verb: String, var fault_domain: String, var message: String):
        self.node = node^
        self.verb = verb^
        self.fault_domain = fault_domain^
        self.message = message^


struct ResultOutput(Copyable, Movable):
    """`outputs[]`: one declared output of a resource that is not secret.

    Layout: owned Strings. No pointer field."""

    var resource: String
    var output: String
    var value: String

    def __init__(out self, var resource: String, var output: String, var value: String):
        self.resource = resource^
        self.output = output^
        self.value = value^


struct ResultDeploy(Copyable, Movable):
    """The deploy keys of one step row (file header). Empty by default: the
    row of a step that names no cell.

    Layout: owned Strings, Lists of owned rows and a Bool. No pointer
    field."""

    var cell: String
    var cloud: String
    var landed: List[ResultLanded]
    var pending: List[String]
    var has_failed: Bool
    var failed: ResultFailedNode
    var outputs: List[ResultOutput]
    var plan_hash: String
    var leftover: List[String]
    var left_behind: List[String]
    var released: List[String]

    def __init__(out self):
        self.cell = String("")
        self.cloud = String("")
        self.landed = List[ResultLanded]()
        self.pending = List[String]()
        self.has_failed = False
        self.failed = ResultFailedNode(String(""), String(""), String(""), String(""))
        self.outputs = List[ResultOutput]()
        self.plan_hash = String("")
        self.leftover = List[String]()
        self.left_behind = List[String]()
        self.released = List[String]()

    def holds_a_value(self) -> Bool:
        """Whether any key other than cell and cloud holds something."""
        return (
            len(self.landed) > 0
            or len(self.pending) > 0
            or self.has_failed
            or len(self.outputs) > 0
            or self.plan_hash.byte_length() > 0
            or len(self.leftover) > 0
            or len(self.left_behind) > 0
            or len(self.released) > 0
        )


def check_deploy_row(d: ResultDeploy, outcome: String, where: String) raises:
    """The checks of the file header over one step row whose outcome is
    `outcome` ("" for a step that has none); `where` prefixes the message."""
    if d.cell.byte_length() == 0:
        if d.cloud.byte_length() > 0 or d.holds_a_value():
            raise Error(where + String("the deploy keys belong to a step that names its cell (cell is EMPTY)"))
        return
    if d.cloud.byte_length() == 0:
        raise Error(where + String("a step that names its cell names its cloud (cloud is EMPTY)"))
    if len(d.landed) > 0 and outcome.byte_length() > 0:
        var n = exit_code_of(outcome)
        if promises_no_effect(n):
            raise Error(
                where + String("outcome ") + outcome + String(" (exit ") + String(n)
                + String(") says no effect landed, yet landed lists ") + String(len(d.landed))
                + String(" node(s), the first '") + d.landed[0].node + String("'")
            )
    if d.plan_hash.byte_length() > 0 and not _is_sha256_hex(d.plan_hash):
        raise Error(where + String("plan_hash '") + d.plan_hash + String("' is not 64 lowercase hex characters"))


def put_deploy_keys(mut o: _Obj, d: ResultDeploy) raises:
    """Add the deploy keys of a row to `o`; nothing for a row whose cell is
    "" (file header)."""
    if d.cell.byte_length() == 0:
        return
    o.put_str(String("cell"), d.cell)
    o.put_str(String("cloud"), d.cloud)
    if d.has_failed:
        var f = _Obj()
        f.put_str(String("fault_domain"), d.failed.fault_domain)
        f.put_str(String("message"), d.failed.message)
        f.put_str(String("node"), d.failed.node)
        f.put_str(String("verb"), d.failed.verb)
        o.put(String("failed"), f.build())
    var landed = JsonValue.empty_array()
    for i in range(len(d.landed)):
        var l = _Obj()
        l.put_str(String("node"), d.landed[i].node)
        l.put_str(String("verb"), d.landed[i].verb)
        landed.push(l.build())
    o.put(String("landed"), landed^)
    o.put(String("left_behind"), _str_array(d.left_behind))
    o.put(String("leftover"), _str_array(d.leftover))
    var outs = JsonValue.empty_array()
    for i in range(len(d.outputs)):
        var x = _Obj()
        x.put_str(String("output"), d.outputs[i].output)
        x.put_str(String("resource"), d.outputs[i].resource)
        x.put_str(String("value"), d.outputs[i].value)
        outs.push(x.build())
    o.put(String("outputs"), outs^)
    o.put(String("pending"), _str_array(d.pending))
    o.put_str(String("plan_hash"), d.plan_hash)
    o.put(String("released"), _str_array(d.released))


def _ids(row: JsonValue, key: String, source: String, where: String) raises -> List[String]:
    """A list of node ids added inside the major: empty when absent."""
    var out = List[String]()
    if not row.has(key):
        return out^
    var a = _need(row, key, JSON_ARRAY, source, where)
    for i in range(a.array_len()):
        var v = a.element_at(i)
        if v.kind_tag() != JSON_STRING:
            _refuse(source, where + key + String("[") + String(i) + String("] is not a string"))
        out.append(v.as_string())
    return out^


def _object_at(a: JsonValue, i: Int, source: String, where: String) raises -> JsonValue:
    var v = a.element_at(i)
    if v.kind_tag() != JSON_OBJECT:
        _refuse(source, where + String("not an object"))
    _no_dup_keys(v, source, where)
    return v^


def parse_deploy_keys(
    row: JsonValue, source: String, where: String, path: String, mut ignored: List[String]
) raises -> ResultDeploy:
    """Read the deploy keys of the step row `row`; an absent key reads as
    empty. `where` prefixes a refusal, `path` (`steps[0].`) an ignored key."""
    var d = ResultDeploy()
    d.cell = _s_absent_empty(row, String("cell"), source, where)
    d.cloud = _s_absent_empty(row, String("cloud"), source, where)
    d.plan_hash = _s_absent_empty(row, String("plan_hash"), source, where)
    d.pending = _ids(row, String("pending"), source, where)
    d.leftover = _ids(row, String("leftover"), source, where)
    d.left_behind = _ids(row, String("left_behind"), source, where)
    d.released = _ids(row, String("released"), source, where)
    if row.has(String("landed")):
        var a = _need(row, String("landed"), JSON_ARRAY, source, where)
        for i in range(a.array_len()):
            var w = where + String("landed[") + String(i) + String("]: ")
            var l = _object_at(a, i, source, w)
            _note_unknown(l, _keys(String("node verb")), path + String("landed[") + String(i) + String("]."), ignored)
            d.landed.append(ResultLanded(_s(l, String("node"), source, w), _s(l, String("verb"), source, w)))
    if row.has(String("outputs")):
        var a = _need(row, String("outputs"), JSON_ARRAY, source, where)
        for i in range(a.array_len()):
            var w = where + String("outputs[") + String(i) + String("]: ")
            var x = _object_at(a, i, source, w)
            _note_unknown(x, _keys(String("output resource value")), path + String("outputs[") + String(i) + String("]."), ignored)
            d.outputs.append(
                ResultOutput(_s(x, String("resource"), source, w), _s(x, String("output"), source, w), _s(x, String("value"), source, w))
            )
    if row.has(String("failed")):
        var w = where + String("failed: ")
        var f = _need(row, String("failed"), JSON_OBJECT, source, where)
        _no_dup_keys(f, source, w)
        _note_unknown(f, _keys(String("fault_domain message node verb")), path + String("failed."), ignored)
        d.has_failed = True
        d.failed = ResultFailedNode(
            _s(f, String("node"), source, w),
            _s(f, String("verb"), source, w),
            _s(f, String("fault_domain"), source, w),
            _s(f, String("message"), source, w),
        )
    return d^


def refuse_top_level_deploy_keys(doc: JsonValue, source: String) raises:
    """Refuse a step row's deploy key at the top level of the document (file
    header): ignoring it would lose what landed, and where."""
    var keys = deploy_step_keys()
    for i in range(len(keys)):
        if doc.has(keys[i]):
            _refuse(
                source,
                String("'") + keys[i] + String("' is a key of a step row (steps[].") + keys[i]
                + String("), never of the document: a stage can deploy into several cells"),
            )
