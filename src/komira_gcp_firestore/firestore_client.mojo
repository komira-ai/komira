# =============================================================================
# komira_gcp_firestore/firestore_client.mojo — the Firestore document client.
# =============================================================================
#
# WHAT THIS IS. The document operations komira's stores call (get, create,
# replace, delete, query, and the two atomic conditional writes), written on
# the GENERATED REST client of komira_gcp_firestore_v1. This module adds no
# wire code: it builds the generated request messages, sends them, converts
# documents between the generated `Document` and `FsValue`, and maps a failed
# call onto the typed errors its callers branch on.
#
# THE METHODS, as Google's own Firestore client libraries use them:
#   * get_document         -> BatchGetDocuments with one name. A missing
#                             document is a `missing` result inside a 200.
#   * create_document,     -> Commit, one `update` write with the precondition
#     create_if_absent        `currentDocument.exists = false`.
#   * patch_document       -> Commit, one `update` write, no precondition (a
#                             whole-document replace or create).
#   * update_if_unchanged  -> Commit, one `update` write with
#                             `currentDocument.updateTime = <expected>`.
#   * delete_document      -> BatchGetDocuments, then Commit with one `delete`
#                             write conditioned on `exists = true`, so a
#                             missing document is the typed not-found error.
#   * run_query            -> RunQuery on the database root.
#
# THE TYPED ERRORS, read off the google.rpc.Code of the failed call and
# whether its body named a status at all. Both come from komira_gcp_core
# (`gcp_status_error_code`, `gcp_status_error_unlabelled`), which reads them
# back out of the error line it rendered itself (`GcpStatusError.message`):
# a generated REST client raises that line, and keeps no byte of the error
# body, so Google's `error.message` (which names projects, databases and
# documents) is never consulted, here or anywhere. Because no method here
# answers NOT_FOUND for a missing document (BatchGetDocuments says
# `missing`, a write without an exists precondition creates), NOT_FOUND
# means the DATABASE is absent — the distinction the absent-database
# sentinel exists for, made on structure. The exceptions are the
# conditional writes: an `exists = true` delete of a document a read has
# just found (so the database exists) is a not-found of THAT document, and
# a version CAS (`updateTime`) that answers NOT_FOUND is settled by reading
# the document (`update_if_unchanged`).
#
# AUTH. The generated client asks its komira_gcp_core `GcpTokenSource` for
# the bearer of EVERY request. In production that is the Application Default
# Credentials source (`firestore_adc_token_source`, the CachingTokenSource
# komira_gcp_core resolves); `FixedBearer` is for a hand-minted token, the
# emulator or a test.
#
# SYNCHRONOUS. Each operation drives one request to completion on a
# `BlockingRuntime` of its own, as the methods' callers expect; a caller
# that needs another runtime calls the generated client (`api()`) directly.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard origins;
# ZERO unsafe_from_address. The client owns the generated client (which owns
# its HttpClient, connector and token source) and two Strings.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import (
    AdcFetcher,
    AdcOptions,
    CachingTokenSource,
    GcpConnectorTransport,
    SystemWallClock,
    CODE_ABORTED,
    CODE_ALREADY_EXISTS,
    CODE_FAILED_PRECONDITION,
    CODE_INVALID_ARGUMENT,
    CODE_NOT_FOUND,
    GcpTokenSource,
    application_default_token_source,
    gcp_status_error_code,
    gcp_status_error_unlabelled,
)
from komira_retry import SystemClock
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_http_client.header_map import HeaderMap
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_proto_codec.codec import decode_json
from komira_rowcell.row_cell import RowCell
from komira_wkt import Timestamp

from komira_gcp_firestore_v1.common import Precondition
from komira_gcp_firestore_v1.document import Document
from komira_gcp_firestore_v1.firestore import (
    BatchGetDocumentsRequest,
    BatchGetDocumentsResponse,
    CommitRequest,
    CommitResponse,
    FirestoreClient as FirestoreV1Client,
    RunQueryRequest,
    RunQueryResponse,
)
from komira_gcp_firestore_v1.query import StructuredQuery
from komira_gcp_firestore_v1.write import DocumentTransform_FieldTransform, Write

from .firestore_endpoint import FIRESTORE_HOST, FirestoreEndpoint
from .firestore_value import (
    FsValue,
    fs_fields_from_v1,
    fs_fields_to_row_cells,
    fs_fields_to_v1,
)


