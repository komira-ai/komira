# =============================================================================
# test_request_shape.mojo: what `parse_evaluation` and `parse_evaluations`
# accept and refuse, by reason code.
# =============================================================================
#
# Every member the profile reads is tried missing, of each wrong JSON kind,
# and at each length bound (the shortest and longest accepted value, one
# past the longest); the batch bounds (1 and 100 items accepted, 0 and 101
# refused); a batch item that breaks the profile placed LAST, after good
# items, so a check that looks only at the first item is caught; the
# per-item `subject`, `action` and `context` overrides AuthZEN allows and
# this profile refuses; a duplicate member nested inside `subject` and
# inside a batch item. Accepted requests are read back field by field, the
# batch's resources in order.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_test_pdp import (
    MAX_BATCH_ITEMS,
    MAX_RESOURCE_ID_BYTES,
    REASON_ACTION_INVALID,
    REASON_BATCH_INVALID,
    REASON_BODY_NOT_JSON,
    REASON_CONTEXT_INVALID,
    REASON_DUPLICATE_MEMBER,
    REASON_RESOURCE_INVALID,
    REASON_SUBJECT_INVALID,
    parse_evaluation,
    parse_evaluations,
)

comptime SUBJECT: String = '{"type":"jwt_sub","id":"alice","properties":{"token":"t"}}'
comptime ACTION: String = '{"name":"read"}'
comptime RESOURCE: String = '{"type":"note","id":"n1"}'
comptime CONTEXT: String = '{"audience":"notes"}'
comptime OMIT: String = "-"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _obj(
    subject: String, action: String, resource: String, context: String, extra: String = ""
) -> String:
    """An object with each part that is not OMIT; `extra` is raw members."""
    var parts = List[String]()
    if subject != OMIT:
        parts.append(String('"subject":') + subject)
    if action != OMIT:
        parts.append(String('"action":') + action)
    if resource != OMIT:
        parts.append(String('"resource":') + resource)
    if context != OMIT:
        parts.append(String('"context":') + context)
    if extra.byte_length() != 0:
        parts.append(extra)
    var s = String("{")
    for i in range(len(parts)):
        if i > 0:
            s += ","
        s += parts[i]
    return s + "}"


def _items(n: Int, last: String = "") -> String:
    """`"evaluations":[...]` with n good items, then `last` when given."""
    var s = String('"evaluations":[')
    for i in range(n):
        if i > 0:
            s += ","
        s += String('{"resource":{"type":"note","id":"n') + String(i) + '"}}'
    if last.byte_length() != 0:
        if n > 0:
            s += ","
        s += last
    return s + "]"


@fieldwise_init
struct Case(Copyable, Movable):
    var label: String
    var body: String
    var want: String


def _run(cases: List[Case], batch: Bool) -> String:
    var misses = String("")
    for i in range(len(cases)):
        ref c = cases[i]
        var got = parse_evaluations(_bytes(c.body)).reason if batch else parse_evaluation(
            _bytes(c.body)
        ).reason
        if got != c.want:
            misses += c.label + ": got [" + got + "] want [" + c.want + "]\n"
    return misses^


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def test_single_accepts_and_reads() raises:
    var out = parse_evaluation(_bytes(_obj(SUBJECT, ACTION, RESOURCE, CONTEXT, '"x":[1,{"y":2}]')))
    assert_equal(out.reason, String(""))
    ref r = out.request
    assert_equal(r.subject_type, String("jwt_sub"))
    assert_equal(r.subject_id, String("alice"))
    assert_equal(r.subject_token, String("t"))
    assert_equal(r.action, String("read"))
    assert_equal(r.audience, String("notes"))
    assert_equal(len(r.resources), 1)
    assert_equal(r.resources[0].type, String("note"))
    assert_equal(r.resources[0].id, String("n1"))


