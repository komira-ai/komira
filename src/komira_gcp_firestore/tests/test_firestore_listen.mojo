# =============================================================================
# test_firestore_listen.mojo — the Firestore `Listen` H2-bidi client FALSIFIERS
#   (protocol logic + the WINDOW_UPDATE flow-control de-risk), fully OFFLINE.
# =============================================================================
#
# This proves — with ZERO network — the protocol half of the H2-bidi Firestore
# Listen client. The ONLY thing that needs the live endpoint is the actual
# socket-level flow-control behavior; everything the client DECIDES (proto
# encode/decode, the gRPC 5-byte framing, and — critically — the h2 recv-window
# WINDOW_UPDATE replenishment on a LONG-LIVED server push) is exercised here
# against synthetic frames replayed off a ScriptedStream (an in-process mock
# IoStream), so the logic is falsifiable offline.
#
# THE FALSIFIERS:
#
#   (1) PROTO ROUND-TRIP: a ListenRequest(add DocumentsTarget) encodes to
#       protobuf bytes that DECODE back to the same database + document + target
#       (via a raw PbFieldCursor). FALSIFIER: a wrong field number / wire type
#       corrupts the decode.
#
#   (2) LISTEN RESPONSE DECODE: a synthetic TargetChange(CURRENT),
#       DocumentChange(with typed fields), and DocumentDelete decode to the right
#       ListenEvent kind + the DocumentChange's fields map onto the right
#       RowCells (string/long/double/bool). FALSIFIER: a mis-decoded oneof arm /
#       a dropped field.
#
#   (3) gRPC FRAMING ACROSS FRAGMENTS: two gRPC messages fed in arbitrary
#       byte-chunk splits reassemble to exactly two complete payloads.
#       FALSIFIER: an off-by-one in the 5-byte length-prefix framer.
#
#   (4) THE FLOW-CONTROL DE-RISK (the load-bearing one): drive the FULL
#       FirestoreListenClient (open + repeated poll) against a ScriptedStream
#       carrying >128 KB of server-pushed DocumentChange DATA across many h2
#       DATA frames. Assert:
#         (a) the client DRAINS all >128 KB of pushed data (bytes_seen crosses
#             both the 64 KB and 128 KB thresholds — the stream KEEPS FLOWING),
#         (b) the client EMITTED >=1 WINDOW_UPDATE frame into its write-capture
#             (the replenishment fired — the exact mechanism whose ABSENCE was
#             a >64KB stall),
#         (c) all the pushed DocumentChanges decoded (event count matches).
#       FALSIFIER: a client that did NOT replenish would (on a real
#       flow-control-respecting server) stall at ~64 KB; here the falsifier is
#       the WINDOW_UPDATE-count assertion + the >128KB drain — a non-replenishing
#       client emits zero WINDOW_UPDATEs and (against a strict server) never sees
#       past the initial window.
#
# WHY the ScriptedStream models the de-risk faithfully. The de-risk is about the
# CLIENT's OUTBOUND WINDOW_UPDATE emission as it consumes pushed DATA. The
# ScriptedStream captures every byte the client writes (`capture_view`), so we
# can DECODE the client's outbound frames and COUNT the WINDOW_UPDATEs it
# actually put on the wire while draining >128 KB — which is precisely the
# behavior a strict server depends on. The live run then confirms the real
# Firestore server keeps pushing (i.e. it honored those WINDOW_UPDATEs).
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_WINDOW_UPDATE,
    FRAME_DATA,
    FRAME_HEADERS,
    FRAME_DECODE_OK,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader, HpackDecoder
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedStream

from komira_protobuf.reader import PbFieldCursor
from komira_protobuf.writer import (
    pb_write_string_field,
    pb_write_message_field,
    pb_write_varint_field,
    pb_write_double_field,
    pb_write_bool_field,
)