comptime _RT = BlockingRuntime[NoopSink]


# =============================================================================
# The generated messages' oneof arms this module sets or reads.
# =============================================================================
# A generated message keeps each oneof as `_oneofN_case`: 0 unset, then 1..N
# in the order the proto declares the arms. These names say which arm each
# number is; test_firestore_client pins every one against the generated
# decoder (it decodes the arm's JSON and reads the case back), so a bump of
# the pinned protos that reordered an arm fails a test instead of changing
# behaviour.

comptime BATCH_GET_FOUND = 1
"""`BatchGetDocumentsResponse.result`: `found`."""
comptime BATCH_GET_MISSING = 2
"""`BatchGetDocumentsResponse.result`: `missing`."""
comptime PRECONDITION_EXISTS = 1
"""`Precondition.condition_type`: `exists`."""
comptime PRECONDITION_UPDATE_TIME = 2
"""`Precondition.condition_type`: `update_time`."""
comptime WRITE_UPDATE = 1
"""`Write.operation`: `update`."""
comptime WRITE_DELETE = 2
"""`Write.operation`: `delete`."""
comptime RUN_QUERY_STRUCTURED = 1
"""`RunQueryRequest.query_type`: `structured_query`."""


# =============================================================================
# §0 — the typed errors.
# =============================================================================
# Each is a message PREFIX a caller tests with its `is_*` predicate. The text
# after the prefix names the operation and the collection/document, then the
# generated client's error in parentheses (the verb, the method, the HTTP
# status and the google.rpc.Code; no byte of the response body).

comptime FIRESTORE_NOT_FOUND_PREFIX: String = "FirestoreNotFound: "
"""A document that does not exist (`get_document`), or one that went away
under a version CAS (`update_if_unchanged`)."""

comptime FIRESTORE_ALREADY_EXISTS_PREFIX: String = "FirestoreAlreadyExists: "
"""A create (`create_document`, `create_if_absent`) whose document already
exists: the commit failed whole and wrote nothing (ALREADY_EXISTS). The
analog of a unique index rejecting a second row: the caller re-reads and
adopts."""

comptime FIRESTORE_PRECONDITION_FAILED_PREFIX: String = (
    "FirestorePreconditionFailed: "
)
"""A version CAS (`update_if_unchanged`) that lost: the document's
`updateTime` moved on (FAILED_PRECONDITION), or the commit contended with
another (ABORTED). Nothing was written; the caller re-reads and retries."""

# The DATABASE-STATE precondition. DISTINCT from the one above, which is a
# precondition on ONE DOCUMENT'S VERSION (a lost race: re-read, retry, win).
# THIS one is Google's FAILED_PRECONDITION on a READ or QUERY: the database's
# own configuration does not admit the request, overwhelmingly a missing
# COMPOSITE INDEX, which Firestore never creates on its own. The identical
# request fails identically until an operator applies the index, so a caller
# MUST NOT retry it on a timer.
comptime FIRESTORE_DATABASE_PRECONDITION_PREFIX: String = (
    "FirestoreDatabasePrecondition: "
)

# The ABSENT-DATABASE sentinel. The configured database does not exist in the
# configured project: a deploy-time misconfiguration that affects every
# request and that no retry or re-read changes. It must never read as an
# absent DOCUMENT, which callers correctly treat as empty, or a service runs
# against nothing while reporting normal absence. Firestore answers both with
# NOT_FOUND; this client tells them apart by the method (§ header), not by
# the message.
comptime FIRESTORE_DATABASE_ABSENT_PREFIX: String = "FirestoreDatabaseAbsent: "


@always_inline
def _has_prefix(err: String, prefix: String) -> Bool:
    return err.startswith(prefix)


@always_inline
def is_not_found_error(err: String) -> Bool:
    """True iff `err` (an Error's message) is the typed not-found error: the
    document does not exist (or, for a version CAS, no longer exists)."""
    return _has_prefix(err, FIRESTORE_NOT_FOUND_PREFIX)


@always_inline
def is_already_exists_error(err: String) -> Bool:
    """True iff `err` is the typed ALREADY_EXISTS conflict of a create: the
    document existed and nothing was written (the caller re-reads and
    adopts)."""
    return _has_prefix(err, FIRESTORE_ALREADY_EXISTS_PREFIX)


