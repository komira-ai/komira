"""Acceptance gate — the FIRESTORE `ConditionalWriteStore` conformer.

A consumer written generically over `[Store: ConditionalWriteStore]` must be
able to run on this conformer unchanged; this file proves it, by driving the
conformer through `_LastWriterWinsKv` (§5), a neutral in-file generic consumer
whose call sequences are the canonical ones such a consumer makes.

⛔ WHAT THIS FILE IS ACTUALLY ABOUT, AND IT IS NOT THE CAS. Both CAS primitives
already existed on `FirestoreClient` (`create_if_absent`,
`update_if_unchanged`) and map 1:1 onto the trait's two preconditions. What kills
a conformer is the ERROR TAXONOMY: every consumer decides "was that a CAS
conflict?" and "was that an absent object?" by SUBSTRING-SCANNING the error
message, so a mapping that is right in the code and wrong in the WORDS is
undetectable by inspection and catastrophic in production.

The two classifiers being satisfied are the substring predicates generic
`ConditionalWriteStore` consumers carry (`_consumer_says_*`, §0), and
`_LastWriterWinsKv` makes every one of its decisions with exactly those two, so
what the gates assert is the predicate a caller really reads, not a paraphrase
of it.

GATES

  1. KEY MAPPING. `item/<name>` -> collection `item`, document `<name>`;
     a 4-segment key is a sub-collection document; an ODD segment count is a
     REFUSAL (it names a collection, and there is no document there); reserved
     `__…__` ids and over-long ids are refusals.
  2. LAST-WRITER-WINS, END TO END, THROUGH `_LastWriterWinsKv` over a stateful
     Firestore double at the HTTP boundary: publish -> read -> REPUBLISH (head +
     CAS on the etag) -> read, plus `publish_if_changed` writing iff changed.
  3. CREATE-OR-CONFLICT on the stateful double: a SECOND create of a key is
     REFUSED as a precondition, and the stored value is UNCHANGED.
  5. ★ THE 412. A Firestore 409 ALREADY_EXISTS (the create precondition lost)
     becomes `StoreError[PRECONDITION] … status=412`, and the CONSUMER's
     predicate reads it as a conflict and NOT as an absence.
  6. ★ THE OTHER 412. A 400 FAILED_PRECONDITION (the updateTime CAS lost) maps
     the same way — and drives `publish`'s retry-once rather than a
     fatal write.
  7. AN ABSENT DOCUMENT is `StoreError[NOT_FOUND] … status=404`, which
     a generic reader turns into an absent answer (`found=False`) — not a
     raise.
  8. ★★ AN ABSENT **DATABASE** IS NOT AN ABSENT OBJECT. Firestore answers both
     with NOT_FOUND to a document GET; the client reads documents with
     BatchGetDocuments, where an absent document is a `missing` result, so a
     NOT_FOUND status is the database. Passed through as NOT_FOUND, every
     lookup would answer "absent" and the store look like an empty world
     while it is broken. The mapped error must be read as NEITHER
     family, and `read` must RAISE.
  9. ★★ A MISSING COMPOSITE INDEX IS NOT A LOST CAS. The sentinel's own name
     contains the token `Precondition`. Passed through, `publish` reads
     a permanent database fault as contention and reports "retry".
 10. THE REST OF THE TAXONOMY: 403 -> PERMISSION_DENIED, 503 -> THROTTLED,
     500 -> TRANSPORT — every one of them read as NEITHER family, so the
     consumer re-raises instead of swallowing.
 11. ★★ THE DEFUSER. A key literally NAMED `404` must not be able to
     change the class of the error it appears in, and a Google message
     containing the word `precondition` never reaches the error at all (the
     generated client keeps no byte of a body). This is the arm that makes
     gates 8/9/10 hold for inputs nobody chose.
 12. ★ THE CAS HANDLE IS `head().etag`, NOT ONLY `.version`. This is the
     leg-C `_HEAD`-advance defect `GcsGrpcConditionalStore` documents, and
     a last-writer-wins publish (`_LastWriterWinsKv._try_once`) reads exactly
     `meta.etag`.
 13. DELETE is idempotent on an absent DOCUMENT and RAISES on an absent
     DATABASE — the swallow is on the typed prefix, tested before mapping.
 14. LIST returns full object keys a caller can feed back to `get`; the ROOT
     prefix and a NESTED collection are REFUSALS, never an empty list.
 15. THE VALUE ROUND-TRIPS through the single `value` stringValue; a non-ASCII
     body is refused; a document with no `value` field is refused rather than
     read as an empty object.
 16. ⛔ THE REFUSE-EVERYTHING CONTROL. A store whose transport raises on every
     call, driven through every positive gate above. Each one must RAISE — and
     in particular `read` must RAISE rather than answer
     `found=false`, because a dead transport reported as an absent key is
     gate 8's failure wearing a different hat.

HERMETIC. A stateful in-file Firestore double (`_FakeFirestore`, served by
komira_gcp_firestore's `ExchangeConnector`) and the shipped `ScriptedFirestore`,
both at the HTTP request/response boundary. ZERO sockets, ZERO GCP credentials,
ZERO emulator. The double reads each request with the same generated messages
the client wrote it with, and every error body below is the literal envelope
shape Google returns, so what is exercised is the generated request builder,
the generated response parser and the real classifier.
"""

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_firestore.firestore_client import (
    FirestoreClient,
    is_already_exists_error,
    is_database_absent_error,
    is_database_precondition_error,
    is_not_found_error,
    is_precondition_failed_error,
)
from komira_gcp_firestore.firestore_conditional_store import (
    FirestoreConditionalStore,
    bytes_to_document_text,
    collection_from_prefix,
    document_text_to_bytes,
    key_from_document_name,
    split_document_path,
)
from komira_gcp_firestore.firestore_fake import (
    ExchangeAnswer,
    ExchangeConnector,
    HttpExchange,
)
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_gcp_firestore_v1.document import Document
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    CommitRequest,
    RunQueryRequest,
)
from komira_http_core.transport.scripted import ScriptedConnector
from komira_proto_codec.codec import decode_json, encode_json
from komira_wkt import Timestamp
from komira_gcp_firestore.firestore_store_errors import (
    STORE_KIND_MALFORMED,
    STORE_KIND_NOT_FOUND,
    STORE_KIND_PERMISSION_DENIED,
    STORE_KIND_PRECONDITION,
    STORE_KIND_THROTTLED,
    STORE_KIND_TRANSPORT,
    defuse_classifier_tokens,
    firestore_http_status,
    map_firestore_error_to_store_error,
    message_class_is_exactly,
    store_error_says_not_found,
    store_error_says_precondition,
)

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import ObjectMeta, WritePrecondition


comptime _PROJECT: StaticString = "example-project"
comptime _DATABASE: StaticString = "example-db"


# =============================================================================
# §0 — THE CONSUMER'S OWN PREDICATES.
#
# ⛔ THE SUBSTRING PREDICATES A GENERIC `ConditionalWriteStore` CONSUMER CARRIES,
# TOKEN FOR TOKEN, NOT PARAPHRASED. The whole point of this file is that a
# message can be correctly CLASSIFIED and still be MISREAD, and the only thing
# that can prove it is not misread is the reader's real predicate — which is
# why `_LastWriterWinsKv` (§5) decides every branch with exactly these two. If
# the consumer-side token list gains a token these must gain it too — and so
# must `firestore_store_errors._token`, which is the same list a third time and
# is what gate 11 exists to police.
# =============================================================================


def _consumer_says_precondition(msg: String) -> Bool:
    return (
        msg.find("StoreError[PRECONDITION]") >= 0
        or msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("PreconditionFailed") >= 0
        or msg.find("412") >= 0
    )


def _consumer_says_not_found(msg: String) -> Bool:
    return (
        msg.find("StoreError[NOT_FOUND]") >= 0
        or msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("NoSuchKey") >= 0
        or msg.find("404") >= 0
    )