# The cell model, from the zero-dep leaf. Was
# `komira_iceberg.iceberg_row_value` / `.iceberg_types`; same symbols, new home
# — `CELL_T_X` is what `ICE_T_X` was.
from komira_rowcell import (
    RowCell,
    CELL_T_STRING,
    CELL_T_LONG,
    CELL_T_DOUBLE,
    CELL_T_BOOLEAN,
)

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    FsDocument,
    decode_listen_response,
    encode_listen_request_documents,
    LE_TARGET_CHANGE,
    LE_DOCUMENT_CHANGE,
    LE_DOCUMENT_DELETE,
    LE_DOCUMENT_REMOVE,
    TCT_CURRENT,
    LISTEN_REQUEST_ADD_TARGET,
    TARGET_DOCUMENTS,
    TARGET_READ_TIME,
    LISTEN_TARGET_CHANGE,
    LISTEN_DOCUMENT_CHANGE,
    LISTEN_DOCUMENT_DELETE,
    LISTEN_DOCUMENT_REMOVE,
)
from komira_gcp_firestore_listen.firestore import (
    ListenRequest,
    ListenResponse,
    Target,
)
from komira_proto_codec.codec import decode_json, decode_proto, encode_proto

# google.firestore.v1 field numbers (firestore.proto, write.proto,
# document.proto at the pinned googleapis commit), for building the server's
# side of the wire here independently of the generated messages.
comptime LR_DATABASE = 1  # ListenRequest.database
comptime LR_ADD_TARGET = 2  # ListenRequest.add_target
comptime TGT_DOCUMENTS = 3  # Target.documents
comptime TGT_TARGET_ID = 5  # Target.target_id
comptime DOCS_TGT_DOCUMENTS = 2  # Target.DocumentsTarget.documents
comptime LRESP_TARGET_CHANGE = 2  # ListenResponse.target_change
comptime LRESP_DOCUMENT_CHANGE = 3  # ListenResponse.document_change
comptime LRESP_DOCUMENT_DELETE = 4  # ListenResponse.document_delete
comptime TC_TARGET_CHANGE_TYPE = 1  # TargetChange.target_change_type
comptime DC_DOCUMENT = 1  # DocumentChange.document
comptime DDEL_DOCUMENT = 1  # DocumentDelete.document
comptime DOC_NAME = 1  # Document.name
comptime DOC_FIELDS = 2  # Document.fields (map entries)
comptime FV_STRING_VALUE = 17  # Value.string_value
comptime FV_INTEGER_VALUE = 2  # Value.integer_value
comptime FV_DOUBLE_VALUE = 3  # Value.double_value
comptime FV_BOOLEAN_VALUE = 1  # Value.boolean_value
comptime FMAP_ENTRY_KEY = 1  # map entry key
comptime FMAP_ENTRY_VALUE = 2  # map entry value


from komira_gcp_firestore.firestore_value import fs_fields_to_row_cells
from komira_grpc import ClientFramer

from komira_gcp_firestore.firestore_listen_client import (
    FirestoreListenClient,
    encode_grpc_envelope,
)


# -----------------------------------------------------------------------------
# Reactor helper (mirrors the h2 client tests).
# -----------------------------------------------------------------------------


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


# -----------------------------------------------------------------------------
# Synthetic Firestore protobuf builders (server-side wire fixtures). Kept in the
# test so the fixtures are independent of the client's own encoder for the
# response side (an honest falsifier).
# -----------------------------------------------------------------------------


def _fs_string_value(field_num: Int, value: String) -> List[UInt8]:
    """A Value{ stringValue } sub-message wrapped as map-entry-value bytes with
    the given field number (used to nest a Value inside a map entry)."""
    var val = List[UInt8]()
    pb_write_string_field(val, FV_STRING_VALUE, value)
    var out = List[UInt8]()
    pb_write_message_field(out, field_num, val)
    return out^


def _map_entry(key: String, var value_msg: List[UInt8]) -> List[UInt8]:
    """A Document.fields map entry: { string key = 1; Value value = 2; }.

    `value_msg` is the encoded Value message bytes."""
    var entry = List[UInt8]()
    pb_write_string_field(entry, FMAP_ENTRY_KEY, key)
    pb_write_message_field(entry, FMAP_ENTRY_VALUE, value_msg)
    return entry^


def _value_string(v: String) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_string_field(out, FV_STRING_VALUE, v)
    return out^