@always_inline
def is_precondition_failed_error(err: String) -> Bool:
    """True iff `err` is the typed version-CAS conflict of
    `update_if_unchanged` (the caller re-reads and retries the CAS)."""
    return _has_prefix(err, FIRESTORE_PRECONDITION_FAILED_PREFIX)


@always_inline
def is_database_precondition_error(err: String) -> Bool:
    """True iff `err` is the typed DATABASE-STATE precondition error: a read or
    query the database's configuration does not admit, overwhelmingly a
    missing composite index. PERMANENT: the caller must not re-drive the same
    call; an operator applies the index. NOT the retryable version-CAS
    conflict (`is_precondition_failed_error`)."""
    return _has_prefix(err, FIRESTORE_DATABASE_PRECONDITION_PREFIX)


@always_inline
def is_database_absent_error(err: String) -> Bool:
    """True iff `err` is the typed ABSENT-DATABASE error: the configured
    database does not exist in the configured project. A CONFIGURATION fault,
    permanent for every request; never to be treated as absence of data."""
    return _has_prefix(err, FIRESTORE_DATABASE_ABSENT_PREFIX)


# How a failed call is classified (`_classify`).
comptime _READ = 0
"""BatchGetDocuments or RunQuery: FAILED_PRECONDITION is the database's."""
comptime _WRITE = 1
"""A commit without a precondition."""
comptime _CREATE = 2
"""A commit with `exists = false`: ALREADY_EXISTS is the typed conflict."""
comptime _CAS = 3
"""A commit with an `updateTime` precondition."""
comptime _DELETE = 4
"""A delete with `exists = true`, after a read found the document: its
NOT_FOUND is the document having gone since (the read proved the database
exists)."""


def _classify(
    op: String, resource: String, rpc: String, text: String, mode: Int
) -> Error:
    """The error `op` on `resource` raises for a failed `rpc` whose generated
    client raised `text`."""
    var code = gcp_status_error_code(String("POST"), rpc, text)
    var where = op + String(": ") + resource
    var detail = String(" (") + text + String(")")
    if code < 0:
        # Not a status: the request never got an answer (a refused dial, a
        # timeout, a body the client could not read).
        return Error(String("FirestoreClient.") + where + String(": ") + text)
    if mode == _DELETE and code == CODE_NOT_FOUND:
        return Error(FIRESTORE_NOT_FOUND_PREFIX + where + detail)
    if code == CODE_NOT_FOUND:
        if mode == _CAS:
            return Error(FIRESTORE_NOT_FOUND_PREFIX + where + detail)
        return Error(FIRESTORE_DATABASE_ABSENT_PREFIX + where + detail)
    if code == CODE_ALREADY_EXISTS and mode == _CREATE:
        return Error(FIRESTORE_ALREADY_EXISTS_PREFIX + where + detail)
    if mode == _CAS and (code == CODE_FAILED_PRECONDITION or code == CODE_ABORTED):
        return Error(FIRESTORE_PRECONDITION_FAILED_PREFIX + where + detail)
    if (
        mode == _CAS
        and code == CODE_INVALID_ARGUMENT
        and gcp_status_error_unlabelled(String("POST"), rpc, text)
    ):
        # No google.rpc.Status to say otherwise: a 400 on a CAS commit (its
        # code derived from the HTTP status alone) is read as the lost race
        # it nearly always is. A LABELLED INVALID_ARGUMENT (naming a refused
        # write) is never: typing a refused write as a lost race makes a
        # permanent rejection a swallowed retry. (An unlabelled 409 is
        # ABORTED, the arm above.)
        return Error(FIRESTORE_PRECONDITION_FAILED_PREFIX + where + detail)
    if mode == _READ and code == CODE_FAILED_PRECONDITION:
        return Error(FIRESTORE_DATABASE_PRECONDITION_PREFIX + where + detail)
    return Error(String("FirestoreClient.") + where + detail)


# =============================================================================
# §1 — the document and commit-result values.
# =============================================================================