def _assert_reads_as(
    msg: String, want_precondition: Bool, want_not_found: Bool, ctx: String
) raises:
    """Assert how the CONSUMER will classify `msg` — both directions, always.

    ⚠ BOTH DIRECTIONS, ALWAYS. Asserting only "reads as a conflict" would pass
    for a message that reads as a conflict AND as an absence, which is precisely
    what an undefused Firestore 404-with-a-database-message is."""
    var pre = _consumer_says_precondition(msg)
    var nf = _consumer_says_not_found(msg)
    if pre != want_precondition:
        raise Error(
            ctx + ": the CONSUMER's precondition predicate says "
            + String(pre) + " but this error must read as "
            + String(want_precondition) + ". Message: " + msg
        )
    if nf != want_not_found:
        raise Error(
            ctx + ": the CONSUMER's not-found predicate says " + String(nf)
            + " but this error must read as " + String(want_not_found)
            + ". Message: " + msg
        )


def _assert_contains(hay: String, needle: String, ctx: String) raises:
    if hay.find(needle) < 0:
        raise Error(
            ctx + ": expected the text to contain '" + needle + "' but it was: "
            + hay
        )


def _assert_lacks(hay: String, needle: String, ctx: String) raises:
    if hay.find(needle) >= 0:
        raise Error(
            ctx + ": expected the text NOT to contain '" + needle
            + "' but it was: " + hay
        )


# =============================================================================
# §1 — Literal Google error envelopes. Every one is the shape the live service
#      returns; the two 404s differ ONLY in `error.message`, which is the whole
#      reason gate 8 exists.
# =============================================================================


def _body_doc_not_found(full_name: String) -> String:
    """A BatchGetDocuments answer for a document that does not exist: a
    `missing` result inside a 200."""
    return (
        String('[{"missing":"')
        + full_name
        + String('","readTime":"2026-10-01T12:00:00Z"}]')
    )


def _found(doc_json: String) -> String:
    """A BatchGetDocuments answer finding `doc_json`."""
    return (
        String('[{"found":')
        + doc_json
        + String(',"readTime":"2026-10-01T12:00:00Z"}]')
    )


def _body_database_absent() -> String:
    return String(
        '{"error":{"code":404,"message":"The database example-db does not exist'
        ' for project example-project. Please visit'
        ' https://console.cloud.google.com/datastore/setup?project=example-project'
        ' to add a Cloud Datastore or Cloud Firestore database.",'
        '"status":"NOT_FOUND"}}'
    )


def _body_already_exists(full_name: String) -> String:
    return (
        String('{"error":{"code":409,"message":"Document already exists: ')
        + full_name
        + String('","status":"ALREADY_EXISTS"}}')
    )


def _body_cas_lost() -> String:
    return String(
        '{"error":{"code":400,"message":"the stored version does not match the'
        ' required base version","status":"FAILED_PRECONDITION"}}'
    )


def _body_missing_index() -> String:
    return String(
        '{"error":{"code":400,"message":"The query requires an index. You can'
        ' create it here: https://console.firebase.google.com/project/'
        'example-project/firestore/indexes?create_composite=Ck1w",'
        '"status":"FAILED_PRECONDITION"}}'
    )


def _body_permission_denied() -> String:
    return String(
        '{"error":{"code":403,"message":"Missing or insufficient permissions.",'
        '"status":"PERMISSION_DENIED"}}'
    )


def _body_unavailable() -> String:
    return String(
        '{"error":{"code":503,"message":"The service is currently unavailable.",'
        '"status":"UNAVAILABLE"}}'
    )


def _body_internal() -> String:
    return String(
        '{"error":{"code":500,"message":"Internal error encountered.",'
        '"status":"INTERNAL"}}'
    )


# =============================================================================
# §2 — A stateful Firestore double at the HTTP boundary.
#
# It answers BatchGetDocuments, Commit (an update with either precondition, or
# none, and a delete) and RunQuery, with the real status codes and the real
# envelopes, reading each request with the generated messages. It is
# deliberately NOT a mock of this conformer's own calls: the request it parses
# is the request the generated client BUILT, so the round trip exercises the
# request builder, the document converter and the classifier — everything
# except the socket.
# =============================================================================


def _key_of(name: String) raises -> String:
    var marker = String("/documents/")
    var at = name.find(marker)
    if at < 0:
        raise Error("fake firestore: not a document name: " + name)
    return String(unsafe_from_utf8=name.as_bytes()[at + marker.byte_length() :])