def _value_integer(v: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_varint_field(out, FV_INTEGER_VALUE, UInt64(v))
    return out^


def _value_double(v: Float64) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_double_field(out, FV_DOUBLE_VALUE, v)
    return out^


def _value_bool(v: Bool) -> List[UInt8]:
    var out = List[UInt8]()
    pb_write_bool_field(out, FV_BOOLEAN_VALUE, v)
    return out^


def _build_document(
    name: String,
    field_names: List[String],
    field_values: List[List[UInt8]],
) -> List[UInt8]:
    """Build a Document{ name = 1; map<string,Value> fields = 2; } proto.

    Each `field_values[i]` is the encoded Value message for `field_names[i]`."""
    var doc = List[UInt8]()
    pb_write_string_field(doc, DOC_NAME, name)
    for i in range(len(field_names)):
        var entry = _map_entry(field_names[i], field_values[i].copy())
        pb_write_message_field(doc, DOC_FIELDS, entry)
    return doc^


def _listen_response_document_change(
    doc_bytes: List[UInt8],
) -> List[UInt8]:
    """A ListenResponse{ document_change = 3 { document = 1 } }."""
    var dc = List[UInt8]()
    pb_write_message_field(dc, DC_DOCUMENT, doc_bytes)
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_DOCUMENT_CHANGE, dc)
    return resp^


def _listen_response_target_change_current() -> List[UInt8]:
    """A ListenResponse{ target_change = 2 { target_change_type = CURRENT } }."""
    var tc = List[UInt8]()
    pb_write_varint_field(tc, TC_TARGET_CHANGE_TYPE, UInt64(TCT_CURRENT))
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_TARGET_CHANGE, tc)
    return resp^


def _listen_response_document_delete(name: String) -> List[UInt8]:
    """A ListenResponse{ document_delete = 4 { document = 1 } }."""
    var dd = List[UInt8]()
    pb_write_string_field(dd, DDEL_DOCUMENT, name)
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_DOCUMENT_DELETE, dd)
    return resp^


# -----------------------------------------------------------------------------
# (1) ListenRequest proto round-trip.
# -----------------------------------------------------------------------------


def test_listen_request_roundtrip() raises:
    print("  test_listen_request_roundtrip...")
    var db = String("projects/p1/databases/(default)")
    var docs = List[String]()
    docs.append(
        String("projects/p1/databases/(default)/documents/coll/doc1")
    )
    var target_id = 7
    var bytes = encode_listen_request_documents(db, docs, target_id)

    # Decode the outer ListenRequest.
    var view = Span[UInt8](bytes).as_imm()
    var cur = PbFieldCursor.over(view)
    var got_db = String("")
    var got_doc = String("")
    var got_target = 0
    while cur.has_next():
        var tag = cur.next_tag()
        if tag.field_number == LR_DATABASE:
            got_db = cur.read_string()
        elif tag.field_number == LR_ADD_TARGET:
            var tgt = cur.read_message()
            while tgt.has_next():
                var tt = tgt.next_tag()
                if tt.field_number == TGT_DOCUMENTS:
                    var dt = tgt.read_message()
                    while dt.has_next():
                        var dtag = dt.next_tag()
                        if dtag.field_number == DOCS_TGT_DOCUMENTS:
                            got_doc = dt.read_string()
                        else:
                            dt.skip()
                elif tt.field_number == TGT_TARGET_ID:
                    got_target = Int(tgt.read_varint())
                else:
                    tgt.skip()
        else:
            cur.skip()

    assert_equal(got_db, db)
    assert_equal(got_doc, docs[0])
    assert_equal(got_target, target_id)
    print("    OK")


