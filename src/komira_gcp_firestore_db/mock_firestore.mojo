# =============================================================================
# komira_gcp_firestore_db/mock_firestore.mojo — the ATOMIC in-process Firestore
#   double (the no-cloud substrate Firestore-backed store tests drive).
# =============================================================================
#
# `MockFirestore` answers the three methods the document client sends
# (BatchGetDocuments, Commit, RunQuery) from an in-memory document store, at
# the HTTP boundary: it is a komira_gcp_firestore `HttpExchange`, served by an
# `ExchangeConnector` (`connector()`), so a `FirestoreDatabase` over it runs
# the real generated client end to end with no socket. It reads each request
# with the same generated messages the client wrote it with, and answers with
# the service's own shapes and status codes.
#
# WHY IN THE PACKAGE (not a test). Every Firestore-backed store test drives the
# SAME double, across packages; a test compiles one entry file, so a helper
# shared across tests must be a package module.
#
# WHAT IT MODELS (ZERO network, ZERO GCP):
#   * BatchGetDocuments                  -> `found` / `missing` per name.
#   * Commit, an update:
#       - with currentDocument.exists = false -> ATOMIC create: 200 iff
#         absent, else 409 ALREADY_EXISTS;
#       - with currentDocument.updateTime     -> ATOMIC CAS: 200 iff the
#         stored updateTime equals it, else 400 FAILED_PRECONDITION (404 if
#         absent);
#       - with none                           -> upsert;
#     each mints a fresh updateTime.
#   * Commit, a delete (with currentDocument.exists = true: 404 if absent).
#   * RunQuery: the documents of the `from` collection matching the `where`
#     filter (a fieldFilter EQUAL / NOT_EQUAL / LESS_THAN / LESS_THAN_OR_EQUAL
#     / GREATER_THAN / GREATER_THAN_OR_EQUAL / ARRAY_CONTAINS, a unaryFilter
#     IS_NULL / IS_NOT_NULL, or an AND of them), ordered by the first orderBy
#     field (integers numerically), cut at `limit`. What is modelled of the
#     live service's null and absent-field rules:
#       - a document that LACKS the filtered field matches no filter on it
#         (not EQUAL, NOT_EQUAL, a range, IS_NULL or IS_NOT_NULL), and one
#         that lacks the first orderBy field is left out of the result;
#       - an EQUAL or NOT_EQUAL against a null value matches nothing (IS NULL
#         is a unaryFilter), and NOT_EQUAL does not match an explicit null;
#       - IS_NULL matches only an explicit `nullValue`.
#     Not modelled: NaN, mixed-type ordering across value types, OR, and
#     the other operators (IN, NOT_IN, ARRAY_CONTAINS_ANY).
#
# The store is behind an ArcPointer so two handles (`share()`, a race or a
# crash-recover) see the SAME durable state, as two clients of one database
# do.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard origins;
# ZERO unsafe_from_address. Owned lists of generated `Document`s behind an
# ArcPointer.
# =============================================================================

from std.memory import ArcPointer

from komira_gcp_firestore.firestore_client import (
    PRECONDITION_EXISTS,
    PRECONDITION_UPDATE_TIME,
    WRITE_DELETE,
    WRITE_UPDATE,
)
from komira_gcp_firestore.firestore_value import (
    VALUE_ARRAY,
    VALUE_BOOLEAN,
    VALUE_INTEGER,
    VALUE_NULL,
    VALUE_STRING,
    VALUE_TIMESTAMP,
)
from komira_gcp_firestore.firestore_fake import (
    ExchangeAnswer,
    ExchangeConnector,
    HttpExchange,
)
from komira_gcp_firestore_v1.document import Document, Value
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    CommitRequest,
    RunQueryRequest,
)
from komira_gcp_firestore_v1.query import (
    StructuredQuery_Direction,
    StructuredQuery_FieldFilter_Operator,
    StructuredQuery_Filter,
    StructuredQuery_UnaryFilter_Operator,
)
from komira_proto_codec.codec import decode_json, encode_json
from komira_wkt import Timestamp