struct _FsState(Movable, Deinitable):
    """The double's documents plus its per-method call counters. The counters
    are what let a gate assert a WRITE DID NOT HAPPEN, which no return value
    can."""

    var keys: List[String]
    var docs: List[Document]
    var n_get: Int
    var n_commit: Int
    var n_query: Int
    var clock: Int

    def __init__(out self):
        self.keys = List[String]()
        self.docs = List[Document]()
        self.n_get = 0
        self.n_commit = 0
        self.n_query = 0
        self.clock = 0

    def index_of(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1

    def tick(mut self) -> Timestamp:
        """The next update time: 2026-10-01T12:00:00Z plus a second per write."""
        self.clock += 1
        return Timestamp(Int64(1790856000 + self.clock), Int32(0))

    def n_writes(self) -> Int:
        return self.n_commit


struct _FakeFirestore(HttpExchange, Movable, Deinitable):
    """A stateful Firestore, shared by Arc so a test keeps an observation handle
    after moving one into the store."""

    var _s: ArcPointer[_FsState]

    def __init__(out self):
        self._s = ArcPointer[_FsState](_FsState())

    def handle(self) -> ArcPointer[_FsState]:
        return self._s.copy()

    def answer(
        mut self, method: String, target: String, body: String
    ) raises -> ExchangeAnswer:
        if method != "POST":
            raise Error("fake firestore: unhandled method " + method)
        if target.endswith(":batchGet"):
            return self._batch_get(body)
        if target.endswith(":commit"):
            return self._commit(body)
        if target.endswith(":runQuery"):
            return self._run_query(body)
        raise Error("fake firestore: unroutable target " + target)

    def _batch_get(mut self, body: String) raises -> ExchangeAnswer:
        self._s[].n_get += 1
        var req = decode_json[BatchGetDocumentsRequest](body)
        var out = String("[")
        for i in range(len(req.documents)):
            if i > 0:
                out += ","
            var idx = self._s[].index_of(_key_of(req.documents[i]))
            if idx < 0:
                out += String('{"missing":"') + req.documents[i] + '"}'
            else:
                out += String('{"found":') + encode_json(self._s[].docs[idx]) + "}"
        out += "]"
        return ExchangeAnswer(200, out^)

    def _commit(mut self, body: String) raises -> ExchangeAnswer:
        self._s[].n_commit += 1
        var req = decode_json[CommitRequest](body)
        if len(req.writes) != 1:
            raise Error("fake firestore: one write per commit")
        var w = req.writes[0].copy()
        if w._oneof0_case == 2:
            var dk = _key_of(w.delete.value())
            var di = self._s[].index_of(dk)
            if di < 0 and w.current_document:
                if w.current_document.value().exists.value():
                    return ExchangeAnswer(404, _body_doc_gone(w.delete.value()))
            if di >= 0:
                _ = self._s[].keys.pop(di)
                _ = self._s[].docs.pop(di)
            return ExchangeAnswer(200, String('{"writeResults":[{}]}'))
        var doc = w.update.value().copy()
        var key = _key_of(doc.name)
        var idx = self._s[].index_of(key)
        if w.current_document:
            var pre = w.current_document.value().copy()
            if pre._oneof0_case == 1 and not pre.exists.value() and idx >= 0:
                return ExchangeAnswer(409, _body_already_exists(doc.name))
            if pre._oneof0_case == 2:
                var want = pre.update_time.value()
                if idx < 0:
                    return ExchangeAnswer(404, _body_doc_gone(doc.name))
                var have = self._s[].docs[idx].update_time.value()
                if have.seconds != want.seconds or have.nanos != want.nanos:
                    return ExchangeAnswer(400, _body_cas_lost())
        var t = self._s[].tick()
        doc.update_time = t
        if idx < 0:
            doc.create_time = t
            self._s[].keys.append(key)
            self._s[].docs.append(doc^)
        else:
            doc.create_time = self._s[].docs[idx].create_time
            self._s[].docs[idx] = doc^
        var stamp = t.to_proto3_json()
        return ExchangeAnswer(
            200,
            String('{"writeResults":[{"updateTime":"') + stamp
            + String('"}],"commitTime":"') + stamp + String('"}'),
        )

    def _run_query(mut self, body: String) raises -> ExchangeAnswer:
        self._s[].n_query += 1
        var req = decode_json[RunQueryRequest](body)
        var coll = req.structured_query.value().from_[0].collection_id.copy()
        var head = coll + String("/")
        var out = String("[")
        var first = True
        for i in range(len(self._s[].keys)):
            var k = self._s[].keys[i].copy()
            if not k.startswith(head):
                continue
            # Direct children only: the remainder must carry no further `/`.
            var rest = String(unsafe_from_utf8=k.as_bytes()[head.byte_length() :])
            if String("/") in rest:
                continue
            if not first:
                out += String(",")
            first = False
            out += String('{"document":')
            out += encode_json(self._s[].docs[i])
            out += String(',"readTime":"2026-10-01T12:00:00Z"}')
        if first:
            # No result: the stream still says when it read.
            out += String('{"readTime":"2026-10-01T12:00:00Z"}')
        out += String("]")
        return ExchangeAnswer(200, out^)


def _body_doc_gone(full_name: String) -> String:
    """A Commit whose updateTime precondition names a document that is gone."""
    return (
        String('{"error":{"code":404,"message":"No document to update: ')
        + full_name
        + String('","status":"NOT_FOUND"}}')
    )


# =============================================================================
# §3 — THE REFUSE-EVERYTHING CONTROL (gate 16): a connector that refuses every
#      dial, so no request is ever answered.
# =============================================================================

comptime _Fake = ExchangeConnector[_FakeFirestore]


# =============================================================================
# §4 — Builders.
# =============================================================================


def _fake_store(var t: _FakeFirestore) -> FirestoreConditionalStore[_Fake]:
    var c = FirestoreClient[_Fake](
        _Fake(ArcPointer[_FakeFirestore](t^)),
        String(_PROJECT),
        String(_DATABASE),
        String("test-bearer"),
    )
    return FirestoreConditionalStore[_Fake](c^, String(_DATABASE))


def _fake_consumer(
    var t: _FakeFirestore,
) -> _LastWriterWinsKv[FirestoreConditionalStore[_Fake]]:
    return _LastWriterWinsKv[FirestoreConditionalStore[_Fake]](_fake_store(t^))


def _scripted_store(
    mut t: ScriptedFirestore,
) raises -> FirestoreConditionalStore[ScriptedConnector]:
    var c = FirestoreClient[ScriptedConnector](
        t.take_connector(), String(_PROJECT), String(_DATABASE), String("test-bearer")
    )
    return FirestoreConditionalStore[ScriptedConnector](c^, String(_DATABASE))


def _refusing_consumer() -> _LastWriterWinsKv[FirestoreConditionalStore[_Fake]]:
    var c = FirestoreClient[_Fake](
        _Fake.refuse_every_dial(ArcPointer[_FakeFirestore](_FakeFirestore())),
        String(_PROJECT),
        String(_DATABASE),
        String("test-bearer"),
    )
    return _LastWriterWinsKv[FirestoreConditionalStore[_Fake]](
        FirestoreConditionalStore[_Fake](c^, String(_DATABASE))
    )


def _b(s: String) -> List[UInt8]:
    var raw = s.as_bytes()
    var out = List[UInt8](capacity=len(raw))
    for i in range(len(raw)):
        out.append(raw[i])
    return out^


def _s(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


# =============================================================================
# §5 — A NEUTRAL GENERIC CONSUMER: `_LastWriterWinsKv[Store]`.
#
# What the gates need is not a particular product but the CALL SEQUENCES a
# consumer generic over `ConditionalWriteStore` makes, decided by the §0
# predicates. This is the smallest such consumer, written against the trait
# only, so it runs unchanged on any conformer:
#
#   publish            head -> absent ? conditional_put(If-None-Match: *)
#                                     : compare_and_swap(head().etag)
#                      a 412 (either arm) is a lost race: RETRY ONCE, then raise.
#   publish_if_changed read first; write only when the stored value differs.
#   read               get; a NOT_FOUND is an ABSENT answer, anything else RAISES.
#   remove             head-then-delete; True iff something was there.
#   list_names         list_with_delimiter("item/"), prefix stripped.
#
# Every `except` arm reads the error ONLY through `_consumer_says_*` — the point
# of the file. A conformer whose words lie is caught here exactly as it would
# be by a real caller.
# =============================================================================

comptime _ITEM_PREFIX: StaticString = "item"


@fieldwise_init
struct _Lookup(Copyable, Movable):
    """One read: the key consulted, whether it was present, and the value."""

    var found: Bool
    var value: String
    var key: String


struct _LastWriterWinsKv[Store: ConditionalWriteStore](Movable):
    """`item/<name>` -> value bytes, last writer wins, over ONE moved-in store."""

    var _store: Self.Store

    def __init__(out self, var store: Self.Store):
        self._store = store^

    def into_store(deinit self) -> Self.Store:
        return self._store^

    def key_of(self, name: String) -> String:
        return String(_ITEM_PREFIX) + String("/") + name

    def publish(mut self, name: String, value: String) raises:
        var path = Path.parse(self.key_of(name))
        var bytes = _b(value)
        if self._try_once(path, bytes):
            return
        if self._try_once(path, bytes):
            return
        raise Error(
            "last-writer-wins: persistent CAS contention writing '" + name
            + "' (412 twice) — retry"
        )

    def publish_if_changed(mut self, name: String, value: String) raises -> Bool:
        var cur = self.read(name)
        if cur.found and cur.value == value:
            return False
        self.publish(name, value)
        return True

    def read(self, name: String) raises -> _Lookup:
        var key = self.key_of(name)
        try:
            var bytes = self._store.get(Path.parse(key))
            return _Lookup(True, _s(bytes), key)
        except e:
            if _consumer_says_not_found(String(e)):
                return _Lookup(False, String(""), key)
            raise e^

    def remove(mut self, name: String) raises -> Bool:
        var path = Path.parse(self.key_of(name))
        try:
            _ = self._store.head(path)
        except e:
            if _consumer_says_not_found(String(e)):
                return False
            raise e^
        try:
            self._store.delete(path)
        except e:
            if _consumer_says_not_found(String(e)):
                return False
            raise e^
        return True

    def list_names(self) raises -> List[String]:
        var head = String(_ITEM_PREFIX) + String("/")
        var res = self._store.list_with_delimiter(Path.parse(head))
        var out = List[String]()
        for i in range(len(res.objects)):
            var loc = String(res.objects[i].location)
            if not loc.startswith(head):
                raise Error("last-writer-wins: listed key outside prefix: " + loc)
            out.append(String(unsafe_from_utf8=loc.as_bytes()[head.byte_length() :]))
        return out^

    def _try_once(self, path: Path, bytes: List[UInt8]) raises -> Bool:
        """One head + conditional-write cycle. True on commit, False on a 412."""
        var cur_etag = Optional[String]()
        try:
            var meta = self._store.head(path)
            cur_etag = Optional[String](meta.etag)
        except e:
            if not _consumer_says_not_found(String(e)):
                raise e^
        if not cur_etag:
            try:
                _ = self._store.conditional_put(
                    path, bytes, WritePrecondition.if_none_match_star()
                )
                return True
            except e:
                if _consumer_says_precondition(String(e)):
                    return False
                raise e^
        try:
            _ = self._store.compare_and_swap(path, bytes, cur_etag.value())
            return True
        except e:
            if _consumer_says_precondition(String(e)):
                return False
            raise e^



# =============================================================================
# GATE 1 — the key mapping.
# =============================================================================


def test_gate1_an_object_key_is_a_firestore_document_path() raises:
    var two = split_document_path(String("item/api-svc"))
    assert_equal(String(two[0]), String("item"))
    assert_equal(String(two[1]), String("api-svc"))

    # A dotted, escaped id (`<platform>.<escaped principal>`) is
    # `[A-Za-z0-9.-_]` by construction — every byte of it is a legal Firestore
    # id, and it can never begin `__` when its first token is `[a-z0-9-]`. So
    # such a keyspace needs NO escaping here.
    var idk = String("owner/gcp.worker_40example-project.iam.gserviceaccount.com")
    var ident = split_document_path(idk)
    assert_equal(String(ident[0]), String("owner"))
    assert_equal(
        String(ident[1]),
        String("gcp.worker_40example-project.iam.gserviceaccount.com"),
    )

    # A 4-segment key is an ordinary sub-collection document.
    var deep = split_document_path(String("a/b/c/d"))
    assert_equal(String(deep[0]), String("a/b/c"))
    assert_equal(String(deep[1]), String("d"))

    # ⛔ An ODD segment count names a COLLECTION. There is no document at it, so
    # it is a refusal — never a silently-synthesised segment.
    var odd_raised = False
    try:
        _ = split_document_path(String("item"))
    except e:
        odd_raised = True
        _assert_contains(String(e), String("EVEN"), "one-segment key")
        _assert_reads_as(String(e), False, False, "one-segment key")
    assert_true(odd_raised)

    var odd3 = False
    try:
        _ = split_document_path(String("a/b/c"))
    except:
        odd3 = True
    assert_true(odd3)

    # Firestore's reserved id form.
    var reserved = False
    try:
        _ = split_document_path(String("item/__name__"))
    except e:
        reserved = True
        _assert_contains(String(e), String("RESERVED"), "reserved id")
    assert_true(reserved)

    # The 1500-byte id cap, refused HERE rather than as a 400 from Google.
    var long_name = String("")
    for _ in range(1501):
        long_name += String("x")
    var too_long = False
    try:
        _ = split_document_path(String("item/") + long_name)
    except e:
        too_long = True
        _assert_contains(String(e), String("1500"), "over-long id")
    assert_true(too_long)

    # The key comes back off the SERVER's own resource name.
    assert_equal(
        key_from_document_name(
            String(
                "projects/example-project/databases/example-db/documents/item/api"
            )
        ),
        String("item/api"),
    )


# =============================================================================
# GATE 2 — DISCOVERY, end to end: last-writer-wins.
# =============================================================================


def test_gate2_discovery_is_last_writer_wins_end_to_end() raises:
    var fake = _FakeFirestore()
    var obs = fake.handle()
    var d = _fake_consumer(fake^)

    d.publish(String("api-svc"), String("https://api-1.run.app"))
    var r1 = d.read(String("api-svc"))
    assert_true(r1.found)
    assert_equal(r1.value, String("https://api-1.run.app"))
    assert_equal(r1.key, String("item/api-svc"))

    # A REPUBLISH overwrites: the newest value wins. This is the head+CAS path,
    # not a create — the object already exists.
    d.publish(String("api-svc"), String("https://api-2.run.app"))
    var r2 = d.read(String("api-svc"))
    assert_equal(r2.value, String("https://api-2.run.app"))

    # `publish_if_changed` is a PURE READ when nothing moved. Asserted
    # on the double's WRITE COUNTER, because the return value would be equally
    # False for a store that wrote and then lied about it.
    var writes_before = obs[].n_writes()
    var wrote = d.publish_if_changed(
        String("api-svc"), String("https://api-2.run.app")
    )
    assert_false(wrote)
    assert_equal(obs[].n_writes(), writes_before)

    var wrote2 = d.publish_if_changed(
        String("api-svc"), String("https://api-3.run.app")
    )
    assert_true(wrote2)
    assert_true(obs[].n_writes() > writes_before)
    assert_equal(
        d.read(String("api-svc")).value,
        String("https://api-3.run.app"),
    )

    # A never-written name is an ABSENT answer read from the store — never a
    # raise.
    var miss = d.read(String("never-written"))
    assert_false(miss.found)
    assert_equal(miss.key, String("item/never-written"))


# =============================================================================
# GATE 3 — CREATE-OR-CONFLICT on the stateful fake: a create precondition that
# loses leaves the incumbent value in place.
# =============================================================================


def test_gate3_a_second_create_is_refused_and_the_incumbent_stays() raises:
    var fake = _FakeFirestore()
    var obs = fake.handle()
    var store = _fake_store(fake^)
    var key = Path.parse(String("owner/gcp.worker"))

    _ = store.conditional_put(
        key, _b(String("worker")), WritePrecondition.if_none_match_star()
    )
    assert_equal(_s(store.get(key)), String("worker"))

    # A SECOND create of the same key is REFUSED: the conflict reads as a
    # precondition, never as an absence (which a caller would answer by
    # writing again).
    var writes_before = obs[].n_writes()
    var refused = False
    try:
        _ = store.conditional_put(
            key, _b(String("api-server")), WritePrecondition.if_none_match_star()
        )
    except e:
        refused = True
        _assert_contains(String(e), String("StoreError[PRECONDITION]"), "2nd create")
        _assert_reads_as(String(e), True, False, "2nd create")
    assert_true(refused)

    # AND THE VALUE IS UNCHANGED. Asserted on the store, not on the raise: a
    # refusal that had already written would raise identically.
    assert_equal(_s(store.get(key)), String("worker"))
    assert_equal(obs[].n_writes(), writes_before + 1)  # the rejected commit only


# =============================================================================
# GATE 5 — ★ THE 412 (create precondition lost).
# =============================================================================


def test_gate5_a_create_conflict_is_StoreError_PRECONDITION_412() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        409,
        _body_already_exists(
            String(
                "projects/example-project/databases/example-db/documents/owner/"
                "gcp.a"
            )
        ),
    )
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.conditional_put(
            Path.parse(String("owner/gcp.a")),
            _b(String("worker")),
            WritePrecondition.if_none_match_star(),
        )
    except e:
        raised = True
        var m = String(e)
        _assert_contains(m, String("StoreError[PRECONDITION]"), "create 412")
        _assert_contains(m, String("status=412"), "create 412")
        # ★ THE ASSERTION THE GATE IS NAMED FOR: the CONSUMER reads it as a
        # conflict and NOT as an absence. A message that is both turns a
        # create-or-conflict caller's "someone else owns it" into "it is gone",
        # which that caller answers by writing again.
        _assert_reads_as(m, True, False, "create 412")
    assert_true(raised)


# =============================================================================
# GATE 6 — ★ THE OTHER 412 (updateTime CAS lost), and the retry it drives.
# =============================================================================


def test_gate6_a_cas_conflict_is_StoreError_PRECONDITION_412() raises:
    var t = ScriptedFirestore()
    t.queue_response(400, _body_cas_lost())
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.compare_and_swap(
            Path.parse(String("item/api-svc")),
            _b(String("https://x")),
            String("2026-10-01T12:00:01.000000Z"),
        )
    except e:
        raised = True
        var m = String(e)
        _assert_contains(m, String("StoreError[PRECONDITION]"), "cas 412")
        _assert_reads_as(m, True, False, "cas 412")
    assert_true(raised)


def test_gate6b_a_concurrent_publisher_is_a_RETRY_not_a_fatal_write() raises:
    """The behavioural half of gate 6: a 412 that is not re-emitted in the consumer's vocabulary
    turns an ordinary concurrent-writer retry into a fatal write failure.

    Scripted, in `publish`'s exact call order:
      batchGet 200 -> the object exists at version T1   (head)
      commit   400 -> FAILED_PRECONDITION               (the CAS lost the race)
      batchGet 200 -> version T2                        (the retry's head)
      commit   200 -> committed                         (the retry wins)"""
    var t = ScriptedFirestore()
    var name = String(
        "projects/example-project/databases/example-db/documents/item/api-svc"
    )
    t.queue_response(
        200,
        _found(
            String('{"name":"') + name + String(
                '","fields":{"value":{"stringValue":"https://old"}},'
                '"updateTime":"2026-10-01T12:00:01.000000Z"}'
            )
        ),
    )
    t.queue_response(400, _body_cas_lost())
    t.queue_response(
        200,
        _found(
            String('{"name":"') + name + String(
                '","fields":{"value":{"stringValue":"https://raced"}},'
                '"updateTime":"2026-10-01T12:00:02.000000Z"}'
            )
        ),
    )
    t.queue_response(
        200,
        String(
            '{"writeResults":[{"updateTime":"2026-10-01T12:00:03.000000Z"}],'
            '"commitTime":"2026-10-01T12:00:03.000000Z"}'
        ),
    )
    var d = _LastWriterWinsKv[
        FirestoreConditionalStore[ScriptedConnector]
    ](_scripted_store(t))
    # No raise: the 412 was READ AS A 412, so the retry ran and committed.
    d.publish(String("api-svc"), String("https://new"))


# =============================================================================
# GATE 7 — an absent DOCUMENT.
# =============================================================================


def test_gate7_an_absent_document_is_StoreError_NOT_FOUND_404() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        _body_doc_not_found(
            String(
                "projects/example-project/databases/example-db/documents/item/x"
            )
        ),
    )
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.get(Path.parse(String("item/x")))
    except e:
        raised = True
        var m = String(e)
        _assert_contains(m, String("StoreError[NOT_FOUND]"), "absent doc")
        _assert_contains(m, String("status=404"), "absent doc")
        _assert_reads_as(m, False, True, "absent doc")
    assert_true(raised)

    # And through a generic reader: `found=False`, not a raise.
    var t2 = ScriptedFirestore()
    t2.queue_response(
        200,
        _body_doc_not_found(
            String(
                "projects/example-project/databases/example-db/documents/item/x"
            )
        ),
    )
    var d = _LastWriterWinsKv[
        FirestoreConditionalStore[ScriptedConnector]
    ](_scripted_store(t2))
    var r = d.read(String("x"))
    assert_false(r.found)
    assert_equal(r.key, String("item/x"))


