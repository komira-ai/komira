# The Listen messages of the generated komira_gcp_firestore_listen package on
# the protobuf wire, against bytes built here field by field from
# google/firestore/v1/{firestore,write,document}.proto's field numbers (no
# upstream test body is copied): the ListenRequest a watch sends, and each
# arm of the ListenResponse a server pushes.
from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_firestore_listen.document import Document, Value
from komira_gcp_firestore_listen.firestore import (
    ListenRequest,
    ListenResponse,
    Target,
    Target_DocumentsTarget,
    TargetChange_TargetChangeType,
)
from komira_proto_codec.codec import decode_proto, encode_proto
from komira_wkt import Timestamp


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _tag(mut out: List[UInt8], field: Int, wire_type: Int):
    _varint(out, UInt64(field << 3 | wire_type))


def _len(mut out: List[UInt8], field: Int, b: List[UInt8]):
    _tag(out, field, 2)
    _varint(out, UInt64(len(b)))
    for i in range(len(b)):
        out.append(b[i])


def _str(mut out: List[UInt8], field: Int, s: String):
    var b = List[UInt8]()
    b.extend(Span(s.as_bytes()))
    _len(out, field, b)


def _int(mut out: List[UInt8], field: Int, v: Int):
    _tag(out, field, 0)
    _varint(out, UInt64(v))


comptime _DB = "projects/demo-project/databases/(default)"


def test_listen_request_adds_a_documents_target() raises:
    # ListenRequest{database=1, add_target=2: Target{documents=3:
    # DocumentsTarget{documents=2}, target_id=5}}: the first and only message
    # a documents watch sends.
    var names = List[String]()
    names.append(String(_DB) + "/documents/c/a")
    names.append(String(_DB) + "/documents/c/b")
    var target = Target(
        Int32(1), False, None, 2, None, Target_DocumentsTarget(names^), 0, None, None
    )
    var req = ListenRequest(String(_DB), Dict[String, String](), None, 1, target^, None)
    var docs = List[UInt8]()
    _str(docs, 2, String(_DB) + "/documents/c/a")
    _str(docs, 2, String(_DB) + "/documents/c/b")
    var tgt = List[UInt8]()
    _len(tgt, 3, docs)
    _int(tgt, 5, 1)
    var want = List[UInt8]()
    _str(want, 1, String(_DB))
    _len(want, 2, tgt)
    # Field order on the wire is free; compare as decoded and as bytes.
    var got = encode_proto(req)
    var back = decode_proto[ListenRequest](got.copy())
    assert_equal(back.database, String(_DB))
    assert_equal(back._oneof0_case, 1)
    assert_equal(back.add_target.value().target_id, Int32(1))
    assert_equal(len(back.add_target.value().documents.value().documents), 2)
    var from_want = decode_proto[ListenRequest](want.copy())
    assert_equal(encode_proto(from_want), got)


def test_listen_request_resumes_from_a_token() raises:
    # Target.resume_token=4 (bytes), in the resume_type oneof.
    var names = List[String]()
    names.append(String(_DB) + "/documents/c/a")
    var token = List[UInt8]()
    token.append(UInt8(0x0A))
    token.append(UInt8(0xFF))
    var target = Target(
        Int32(7), False, None, 2, None, Target_DocumentsTarget(names^), 1, token.copy(), None
    )
    var req = ListenRequest(String(_DB), Dict[String, String](), None, 1, target^, None)
    var back = decode_proto[ListenRequest](encode_proto(req))
    var t = back.add_target.value().copy()
    assert_equal(t._oneof1_case, 1)
    assert_equal(t.resume_token.value(), token)
    assert_equal(t.target_id, Int32(7))


def test_target_change_current_with_token_and_read_time() raises:
    # ListenResponse.target_change=2: TargetChange{target_change_type=1
    # (CURRENT=3), target_ids=2 [1], resume_token=4, read_time=6}.
    var ts = List[UInt8]()
    _int(ts, 1, 1788393600)
    _int(ts, 2, 5000)
    var tc = List[UInt8]()
    _int(tc, 1, 3)
    var ids = List[UInt8]()
    _varint(ids, 1)
    _len(tc, 2, ids)
    var tok = List[UInt8]()
    tok.append(UInt8(1))
    tok.append(UInt8(2))
    _len(tc, 4, tok)
    _len(tc, 6, ts)
    var msg = List[UInt8]()
    _len(msg, 2, tc)
    var r = decode_proto[ListenResponse](msg^)
    assert_equal(r._oneof0_case, 1)
    var change = r.target_change.value().copy()
    assert_equal(change.target_change_type.value, TargetChange_TargetChangeType.CURRENT)
    assert_equal(len(change.target_ids), 1)
    assert_equal(change.target_ids[0], Int32(1))
    assert_equal(change.resume_token, tok)
    assert_equal(change.read_time.value().seconds, Int64(1788393600))
    assert_equal(change.read_time.value().nanos, Int32(5000))