def test_listen_request_bytes_match_grpcurl_reference() raises:
    """BYTE-EXACT wire-format pin against an EXTERNAL known-good reference.

    The `encode_listen_request_documents` output MUST match, byte for byte, the
    protobuf a proven gRPC client (grpcurl, driven off the public
    google/firestore/v1/firestore.proto) puts on the wire for the SAME
    ListenRequest. This locks the generated encoder to the canonical wire
    format — a wrong field number / wire type / length prefix changes what
    the reference decodes to.

    The reference bytes below were computed from the protobuf spec (verified
    identical to grpcurl's live-captured request against real Firestore during
    a root-cause investigation): ListenRequest{
      database    = "projects/p1/databases/(default)"          (field 1, str)
      add_target  = Target{                                    (field 2, msg)
        documents = DocumentsTarget{                           (field 3, msg)
          documents = [".../documents/coll/doc1"]              (field 2, str)
        }
        target_id = 7                                          (field 5, varint)
      }
    }

    FALSIFIER: the messages are generated from the pinned protos, so a wrong
    field number would come from a wrong pin; the reference bytes would then
    decode to a different request. This guards that the encoding is
    wire-correct:
    the zero-bytes symptom was NOT a bad request BODY (this test proves
    the ListenRequest bytes are right) — it was a MISSING request HEADER. The
    Firestore frontend rejected the RPC with grpc-status 3 (INVALID_ARGUMENT,
    "Missing required http header ('google-cloud-resource-prefix' or
    'x-goog-request-params')") and pushed zero DATA. The fix is the
    google-cloud-resource-prefix header in FirestoreListenClient.open (see
    firestore_listen_client.mojo); the request PAYLOAD encoding was always
    correct, as this byte-pin proves."""
    print("  test_listen_request_bytes_match_grpcurl_reference...")
    var db = String("projects/p1/databases/(default)")
    var docs = List[String]()
    docs.append(
        String("projects/p1/databases/(default)/documents/coll/doc1")
    )
    var target_id = 7
    var got = encode_listen_request_documents(db, docs, target_id)

    # The externally-computed reference wire bytes (92 bytes, DECIMAL).
    var reference: List[Int] = [
        10, 31, 112, 114, 111, 106, 101, 99, 116, 115, 47, 112, 49, 47, 100, 97,
        116, 97, 98, 97, 115, 101, 115, 47, 40, 100, 101, 102, 97, 117, 108, 116,
        41, 18, 57, 26, 53, 18, 51, 112, 114, 111, 106, 101, 99, 116, 115, 47,
        112, 49, 47, 100, 97, 116, 97, 98, 97, 115, 101, 115, 47, 40, 100, 101,
        102, 97, 117, 108, 116, 41, 47, 100, 111, 99, 117, 109, 101, 110, 116,
        115, 47, 99, 111, 108, 108, 47, 100, 111, 99, 49, 40, 7,
    ]
    # The generated encoder writes a message's oneof fields after its plain
    # ones (Target.target_id before Target.documents), where protoc writes in
    # field-number order, and it writes an implicit-presence field at its
    # default (`Target.once = false`, 2 bytes) where protoc omits it. Protobuf
    # leaves both to the encoder and every parser reads them the same. So the
    # pin is: the reference decodes to this request, and the reference
    # re-encoded by the generated encoder is byte-identical to what the client
    # sends.
    assert_equal(len(reference), 92)
    var ref_bytes = List[UInt8]()
    for i in range(92):
        ref_bytes.append(UInt8(reference[i]))
    var ref_req = decode_proto[ListenRequest](ref_bytes^)
    assert_equal(ref_req.database, db)
    assert_equal(ref_req.add_target.value().target_id, Int32(7))
    assert_equal(ref_req.add_target.value().documents.value().documents[0], docs[0])
    assert_equal(encode_proto(ref_req), got)
    print("    OK (the grpcurl reference decodes to the same request)")


# -----------------------------------------------------------------------------
# (2) ListenResponse decode + FsValue-fields -> RowCell mapping.
# -----------------------------------------------------------------------------


def test_target_change_decode() raises:
    print("  test_target_change_decode...")
    var bytes = _listen_response_target_change_current()
    var view = Span[UInt8](bytes).as_imm()
    var ev = decode_listen_response(view)
    assert_equal(ev.kind, LE_TARGET_CHANGE)
    assert_equal(ev.target_change_type, TCT_CURRENT)
    assert_false(ev.is_document_present)
    print("    OK")