# =============================================================================
# GATE 8 — ★★ AN ABSENT DATABASE IS NOT AN ABSENT OBJECT.
# =============================================================================


def test_gate8_an_absent_DATABASE_never_reads_as_an_absent_object() raises:
    """Firestore answers a GET of an absent DATABASE and of an absent DOCUMENT
    with the SAME HTTP 404 and the SAME `NOT_FOUND` status token; only
    `error.message` differs. The client reads with BatchGetDocuments, where
    an absent document is a `missing` result, so NOT_FOUND is the database.
    Read as an absent object instead, every lookup answers "absent" for every
    key in the world, and a broken deploy looks like an empty store."""
    var t = ScriptedFirestore()
    t.queue_response(404, _body_database_absent())
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.get(Path.parse(String("item/api-svc")))
    except e:
        raised = True
        var m = String(e)
        # NOT `NOT_FOUND`. A permanent configuration fault.
        _assert_contains(m, String("StoreError[MALFORMED]"), "absent database")
        _assert_lacks(m, String("StoreError[NOT_FOUND]"), "absent database")
        # ★ THE ASSERTION THE GATE IS NAMED FOR.
        _assert_reads_as(m, False, False, "absent database")
        # The line names the store's own database and the method, status and
        # code; no byte of Google's message (it names projects and databases).
        _assert_contains(m, String("firestore://example-db/"), "absent database detail")
        _assert_contains(m, String("NOT_FOUND (code 5)"), "absent database detail")
        _assert_lacks(m, String("does not exist"), "absent database detail")
        _assert_lacks(m, String("example-project"), "absent database detail")
    assert_true(raised)

    # And through a generic reader: `read` RE-RAISES. It must not manufacture an
    # `absent` result out of a database that is not there.
    var t2 = ScriptedFirestore()
    t2.queue_response(404, _body_database_absent())
    var d = _LastWriterWinsKv[
        FirestoreConditionalStore[ScriptedConnector]
    ](_scripted_store(t2))
    var propagated = False
    try:
        var r = d.read(String("api-svc"))
        raise Error(
            "read reported found=" + String(r.found)
            + " for a database that DOES NOT EXIST — the store would report"
            " an empty world and look healthy doing it"
        )
    except e:
        propagated = True
        _assert_contains(
            String(e), String("StoreError[MALFORMED]"), "propagated"
        )
    assert_true(propagated)