comptime _BASE_SECONDS: Int64 = 1790812800
"""The double's clock starts at 2026-10-01T00:00:00Z and ticks a second per
write, so each write's updateTime is distinct and ordered."""


def _err(code: Int, status: String, message: String) -> ExchangeAnswer:
    return ExchangeAnswer(
        code,
        String('{"error":{"code":')
        + String(code)
        + ',"status":"'
        + status
        + '","message":"'
        + message
        + '"}}',
    )


def _split_name(name: String) raises -> Tuple[String, String]:
    """(collection path, document id) of a document resource name."""
    var marker = String("/documents/")
    var at = name.find(marker)
    if at < 0:
        raise Error("MockFirestore: not a document name: " + name)
    var rel = String(unsafe_from_utf8=name.as_bytes()[at + marker.byte_length() :])
    var slash = -1
    var b = rel.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord("/")):
            slash = i
    if slash < 0:
        raise Error("MockFirestore: not a document name: " + name)
    return (
        String(unsafe_from_utf8=b[:slash]),
        String(unsafe_from_utf8=b[slash + 1 :]),
    )


struct _FsState(Movable):
    var collections: List[String]
    var ids: List[String]
    var docs: List[Document]
    var clock: Int64
    var run_query_log: List[String]
    var get_count: Int
    var commit_fault_status: Int
    var commit_fault_body: String
    var fault: Bool

    def __init__(out self):
        self.collections = List[String]()
        self.ids = List[String]()
        self.docs = List[Document]()
        self.clock = 0
        self.run_query_log = List[String]()
        self.get_count = 0
        self.commit_fault_status = 0
        self.commit_fault_body = String("")
        self.fault = False

    def find(self, collection: String, doc_id: String) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == doc_id and self.collections[i] == collection:
                return i
        return -1

    def count(self, doc_id: String) -> Int:
        var n = 0
        for i in range(len(self.ids)):
            if self.ids[i] == doc_id:
                n += 1
        return n

    def tick(mut self) -> Timestamp:
        self.clock += 1
        return Timestamp(_BASE_SECONDS + self.clock, Int32(0))

    def remove(mut self, i: Int):
        _ = self.collections.pop(i)
        _ = self.ids.pop(i)
        _ = self.docs.pop(i)


# =============================================================================
# §1 — the double.
# =============================================================================