struct FirestoreDocument(Copyable, Movable, Deinitable):
    """A Firestore document: its resource name, its typed `fields` (an FS_T_MAP
    FsValue), and its create/update timestamps (RFC 3339, "" when not known).

    Layout: a plain owned-field struct (String + the plain-List-backed FsValue),
    no pointer field, no wildcard origin."""

    var name: String
    var fields: FsValue
    var create_time: String
    var update_time: String

    def __init__(
        out self,
        var name: String,
        var fields: FsValue,
        var create_time: String,
        var update_time: String,
    ):
        self.name = name^
        self.fields = fields^
        self.create_time = create_time^
        self.update_time = update_time^

    def copy(self) -> Self:
        return Self(
            String(self.name),
            self.fields.copy(),
            String(self.create_time),
            String(self.update_time),
        )

    @staticmethod
    def from_v1(doc: Document) raises -> FirestoreDocument:
        """The document a generated `Document` holds."""
        var created = String("")
        if doc.create_time:
            created = doc.create_time.value().to_proto3_json()
        var updated = String("")
        if doc.update_time:
            updated = doc.update_time.value().to_proto3_json()
        return FirestoreDocument(
            doc.name.copy(), fs_fields_from_v1(doc.fields), created^, updated^
        )

    def get_field(self, key: String) raises -> FsValue:
        """The typed value of `key` (raises if absent)."""
        return self.fields.map_get(key)

    def has_field(self, key: String) -> Bool:
        return self.fields.map_has(key)

    def to_row_cells(self, column_names: List[String]) raises -> List[RowCell]:
        """Project the document's fields onto a positional row of RowCells in
        `column_names` order (absent -> null-fill)."""
        return fs_fields_to_row_cells(self.fields, column_names)


struct FirestoreCommitResult(Copyable, Movable, Deinitable):
    """The result of a successful atomic write (`create_if_absent`,
    `update_if_unchanged`): the committed document's `update_time` (RFC 3339),
    the CAS token a later `update_if_unchanged` passes as
    `expected_update_time` (Firestore's per-document updateTime IS the
    version). A commit does not echo the fields, so this result is thin."""

    var update_time: String

    def __init__(out self, var update_time: String):
        self.update_time = update_time^


comptime FIRESTORE_EMULATOR_BEARER: String = "owner"
"""The bearer Google's Firestore client libraries send to an emulator."""


struct FixedBearer(GcpTokenSource, Copyable, Movable, Deinitable):
    """A `GcpTokenSource` that returns one fixed token on every request.

    For a hand-minted token, the emulator or a test. For the emulator, pass
    `FIRESTORE_EMULATOR_BEARER` ("owner"): Google's Firestore libraries send
    `Authorization: Bearer owner` to an emulator, which lets the request
    bypass security rules. An EMPTY token is accepted (komira_gcp_core's
    `StaticTokenSource` refuses one) and sent as `Authorization: Bearer `
    with nothing after it, which the emulator does not check either. A
    long-lived production client takes a refreshing source instead
    (`firestore_adc_token_source`), so a token that expires after an hour is
    refetched rather than presented stale.

    It is also the only token source a plaintext endpoint accepts
    (`FirestoreClient.set_endpoint`), so a real credential is never sent in
    cleartext.

    `@implicit` from `String`, so `FirestoreClient[C](connector, project,
    database, token)` builds a fixed-token client."""

    var _token: String

    @implicit
    def __init__(out self, var token: String):
        self._token = token^

    def access_token(mut self) raises -> String:
        return self._token.copy()


# =============================================================================
# §2 — FirestoreClient.
# =============================================================================