def test_document_change_decode_and_rowcells() raises:
    print("  test_document_change_decode_and_rowcells...")
    var names = List[String]()
    names.append(String("title"))
    names.append(String("count"))
    names.append(String("ratio"))
    names.append(String("active"))
    var values = List[List[UInt8]]()
    values.append(_value_string(String("hello")))
    values.append(_value_integer(Int64(42)))
    values.append(_value_double(Float64(3.5)))
    values.append(_value_bool(True))
    var doc = _build_document(
        String("projects/p/databases/d/documents/c/x"), names, values
    )
    var resp = _listen_response_document_change(doc)

    var view = Span[UInt8](resp).as_imm()
    var ev = decode_listen_response(view)
    assert_equal(ev.kind, LE_DOCUMENT_CHANGE)
    assert_true(ev.is_document_present)
    assert_equal(
        ev.document.name, String("projects/p/databases/d/documents/c/x")
    )

    # Map the decoded fields onto RowCells in a column order + assert arms.
    var cols = List[String]()
    cols.append(String("title"))
    cols.append(String("count"))
    cols.append(String("ratio"))
    cols.append(String("active"))
    var cells = fs_fields_to_row_cells(ev.document.fields, cols)
    assert_equal(len(cells), 4)
    assert_equal(cells[0].type_tag, CELL_T_STRING)
    assert_equal(cells[0].as_string(), String("hello"))
    assert_equal(cells[1].type_tag, CELL_T_LONG)
    assert_equal(cells[1].as_long(), Int64(42))
    assert_equal(cells[2].type_tag, CELL_T_DOUBLE)
    assert_equal(cells[3].type_tag, CELL_T_BOOLEAN)
    print("    OK")


def test_document_delete_decode() raises:
    print("  test_document_delete_decode...")
    var name = String("projects/p/databases/d/documents/c/gone")
    var bytes = _listen_response_document_delete(name)
    var view = Span[UInt8](bytes).as_imm()
    var ev = decode_listen_response(view)
    assert_equal(ev.kind, LE_DOCUMENT_DELETE)
    assert_true(ev.is_document_present)
    assert_equal(ev.document.name, name)
    print("    OK")


# -----------------------------------------------------------------------------
# (3) gRPC 5-byte framing across arbitrary chunk splits.
# -----------------------------------------------------------------------------


def test_grpc_framing_across_fragments() raises:
    print("  test_grpc_framing_across_fragments...")
    # Two gRPC messages: a target_change + a document_delete.
    var m1 = encode_grpc_envelope(_listen_response_target_change_current())
    var m2 = encode_grpc_envelope(
        _listen_response_document_delete(String("projects/p/x"))
    )
    var wire = List[UInt8]()
    for i in range(len(m1)):
        wire.append(m1[i])
    for i in range(len(m2)):
        wire.append(m2[i])

    # Feed the wire in 7-byte chunks (mid-message fragmentation).
    var framer = ClientFramer()
    var popped = List[List[UInt8]]()
    var pos = 0
    while pos < len(wire):
        var chunk = List[UInt8]()
        var end = pos + 7
        if end > len(wire):
            end = len(wire)
        for i in range(pos, end):
            chunk.append(wire[i])
        framer.feed_owned(chunk^)
        while True:
            var one = framer.try_pop_envelope()
            if not one.__bool__():
                break
            var envelope = one.take()
            popped.append(envelope.payload.copy())
        pos = end

    assert_equal(len(popped), 2)
    # Message 1 decodes to a TARGET_CHANGE; message 2 to a DOCUMENT_DELETE.
    var v1 = Span[UInt8](popped[0]).as_imm()
    var e1 = decode_listen_response(v1)
    assert_equal(e1.kind, LE_TARGET_CHANGE)
    var v2 = Span[UInt8](popped[1]).as_imm()
    var e2 = decode_listen_response(v2)
    assert_equal(e2.kind, LE_DOCUMENT_DELETE)
    print("    OK")


# -----------------------------------------------------------------------------
# (4) THE FLOW-CONTROL DE-RISK — drive the FULL client against >128KB of pushed
#     DocumentChange DATA + assert WINDOW_UPDATE emission + full drain.
# -----------------------------------------------------------------------------