struct MockFirestore(HttpExchange, Movable, Deinitable):
    """A stateful in-memory Firestore (see the module header). `connector()`
    is the connector a `FirestoreClient` is built over; `share()` a second
    handle over the SAME state."""

    var _p: ArcPointer[_FsState]

    def __init__(out self):
        self._p = ArcPointer[_FsState](_FsState())

    def __init__(out self, *, var _share: ArcPointer[_FsState]):
        self._p = _share^

    def share(self) -> MockFirestore:
        """A SECOND handle over ONE durable store (a race / crash-recover / a
        test probe that reads the store directly)."""
        return MockFirestore(_share=ArcPointer[_FsState](copy=self._p))

    def connector(self) -> ExchangeConnector[MockFirestore]:
        """A connector whose every request this store answers."""
        return ExchangeConnector[MockFirestore](ArcPointer[MockFirestore](self.share()))

    def count(self, doc_id: String) -> Int:
        """How many docs exist with this id (an ATOMIC store has AT MOST 1)."""
        return self._p[].count(doc_id)

    def run_query_count(self) -> Int:
        """How many RunQuery requests this store has recorded."""
        return len(self._p[].run_query_log)

    def run_query_body(self, i: Int) -> String:
        """The i-th recorded RunQuery request body (the index-audit probe)."""
        return String(self._p[].run_query_log[i])

    def get_count(self) -> Int:
        """How many BatchGetDocuments requests this store has served (a
        readiness probe is one keyed read — a debounce test asserts EXACTLY
        ONE)."""
        return self._p[].get_count

    def fail_next_commit(mut self, status: Int, var body: String):
        """Make the NEXT Commit return `(status, body)` instead of applying its
        writes — a ONE-SHOT fault that clears itself. The documents are left
        UNTOUCHED: it models a refused write whose row still matches the CAS
        guard exactly. Visible through every handle (shared state)."""
        self._p[].commit_fault_status = status
        self._p[].commit_fault_body = body^

    def set_fault(mut self, on: Bool):
        """When `on`, EVERY request answers 503 UNAVAILABLE (a datastore that is
        unreachable — the readiness gate's case). Shared state."""
        self._p[].fault = on

    def answer(
        mut self, method: String, target: String, body: String
    ) raises -> ExchangeAnswer:
        if target.endswith(":batchGet"):
            self._p[].get_count += 1
        if self._p[].fault:
            return _err(503, String("UNAVAILABLE"), String("backend unreachable"))
        if method != "POST":
            raise Error("MockFirestore: unhandled method " + method)
        if target.endswith(":batchGet"):
            return self._batch_get(body)
        if target.endswith(":commit"):
            return self._commit(body)
        if target.endswith(":runQuery"):
            self._p[].run_query_log.append(body)
            return self._run_query(body)
        raise Error("MockFirestore: unroutable target " + target)

    # ----- BatchGetDocuments -------------------------------------------------
    def _batch_get(self, body: String) raises -> ExchangeAnswer:
        var req = decode_json[BatchGetDocumentsRequest](body)
        var out = String("[")
        for i in range(len(req.documents)):
            if i > 0:
                out += ","
            var parts = _split_name(req.documents[i])
            var idx = self._p[].find(parts[0], parts[1])
            if idx < 0:
                out += String('{"missing":"') + req.documents[i] + '"}'
            else:
                out += String('{"found":') + encode_json(self._p[].docs[idx]) + "}"
        out += "]"
        return ExchangeAnswer(200, out^)

    # ----- Commit ------------------------------------------------------------
    def _commit(mut self, body: String) raises -> ExchangeAnswer:
        # The ONE-SHOT refusal, consumed BEFORE any state is touched.
        if self._p[].commit_fault_status > 0:
            var st = self._p[].commit_fault_status
            var fb = self._p[].commit_fault_body.copy()
            self._p[].commit_fault_status = 0
            self._p[].commit_fault_body = String("")
            return ExchangeAnswer(st, fb^)
        var req = decode_json[CommitRequest](body)
        if len(req.writes) != 1:
            raise Error("MockFirestore: one write per commit")
        var w = req.writes[0].copy()
        if w._oneof0_case == WRITE_DELETE:
            var parts = _split_name(w.delete.value())
            var di = self._p[].find(parts[0], parts[1])
            if di < 0:
                if w.current_document and w.current_document.value().exists.value():
                    return _err(404, String("NOT_FOUND"), String("no entity to delete"))
            else:
                self._p[].remove(di)
            return ExchangeAnswer(200, String('{"writeResults":[{}]}'))
        if w._oneof0_case != WRITE_UPDATE:
            raise Error("MockFirestore: unsupported write")
        var doc = w.update.value().copy()
        var parts = _split_name(doc.name)
        var idx = self._p[].find(parts[0], parts[1])
        if w.current_document:
            var pre = w.current_document.value().copy()
            if (
                pre._oneof0_case == PRECONDITION_EXISTS
                and not pre.exists.value()
                and idx >= 0
            ):
                return _err(409, String("ALREADY_EXISTS"), String("entity already exists"))
            if pre._oneof0_case == PRECONDITION_UPDATE_TIME:
                if idx < 0:
                    return _err(404, String("NOT_FOUND"), String("no entity to update"))
                var want = pre.update_time.value()
                var have = self._p[].docs[idx].update_time.value()
                if have.seconds != want.seconds or have.nanos != want.nanos:
                    return _err(400, String("FAILED_PRECONDITION"), String("stale version"))
        var t = self._p[].tick()
        doc.update_time = t
        if idx < 0:
            doc.create_time = t
            self._p[].collections.append(parts[0])
            self._p[].ids.append(parts[1])
            self._p[].docs.append(doc^)
        else:
            doc.create_time = self._p[].docs[idx].create_time
            self._p[].docs[idx] = doc^
        var stamp = t.to_proto3_json()
        return ExchangeAnswer(
            200,
            String('{"writeResults":[{"updateTime":"') + stamp
            + String('"}],"commitTime":"') + stamp + String('"}'),
        )

    # ----- RunQuery ----------------------------------------------------------
    def _run_query(self, body: String) raises -> ExchangeAnswer:
        var req = decode_json[RunQueryRequest](body)
        var q = req.structured_query.value().copy()
        var collection = String("")
        if len(q.from_) > 0:
            collection = q.from_[0].collection_id.copy()
        var matched = List[Int]()
        for i in range(len(self._p[].ids)):
            if collection.byte_length() > 0 and self._p[].collections[i] != collection:
                continue
            if q.where:
                if not _matches(self._p[].docs[i], q.where.value()):
                    continue
            matched.append(i)
        if len(q.order_by) > 0 and q.order_by[0].field:
            var field = q.order_by[0].field.value().field_path.copy()
            # An orderBy on a field excludes the documents that lack it.
            var having = List[Int]()
            for k in range(len(matched)):
                if field in self._p[].docs[matched[k]].fields:
                    having.append(matched[k])
            matched = having^
            var descending = (
                q.order_by[0].direction.value == StructuredQuery_Direction.DESCENDING
            )
            # A stable insertion sort on the field.
            for a in range(1, len(matched)):
                var j = a
                while j > 0:
                    var c = _compare(
                        self._p[].docs[matched[j - 1]], self._p[].docs[matched[j]], field
                    )
                    var out_of_order = c < 0 if descending else c > 0
                    if not out_of_order:
                        break
                    var tmp = matched[j - 1]
                    matched[j - 1] = matched[j]
                    matched[j] = tmp
                    j -= 1
        var n = len(matched)
        if q.limit and Int(q.limit.value().value) < n:
            n = Int(q.limit.value().value)
        var out = String("[")
        for i in range(n):
            if i > 0:
                out += ","
            out += String('{"document":') + encode_json(self._p[].docs[matched[i]]) + "}"
        if n == 0:
            out += String('{"readTime":"2026-10-01T00:00:00Z"}')
        out += "]"
        return ExchangeAnswer(200, out^)