def test_document_change_carries_the_document() raises:
    # ListenResponse.document_change=3: DocumentChange{document=1:
    # Document{name=1, fields=2 map<string, Value>}, target_ids=5}. Value
    # arms: string_value=17, integer_value=2, map_value=6 (MapValue{fields=1}).
    var sval = List[UInt8]()
    _str(sval, 17, String("x"))
    var e1 = List[UInt8]()
    _str(e1, 1, String("s"))
    _len(e1, 2, sval)
    var ival = List[UInt8]()
    _int(ival, 2, 42)
    var inner_entry = List[UInt8]()
    _str(inner_entry, 1, String("i"))
    _len(inner_entry, 2, ival)
    var mapv = List[UInt8]()
    _len(mapv, 1, inner_entry)
    var mval = List[UInt8]()
    _len(mval, 6, mapv)
    var e2 = List[UInt8]()
    _str(e2, 1, String("m"))
    _len(e2, 2, mval)
    var doc = List[UInt8]()
    _str(doc, 1, String(_DB) + "/documents/c/a")
    _len(doc, 2, e1)
    _len(doc, 2, e2)
    var dc = List[UInt8]()
    _len(dc, 1, doc)
    var ids = List[UInt8]()
    _varint(ids, 1)
    _len(dc, 5, ids)
    var msg = List[UInt8]()
    _len(msg, 3, dc)
    var r = decode_proto[ListenResponse](msg^)
    assert_equal(r._oneof0_case, 2)
    var d = r.document_change.value().document.value().copy()
    assert_equal(d.name, String(_DB) + "/documents/c/a")
    assert_equal(d.fields[String("s")].string_value.value(), String("x"))
    var m = d.fields[String("m")].copy()
    assert_equal(m._oneof0_case, 11)
    assert_equal(m.map_value[0].fields[String("i")].integer_value.value(), Int64(42))
    assert_equal(r.document_change.value().target_ids[0], Int32(1))


def test_delete_remove_and_filter() raises:
    # document_delete=4 {document=1}, document_remove=6 {document=1},
    # filter=5 {target_id=1, count=2}.
    var del_ = List[UInt8]()
    _str(del_, 1, String(_DB) + "/documents/c/a")
    var m1 = List[UInt8]()
    _len(m1, 4, del_)
    var r1 = decode_proto[ListenResponse](m1^)
    assert_equal(r1._oneof0_case, 3)
    assert_equal(r1.document_delete.value().document, String(_DB) + "/documents/c/a")
    var m2 = List[UInt8]()
    _len(m2, 6, del_)
    var r2 = decode_proto[ListenResponse](m2^)
    assert_equal(r2._oneof0_case, 4)
    var f = List[UInt8]()
    _int(f, 1, 1)
    _int(f, 2, 3)
    var m3 = List[UInt8]()
    _len(m3, 5, f)
    var r3 = decode_proto[ListenResponse](m3^)
    assert_equal(r3._oneof0_case, 5)
    assert_equal(r3.filter.value().count, Int32(3))


def test_an_unknown_field_is_skipped() raises:
    # A field this pin does not define (99) beside a known arm.
    var del_ = List[UInt8]()
    _str(del_, 1, String("n"))
    var msg = List[UInt8]()
    _int(msg, 99, 1)
    _len(msg, 4, del_)
    var r = decode_proto[ListenResponse](msg^)
    assert_equal(r._oneof0_case, 3)


def main() raises:
    test_listen_request_adds_a_documents_target()
    test_listen_request_resumes_from_a_token()
    test_target_change_current_with_token_and_read_time()
    test_document_change_carries_the_document()
    test_delete_remove_and_filter()
    test_an_unknown_field_is_skipped()
    print("OK")