# =============================================================================
# GATE 9 — ★★ A MISSING COMPOSITE INDEX IS NOT A LOST CAS.
# =============================================================================


def test_gate9_a_missing_index_never_reads_as_a_lost_cas() raises:
    """The sentinel's own NAME carries the token: `FirestoreDatabasePrecondition`.
    Read as a CAS conflict it is retried forever against a fault only an
    operator can clear; read as an absence it is worse. It is neither."""
    var t = ScriptedFirestore()
    t.queue_response(400, _body_missing_index())
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.list_with_delimiter(Path.parse(String("item/")))
    except e:
        raised = True
        var m = String(e)
        _assert_contains(m, String("StoreError[MALFORMED]"), "missing index")
        _assert_reads_as(m, False, False, "missing index")
        # The line says it was the query and the code; Google's message (the
        # index and a console URL, both naming the project) is not kept.
        _assert_contains(m, String("run_query"), "missing index detail")
        _assert_contains(m, String("FAILED_PRECONDITION (code 9)"), "missing index detail")
        _assert_lacks(m, String("create_composite"), "missing index detail")
    assert_true(raised)

    # Through a READ: a database-state precondition must not be laundered into
    # "that key is absent".
    var t2 = ScriptedFirestore()
    t2.queue_response(400, _body_missing_index())
    var d = _LastWriterWinsKv[
        FirestoreConditionalStore[ScriptedConnector]
    ](_scripted_store(t2))
    var propagated = False
    try:
        var r = d.read(String("api-svc"))
        raise Error(
            "read reported found=" + String(r.found)
            + " for a DATABASE-STATE precondition (a missing index)"
        )
    except e:
        propagated = True
        _assert_reads_as(String(e), False, False, "missing index via reader")
    assert_true(propagated)


# =============================================================================
# GATE 10 — the rest of the taxonomy.
# =============================================================================


def test_gate10_the_remaining_arms_are_neither_family() raises:
    var cases_status = List[Int]()
    var cases_body = List[String]()
    var cases_kind = List[String]()
    cases_status.append(403)
    cases_body.append(_body_permission_denied())
    cases_kind.append(String(STORE_KIND_PERMISSION_DENIED))
    cases_status.append(503)
    cases_body.append(_body_unavailable())
    cases_kind.append(String(STORE_KIND_THROTTLED))
    cases_status.append(500)
    cases_body.append(_body_internal())
    cases_kind.append(String(STORE_KIND_TRANSPORT))

    for i in range(len(cases_status)):
        var t = ScriptedFirestore()
        t.queue_response(cases_status[i], String(cases_body[i]))
        var store = _scripted_store(t)
        var raised = False
        try:
            _ = store.get(Path.parse(String("item/api-svc")))
        except e:
            raised = True
            var m = String(e)
            _assert_contains(
                m,
                String("StoreError[") + cases_kind[i] + String("]"),
                String("http ") + String(cases_status[i]),
            )
            # NEITHER family: the consumer must RE-RAISE, never swallow one of
            # these as a benign outcome.
            _assert_reads_as(
                m, False, False, String("http ") + String(cases_status[i])
            )
        assert_true(raised)

    # The HTTP status is read from the generated client's own `: HTTP <n>,`
    # frame, not from the first run of digits — a resource is full of digits.
    assert_equal(
        firestore_http_status(
            String(
                "FirestoreClient.get_document: item/api-404-500 (POST"
                " BatchGetDocuments: HTTP 503, UNAVAILABLE (code 14), body 0 bytes)"
            )
        ),
        503,
    )
    # A raise carrying no HTTP frame at all (a transport dial failure) is
    # TRANSPORT, matching the GCS mapper's no-recognizable-prefix arm.
    assert_equal(firestore_http_status(String("connection reset by peer")), -1)


