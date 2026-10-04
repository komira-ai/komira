# =============================================================================
# komira_gcp_firestore/firestore_listen_proto.mojo — the Listen messages the
#   watch sends and receives, as the GENERATED messages of
#   komira_gcp_firestore_listen, and the normalized `ListenEvent`.
# =============================================================================
#
# The watch (firestore_listen_client.mojo) speaks `google.firestore.v1.
# Firestore/Listen`: it sends one `ListenRequest` adding a documents target,
# and the server pushes `ListenResponse`s. Both are generated from the pinned
# googleapis protos (//tools/vendor/googleapis:firestore_v1) and encoded and
# decoded by komira_proto_codec; nothing here writes a protobuf byte.
#
# This module builds the request (`encode_listen_request_documents`, and the
# `_after` form that resumes from a read time) and folds one response into a
# `ListenEvent`: target_change / document_change / document_delete /
# document_remove, with a document's fields as the same `FsValue` map the
# REST path produces (`fs_fields_from_listen`), so a document change maps
# onto RowCells exactly as a REST read does. A response arm the watch does not
# model (an existence `filter`) is `LE_UNKNOWN`.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard origins;
# ZERO unsafe_from_address. Owned `List[UInt8]` / `String` / `FsValue` only.
# =============================================================================

from komira_proto_codec.codec import decode_proto, encode_proto
from komira_wkt import Timestamp

from komira_gcp_firestore_listen.firestore import (
    ListenRequest,
    ListenResponse,
    Target,
    Target_DocumentsTarget,
)

from komira_gcp_firestore.firestore_value import FsValue, fs_fields_from_listen


# =============================================================================
# §0 — TargetChange.TargetChangeType, as the event carries it.
# =============================================================================

comptime TCT_NO_CHANGE: Int = 0
comptime TCT_ADD: Int = 1
comptime TCT_REMOVE: Int = 2
comptime TCT_CURRENT: Int = 3
comptime TCT_RESET: Int = 4


def target_change_type_name(t: Int) -> StaticString:
    if t == TCT_NO_CHANGE:
        return "NO_CHANGE"
    elif t == TCT_ADD:
        return "ADD"
    elif t == TCT_REMOVE:
        return "REMOVE"
    elif t == TCT_CURRENT:
        return "CURRENT"
    elif t == TCT_RESET:
        return "RESET"
    return "UNKNOWN"


# =============================================================================
# §1 — the ListenRequest a documents watch sends.
# =============================================================================


# The generated messages' oneof arms this module sets or reads
# (`_oneofN_case`, in the order the proto declares them); test_firestore_listen
# pins each against the generated decoder.
comptime LISTEN_REQUEST_ADD_TARGET = 1
"""`ListenRequest.target_change`: `add_target`."""
comptime TARGET_DOCUMENTS = 2
"""`Target.target_type`: `documents`."""
comptime TARGET_READ_TIME = 2
"""`Target.resume_type`: `read_time`."""
comptime LISTEN_TARGET_CHANGE = 1
"""`ListenResponse.response_type`: `target_change`."""
comptime LISTEN_DOCUMENT_CHANGE = 2
"""`ListenResponse.response_type`: `document_change`."""
comptime LISTEN_DOCUMENT_DELETE = 3
"""`ListenResponse.response_type`: `document_delete`."""
comptime LISTEN_DOCUMENT_REMOVE = 4
"""`ListenResponse.response_type`: `document_remove`."""


def _documents_target(
    document_names: List[String], target_id: Int
) -> Target:
    var names = List[String]()
    for i in range(len(document_names)):
        names.append(document_names[i].copy())
    return Target(
        Int32(target_id),
        False,
        None,
        TARGET_DOCUMENTS,
        None,
        Target_DocumentsTarget(names^),
        0,
        None,
        None,
    )


def encode_listen_request_documents(
    database: String,
    document_names: List[String],
    target_id: Int,
) raises -> List[UInt8]:
    """The protobuf bytes of `ListenRequest{database, add_target: Target{
    documents: DocumentsTarget{documents}, target_id}}`: the first (and, for a
    documents watch, only) message the client sends. `database` is
    `projects/<p>/databases/<d>`, each name a full document resource name,
    `target_id` the id the server echoes in its responses. With no resume
    position the server first sends the documents' current state."""
    var req = ListenRequest(
        database.copy(),
        Dict[String, String](),
        None,
        LISTEN_REQUEST_ADD_TARGET,
        _documents_target(document_names, target_id),
        None,
    )
    return encode_proto(req)


