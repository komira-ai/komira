# =============================================================================
# test_firestore_db_encoding.mojo — the driver's pure pieces, each against an
#   exact expected value: the client-side guard evaluator, the update
#   applier, the predicate renderer, the field encoder / decoder, and the
#   small text helpers. Plus the round trips that only the document form
#   can break (bytes, text arrays, an absent column, a key-less table).
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_db import (
    DbValue,
    DbColVal,
    Pred,
    Filter,
    Order,
    LOGICAL_TEXT,
)

from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    FirestoreDocument,
)
from komira_gcp_firestore.firestore_value import FsValue

from komira_gcp_firestore_db import (
    DeclaredIndex,
    DeclaredIndexField,
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)
from komira_gcp_firestore_db.firestore_database import (
    _apply_updates,
    _build_structured_query,
    _doc_field_int,
    _doc_field_text,
    _encode_doc_id_part,
    _encode_fields,
    _guard_matches,
    _hex2,
    _pred_value_json,
    _render_pred,
    _text_to_int,
)


comptime _Rt = BlockingRuntime[NoopSink]
comptime _MockT = MockFirestoreConnector
comptime _FsDb = FirestoreDatabase[_MockT]


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _doc() -> FirestoreDocument:
    """s = "x" (string), n = 5 (integer), z = null; `q` is absent."""
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("s"))
    vals.append(FsValue.string(String("x")))
    keys.append(String("n"))
    vals.append(FsValue.integer(String("5")))
    keys.append(String("z"))
    vals.append(FsValue.null())
    return FirestoreDocument(
        String("projects/p/databases/d/documents/t/d1"),
        FsValue.map_of(keys^, vals^),
        String(""),
        String(""),
    )


def _m(var p: Pred) raises -> Bool:
    return _guard_matches(_doc(), Filter.just(p^))


def _null() -> DbValue:
    return DbValue.null(LOGICAL_TEXT)


# =============================================================================
# 1. _guard_matches: every operator against a present, a NULL and an ABSENT
#    field.
# =============================================================================
def test_guard_operators() raises:
    # EQ: a NULL or absent field never equals anything.
    assert_true(_m(Pred.eq(String("s"), DbValue.text("x"))))
    assert_false(_m(Pred.eq(String("s"), DbValue.text("y"))))
    assert_false(_m(Pred.eq(String("z"), DbValue.text(""))), "EQ on a NULL field")
    assert_false(_m(Pred.eq(String("q"), DbValue.text(""))), "EQ on an absent field")

    # NE is IS DISTINCT FROM.
    assert_true(_m(Pred.ne(String("s"), DbValue.text("y"))))
    assert_false(_m(Pred.ne(String("s"), DbValue.text("x"))), "equal is not distinct")
    assert_true(_m(Pred.ne(String("z"), DbValue.text("x"))), "NULL is distinct from a value")
    assert_true(_m(Pred.ne(String("q"), DbValue.text("x"))), "absent is distinct from a value")
    assert_true(_m(Pred.ne(String("s"), _null())), "a value is distinct from NULL")
    assert_false(_m(Pred.ne(String("z"), _null())), "NULL is not distinct from NULL")
    assert_false(_m(Pred.ne(String("q"), _null())), "absent is not distinct from NULL")

    # LT / GTE compare integers, and a NULL / absent field fails them.
    assert_true(_m(Pred.lt(String("n"), DbValue.int8(Int64(6)))))
    assert_false(_m(Pred.lt(String("n"), DbValue.int8(Int64(5)))), "5 < 5")
    assert_false(_m(Pred.lt(String("z"), DbValue.int8(Int64(6)))), "LT on NULL")
    assert_false(_m(Pred.lt(String("q"), DbValue.int8(Int64(6)))), "LT on absent")
    assert_true(_m(Pred.gte(String("n"), DbValue.int8(Int64(5)))), "5 >= 5")
    assert_false(_m(Pred.gte(String("n"), DbValue.int8(Int64(6)))))
    assert_false(_m(Pred.gte(String("z"), DbValue.int8(Int64(0)))), "GTE on NULL")

    # IS_NULL / IS_NOT_NULL: an absent field reads as NULL here.
    assert_true(_m(Pred.is_null(String("z"))))
    assert_true(_m(Pred.is_null(String("q"))))
    assert_false(_m(Pred.is_null(String("s"))))
    assert_true(_m(Pred.is_not_null(String("s"))))
    assert_false(_m(Pred.is_not_null(String("z"))))
    assert_false(_m(Pred.is_not_null(String("q"))))

    # An operator the evaluator has no arm for fails closed.
    assert_false(
        _m(Pred.json_key_eq(String("s"), String("k"), DbValue.text("x"))),
        "JSON_KEY_EQ fails closed",
    )
    var vals = List[DbValue]()
    vals.append(DbValue.text("x"))
    assert_false(_m(Pred.in_list(String("s"), vals^)), "IN fails closed")

    # Every predicate must hold: one failing term fails the guard.
    var all = List[Pred]()
    all.append(Pred.eq(String("s"), DbValue.text("x")))
    all.append(Pred.gte(String("n"), DbValue.int8(Int64(1))))
    all.append(Pred.is_null(String("z")))
    assert_true(_guard_matches(_doc(), Filter.all_of(all.copy())))
    all.append(Pred.lt(String("n"), DbValue.int8(Int64(2))))
    assert_false(_guard_matches(_doc(), Filter.all_of(all^)), "the last term fails")
    print("    [PASS] _guard_matches: every operator, present / NULL / absent")