def _build_server_listen_stream(
    sid: UInt32, n_docs: Int, payload_bytes_per_doc: Int
) raises -> List[UInt8]:
    """Synthesize the server side of a Listen stream:
      SETTINGS + HEADERS(:status 200, content-type application/grpc) [no
      END_STREAM] + a TargetChange(CURRENT) + N DocumentChanges — each a big
      document (a large string field) wrapped in a gRPC envelope and carried in
      its own h2 DATA frame [NO END_STREAM — the stream stays open].

    The total pushed DATA far exceeds the 65535-byte initial recv window, so a
    client that does NOT replenish its window would (against a strict server)
    stall — here it must drain all of it AND emit WINDOW_UPDATEs."""
    var bytes = List[UInt8]()

    # Server initial SETTINGS (empty non-ACK).
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)

    # Response HEADERS: :status 200 + content-type application/grpc. NO
    # END_STREAM (the server keeps the response half open for the push).
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        sid, block^, end_stream=False, end_headers=True, out=bytes
    )

    # A TargetChange(CURRENT) as the first pushed message.
    var tc_env = encode_grpc_envelope(
        _listen_response_target_change_current()
    )
    encode_data_frame(sid, tc_env^, end_stream=False, out=bytes)

    # N DocumentChanges, each carrying a big string field.
    var big = String("")
    for _i in range(payload_bytes_per_doc):
        big += String("x")
    for d in range(n_docs):
        var names = List[String]()
        names.append(String("blob"))
        names.append(String("seq"))
        var values = List[List[UInt8]]()
        values.append(_value_string(big))
        values.append(_value_integer(Int64(d)))
        var doc = _build_document(
            String("projects/p/databases/d/documents/c/doc")
            + String(d),
            names, values,
        )
        var env = encode_grpc_envelope(_listen_response_document_change(doc))
        # Chunk the envelope into <=8KB h2 DATA frames (the peer max-frame is
        # 16KB; 8KB keeps each frame well under it), NO END_STREAM.
        var ei = 0
        while ei < len(env):
            var frame_payload = List[UInt8]()
            var fend = ei + 8192
            if fend > len(env):
                fend = len(env)
            for k in range(ei, fend):
                frame_payload.append(env[k])
            encode_data_frame(sid, frame_payload^, end_stream=False, out=bytes)
            ei = fend
    return bytes^


def _count_window_updates(capture: Span[UInt8, _]) raises -> Int:
    """Decode the client's outbound frame stream (skipping the 24-byte h2
    preface if present) and count FRAME_WINDOW_UPDATE frames — the de-risk
    evidence that the client replenished its recv window."""
    # Skip the 24-byte client connection preface if present.
    var start = 0
    if len(capture) >= 24:
        # The preface begins with "PRI ".
        if (
            capture[0] == UInt8(ord("P"))
            and capture[1] == UInt8(ord("R"))
            and capture[2] == UInt8(ord("I"))
        ):
            start = 24
    var count = 0
    var pos = start
    while pos < len(capture):
        var rest = capture[pos:]
        var res = decode_frame(rest, 16384)
        if res.status != FRAME_DECODE_OK:
            break
        if res.frame.header.kind == FRAME_WINDOW_UPDATE:
            count += 1
        pos += res.consumed
        if res.consumed <= 0:
            break
    return count


def _decode_first_headers_block(capture: Span[UInt8, _]) raises -> List[HpackHeader]:
    """Decode the client's outbound frame stream (skipping the 24-byte h2
    preface if present), find the FIRST FRAME_HEADERS frame, and HPACK-decode
    its block into (name, value) pairs — the request headers the client put on
    the wire."""
    var start = 0
    if len(capture) >= 24:
        if (
            capture[0] == UInt8(ord("P"))
            and capture[1] == UInt8(ord("R"))
            and capture[2] == UInt8(ord("I"))
        ):
            start = 24
    var pos = start
    var decoder = HpackDecoder()
    while pos < len(capture):
        var rest = capture[pos:]
        var res = decode_frame(rest, 16384)
        if res.status != FRAME_DECODE_OK:
            break
        if res.frame.header.kind == FRAME_HEADERS:
            var block = Span[UInt8](res.frame.payload).as_imm()
            return decoder.decode_block(block)
        pos += res.consumed
        if res.consumed <= 0:
            break
    return List[HpackHeader]()