# =============================================================================
# GATE 11 — ★★ THE DEFUSER.
# =============================================================================


def test_gate11_a_classifier_token_in_the_payload_cannot_change_the_class() raises:
    # (a) A KEY LITERALLY NAMED `404`. The resource is interpolated into
    #     every error about it, so an undefused mapper turns every TRANSPORT
    #     failure on this key into an absent-object verdict.
    var t = ScriptedFirestore()
    t.queue_response(500, _body_internal())
    var store = _scripted_store(t)
    var raised = False
    try:
        _ = store.get(Path.parse(String("item/404")))
    except e:
        raised = True
        var m = String(e)
        _assert_contains(m, String("StoreError[TRANSPORT]"), "key named 404")
        _assert_reads_as(m, False, False, "key named 404")
        # Defused, not deleted — an operator must still be able to read which
        # key the failure was about.
        _assert_contains(m, String("4[0]4"), "key named 404")
    assert_true(raised)

    # (b) A GOOGLE MESSAGE CONTAINING THE WORD `precondition` ON A 403. Read as
    #     a CAS conflict, `_try_last_writer_wins` swallows it and retries — a
    #     permissions fault reported as contention. The generated client keeps
    #     no byte of the message, so the word never reaches the error at all.
    var t2 = ScriptedFirestore()
    t2.queue_response(
        403,
        String(
            '{"error":{"code":403,"message":"Some preconditions were not met'
            ' for this caller.","status":"PERMISSION_DENIED"}}'
        ),
    )
    var store2 = _scripted_store(t2)
    var raised2 = False
    try:
        _ = store2.get(Path.parse(String("item/api-svc")))
    except e:
        raised2 = True
        var m2 = String(e)
        _assert_contains(
            m2, String("StoreError[PERMISSION_DENIED]"), "403 saying precondition"
        )
        _assert_reads_as(m2, False, False, "403 saying precondition")
        _assert_lacks(m2, String("preconditions were not met"), "403 message")
    assert_true(raised2)

    # (c) The defuser is legible and total.
    assert_equal(
        defuse_classifier_tokens(String("HTTP 404 and 412 and Precondition")),
        String("HTTP 4[0]4 and 4[1]2 and P[r]econdition"),
    )
    assert_false(
        _consumer_says_not_found(
            defuse_classifier_tokens(String("NotFound not_found NoSuchKey 404"))
        )
    )
    assert_false(
        _consumer_says_precondition(
            defuse_classifier_tokens(
                String("PreconditionFailed precondition 412")
            )
        )
    )
    # A string with NO token is returned unchanged — the defuser must not be a
    # general mangler.
    assert_equal(
        defuse_classifier_tokens(String("https://api.run.app/v1/services")),
        String("https://api.run.app/v1/services"),
    )


# =============================================================================
# GATE 12 — ★ THE CAS HANDLE IS `head().etag`.
# =============================================================================


def test_gate12_head_returns_the_cas_handle_in_etag_not_only_version() raises:
    """A last-writer-wins publish (`_LastWriterWinsKv._try_once`) reads
    `meta.etag` and feeds it straight to `compare_and_swap`. A conformer that puts the CAS token only in
    `version` makes every last-writer-wins publish CAS against `""` — the leg-C
    `_HEAD`-advance defect `GcsGrpcConditionalStore` documents."""
    var fake = _FakeFirestore()
    var store = _fake_store(fake^)
    var p = Path.parse(String("item/api-svc"))
    var created = store.conditional_put(
        p, _b(String("https://a")), WritePrecondition.if_none_match_star()
    )
    assert_true(created.etag.byte_length() > 0)
    assert_equal(created.etag, created.version)

    var meta = store.head(p)
    assert_true(meta.etag.byte_length() > 0)
    assert_equal(meta.etag, meta.version)
    assert_equal(meta.etag, created.etag)
    assert_equal(meta.location, String("item/api-svc"))
    assert_equal(meta.size, Int64(9))

    # THE HANDLE ROUND-TRIPS: head -> compare_and_swap, exactly as `_try_once`
    # does it.
    var swapped = store.compare_and_swap(p, _b(String("https://b")), meta.etag)
    assert_true(swapped.etag != meta.etag)
    assert_equal(_s(store.get(p)), String("https://b"))

    # And a STALE handle is refused as a 412.
    var stale = False
    try:
        _ = store.compare_and_swap(p, _b(String("https://c")), meta.etag)
    except e:
        stale = True
        _assert_reads_as(String(e), True, False, "stale handle")
    assert_true(stale)

    # An EMPTY handle is refused LOCALLY, naming the cause — never sent as an
    # empty precondition that comes back as an INVALID_ARGUMENT reading like a
    # lost race.
    var empty = False
    try:
        _ = store.compare_and_swap(p, _b(String("https://d")), String(""))
    except e:
        empty = True
        _assert_contains(String(e), String("EMPTY version handle"), "empty etag")
        _assert_reads_as(String(e), False, False, "empty etag")
    assert_true(empty)


# =============================================================================
# GATE 13 — DELETE.
# =============================================================================


def test_gate13_delete_is_idempotent_but_not_on_an_absent_database() raises:
    var fake = _FakeFirestore()
    var store = _fake_store(fake^)
    var p = Path.parse(String("item/api-svc"))
    _ = store.put(p, _b(String("https://a")))
    store.delete(p)
    # Idempotent: a second reap pass is not an error.
    store.delete(p)

    # A generic head-then-delete reports present/absent.
    var fake2 = _FakeFirestore()
    var d = _fake_consumer(fake2^)
    d.publish(String("gone"), String("https://gone"))
    assert_true(d.remove(String("gone")))
    assert_false(d.remove(String("gone")))

    # ⛔ AN ABSENT DATABASE IS ALSO AN HTTP 404. The swallow is on the TYPED
    # prefix, tested BEFORE mapping, so it cannot reach this arm — otherwise
    # `delete` returns SUCCESS against a database that does not exist.
    var t = ScriptedFirestore()
    t.queue_response(404, _body_database_absent())
    var store3 = _scripted_store(t)
    var raised = False
    try:
        store3.delete(Path.parse(String("item/api-svc")))
    except e:
        raised = True
        _assert_contains(
            String(e), String("StoreError[MALFORMED]"), "delete on no database"
        )
    assert_true(raised)


# =============================================================================
# GATE 14 — LIST.
# =============================================================================