comptime MockFirestoreConnector = ExchangeConnector[MockFirestore]
"""The connector type a `FirestoreClient` / `FirestoreDatabase` over a
`MockFirestore` is parametric on."""


# =============================================================================
# §2 — the WHERE evaluator.
# =============================================================================

comptime FILTER_COMPOSITE = 1
"""`StructuredQuery.Filter.filter_type`: `composite_filter`."""
comptime FILTER_FIELD = 2
"""`StructuredQuery.Filter.filter_type`: `field_filter`."""
comptime FILTER_UNARY = 3
"""`StructuredQuery.Filter.filter_type`: `unary_filter`. The three are pinned
against the generated decoder by test_firestore_database_standalone."""


@fieldwise_init
struct _Raw(Copyable, Movable):
    """A field's value as the filter compares it: null (an explicit
    `nullValue`, or a field the document lacks, which every filter arm
    then rejects), else its text (a string as itself, an integer as its
    decimal, ...)."""

    var is_null: Bool
    var text: String
    var is_int: Bool
    var int_value: Int64


def _raw(v: Value) raises -> _Raw:
    var c = v._oneof0_case
    if c == 0 or c == VALUE_NULL:
        return _Raw(True, String(""), False, 0)
    if c == VALUE_INTEGER:
        return _Raw(False, String(v.integer_value.value()), True, v.integer_value.value())
    if c == VALUE_STRING:
        return _Raw(False, v.string_value.value().copy(), False, 0)
    if c == VALUE_BOOLEAN:
        return _Raw(False, String("true") if v.boolean_value.value() else String("false"), False, 0)
    if c == VALUE_TIMESTAMP:
        return _Raw(False, v.timestamp_value.value().to_proto3_json(), False, 0)
    return _Raw(False, encode_json(v), False, 0)