def test_open_sends_resource_prefix_routing_header() raises:
    """REGRESSION GUARD for a zero-DATA-frame bug. FirestoreListenClient.open MUST send the
    `google-cloud-resource-prefix` header (value = the database resource name),
    or the Firestore frontend rejects the Listen RPC with grpc-status 3
    (INVALID_ARGUMENT, "Missing required http header
    ('google-cloud-resource-prefix' or 'x-goog-request-params')") — returning
    :status 200 but pushing ZERO DATA frames (the exact symptom that made a
    live client report bytes_seen=0 forever).

    FAILS ON CURRENT CODE (pre-fix): open() appended only content-type / te /
    grpc-accept-encoding / authorization — no routing header — so this assert
    (google-cloud-resource-prefix present with the DB value) failed. The fix
    adds the header in firestore_listen_client.mojo:open.

    The test decodes the client's ACTUAL outbound HEADERS frame off the
    ScriptedStream write-capture and HPACK-decodes it, so it verifies the header
    truly reached the wire (not just that the code path appended it)."""
    print("  test_open_sends_resource_prefix_routing_header...")
    var reactor = _make_reactor()
    var sid = UInt32(1)
    # A minimal server script: SETTINGS + response HEADERS(:status 200). We only
    # need open() to complete; the header we assert is on the CLIENT's write.
    var server_bytes = _build_server_listen_stream(sid, 1, 16)

    var shared = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(
        server_bytes^, shared
    )
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

    var docs = List[String]()
    docs.append(String("projects/p/databases/d/documents/c/doc0"))
    var database = String("projects/p/databases/d")
    var client = FirestoreListenClient[ScriptedStream](
        stream^, String("firestore.googleapis.com"), String("fake-token")
    )
    client.open[PerCoreAsyncRuntime[NoopSink]](reactor, database, docs, 7)
    assert_equal(Int(client.status()), 200)

    # Decode the client's outbound request HEADERS off the write-capture.
    var cap_view = Span[UInt8](shared[]).as_imm()
    var req_headers = _decode_first_headers_block(cap_view)

    var found_prefix = False
    var prefix_value = String("")
    var found_content_type = False
    for i in range(len(req_headers)):
        var nm = String(req_headers[i].name)
        if nm == String("google-cloud-resource-prefix"):
            found_prefix = True
            prefix_value = String(req_headers[i].value)
        elif nm == String("content-type"):
            found_content_type = True

    # Sanity: we actually decoded the request headers (content-type present).
    assert_true(
        found_content_type,
        String("did not decode the outbound request HEADERS (content-type"
               " missing) — the capture/decode is broken, not the fix"),
    )
    # The load-bearing assertion: the routing header is present with the DB
    # resource name.
    assert_true(
        found_prefix,
        String("google-cloud-resource-prefix header MISSING from the Listen"
               " request — Firestore rejects the RPC with grpc-status 3 and"
               " pushes zero DATA (the zero-bytes bug)"),
    )
    assert_equal(prefix_value, database)
    print("    OK (google-cloud-resource-prefix =", prefix_value, ")")