def test_gate14_list_returns_keys_a_caller_can_feed_back_to_get() raises:
    var fake = _FakeFirestore()
    var d = _fake_consumer(fake^)
    d.publish(String("api-svc"), String("https://api"))
    d.publish(String("worker"), String("https://worker"))

    var names = d.list_names()
    assert_equal(len(names), 2)

    # A document in a SIBLING collection must not leak into the `item/`
    # listing: without it the 2-count below holds whether or not the listing
    # is scoped to its collection.
    var store = d^.into_store()
    _ = store.conditional_put(
        Path.parse(String("owner/gcp.worker")),
        _b(String("worker")),
        WritePrecondition.if_none_match_star(),
    )
    var ids = store.list_with_delimiter(Path.parse(String("owner/")))
    assert_equal(len(ids.objects), 1)
    assert_equal(String(ids.objects[0].location), String("owner/gcp.worker"))

    # The store-level listing hands back FULL object keys, and each one round
    # trips through `get`.
    var res = store.list_with_delimiter(Path.parse(String("item/")))
    assert_equal(len(res.objects), 2)
    assert_equal(len(res.common_prefixes), 0)
    for i in range(len(res.objects)):
        var loc = String(res.objects[i].location)
        _assert_contains(loc, String("item/"), "listed key")
        var body = store.get(Path.parse(loc))
        assert_true(len(body) > 0)
        assert_true(res.objects[i].etag.byte_length() > 0)

    # ⛔ THE ROOT PREFIX IS A REFUSAL, NOT AN EMPTY LIST. Firestore's document
    # API has no list-all-collections verb, and an empty answer is the worst
    # possible one for a reap pass.
    var root_refused = False
    try:
        _ = store.list_with_delimiter(Path.parse(String("")))
    except e:
        root_refused = True
        _assert_contains(String(e), String("ROOT prefix"), "root listing")
        _assert_reads_as(String(e), False, False, "root listing")
    assert_true(root_refused)

    var nested_refused = False
    try:
        _ = store.list_with_delimiter(Path.parse(String("a/b/c/")))
    except e:
        nested_refused = True
        _assert_contains(String(e), String("NESTED"), "nested listing")
    assert_true(nested_refused)

    # ⚠ A FOREIGN DOCUMENT IN THE COLLECTION IS LISTED WITH size=-1, NOT
    # refused. A listing that aborts on one document nobody here wrote cannot
    # enumerate at all — and `list_names` reads only `location`, so raising
    # would break a verb over a field it never looks at.
    var t3 = ScriptedFirestore()
    t3.queue_response(
        200,
        String(
            '[{"document":{"name":"projects/example-project/databases/example-db/'
            'documents/item/mine","fields":{"value":{"stringValue":'
            '"https://mine"}},"updateTime":"2026-10-01T12:00:01.000000Z"}},'
            '{"document":{"name":"projects/example-project/databases/example-db/'
            'documents/item/foreign","fields":{"url":{"stringValue":'
            '"https://x"}},"updateTime":"2026-10-01T12:00:02.000000Z"}}]'
        ),
    )
    var store3 = _scripted_store(t3)
    var listed = store3.list_with_delimiter(Path.parse(String("item/")))
    assert_equal(len(listed.objects), 2)
    var saw_unknown = False
    for i in range(len(listed.objects)):
        if listed.objects[i].location == String("item/foreign"):
            assert_equal(listed.objects[i].size, Int64(-1))
            saw_unknown = True
        if listed.objects[i].location == String("item/mine"):
            assert_equal(listed.objects[i].size, Int64(12))
    assert_true(saw_unknown)

    assert_equal(collection_from_prefix(Path.parse(String("item/"))),
                 String("item"))
    assert_equal(collection_from_prefix(Path.parse(String("owner/"))),
                 String("owner"))


# =============================================================================
# GATE 15 — THE VALUE.
# =============================================================================


def test_gate15_the_body_round_trips_and_refuses_what_it_cannot_hold() raises:
    var fake = _FakeFirestore()
    var store = _fake_store(fake^)

    # Round trip, including the bytes that make a JSON string interesting.
    var payload = String("https://a.run.app/x?q=\"1\"&p=a\\b")
    var p = Path.parse(String("item/api-svc"))
    _ = store.put(p, _b(payload))
    assert_equal(_s(store.get(p)), payload)

    # An EMPTY body is a legitimate stored value, and `head` reports size 0.
    var p2 = Path.parse(String("item/empty"))
    _ = store.put(p2, List[UInt8]())
    assert_equal(len(store.get(p2)), 0)
    assert_equal(store.head(p2).size, Int64(0))

    # `get_range` is a slice of the whole body, and a short read RAISES.
    assert_equal(_s(store.get_range(p, Int64(0), Int64(5))), String("https"))
    var short = False
    try:
        _ = store.get_range(p, Int64(0), Int64(10_000))
    except e:
        short = True
        _assert_contains(String(e), String("short read"), "get_range")
    assert_true(short)

    # ⛔ A NON-ASCII BODY IS A REFUSAL. This conformer is text-valued (the
    # general answer is `bytesValue`, which needs a base64 dep this package's
    # closure does not carry) and a silent mangling is not an option.
    var binary = List[UInt8]()
    binary.append(UInt8(0xC3))
    binary.append(UInt8(0xA9))
    var refused = False
    try:
        _ = store.put(Path.parse(String("item/binary")), binary)
    except e:
        refused = True
        _assert_contains(String(e), String("printable ASCII"), "binary body")
        _assert_contains(String(e), String("bytesValue"), "binary body")
        _assert_reads_as(String(e), False, False, "binary body")
    assert_true(refused)
    assert_equal(
        bytes_to_document_text(_b(String("ok")), String("k")), String("ok")
    )
    assert_equal(_s(document_text_to_bytes(String("ok"))), String("ok"))

    # ⛔ A DOCUMENT WITH NO `value` FIELD IS A REFUSAL, not an empty body. An
    # empty body is a legitimate value, so defaulting would make a foreign
    # document read as a successfully-stored empty object.
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        _found(
            String(
                '{"name":"projects/example-project/databases/example-db/documents/'
                'item/foreign","fields":{"url":{"stringValue":"https://x"}},'
                '"updateTime":"2026-10-01T12:00:01.000000Z"}'
            )
        ),
    )
    var store2 = _scripted_store(t)
    var foreign = False
    try:
        _ = store2.get(Path.parse(String("item/foreign")))
    except e:
        foreign = True
        _assert_contains(String(e), String("carries no 'value' field"), "foreign")
    assert_true(foreign)


# =============================================================================
# GATE 16 — ⛔ THE REFUSE-EVERYTHING CONTROL.
# =============================================================================


def _must_raise(did_raise: Bool, what: String) raises:
    if not did_raise:
        raise Error(
            "REFUSE-EVERYTHING CONTROL: '" + what + "' SUCCEEDED against a"
            " store whose transport answers nothing. That gate is asserting"
            " something other than what it claims."
        )


def test_gate16_CONTROL_every_positive_gate_reds_on_refuse_everything() raises:
    """A store that raises on every call, driven through every positive gate.

    ⛔ THE SECOND ASSERTION IN EACH BLOCK IS THE POINT, NOT THE FIRST. It is not
    enough that a lookup fails — it must fail LOUDLY. A dead transport reported
    as `found=false` is gate 8's catastrophe with a different cause: the
    store would answer "that key is absent" for every key,
    forever, while looking healthy."""
    var d = _refusing_consumer()

    var pub = False
    try:
        d.publish(String("api-svc"), String("https://a"))
    except:
        pub = True
    _must_raise(pub, "publish")

    var res = False
    try:
        var r = d.read(String("api-svc"))
        # ★ NOT AN ABSENT RESULT. This is the arm that matters.
        raise Error(
            "read returned found=" + String(r.found)
            + " from a store that answers NOTHING"
        )
    except:
        res = True
    _must_raise(res, "read")

    var lst = False
    try:
        _ = d.list_names()
    except:
        lst = True
    _must_raise(lst, "list_names")

    var wd = False
    try:
        _ = d.remove(String("api-svc"))
    except:
        wd = True
    _must_raise(wd, "remove")

    var store = d^.into_store()
    var hd = False
    try:
        _ = store.head(Path.parse(String("item/api-svc")))
    except e:
        hd = True
        # A dead transport carries no HTTP frame, so it is TRANSPORT — and it is
        # read as NEITHER family, which is what makes the raise reach the caller.
        _assert_contains(String(e), String("StoreError[TRANSPORT]"), "control")
        _assert_reads_as(String(e), False, False, "control head")
    _must_raise(hd, "head")

    var pt = False
    try:
        _ = store.put(Path.parse(String("item/x")), _b(String("u")))
    except:
        pt = True
    _must_raise(pt, "put")

    var cp = False
    try:
        _ = store.conditional_put(
            Path.parse(String("item/x")),
            _b(String("u")),
            WritePrecondition.if_none_match_star(),
        )
    except:
        cp = True
    _must_raise(cp, "conditional_put(create)")

    var cas = False
    try:
        _ = store.compare_and_swap(
            Path.parse(String("item/x")), _b(String("u")), String("t")
        )
    except:
        cas = True
    _must_raise(cas, "compare_and_swap")

    var gt = False
    try:
        _ = store.get(Path.parse(String("item/x")))
    except:
        gt = True
    _must_raise(gt, "get")

    var gr = False
    try:
        _ = store.get_range(Path.parse(String("item/x")), Int64(0), Int64(4))
    except:
        gr = True
    _must_raise(gr, "get_range")

    var dl = False
    try:
        store.delete(Path.parse(String("item/x")))
    except:
        dl = True
    _must_raise(dl, "delete")

    var ls = False
    try:
        _ = store.list_with_delimiter(Path.parse(String("item/")))
    except:
        ls = True
    _must_raise(ls, "list_with_delimiter")