# =============================================================================
# 2. _apply_updates: BIND / COALESCE / the coalesce flag, an unknown kind, the
#    version bump and the now_cols stamp, on present, NULL and absent fields.
# =============================================================================
def test_apply_updates() raises:
    var u = List[DbColVal]()
    u.append(DbColVal.coalesce(String("s"), _null()))  # NULL coalesce: keep "x"
    u.append(DbColVal.coalesce(String("n"), DbValue.int8(Int64(9))))
    u.append(DbColVal.bind(String("q"), DbValue.text("new")))  # absent: appended
    var now_cols = List[String]()
    now_cols.append(String("s2"))
    var f = _apply_updates(
        _doc(), u, False, Optional[String](String("z")), now_cols, Int64(777)
    )
    assert_equal(f.map_get(String("s")).as_string(), String("x"), "COALESCE(NULL) keeps")
    assert_equal(f.map_get(String("n")).as_string(), String("9"), "COALESCE(9) sets")
    assert_equal(f.map_get(String("q")).as_string(), String("new"), "a new field is added")
    assert_equal(f.map_get(String("z")).as_string(), String("1"), "NULL version bumps to 1")
    assert_equal(f.map_get(String("s2")).as_string(), String("777"), "now_cols stamped")
    assert_equal(len(f.map_keys), 5, "three kept + two added")

    # With coalesce = True a NULL BIND keeps the stored value; without it, a
    # NULL BIND writes NULL.
    var nb = List[DbColVal]()
    nb.append(DbColVal.bind(String("s"), _null()))
    var kept = _apply_updates(
        _doc(), nb, True, Optional[String](), List[String](), Int64(0)
    )
    assert_equal(kept.map_get(String("s")).as_string(), String("x"))
    var nulled = _apply_updates(
        _doc(), nb, False, Optional[String](), List[String](), Int64(0)
    )
    assert_true(nulled.map_get(String("s")).is_null())

    # A version column the document lacks starts at 0 and bumps to 1; an
    # existing one bumps by one.
    var bumped = _apply_updates(
        _doc(), List[DbColVal](), False, Optional[String](String("v")),
        List[String](), Int64(0),
    )
    assert_equal(bumped.map_get(String("v")).as_string(), String("1"))
    var bumped_n = _apply_updates(
        _doc(), List[DbColVal](), False, Optional[String](String("n")),
        List[String](), Int64(0),
    )
    assert_equal(bumped_n.map_get(String("n")).as_string(), String("6"))

    # An update kind with no arm is refused by name, not dropped. The
    # three-argument DbColVal constructor refuses kind 7 itself, but `kind` is
    # a public field, so a caller can still hand this backend one: set it on a
    # BIND term the way DbColVal.coalesce sets its own kind.
    var odd_term = DbColVal.bind(String("s"), DbValue.text("y"))
    odd_term.kind = UInt8(7)
    var odd = List[DbColVal]()
    odd.append(odd_term^)
    with assert_raises(contains="unsupported DbColVal kind 7 for column 's'"):
        _ = _apply_updates(
            _doc(), odd, False, Optional[String](), List[String](), Int64(0)
        )
    print("    [PASS] _apply_updates: every kind, bump and stamp")