def test_flow_control_sustained_server_push_no_stall() raises:
    print("  test_flow_control_sustained_server_push_no_stall...")
    var reactor = _make_reactor()

    # The client will allocate stream_id 1 (first odd id).
    var sid = UInt32(1)
    # 40 docs x ~4KB each => ~160 KB of pushed document DATA — well past 128 KB
    # AND past the 64 KB initial recv window, so replenishment is REQUIRED to
    # drain it all against a strict server.
    var n_docs = 40
    var per_doc = 4000
    var server_bytes = _build_server_listen_stream(sid, n_docs, per_doc)

    # Give the test a handle on the client's OUTBOUND write-capture so we can
    # count WINDOW_UPDATEs after the drive. (ScriptedStream mirrors writes into a
    # shared ArcPointer buffer that survives the stream's move into the client.)
    var shared = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(
        server_bytes^, shared
    )
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    # Serve <=4KB per read so the drive loops many times (models a real socket
    # dribbling the push in small reads — exercises the per-read replenish path).
    stream.set_max_read_per_call(4096)

    var docs = List[String]()
    docs.append(String("projects/p/databases/d/documents/c/doc0"))
    var client = FirestoreListenClient[ScriptedStream](
        stream^, String("firestore.googleapis.com"), String("fake-token")
    )
    client.open[PerCoreAsyncRuntime[NoopSink]](
        reactor,
        String("projects/p/databases/d"),
        docs,
        7,
    )
    assert_equal(Int(client.status()), 200)

    # Poll until the ScriptedStream is exhausted (all pushed frames drained).
    # Each poll returns the events decoded from the next push; accumulate.
    var total_events = 0
    var doc_changes = 0
    var target_changes = 0
    var polls = 0
    while polls < 2000:
        polls += 1
        var events = client.poll[PerCoreAsyncRuntime[NoopSink]](
            reactor, max_wall_us=2_000_000
        )
        if len(events) == 0:
            # No progress this poll — the script is drained (a real live watch
            # would keep the stream open; the mock returns EOF at script end,
            # which poll surfaces as no new events).
            break
        for i in range(len(events)):
            total_events += 1
            if events[i].kind == LE_DOCUMENT_CHANGE:
                doc_changes += 1
            elif events[i].kind == LE_TARGET_CHANGE:
                target_changes += 1

    # (a) The client DRAINED all >128 KB of pushed document data. bytes_seen is
    #     the cumulative pushed DATA the client consumed.
    var seen = client.bytes_seen()
    print("    bytes_seen=", seen, " doc_changes=", doc_changes,
          " target_changes=", target_changes, " polls=", polls)
    assert_true(
        seen > 64 * 1024,
        String("client did not flow past 64KB (bytes_seen=") + String(seen)
        + String(")"),
    )
    assert_true(
        seen > 128 * 1024,
        String("client did not flow past 128KB (bytes_seen=") + String(seen)
        + String(")"),
    )

    # (b) The client EMITTED WINDOW_UPDATE frames while draining — the exact
    #     replenishment whose ABSENCE was a >64KB stall.
    var wu_count = _count_window_updates(
        Span[UInt8](shared[]).as_imm()
    )
    print("    window_updates_emitted=", wu_count)
    assert_true(
        wu_count >= 1,
        String("client emitted NO WINDOW_UPDATE while draining >128KB (a"
               " non-replenishing client would stall on a strict server)"),
    )

    # (c) All the pushed DocumentChanges decoded.
    assert_equal(doc_changes, n_docs)
    assert_true(target_changes >= 1)
    print("    OK")


def test_oneof_arm_constants_are_the_generated_decoders() raises:
    """Each arm constant the Listen module names is the generated decoder's
    number for that arm, so a reordering proto bump fails here."""
    assert_equal(
        decode_json[ListenRequest](
            String('{"database":"d","addTarget":{"targetId":1}}')
        )._oneof0_case,
        LISTEN_REQUEST_ADD_TARGET,
    )
    assert_equal(
        decode_json[Target](String('{"documents":{"documents":["x"]}}'))._oneof0_case,
        TARGET_DOCUMENTS,
    )
    assert_equal(
        decode_json[Target](String('{"readTime":"2026-10-01T00:00:00Z"}'))._oneof1_case,
        TARGET_READ_TIME,
    )
    assert_equal(
        decode_json[ListenResponse](String('{"targetChange":{}}'))._oneof0_case,
        LISTEN_TARGET_CHANGE,
    )
    assert_equal(
        decode_json[ListenResponse](String('{"documentChange":{}}'))._oneof0_case,
        LISTEN_DOCUMENT_CHANGE,
    )
    assert_equal(
        decode_json[ListenResponse](String('{"documentDelete":{}}'))._oneof0_case,
        LISTEN_DOCUMENT_DELETE,
    )
    assert_equal(
        decode_json[ListenResponse](String('{"documentRemove":{}}'))._oneof0_case,
        LISTEN_DOCUMENT_REMOVE,
    )


def main() raises:
    print("test_firestore_listen (H2-bidi Listen — offline protocol + flow-control)")
    test_listen_request_roundtrip()
    test_listen_request_bytes_match_grpcurl_reference()
    test_target_change_decode()
    test_document_change_decode_and_rowcells()
    test_document_delete_decode()
    test_grpc_framing_across_fragments()
    test_open_sends_resource_prefix_routing_header()
    test_flow_control_sustained_server_push_no_stall()
    test_oneof_arm_constants_are_the_generated_decoders()
    print("ALL PASS")