struct FirestoreClient[C: Connector, S: GcpTokenSource = FixedBearer](
    Movable, Deinitable
):
    """The Firestore document client over the generated REST client
    (komira_gcp_firestore_v1), parametric over its HTTP connector `C` (a
    `TlsConnector[KernelTcpConnector]` in production, `KernelTcpConnector` for
    the plaintext emulator, a `ScriptedConnector` in a test) and its token
    source `S`.

        get_document(collection, doc)            -> BatchGetDocuments
        create_document(collection, doc, fields) -> Commit (exists = false)
        patch_document(collection, doc, fields)  -> Commit (replace)
        delete_document(collection, doc)         -> BatchGetDocuments, then
                                                    Commit (delete, exists)
        run_query(structured_query_json)         -> RunQuery
        create_if_absent(collection, doc, fields)
                                                 -> Commit (exists = false)
        update_if_unchanged(collection, doc, fields, expected_update_time)
                                                 -> Commit (updateTime)

    The documents are those of `projects/<project>/databases/<database>`;
    `collection` is a collection id (or a slash path of one nested under a
    document), `doc` a document id."""

    var _api: FirestoreV1Client[Self.C, Self.S]
    var _project: String
    var _database: String

    def __init__(
        out self,
        var http: HttpClient[Self.C],
        var project: String,
        var database: String,
        var tokens: Self.S,
    ):
        """A client sending through `http`, to firestore.googleapis.com (see
        `set_endpoint` for another), asking `tokens` for the bearer of each
        request. The caller owns the time budget: build `http` from the
        `HttpClientConfig` that fits the process (a request handler under a
        platform deadline uses `HttpClientConfig.for_serving_ceiling`)."""
        self._api = FirestoreV1Client[Self.C, Self.S](http^, tokens^)
        self._api.set_rest_host(String(FIRESTORE_HOST))
        self._project = project^
        self._database = database^

    def __init__(
        out self,
        var http: HttpClient[Self.C],
        var project: String,
        var database: String,
        var tokens: Self.S,
        var default_headers: HeaderMap,
    ):
        """As above, with `default_headers` sent on every request (the
        quota project's `x-goog-user-project`,
        `firestore_quota_project_headers`)."""
        self._api = FirestoreV1Client[Self.C, Self.S](
            http^, tokens^, default_headers^
        )
        self._api.set_rest_host(String(FIRESTORE_HOST))
        self._project = project^
        self._database = database^

    def __init__(
        out self,
        var connector: Self.C,
        var project: String,
        var database: String,
        var tokens: Self.S,
    ):
        """As above, over an `HttpClient` with the default configuration
        (`HttpClient.with_defaults`)."""
        self = Self(
            HttpClient[Self.C].with_defaults(connector^),
            project^,
            database^,
            tokens^,
        )

    def set_endpoint(mut self, endpoint: FirestoreEndpoint) raises:
        """Send to `endpoint` (an emulator, or a TLS terminator in front of
        one) instead of firestore.googleapis.com. A plaintext endpoint
        (`insecure`) needs a plaintext connector `C`: the HttpClient refuses
        an http URL over a TLS connector, and the reverse.

        RAISES for a plaintext endpoint unless the token source is
        `FixedBearer`: the bearer goes on every request, and a real
        credential (an ADC token) must not cross the network in cleartext.
        Google's libraries likewise send no real credential to an emulator
        (they send "owner", `FIRESTORE_EMULATOR_BEARER`)."""
        comptime if not (Self.S == FixedBearer):
            if endpoint.insecure:
                raise Error(
                    "FirestoreClient.set_endpoint: a plaintext endpoint takes"
                    " a FixedBearer token source (the emulator's \"owner\"),"
                    " never a real credential, which would be sent in"
                    " cleartext"
                )
        var port = endpoint.port
        if (endpoint.insecure and port == UInt16(80)) or (
            not endpoint.insecure and port == UInt16(443)
        ):
            port = UInt16(0)  # the scheme's own port: no `:port` in Host
        self._api.set_rest_endpoint(endpoint.host.copy(), port, endpoint.insecure)

    def api(mut self) -> ref [self._api] FirestoreV1Client[Self.C, Self.S]:
        """The generated client, for a call this adapter does not make."""
        return self._api

    def token_source(mut self) -> ref [self._api._token_source] Self.S:
        """The token source asked per request (a test advances a fake clock or
        counts fetches through it)."""
        return self._api._token_source

    def database_name(self) -> String:
        """`projects/<project>/databases/<database>`."""
        return (
            String("projects/")
            + self._project
            + String("/databases/")
            + self._database
        )

    def document_name(self, collection: String, doc: String) -> String:
        """The resource name of document `doc` of `collection`."""
        return (
            self.database_name()
            + String("/documents/")
            + collection
            + String("/")
            + doc
        )

    # ----- sends -------------------------------------------------------------

    def _batch_get(
        mut self, var names: List[String], op: String, resource: String
    ) raises -> List[BatchGetDocumentsResponse]:
        var req = BatchGetDocumentsRequest(
            self.database_name(), names^, None, None, 0, None, None, None
        )
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        try:
            return self._api.batch_get_documents[_RT](req, reactor)
        except e:
            raise _classify(op, resource, String("BatchGetDocuments"), String(e), _READ)

    def _commit(
        mut self, var writes: List[Write], op: String, resource: String, mode: Int
    ) raises -> CommitResponse:
        var req = CommitRequest(self.database_name(), writes^, List[UInt8](), None)
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        try:
            return self._api.commit[_RT](req, reactor)
        except e:
            raise _classify(op, resource, String("Commit"), String(e), mode)

    # ----- document ops ------------------------------------------------------

    def get_document(
        mut self, collection: String, doc: String
    ) raises -> FirestoreDocument:
        """Read one document. RAISES the typed not-found error when it does not
        exist (`is_not_found_error`), and the absent-database error when the
        database does not (`is_database_absent_error`)."""
        var resource = collection + String("/") + doc
        var names = List[String]()
        names.append(self.document_name(collection, doc))
        var got = self._batch_get(names^, String("get_document"), resource)
        for i in range(len(got)):
            if got[i]._oneof0_case == BATCH_GET_FOUND:
                return FirestoreDocument.from_v1(got[i].found.value())
            if got[i]._oneof0_case == BATCH_GET_MISSING:
                raise Error(
                    FIRESTORE_NOT_FOUND_PREFIX
                    + String("get_document: ")
                    + resource
                )
        raise Error(
            String("FirestoreClient.get_document: ")
            + resource
            + String(": the BatchGetDocuments stream held no result")
        )

    def create_document(
        mut self, collection: String, doc: String, fields: FsValue
    ) raises -> FirestoreDocument:
        """Create document `doc` in `collection`; RAISES the typed
        already-exists error if it exists (nothing is written). Returns the
        document as written: the commit's update time is its create time."""
        var name = self.document_name(collection, doc)
        var resource = collection + String("/") + doc
        var writes = List[Write]()
        writes.append(_update_write(name, fields, Precondition(PRECONDITION_EXISTS, False, None)))
        var resp = self._commit(writes^, String("create_document"), resource, _CREATE)
        var t = _update_time(resp)
        return FirestoreDocument(name^, fields.copy(), t.copy(), t^)

    def patch_document(
        mut self, collection: String, doc: String, fields: FsValue
    ) raises -> FirestoreDocument:
        """Write document `doc` whole, creating it if absent. Returns the
        document as written (its create time is not in a commit's answer, so
        it is "")."""
        var name = self.document_name(collection, doc)
        var resource = collection + String("/") + doc
        var writes = List[Write]()
        writes.append(_update_write(name, fields, None))
        var resp = self._commit(writes^, String("patch_document"), resource, _WRITE)
        return FirestoreDocument(name^, fields.copy(), String(""), _update_time(resp))

    def delete_document(mut self, collection: String, doc: String) raises:
        """Delete document `doc`; RAISES the typed not-found error if it does
        not exist, so a caller can count what it deleted (a SQL `DELETE`'s row
        count) and an idempotent caller swallows it.

        Firestore's own delete of a missing document succeeds, and a delete
        conditioned on `exists = true` answers NOT_FOUND for a missing
        document AND for a missing database. So the document is read first
        (BatchGetDocuments: `missing`, or NOT_FOUND for the database), then
        deleted with `currentDocument.exists = true`; a document deleted by
        someone else in between is not-found, as it would have been a moment
        earlier."""
        var resource = collection + String("/") + doc
        var name = self.document_name(collection, doc)
        var names = List[String]()
        names.append(name.copy())
        var got = self._batch_get(names^, String("delete_document"), resource)
        for i in range(len(got)):
            if got[i]._oneof0_case == BATCH_GET_MISSING:
                raise Error(
                    FIRESTORE_NOT_FOUND_PREFIX
                    + String("delete_document: ")
                    + resource
                )
        var w = _delete_write(name)
        w.current_document = Precondition(PRECONDITION_EXISTS, True, None)
        var writes = List[Write]()
        writes.append(w^)
        _ = self._commit(writes^, String("delete_document"), resource, _DELETE)

    def run_query(
        mut self, structured_query_json: String
    ) raises -> List[FirestoreDocument]:
        """Run a `StructuredQuery`, given as its JSON form (the REST
        `structuredQuery` object), on the database root. The JSON is read
        STRICTLY into the generated `StructuredQuery` first, so a key the
        message does not declare is refused before anything is sent; then
        as `run_structured_query`."""
        var q: StructuredQuery
        try:
            q = decode_json[StructuredQuery](structured_query_json)
        except e:
            raise Error(
                String("FirestoreClient.run_query: the structured query is not")
                + String(" a google.firestore.v1.StructuredQuery: ")
                + String(e)
            )
        return self.run_structured_query(q^)

    def run_structured_query(
        mut self, var q: StructuredQuery
    ) raises -> List[FirestoreDocument]:
        """Run the generated `StructuredQuery` `q` on the database root.
        Returns the documents of the result stream in order (its
        read-time-only elements carry none)."""
        var req = RunQueryRequest(
            self.database_name() + String("/documents"),
            None,
            None,
            RUN_QUERY_STRUCTURED,
            q^,
            0,
            None,
            None,
            None,
        )
        var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
        ref reactor = rt.reactor()
        var got: List[RunQueryResponse]
        try:
            got = self._api.run_query[_RT](req, reactor)
        except e:
            raise _classify(
                String("run_query"), String(":runQuery"), String("RunQuery"), String(e), _READ
            )
        var out = List[FirestoreDocument]()
        for i in range(len(got)):
            if got[i].document:
                out.append(FirestoreDocument.from_v1(got[i].document.value()))
        return out^

    # ----- atomic conditional writes ----------------------------------------

    def create_if_absent(
        mut self, collection: String, doc: String, fields: FsValue
    ) raises -> FirestoreCommitResult:
        """ATOMIC CONDITIONAL CREATE: write `doc` iff it does not exist
        (`currentDocument.exists = false`). The service applies it atomically:
        if the document exists the commit fails whole (ALREADY_EXISTS) and
        nothing is written, like a unique index rejecting a second row.
        RETURNS the write's update time, the CAS token for a later
        `update_if_unchanged`. RAISES the typed already-exists error iff the
        document existed (the caller re-reads and adopts)."""
        var resource = collection + String("/") + doc
        var writes = List[Write]()
        writes.append(
            _update_write(
                self.document_name(collection, doc),
                fields,
                Precondition(PRECONDITION_EXISTS, False, None),
            )
        )
        var resp = self._commit(writes^, String("create_if_absent"), resource, _CREATE)
        return FirestoreCommitResult(_update_time(resp))

    def update_if_unchanged(
        mut self,
        collection: String,
        doc: String,
        fields: FsValue,
        expected_update_time: String,
    ) raises -> FirestoreCommitResult:
        """SINGLE-DOCUMENT VERSION CAS: write `doc` whole iff its update time
        is still `expected_update_time` (RFC 3339; `currentDocument.updateTime`).
        Atomic: if it moved on, the commit fails whole and nothing is written.
        RETURNS the new update time (the next CAS token). RAISES the typed
        precondition-failed error iff the version moved (the caller re-reads
        and retries), and the typed not-found error iff the document is gone.
        A commit answering NOT_FOUND is settled by one read of the document,
        so an absent DATABASE raises the absent-database error rather than
        reading as a gone document."""
        var resource = collection + String("/") + doc
        var expected = Timestamp.from_proto3_json(expected_update_time)
        var writes = List[Write]()
        writes.append(
            _update_write(
                self.document_name(collection, doc),
                fields,
                Precondition(PRECONDITION_UPDATE_TIME, None, expected),
            )
        )
        var resp: CommitResponse
        try:
            resp = self._commit(
                writes^, String("update_if_unchanged"), resource, _CAS
            )
        except e:
            var err = String(e)
            if not is_not_found_error(err):
                raise Error(err)
            # NOT_FOUND on a version CAS is either the document having gone
            # or the DATABASE being absent; the commit cannot say which. One
            # read can: BatchGetDocuments answers `missing` for a document
            # and NOT_FOUND only for the database (raised here, typed as
            # absent). A document that is there again was deleted and
            # recreated since the caller's read: its version moved on.
            var names = List[String]()
            names.append(self.document_name(collection, doc))
            var got = self._batch_get(
                names^, String("update_if_unchanged"), resource
            )
            for i in range(len(got)):
                if got[i]._oneof0_case == BATCH_GET_FOUND:
                    raise Error(
                        FIRESTORE_PRECONDITION_FAILED_PREFIX
                        + String("update_if_unchanged: ")
                        + resource
                        + String(" (recreated since it was read)")
                    )
            raise Error(err)
        return FirestoreCommitResult(_update_time(resp))