def encode_listen_request_documents_after(
    database: String,
    document_names: List[String],
    target_id: Int,
    resume_seconds: Int64,
    resume_nanos: Int64,
) raises -> List[UInt8]:
    """The RESUMING form: as `encode_listen_request_documents`, with the
    Target's `read_time` (its `resume_type` oneof) set to the watermark, so
    Firestore sends only changes after it (it may repeat changes AT the
    boundary, never send a new one at or before it), with no snapshot
    re-read. A zero watermark (0, 0) is no watermark: the cold-start form.

    Only `read_time` is set, never `resume_token`: the durable, crash-safe
    checkpoint is the read time (a resume token is a same-session optimization
    that does not survive a crash; see firestore_cdc_cursor)."""
    var target = _documents_target(document_names, target_id)
    if resume_seconds != Int64(0) or resume_nanos != Int64(0):
        target._oneof1_case = TARGET_READ_TIME
        target.read_time = Timestamp(resume_seconds, Int32(resume_nanos))
    var req = ListenRequest(
        database.copy(),
        Dict[String, String](),
        None,
        LISTEN_REQUEST_ADD_TARGET,
        target^,
        None,
    )
    return encode_proto(req)


# =============================================================================
# §2 — FsDocument and the normalized ListenEvent.
# =============================================================================


struct FsDocument(Copyable, Movable, Deinitable):
    """A decoded Firestore document: its full resource `name` + its `fields` as
    an FsValue MAP (so fs_fields_to_row_cells maps it straight onto RowCells).

    Layout: a plain owned-field struct (String + FsValue). FsValue is a plain
    owned tagged union (no pointer field), lives only in a plain field / List."""

    var name: String
    var fields: FsValue  # FS_T_MAP

    def __init__(out self, var name: String, var fields: FsValue):
        self.name = name^
        self.fields = fields^

    def copy(self) -> Self:
        return Self(String(self.name), self.fields.copy())


comptime LE_TARGET_CHANGE: Int = 0
comptime LE_DOCUMENT_CHANGE: Int = 1
comptime LE_DOCUMENT_DELETE: Int = 2
comptime LE_DOCUMENT_REMOVE: Int = 3
comptime LE_UNKNOWN: Int = 4


def listen_event_kind_name(k: Int) -> StaticString:
    if k == LE_TARGET_CHANGE:
        return "TARGET_CHANGE"
    elif k == LE_DOCUMENT_CHANGE:
        return "DOCUMENT_CHANGE"
    elif k == LE_DOCUMENT_DELETE:
        return "DOCUMENT_DELETE"
    elif k == LE_DOCUMENT_REMOVE:
        return "DOCUMENT_REMOVE"
    return "UNKNOWN"