def _field_raw(doc: Document, field: String) raises -> _Raw:
    if field in doc.fields:
        return _raw(doc.fields[field])
    return _Raw(True, String(""), False, 0)


def _compare(a: Document, b: Document, field: String) raises -> Int:
    var x = _field_raw(a, field)
    var y = _field_raw(b, field)
    if x.is_null or y.is_null:
        if x.is_null and y.is_null:
            return 0
        return -1 if x.is_null else 1
    if x.is_int and y.is_int:
        if x.int_value < y.int_value:
            return -1
        return 1 if x.int_value > y.int_value else 0
    if x.text < y.text:
        return -1
    return 1 if x.text > y.text else 0


def _matches(doc: Document, f: StructuredQuery_Filter) raises -> Bool:
    var arm = f._oneof0_case
    if arm == FILTER_COMPOSITE:
        # A composite filter: AND of its filters (OR is not modeled).
        for i in range(len(f.composite_filter[0].filters)):
            if not _matches(doc, f.composite_filter[0].filters[i]):
                return False
        return True
    if arm == FILTER_FIELD:
        var ff = f.field_filter.value().copy()
        var field = ff.field.value().field_path.copy()
        var want = _raw(ff.value.value())
        var have = _field_raw(doc, field)
        var op = ff.op.value
        if op == StructuredQuery_FieldFilter_Operator.EQUAL:
            return (not want.is_null) and (not have.is_null) and have.text == want.text
        if op == StructuredQuery_FieldFilter_Operator.NOT_EQUAL:
            # Neither a document lacking the field nor one holding null.
            if want.is_null or have.is_null:
                return False
            return have.text != want.text
        if op == StructuredQuery_FieldFilter_Operator.ARRAY_CONTAINS:
            if not (field in doc.fields) or doc.fields[field]._oneof0_case != VALUE_ARRAY:
                return False
            ref items = doc.fields[field].array_value[0].values
            for i in range(len(items)):
                if _raw(items[i]).text == want.text:
                    return True
            return False
        if have.is_null or want.is_null:
            return False
        var c: Int
        if have.is_int and want.is_int:
            c = -1 if have.int_value < want.int_value else (1 if have.int_value > want.int_value else 0)
        else:
            c = -1 if have.text < want.text else (1 if have.text > want.text else 0)
        if op == StructuredQuery_FieldFilter_Operator.LESS_THAN:
            return c < 0
        if op == StructuredQuery_FieldFilter_Operator.LESS_THAN_OR_EQUAL:
            return c <= 0
        if op == StructuredQuery_FieldFilter_Operator.GREATER_THAN:
            return c > 0
        if op == StructuredQuery_FieldFilter_Operator.GREATER_THAN_OR_EQUAL:
            return c >= 0
        return False  # an unsupported operator fails closed
    if arm == FILTER_UNARY:
        var uf = f.unary_filter.value().copy()
        var path = uf.field.value().field_path.copy()
        if not (path in doc.fields):
            return False  # a unary filter never matches a missing field
        var have = _field_raw(doc, path)
        if uf.op.value == StructuredQuery_UnaryFilter_Operator.IS_NULL:
            return have.is_null
        if uf.op.value == StructuredQuery_UnaryFilter_Operator.IS_NOT_NULL:
            return not have.is_null
        return False
    return True