# =============================================================================
# §3 — the writes.
# =============================================================================


def _update_write(
    name: String, fields: FsValue, var precondition: Optional[Precondition]
) raises -> Write:
    """An `update` write of the whole document `name` (no update mask)."""
    return Write(
        None,
        List[DocumentTransform_FieldTransform](),
        precondition^,
        WRITE_UPDATE,
        Document(name.copy(), fs_fields_to_v1(fields), None, None),
        None,
        None,
    )


def _delete_write(name: String) -> Write:
    return Write(
        None,
        List[DocumentTransform_FieldTransform](),
        None,
        WRITE_DELETE,
        None,
        name.copy(),
        None,
    )


def _update_time(resp: CommitResponse) raises -> String:
    """The first write's update time, else the commit time."""
    if len(resp.write_results) > 0 and resp.write_results[0].update_time:
        return resp.write_results[0].update_time.value().to_proto3_json()
    if resp.commit_time:
        return resp.commit_time.value().to_proto3_json()
    raise Error("FirestoreClient: the commit answered with no update time")


# =============================================================================
# §4 — production: Application Default Credentials.
# =============================================================================

comptime FIRESTORE_SCOPE: String = "https://www.googleapis.com/auth/datastore"
"""The OAuth scope of the Firestore API (Google's client libraries request
it; `cloud-platform` covers it too)."""