# =============================================================================
# 3. _render_pred / _pred_value_json / _build_structured_query: exact JSON.
# =============================================================================
def test_render_exact_json() raises:
    var ff = String('{"fieldFilter":{"field":{"fieldPath":')
    assert_equal(
        _render_pred(Pred.eq(String("a"), _null())),
        String('{"unaryFilter":{"field":{"fieldPath":"a"},"op":"IS_NULL"}}'),
        "= NULL renders as the unary IS_NULL",
    )
    assert_equal(
        _render_pred(Pred.le(String("n"), DbValue.int8(Int64(5)))),
        ff + '"n"},"op":"LESS_THAN_OR_EQUAL","value":{"integerValue":"5"}}}',
    )
    assert_equal(
        _render_pred(Pred.is_null(String("a"))),
        String('{"unaryFilter":{"field":{"fieldPath":"a"},"op":"IS_NULL"}}'),
    )
    assert_equal(
        _render_pred(Pred.is_not_null(String("a"))),
        String('{"unaryFilter":{"field":{"fieldPath":"a"},"op":"IS_NOT_NULL"}}'),
    )
    assert_equal(
        _render_pred(Pred.array_contains(String("tags"), DbValue.text("red"))),
        ff + '"tags"},"op":"ARRAY_CONTAINS","value":{"stringValue":"red"}}}',
    )
    assert_equal(
        _render_pred(Pred.lt(String("a"), _null())),
        ff + '"a"},"op":"LESS_THAN","value":{"nullValue":null}}}',
    )
    assert_equal(_pred_value_json(_null()), String('{"nullValue":null}'))
    with assert_raises(contains="unsupported predicate op 4"):
        _ = _render_pred(Pred.json_key_eq(String("c"), String("k"), DbValue.text("v")))
    var in_vals = List[DbValue]()
    in_vals.append(DbValue.text("v"))
    with assert_raises(contains="unsupported predicate op 6"):
        _ = _render_pred(Pred.in_list(String("c"), in_vals^))

    # Two ORDER BY terms, each with its own direction, served by a declared
    # (a ASC, b DESC) index.
    var fields = List[DeclaredIndexField]()
    fields.append(DeclaredIndexField(String("a"), False, False))
    fields.append(DeclaredIndexField(String("b"), True, False))
    var declared = DeclaredIndexSet()
    declared.declare(DeclaredIndex(String("c"), fields^))
    var order = List[Order]()
    order.append(Order.asc(String("a")))
    order.append(Order.descending(String("b")))
    assert_equal(
        _build_structured_query(
            String("c"), Filter(), order, Optional[UInt32](UInt32(3)), declared
        ),
        String(
            '{"from":[{"collectionId":"c"}],"orderBy":['
            '{"field":{"fieldPath":"a"},"direction":"ASCENDING"},'
            '{"field":{"fieldPath":"b"},"direction":"DESCENDING"}],"limit":3}'
        ),
    )
    print("    [PASS] predicates and queries render to the exact JSON")


# =============================================================================
# 4. The text helpers.
# =============================================================================
def test_text_helpers() raises:
    assert_equal(_text_to_int(String("907")), Int64(907))
    assert_equal(_text_to_int(String("-42")), Int64(-42))
    assert_equal(_text_to_int(String("")), Int64(0), "empty reads as 0")
    assert_equal(_text_to_int(String("12a")), Int64(0), "a non-digit reads as 0")
    assert_equal(_text_to_int(String("1/2")), Int64(0), "a byte below '0' reads as 0")

    assert_equal(_encode_doc_id_part(String("a%b/c")), String("a%25b%2Fc"))
    assert_equal(_encode_doc_id_part(String("%2F")), String("%252F"), "% first")
    assert_equal(_encode_doc_id_part(String("plain-id")), String("plain-id"))

    assert_equal(_hex2(0x00), String("00"))
    assert_equal(_hex2(0x09), String("09"))
    assert_equal(_hex2(0xA0), String("a0"))
    assert_equal(_hex2(0x9F), String("9f"))
    assert_equal(_hex2(0xFF), String("ff"))

    # The claim loop's field readers: absent and NULL both read as empty / 0.
    var d = _doc()
    assert_equal(_doc_field_text(d, String("s")), String("x"))
    assert_equal(_doc_field_text(d, String("z")), String(""), "NULL reads as empty")
    assert_equal(_doc_field_text(d, String("q")), String(""), "absent reads as empty")
    assert_equal(_doc_field_int(d, String("n")), Int64(5))
    assert_equal(_doc_field_int(d, String("z")), Int64(0), "NULL reads as 0")
    assert_equal(_doc_field_int(d, String("q")), Int64(0), "absent reads as 0")

    var keys = TableKeys()
    assert_false(keys.is_declared(String("t")))
    keys.declare(String("t"), String(""))
    keys.declare(String("u"), String("sku"))
    assert_true(keys.is_declared(String("t")), "a key-less declaration is declared")
    assert_true(keys.is_declared(String("u")))
    assert_false(keys.is_declared(String("v")))

    var two = List[String]()
    two.append(String("a"))
    two.append(String("b"))
    var one = List[DbValue]()
    one.append(DbValue.text("x"))
    with assert_raises(contains="cols/vals arity mismatch (2 vs 1)"):
        _ = _encode_fields(two, one)
    print("    [PASS] text helpers")