struct ListenEvent(Copyable, Movable, Deinitable):
    """ONE decoded ListenResponse, normalized across the response oneof.

    Fields:
      kind                — LE_* discriminator.
      target_change_type  — for LE_TARGET_CHANGE: TCT_* (else -1).
      document            — for LE_DOCUMENT_CHANGE: the changed doc (name+fields).
                            For delete/remove it carries only the doc name (empty
                            fields map). For target_change it is an empty doc.
      is_document_present — True iff `document` carries a real doc (change) or a
                            deleted doc name (delete/remove).
      resume_token        — for LE_TARGET_CHANGE: the opaque resume cursor bytes
                            (TargetChange.resume_token, field 4). Empty when
                            absent — check `has_resume_token`, since an
                            empty-but-present token is distinct from an absent one.
      has_resume_token    — True iff this event carried a resume_token (NOT set on
                            every target change).
      read_time_seconds   — for LE_TARGET_CHANGE: TargetChange.read_time.seconds
                            (google.protobuf.Timestamp, field 6). 0 when absent.
      read_time_nanos     — TargetChange.read_time.nanos. 0 when absent.
      has_read_time       — True iff this event carried a read_time.

    The resume_token + read_time ride ONLY on a TargetChange (the CDC checkpoint
    boundary); a DocumentChange/Delete/Remove leaves them absent. The CDC
    ChangeSource threads the resume_token (resume the watch) + read_time (the
    record ordering key) from the latest resumable TargetChange.

    Layout: plain owned fields (Int + FsDocument{String,FsValue} + a plain
    `List[UInt8]` token + Int64 timestamp parts). No pointer field, no wildcard
    origin, no byte-slab."""

    var kind: Int
    var target_change_type: Int
    var document: FsDocument
    var is_document_present: Bool
    var resume_token: List[UInt8]
    var has_resume_token: Bool
    var read_time_seconds: Int64
    var read_time_nanos: Int64
    var has_read_time: Bool

    def __init__(
        out self,
        kind: Int,
        target_change_type: Int,
        var document: FsDocument,
        is_document_present: Bool,
    ):
        """Construct a ListenEvent with NO resumable position (the common case
        for document_change / delete / remove, and a bare target_change)."""
        self.kind = kind
        self.target_change_type = target_change_type
        self.document = document^
        self.is_document_present = is_document_present
        self.resume_token = List[UInt8]()
        self.has_resume_token = False
        self.read_time_seconds = Int64(0)
        self.read_time_nanos = Int64(0)
        self.has_read_time = False

    def __init__(
        out self,
        kind: Int,
        target_change_type: Int,
        var document: FsDocument,
        is_document_present: Bool,
        var resume_token: List[UInt8],
        has_resume_token: Bool,
        read_time_seconds: Int64,
        read_time_nanos: Int64,
        has_read_time: Bool,
    ):
        """Construct a ListenEvent carrying a resumable position (a TargetChange
        with a resume_token and/or read_time)."""
        self.kind = kind
        self.target_change_type = target_change_type
        self.document = document^
        self.is_document_present = is_document_present
        self.resume_token = resume_token^
        self.has_resume_token = has_resume_token
        self.read_time_seconds = read_time_seconds
        self.read_time_nanos = read_time_nanos
        self.has_read_time = has_read_time

    def copy(self) -> Self:
        var tok = List[UInt8]()
        for i in range(len(self.resume_token)):
            tok.append(self.resume_token[i])
        return Self(
            self.kind,
            self.target_change_type,
            self.document.copy(),
            self.is_document_present,
            tok^,
            self.has_resume_token,
            self.read_time_seconds,
            self.read_time_nanos,
            self.has_read_time,
        )

    @always_inline
    def kind_name(self) -> String:
        return listen_event_kind_name(self.kind)


# =============================================================================
# §3 — one ListenResponse -> ListenEvent.
# =============================================================================


def _no_document() -> FsDocument:
    return FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]()))


def listen_event_from_response(r: ListenResponse) raises -> ListenEvent:
    """The `ListenEvent` of one decoded `ListenResponse`."""
    var arm = r._oneof0_case
    if arm == LISTEN_TARGET_CHANGE:
        var tc = r.target_change.value().copy()
        var seconds = Int64(0)
        var nanos = Int64(0)
        var has_read_time = Bool(tc.read_time)
        if has_read_time:
            seconds = tc.read_time.value().seconds
            nanos = Int64(tc.read_time.value().nanos)
        # proto3 bytes carry no presence: an empty token is no token.
        var has_token = len(tc.resume_token) > 0
        return ListenEvent(
            LE_TARGET_CHANGE,
            tc.target_change_type.value,
            _no_document(),
            False,
            tc.resume_token.copy(),
            has_token,
            seconds,
            nanos,
            has_read_time,
        )
    elif arm == LISTEN_DOCUMENT_CHANGE:
        var dc = r.document_change.value().copy()
        if not dc.document:
            return ListenEvent(LE_DOCUMENT_CHANGE, -1, _no_document(), False)
        var d = dc.document.value().copy()
        return ListenEvent(
            LE_DOCUMENT_CHANGE,
            -1,
            FsDocument(d.name.copy(), fs_fields_from_listen(d.fields)),
            True,
        )
    elif arm == LISTEN_DOCUMENT_DELETE:
        return ListenEvent(
            LE_DOCUMENT_DELETE,
            -1,
            FsDocument(
                r.document_delete.value().document.copy(),
                FsValue.map_of(List[String](), List[FsValue]()),
            ),
            True,
        )
    elif arm == LISTEN_DOCUMENT_REMOVE:
        return ListenEvent(
            LE_DOCUMENT_REMOVE,
            -1,
            FsDocument(
                r.document_remove.value().document.copy(),
                FsValue.map_of(List[String](), List[FsValue]()),
            ),
            True,
        )
    # An existence filter, or no arm: not modeled by the watch.
    return ListenEvent(LE_UNKNOWN, -1, _no_document(), False)


def decode_listen_response(message_bytes: Span[UInt8, _]) raises -> ListenEvent:
    """Decode ONE `ListenResponse` (a gRPC envelope's payload, its 5-byte
    prefix already stripped) with the generated message, into a
    `ListenEvent`."""
    var b = List[UInt8](capacity=len(message_bytes))
    b.extend(message_bytes)
    return listen_event_from_response(decode_proto[ListenResponse](b^))