comptime FirestoreAdcTokenSource = CachingTokenSource[
    AdcFetcher[
        GcpConnectorTransport[KernelTcpConnector],
        GcpConnectorTransport[TlsConnector[KernelTcpConnector]],
        SystemWallClock,
    ],
    SystemClock,
]
"""The token source `firestore_adc_token_source` returns."""

comptime FirestoreCloudClient = FirestoreClient[
    TlsConnector[KernelTcpConnector], FirestoreAdcTokenSource
]
"""A client of firestore.googleapis.com authenticated by Application Default
Credentials (`firestore_cloud_client`)."""


def _mk_plain() raises -> KernelTcpConnector:
    return KernelTcpConnector.new()


def _mk_token_tls() raises -> TlsConnector[KernelTcpConnector]:
    return build_public_ca_tls_connector(String("oauth2.googleapis.com"))


def firestore_quota_project_headers(quota_project_id: String) raises -> HeaderMap:
    """The headers that bill a request to `quota_project_id`:
    `x-goog-user-project`, or none when it is "" (the metadata server's
    credentials, or a file that names none)."""
    var headers = HeaderMap()
    if quota_project_id.byte_length() > 0:
        headers.append(String("x-goog-user-project"), quota_project_id.copy())
    return headers^


def firestore_adc_options() -> AdcOptions:
    """The ADC options for Firestore: its scope, for a credential that mints
    a scoped token (a service-account key or the metadata server)."""
    var scopes = List[String]()
    scopes.append(String(FIRESTORE_SCOPE))
    return AdcOptions(scopes^)