# =============================================================================
# 5. Round trips through the document form: bytes, a text array (and the
#    native array the ARRAY_CONTAINS filter matches), an absent column, and a
#    key-less table whose rows get minted ids.
# =============================================================================
def test_round_trips() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var mock = MockFirestore()
    var keys = TableKeys()
    keys.declare(String("ledger"), String(""))
    var client = FirestoreClient[_MockT](
        mock.connector(),
        String("test-project"),
        String("(default)"),
        String("test-bearer"),
    )
    var db = _FsDb(client^, DeclaredIndexSet(), keys^)

    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("blob"))
    cols.append(String("tags"))
    var raw = List[UInt8]()
    raw.append(0)
    raw.append(255)
    raw.append(10)
    raw.append(0x80)
    var tags = List[String]()
    tags.append(String("red"))
    tags.append(String("blue"))
    var vals = List[DbValue]()
    vals.append(DbValue.text("r-1"))
    vals.append(DbValue.bytes(raw))
    vals.append(DbValue.text_array(tags))
    _ = db.put[_Rt](reactor, String("item"), cols.copy(), vals^)
    var other = List[DbValue]()
    other.append(DbValue.text("r-2"))
    other.append(DbValue.bytes(List[UInt8]()))
    other.append(DbValue.text_array(List[String]()))
    _ = db.put[_Rt](reactor, String("item"), cols.copy(), other^)

    var stored = db.client_ref().get_document(String("item"), String("r-1"))
    assert_equal(
        stored.get_field(String("blob")).as_string(), String("AP8KgA=="),
        "bytes are stored as base64",
    )
    assert_equal(len(stored.get_field(String("tags")).list_items), 2, "a native array")

    var read_cols = cols.copy()
    read_cols.append(String("never_written"))
    var got = db.get_by_key[_Rt](
        reactor, String("item"), read_cols, String("id"), DbValue.text("r-1")
    )
    var row = got.take()
    var back = row.get_bytes(row.column_index("blob"))
    assert_equal(len(back), 4)
    for i in range(4):
        assert_equal(back[i], raw[i], "bytes round-trip exactly")
    var arr = row.get_text_array(row.column_index("tags"))
    assert_equal(len(arr), 2)
    assert_equal(arr[0], String("red"))
    assert_equal(arr[1], String("blue"))
    assert_true(row.is_null(row.column_index("never_written")), "absent reads as NULL")

    var by_tag = db.query_rows[_Rt](
        reactor, String("item"), cols.copy(),
        Filter.just(Pred.array_contains(String("tags"), DbValue.text("blue"))),
        List[Order](), Optional[UInt32](),
    )
    assert_equal(by_tag.__len__(), 1, "ARRAY_CONTAINS matches the native array")
    assert_equal(by_tag.row(0).get_text(0), String("r-1"))

    # A key-less table: each put mints its own document.
    var lcols = List[String]()
    lcols.append(String("note"))
    for i in range(2):
        var lv = List[DbValue]()
        lv.append(DbValue.text(String("n") + String(i)))
        _ = db.put[_Rt](reactor, String("ledger"), lcols.copy(), lv^)
    var ledger = db.query_rows[_Rt](
        reactor, String("ledger"), lcols.copy(), Filter(), List[Order](),
        Optional[UInt32](),
    )
    assert_equal(ledger.__len__(), 2, "two puts of a key-less table are two documents")
    _ = db^
    print("    [PASS] bytes, arrays, absent columns and key-less tables round-trip")


def main() raises:
    test_guard_operators()
    test_apply_updates()
    test_render_exact_json()
    test_text_helpers()
    test_round_trips()
    print("PASS test_firestore_db_encoding")