def test_single_shape() raises:
    var c = List[Case]()
    var S = SUBJECT
    var A = ACTION
    var R = RESOURCE
    var X = CONTEXT
    # The document.
    c.append(Case("empty", "", REASON_BODY_NOT_JSON))
    c.append(Case("unclosed", "{", REASON_BODY_NOT_JSON))
    c.append(Case("array", "[]", REASON_BODY_NOT_JSON))
    c.append(Case("string", '"x"', REASON_BODY_NOT_JSON))
    c.append(Case("number", "1", REASON_BODY_NOT_JSON))
    c.append(Case("trailing", _obj(S, A, R, X) + "{}", REASON_BODY_NOT_JSON))
    c.append(Case("dup top", _obj(S, A, R, X, '"action":{"name":"admin"}'), REASON_DUPLICATE_MEMBER))
    c.append(
        Case(
            "dup in subject",
            _obj('{"type":"jwt_sub","id":"alice","id":"bob","properties":{"token":"t"}}', A, R, X),
            REASON_DUPLICATE_MEMBER,
        )
    )
    c.append(
        Case(
            "dup in properties",
            _obj('{"type":"jwt_sub","id":"alice","properties":{"token":"t","token":"u"}}', A, R, X),
            REASON_DUPLICATE_MEMBER,
        )
    )
    # subject.
    c.append(Case("subject missing", _obj(OMIT, A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("subject string", _obj('"alice"', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("subject null", _obj("null", A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("type missing", _obj('{"id":"alice","properties":{"token":"t"}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("type number", _obj('{"type":1,"id":"alice","properties":{"token":"t"}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("id missing", _obj('{"type":"jwt_sub","properties":{"token":"t"}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("id number", _obj('{"type":"jwt_sub","id":7,"properties":{"token":"t"}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("properties missing", _obj('{"type":"jwt_sub","id":"alice"}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("properties string", _obj('{"type":"jwt_sub","id":"alice","properties":"t"}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("token missing", _obj('{"type":"jwt_sub","id":"alice","properties":{}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("token number", _obj('{"type":"jwt_sub","id":"alice","properties":{"token":1}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("token empty", _obj('{"type":"jwt_sub","id":"alice","properties":{"token":""}}', A, R, X), REASON_SUBJECT_INVALID))
    c.append(Case("token one byte", _obj(S, A, R, X), ""))
    c.append(Case("type and id empty", _obj('{"type":"","id":"","properties":{"token":"t"}}', A, R, X), ""))
    # action.
    c.append(Case("action missing", _obj(S, OMIT, R, X), REASON_ACTION_INVALID))
    c.append(Case("action string", _obj(S, '"read"', R, X), REASON_ACTION_INVALID))
    c.append(Case("name missing", _obj(S, "{}", R, X), REASON_ACTION_INVALID))
    c.append(Case("name number", _obj(S, '{"name":1}', R, X), REASON_ACTION_INVALID))
    c.append(Case("name empty", _obj(S, '{"name":""}', R, X), REASON_ACTION_INVALID))
    c.append(Case("name one byte", _obj(S, '{"name":"r"}', R, X), ""))
    # resource.
    c.append(Case("resource missing", _obj(S, A, OMIT, X), REASON_RESOURCE_INVALID))
    c.append(Case("resource string", _obj(S, A, '"n1"', X), REASON_RESOURCE_INVALID))
    c.append(Case("rtype missing", _obj(S, A, '{"id":"n1"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rtype number", _obj(S, A, '{"type":1,"id":"n1"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rtype empty", _obj(S, A, '{"type":"","id":"n1"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rtype one byte", _obj(S, A, '{"type":"k","id":"n1"}', X), ""))
    c.append(Case("rid missing", _obj(S, A, '{"type":"note"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rid number", _obj(S, A, '{"type":"note","id":1}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rid empty", _obj(S, A, '{"type":"note","id":""}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rid one byte", _obj(S, A, '{"type":"note","id":"n"}', X), ""))
    var longest = _repeat("a", MAX_RESOURCE_ID_BYTES)
    c.append(Case("rid 256", _obj(S, A, String('{"type":"note","id":"') + longest + '"}', X), ""))
    c.append(Case("rid 257", _obj(S, A, String('{"type":"note","id":"') + longest + 'a"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rprops object", _obj(S, A, '{"type":"note","id":"n1","properties":{"a":1}}', X), ""))
    c.append(Case("rprops string", _obj(S, A, '{"type":"note","id":"n1","properties":"a"}', X), REASON_RESOURCE_INVALID))
    c.append(Case("rprops array", _obj(S, A, '{"type":"note","id":"n1","properties":[]}', X), REASON_RESOURCE_INVALID))
    # context.
    c.append(Case("context missing", _obj(S, A, R, OMIT), REASON_CONTEXT_INVALID))
    c.append(Case("context string", _obj(S, A, R, '"notes"'), REASON_CONTEXT_INVALID))
    c.append(Case("audience missing", _obj(S, A, R, "{}"), REASON_CONTEXT_INVALID))
    c.append(Case("audience number", _obj(S, A, R, '{"audience":1}'), REASON_CONTEXT_INVALID))
    c.append(Case("audience empty", _obj(S, A, R, '{"audience":""}'), ""))
    var misses = _run(c, False)
    assert_equal(misses, String(""), "single:\n" + misses)


def test_batch_accepts_and_reads() raises:
    var body = _obj(SUBJECT, ACTION, OMIT, CONTEXT, _items(3))
    var out = parse_evaluations(_bytes(body))
    assert_equal(out.reason, String(""))
    ref r = out.request
    assert_equal(len(r.resources), 3)
    for i in range(3):
        assert_equal(r.resources[i].id, String("n") + String(i))
        assert_equal(r.resources[i].type, String("note"))
    assert_equal(r.subject_id, String("alice"))
    assert_equal(r.action, String("read"))
    assert_equal(r.audience, String("notes"))


def test_batch_shape() raises:
    var misses = String("")
    var c = List[Case]()
    var S = SUBJECT
    var A = ACTION
    var X = CONTEXT
    var bad_res = String('{"resource":{"type":"note"}}')
    c.append(Case("one item", _obj(S, A, OMIT, X, _items(1)), ""))
    c.append(Case("100 items", _obj(S, A, OMIT, X, _items(MAX_BATCH_ITEMS)), ""))
    c.append(Case("0 items", _obj(S, A, OMIT, X, _items(0)), REASON_BATCH_INVALID))
    c.append(Case("101 items", _obj(S, A, OMIT, X, _items(MAX_BATCH_ITEMS + 1)), REASON_BATCH_INVALID))
    c.append(Case("evaluations missing", _obj(S, A, OMIT, X), REASON_BATCH_INVALID))
    c.append(Case("evaluations object", _obj(S, A, OMIT, X, '"evaluations":{}'), REASON_BATCH_INVALID))
    c.append(Case("top-level resource", _obj(S, A, RESOURCE, X, _items(1)), REASON_BATCH_INVALID))
    # Each broken item comes last, after two good ones.
    c.append(Case("item string", _obj(S, A, OMIT, X, _items(2, '"n9"')), REASON_BATCH_INVALID))
    c.append(Case("item empty", _obj(S, A, OMIT, X, _items(2, "{}")), REASON_BATCH_INVALID))
    c.append(Case("item other member", _obj(S, A, OMIT, X, _items(2, '{"x":1}')), REASON_BATCH_INVALID))
    c.append(Case("item resource string", _obj(S, A, OMIT, X, _items(2, '{"resource":"n9"}')), REASON_BATCH_INVALID))
    c.append(Case("item bad resource", _obj(S, A, OMIT, X, _items(2, bad_res)), REASON_RESOURCE_INVALID))
    c.append(
        Case(
            "item with subject",
            _obj(S, A, OMIT, X, _items(2, String('{"resource":') + RESOURCE + ',"subject":' + S + "}")),
            REASON_BATCH_INVALID,
        )
    )
    c.append(
        Case(
            "item with action",
            _obj(S, A, OMIT, X, _items(2, String('{"resource":') + RESOURCE + ',"action":' + A + "}")),
            REASON_BATCH_INVALID,
        )
    )
    c.append(
        Case(
            "item with context",
            _obj(S, A, OMIT, X, _items(2, String('{"context":') + X + ',"resource":' + RESOURCE + "}")),
            REASON_BATCH_INVALID,
        )
    )
    c.append(
        Case(
            "item dup",
            _obj(S, A, OMIT, X, _items(2, '{"resource":{"type":"note","id":"a","id":"b"}}')),
            REASON_DUPLICATE_MEMBER,
        )
    )
    # The shared parts are read as for one evaluation.
    c.append(Case("batch subject missing", _obj(OMIT, A, OMIT, X, _items(1)), REASON_SUBJECT_INVALID))
    c.append(Case("batch action missing", _obj(S, OMIT, OMIT, X, _items(1)), REASON_ACTION_INVALID))
    c.append(Case("batch context missing", _obj(S, A, OMIT, OMIT, _items(1)), REASON_CONTEXT_INVALID))
    c.append(Case("batch not json", "{", REASON_BODY_NOT_JSON))
    c.append(Case("batch dup", _obj(S, A, OMIT, X, _items(1) + "," + _items(1)), REASON_DUPLICATE_MEMBER))
    misses += _run(c, True)
    assert_equal(misses, String(""), "batch:\n" + misses)


def main() raises:
    test_single_accepts_and_reads()
    test_single_shape()
    test_batch_accepts_and_reads()
    test_batch_shape()
    print("PASS komira_test_pdp test_request_shape")