def firestore_adc_token_source(
    http_config: HttpClientConfig,
) raises -> FirestoreAdcTokenSource:
    """The production token source: komira_gcp_core's Application Default
    Credentials, searched in Google's order now, the first token fetched on
    the first request and refreshed before it expires. `http_config` bounds
    the token fetches. Raises when the search finds nothing it can use."""
    return application_default_token_source[
        KernelTcpConnector, TlsConnector[KernelTcpConnector]
    ](http_config, _mk_plain, _mk_token_tls, firestore_adc_options())


def firestore_cloud_client(
    var project: String, var database: String, http_config: HttpClientConfig
) raises -> FirestoreCloudClient:
    """A client of firestore.googleapis.com for `project`/`database`, sending
    over public-CA TLS with `http_config`, its bearer from
    `firestore_adc_token_source(http_config)`. A credentials file's
    `quota_project_id` is sent as `x-goog-user-project` on every request,
    as Google's libraries send it: Firestore refuses user credentials
    (`gcloud auth application-default login`) that name no quota
    project."""
    var http = HttpClient[TlsConnector[KernelTcpConnector]](
        config=http_config,
        connector=build_public_ca_tls_connector(String(FIRESTORE_HOST)),
    )
    var tokens = firestore_adc_token_source(http_config)
    var headers = firestore_quota_project_headers(
        tokens.fetcher().quota_project_id()
    )
    return FirestoreCloudClient(http^, project^, database^, tokens^, headers^)
