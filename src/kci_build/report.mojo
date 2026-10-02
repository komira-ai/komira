# =============================================================================
# src/kci_build/report.mojo -- read what buck2 built from its build report
#   (`buck2 build --build-report <file>`), never from a buck-out glob.
# =============================================================================
#
# The parts of the report read here:
#
#   {"success": true,
#    "project_root": "/abs/repo",
#    "results": {
#      "cell//pkg:name": {
#        "success": "SUCCESS",                 or "FAIL"
#        "outputs": {"DEFAULT": ["buck-out/.../pkg.conda"],
#                    "manifest": ["buck-out/.../pkg.json"]},
#        "errors": [{"message_content": "..."}, ...]}}}
#
# A result key carries the cell name before `//`; it is matched to the
# requested `//pkg:name` by what follows the `//`. A sub-target's outputs
# appear under the target's own key, keyed by the sub-target name. Output
# paths are relative to `project_root` unless absolute.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import JSON_ARRAY, JSON_OBJECT, JSON_STRING, JsonValue, parse_json_value

comptime DEFAULT_OUTPUTS: String = "DEFAULT"


struct TargetResult(Copyable, Movable):
    """One target's entry in the report. `found` is False when the report
    has no entry for it.

    Layout: owned values only. No pointer field."""

    var target: String
    var found: Bool
    var success: Bool
    var default_outputs: List[String]
    var sub_outputs: List[String]
    var error: String

    def __init__(out self, var target: String):
        self.target = target^
        self.found = False
        self.success = False
        self.default_outputs = List[String]()
        self.sub_outputs = List[String]()
        self.error = String("")


def _refuse(source: String, why: String) raises:
    raise Error(String("build report '") + source + String("': ") + why)


def _unqualified(label: String) -> String:
    """`cell//pkg:name` -> `//pkg:name`."""
    var at = label.find(String("//"))
    if at <= 0:
        return label.copy()
    return String(label[byte = at:])


def _paths(outputs: JsonValue, key: String, root: String, source: String) raises -> List[String]:
    var out = List[String]()
    if not outputs.has(key):
        return out^
    var arr = outputs.get(key)
    if arr.kind_tag() != JSON_ARRAY:
        _refuse(source, String("outputs '") + key + String("' is not a list"))
    for i in range(arr.array_len()):
        var p = arr.element_at(i)
        if p.kind_tag() != JSON_STRING:
            _refuse(source, String("an output path under '") + key + String("' is not a string"))
        var s = p.as_string()
        if not s.startswith(String("/")) and root.byte_length() > 0:
            s = root + String("/") + s
        out.append(s^)
    return out^


def _error_text(entry: JsonValue) raises -> String:
    if not entry.has(String("errors")):
        return String("")
    var errs = entry.get(String("errors"))
    if errs.kind_tag() != JSON_ARRAY:
        return String("")
    var text = String("")
    for i in range(errs.array_len()):
        var e = errs.element_at(i)
        var msg: String
        if e.kind_tag() == JSON_OBJECT and e.has(String("message_content")):
            var m = e.get(String("message_content"))
            msg = m.as_string() if m.kind_tag() == JSON_STRING else m.serialize()
        else:
            msg = e.serialize()
        if text.byte_length() > 0:
            text += String("; ")
        text += msg
    return text^


def parse_build_report(
    text: String, source: String, targets: List[String], sub_target: String
) raises -> List[TargetResult]:
    """One `TargetResult` per entry of `targets`, in that order: its success,
    its DEFAULT outputs and its `sub_target` outputs, as absolute paths
    when the report states a `project_root`."""
    var doc: JsonValue
    try:
        doc = parse_json_value(text)
    except e:
        _refuse(source, String("not JSON: ") + String(e))
        return List[TargetResult]()
    if not doc.is_object() or not doc.has(String("results")):
        _refuse(source, String("has no 'results' object"))
    var root = String("")
    if doc.has(String("project_root")):
        var r = doc.get(String("project_root"))
        if r.kind_tag() == JSON_STRING:
            root = r.as_string()
    var results = doc.get(String("results"))
    if results.kind_tag() != JSON_OBJECT:
        _refuse(source, String("'results' is not an object"))
    var out = List[TargetResult]()
    for t in range(len(targets)):
        var tr = TargetResult(targets[t].copy())
        for i in range(results.num_members()):
            if _unqualified(results.key_at(i)) != targets[t]:
                continue
            var entry = results.value_at(i)
            if entry.kind_tag() != JSON_OBJECT:
                _refuse(source, String("the entry for ") + targets[t] + String(" is not an object"))
            tr.found = True
            if entry.has(String("success")):
                var s = entry.get(String("success"))
                tr.success = s.kind_tag() == JSON_STRING and s.as_string() == "SUCCESS"
            if entry.has(String("outputs")):
                var outputs = entry.get(String("outputs"))
                if outputs.kind_tag() != JSON_OBJECT:
                    _refuse(source, String("the outputs of ") + targets[t] + String(" are not an object"))
                tr.default_outputs = _paths(outputs, String(DEFAULT_OUTPUTS), root, source)
                tr.sub_outputs = _paths(outputs, sub_target, root, source)
            tr.error = _error_text(entry)
            break
        out.append(tr^)
    return out^


def read_build_report(
    path: String, targets: List[String], sub_target: String
) raises -> List[TargetResult]:
    var text: String
    try:
        text = Path(path).read_text()
    except e:
        raise Error(String("build report '") + path + String("' cannot be read: ") + String(e))
    return parse_build_report(text, path, targets, sub_target)