# =============================================================================
# A cross-check on the THIRD copy of the classifier token list.
# =============================================================================


def test_the_typed_sentinels_are_pairwise_disjoint_prefixes() raises:
    """The mapping classifies on `FirestoreClient`'s five typed PREFIXES rather
    than on a substring, which is what makes it a decision procedure with no
    ordering hazard. That property is not free — it holds because the five
    prefixes are pairwise disjoint — so it is asserted rather than assumed."""
    var doc404 = String("FirestoreNotFound: get_document: item/x")
    var db404 = String(
        "FirestoreDatabaseAbsent: get_document: item/x (POST"
        " BatchGetDocuments: HTTP 404, NOT_FOUND (code 5), body 0 bytes)"
    )
    var already = String(
        "FirestoreAlreadyExists: create_if_absent: owner/gcp.a (POST Commit:"
        " HTTP 409, ALREADY_EXISTS (code 6), body 0 bytes)"
    )
    var cas = String(
        "FirestorePreconditionFailed: update_if_unchanged: item/x (POST"
        " Commit: HTTP 400, FAILED_PRECONDITION (code 9), body 0 bytes)"
    )
    var idx = String(
        "FirestoreDatabasePrecondition: run_query: :runQuery (POST RunQuery:"
        " HTTP 400, FAILED_PRECONDITION (code 9), body 0 bytes)"
    )

    assert_true(is_not_found_error(doc404))
    assert_false(is_database_absent_error(doc404))

    assert_true(is_database_absent_error(db404))
    assert_false(is_not_found_error(db404))

    assert_true(is_already_exists_error(already))
    assert_false(is_precondition_failed_error(already))

    assert_true(is_precondition_failed_error(cas))
    assert_false(is_database_precondition_error(cas))

    assert_true(is_database_precondition_error(idx))
    assert_false(is_precondition_failed_error(idx))

    # ★ AND THE RAW TEXT OF THE TWO PERMANENT ONES IS EXACTLY WHAT WOULD FOOL A
    #   SUBSTRING CLASSIFIER — which is why the mapper defuses rather than
    #   forwards.
    assert_true(_consumer_says_not_found(db404))
    assert_true(_consumer_says_precondition(idx))
    var uri = String("firestore://example-db/item/x")
    _assert_reads_as(
        String(map_firestore_error_to_store_error(String("get"), uri, db404)),
        False,
        False,
        "raw absent-database text, mapped",
    )
    _assert_reads_as(
        String(map_firestore_error_to_store_error(String("get"), uri, idx)),
        False,
        False,
        "raw missing-index text, mapped",
    )


# =============================================================================
# THE SELF-CHECK BACKSTOP — asserted DIRECTLY, because it is unobservable
# through the mapper while the defuser is total.
# =============================================================================


def test_the_self_check_backstop_detects_a_misclassified_message() raises:
    """`map_firestore_error_to_store_error` runs its composed message through
    `message_class_is_exactly` before returning, and withholds the detail if the
    class came out wrong. That branch is UNREACHABLE while the defuser knows
    every token — which is the point of a backstop and also the reason it cannot
    be reached through the mapper by any input.

    ⚠ SO IT IS ASSERTED AT THE FUNCTION. Neutering `message_class_is_exactly` to
    `return True` left every other gate in this file GREEN (measured), because
    nothing else can observe a check that never fires. A backstop nothing
    asserts is a backstop nobody would notice the removal of.

    ⛔ AND THE THIRD COPY OF THE TOKEN LIST IS CHECKED HERE TOO: the two
    predicates below must agree with `_consumer_says_*` at the top of this file,
    which are the CONSUMER's, token for token. Three copies of one list is a
    standing hazard (two guards is how two mirrors come to disagree); this is
    the guard that makes it one."""
    # The predicates agree with the consumer's, token for token.
    var probes = List[String]()
    probes.append(String("StoreError[PRECONDITION] x status=412"))
    probes.append(String("StoreError[NOT_FOUND] x status=404"))
    probes.append(String("plain transport failure status=500"))
    probes.append(String("carries NotFound in the middle"))
    probes.append(String("carries PreconditionFailed in the middle"))
    probes.append(String("NoSuchKey"))
    probes.append(String("not_found"))
    for i in range(len(probes)):
        assert_equal(
            store_error_says_precondition(probes[i]),
            _consumer_says_precondition(probes[i]),
        )
        assert_equal(
            store_error_says_not_found(probes[i]),
            _consumer_says_not_found(probes[i]),
        )

    # A message whose class is RIGHT.
    assert_true(
        message_class_is_exactly(
            String("StoreError[PRECONDITION] conditional_put x status=412"),
            String(STORE_KIND_PRECONDITION),
        )
    )
    assert_true(
        message_class_is_exactly(
            String("StoreError[NOT_FOUND] get x status=404"),
            String(STORE_KIND_NOT_FOUND),
        )
    )
    assert_true(
        message_class_is_exactly(
            String("StoreError[TRANSPORT] get x status=500"),
            String(STORE_KIND_TRANSPORT),
        )
    )

    # ★ AND THE THREE THAT MUST BE CAUGHT — each one is a REAL undefused
    #   Firestore message wearing the wrong class.
    #
    # (a) a TRANSPORT error carrying the absent-database body's `404`.
    assert_false(
        message_class_is_exactly(
            String(
                "StoreError[MALFORMED] get firestore_detail=(HTTP 404"
                " [NOT_FOUND]) status=400"
            ),
            String(STORE_KIND_MALFORMED),
        )
    )
    # (b) a MALFORMED error carrying the missing-index sentinel's `Precondition`.
    assert_false(
        message_class_is_exactly(
            String(
                "StoreError[MALFORMED] list firestore_detail="
                "FirestoreDatabasePrecondition: … status=400"
            ),
            String(STORE_KIND_MALFORMED),
        )
    )
    # (c) a PRECONDITION that ALSO reads as an absence — the one a single-
    #     direction assertion would wave through.
    assert_false(
        message_class_is_exactly(
            String("StoreError[PRECONDITION] x 404 status=412"),
            String(STORE_KIND_PRECONDITION),
        )
    )


def main() raises:
    test_gate1_an_object_key_is_a_firestore_document_path()
    test_gate2_discovery_is_last_writer_wins_end_to_end()
    test_gate3_a_second_create_is_refused_and_the_incumbent_stays()
    test_gate5_a_create_conflict_is_StoreError_PRECONDITION_412()
    test_gate6_a_cas_conflict_is_StoreError_PRECONDITION_412()
    test_gate6b_a_concurrent_publisher_is_a_RETRY_not_a_fatal_write()
    test_gate7_an_absent_document_is_StoreError_NOT_FOUND_404()
    test_gate8_an_absent_DATABASE_never_reads_as_an_absent_object()
    test_gate9_a_missing_index_never_reads_as_a_lost_cas()
    test_gate10_the_remaining_arms_are_neither_family()
    test_gate11_a_classifier_token_in_the_payload_cannot_change_the_class()
    test_gate12_head_returns_the_cas_handle_in_etag_not_only_version()
    test_gate13_delete_is_idempotent_but_not_on_an_absent_database()
    test_gate14_list_returns_keys_a_caller_can_feed_back_to_get()
    test_gate15_the_body_round_trips_and_refuses_what_it_cannot_hold()
    test_gate16_CONTROL_every_positive_gate_reds_on_refuse_everything()
    test_the_typed_sentinels_are_pairwise_disjoint_prefixes()
    test_the_self_check_backstop_detects_a_misclassified_message()
    print("test_firestore_conditional_store: ALL PASS")
