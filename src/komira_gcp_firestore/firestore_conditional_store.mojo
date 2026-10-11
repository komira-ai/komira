# =============================================================================
# komira_gcp_firestore/firestore_conditional_store.mojo —
#   FirestoreConditionalStore[T], the Firestore-backed `ConditionalWriteStore`
#   conformer.
# =============================================================================
#
# WHAT THIS IS FOR. A consumer written generically over ONE
# `ConditionalWriteStore` typically needs one of two OPPOSITE write policies per
# keyspace:
#
#   <collection>/<id>  LAST-WRITER-WINS    head + CAS on the returned etag,
#                                          retry once on 412
#   <collection>/<id>  CREATE-OR-CONFLICT  create-if-absent; a 412 means some
#                                          OTHER writer got there first, and is
#                                          a REFUSAL
#
# Five conformers existed (InMemory / SharedInMemory / DelimiterFaithful /
# LocalFs / GcsGrpc) and none was over Firestore, so such a consumer had no
# Firestore store to bind. This is that store.
#
# ⭐ BOTH POLICIES ARE ALREADY FIRESTORE PRIMITIVES, and that is why this
# conformer is thin. `FirestoreClient` has carried the two atomic `:commit`
# preconditions:
#
#   trait verb                              Firestore `:commit` precondition
#   --------------------------------------  ---------------------------------
#   conditional_put(If-None-Match: *)       currentDocument {"exists": false}
#   compare_and_swap(If-Match: <version>)   currentDocument {"updateTime": "<t>"}
#   put (unconditional)                     a commit with no precondition (upsert)
#
# NOTHING here re-implements a CAS. The work is the TAXONOMY, which lives next
# door in `firestore_store_errors.mojo` — read that file's header before
# changing any `except` arm in this one.
#
# =============================================================================
# THE CAS HANDLE IS THE `updateTime`, AND IT GOES IN `etag` — NOT ONLY `version`.
# =============================================================================
#
# Firestore's per-document version IS its server-assigned `updateTime`, an
# RFC-3339 string. The trait's CAS token is the OPAQUE handle a backend both
# PRODUCES (in `ObjectMeta`) and CONSUMES (in `WritePrecondition.if_match`), and
# the field every caller threads is `etag`:
#
#     a last-writer-wins publish:
#         var meta = store.head(path)
#         cur_etag = Optional[String](meta.etag)         # <-- etag, not version
#         ... store.compare_and_swap(path, bytes, cur_etag.value())
#
# So `head()` putting the updateTime in `version` and leaving `etag` empty would
# make every last-writer-wins publish CAS against `""`, and the manifest head
# would silently stop advancing. BOTH fields carry the updateTime here, with
# the `etag`-is-authoritative rule.
#
# =============================================================================
# THE KEY MAPPING: an object key IS a Firestore document path.
# =============================================================================
#
#     item/api                  -> collection `item`,     document `api`
#     owner/gcp.svc_40x.com     -> collection `owner`,    document `gcp.svc_40x.com`
#
# The split is at the LAST `/`, and the key must have an EVEN number of
# segments. That is not a consumer-shaped assumption — it is Firestore's own
# rule: a path alternates collection/document, so an odd count names a
# COLLECTION and there is no document there to read or write. A 4-segment key
# (`a/b/c/d`) is an ordinary sub-collection document and works unchanged.
#
# ⛔ A KEY THAT CANNOT BE A DOCUMENT IS A REFUSAL, NOT A GUESS. No escaping, no
# flattening, no synthesised segment. A conformer that silently rewrites the key
# it was handed makes `list_with_delimiter` return something the caller cannot
# feed back to `get`, which is a failure a consumer that strips its own key
# prefix back off would then surface a hundred lines away from its cause. `Path.parse` has already rejected
# `.` / `..` / empty segments before we are called, so what remains to check is
# the segment count, the 1500-byte id limit, and Firestore's reserved `__*__`
# form.
#
# =============================================================================
# THE VALUE IS A `stringValue` IN ONE FIELD — SO THE BYTES MUST BE PRINTABLE ASCII.
# =============================================================================
#
# A Firestore document is a field map, not a byte blob, so the object body needs
# a home. It gets exactly ONE field, `value`, holding a `stringValue`.
#
# ⚠ THIS CONFORMER THEREFORE REFUSES NON-PRINTABLE-ASCII BODIES, loudly, with a
# `StoreError[MALFORMED]`. Three reasons, in order of weight:
#
#   1. The general answer is `bytesValue`, which is BASE64 on the wire — and
#      base64 lives in `komira_encoding`, which is not in this package's dep
#      closure. A codec dependency for a payload class the
#      caller does not have is a cost with no buyer.
#   2. The payloads this conformer was built for are text BY CONSTRUCTION: a
#      URL is ASCII by RFC 3986, and a name is `[a-z0-9-]`. A consumer that
#      decodes stored bytes one CODEPOINT per byte while encoding UTF-8 is
#      already ASCII-only — a non-ASCII body would not survive that round trip
#      whatever this conformer did.
#   3. A `stringValue` is READABLE IN THE FIRESTORE CONSOLE, so an operator can
#      go from a bad read to the bytes that caused it; a base64 blob breaks that
#      loop for every value in the store to buy generality for a payload nobody
#      stores.
#
# Widening to `bytesValue` is a real option and it is an ADDITIVE one — a second
# field name with its own encode/decode — but it must arrive with the base64 dep
# and a decision about which field an existing document is read from. Do not do
# it by widening the ASCII check.
#
# =============================================================================
# Encapsulation discipline (CLAUDE.md hard bans) — all satisfied:
#   * ZERO UnsafePointer in any signature. Bytes flow as owned `List[UInt8]`.
#   * ZERO wildcard origins. The client is reached MUTABLY from immutable `self`
#     through `ArcPointer.__getitem__` — a CONCRETE tracked origin (the Arc's own
#     allocation), and NOT a byte-slab + `MutExternalOrigin` (the stale-origin
#     trap).
#   * ZERO `unsafe_from_address`, ZERO `take_pointee`, ZERO FFI.
# =============================================================================

from std.memory import ArcPointer

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_gcp_core import GcpTokenSource

from .firestore_client import (
    FixedBearer,
    FirestoreClient,
    FirestoreDocument,
    is_not_found_error,
)
from komira_http_core.transport.io_stream import Connector
from .firestore_store_errors import (
    STORE_KIND_MALFORMED,
    defuse_classifier_tokens,
    firestore_resource_uri,
    map_firestore_error_to_store_error,
    store_kind_to_http,
)
from .firestore_value import FS_T_STRING, FsValue
from komira_gcp_firestore_v1.query import (
    StructuredQuery,
    StructuredQuery_CollectionSelector,
    StructuredQuery_Order,
)


# =============================================================================
# §1 — Constants.
# =============================================================================

comptime FS_STORE_VALUE_FIELD: StaticString = "value"
"""The ONE document field holding the object body.

⛔ A COMPTIME CONSTANT, NEVER A CONSTRUCTOR PARAMETER — the same argument
a consumer makes for its key prefixes. A configurable field
name is a SECOND value composition, and two compositions over one database is
how a document written by one process becomes invisible to another with a green
deploy on both sides."""

comptime FS_MAX_DOCUMENT_ID_BYTES: Int = 1500
"""Firestore's document-id limit. Checked here so an over-long service name is a
refusal naming the limit, rather than a 400 from Google three layers down."""


# =============================================================================
# §2 — Key mapping: an object key <-> a Firestore document path.
# =============================================================================


def _store_error(kind: String, what: String) -> Error:
    """A locally-raised `StoreError[<KIND>] ... status=<http>`.

    ⚠ `what` IS DEFUSED. It embeds the caller's key, and a key containing `404`
    would otherwise make a refusal read as an absent object to a consumer's
    substring not-found classifier. Same rule as
    `map_firestore_error_to_store_error`; see that module's header."""
    var msg = String("StoreError[")
    msg += kind
    msg += String("] ")
    msg += defuse_classifier_tokens(what)
    msg += String(" status=")
    msg += String(store_kind_to_http(kind))
    return Error(msg)


def _split_key_segments(key: String) raises -> List[String]:
    """Split a normalized object key on `/`. `Path.parse` has already collapsed
    `//`, stripped the leading `/` and rejected `.`/`..`, so this is a plain
    split; an empty segment here would mean the caller bypassed `Path`.

    Each segment is a byte slice of `key`: `/` is ASCII, so every cut is a char
    boundary and a multi-byte UTF-8 character stays whole."""
    var bs = key.as_bytes()
    var out = List[String]()
    var start = 0
    for i in range(len(bs)):
        if bs[i] == UInt8(47):  # '/'
            out.append(String(key[byte=start:i]))
            start = i + 1
    out.append(String(key[byte=start : len(bs)]))
    return out^


def validate_firestore_id(seg: String, key: String) raises:
    """REFUSE a path segment Firestore cannot hold as a collection or document
    id: empty, over 1500 bytes, or the reserved `__…__` form.

    (`.` and `..` are rejected upstream by `Path.parse`, and `/` cannot occur
    because this is called per-segment.)"""
    if seg.byte_length() == 0:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("object key '") + key + String(
                "' has an EMPTY path segment; Firestore has no id for it"
            ),
        )
    if seg.byte_length() > FS_MAX_DOCUMENT_ID_BYTES:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("object key '") + key + String(
                "' has a segment of "
            ) + String(seg.byte_length()) + String(
                " bytes; Firestore ids are capped at "
            ) + String(FS_MAX_DOCUMENT_ID_BYTES),
        )
    var bs = seg.as_bytes()
    if (
        len(bs) >= 4
        and bs[0] == UInt8(95)
        and bs[1] == UInt8(95)
        and bs[len(bs) - 1] == UInt8(95)
        and bs[len(bs) - 2] == UInt8(95)
    ):
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("object key '") + key + String(
                "' has the segment '"
            ) + seg + String(
                "', which matches Firestore's RESERVED `__…__` id form"
            ),
        )


def split_document_path(key: String) raises -> List[String]:
    """`key` -> `[collection_path, document_id]`.

    THE SPLIT IS AT THE LAST `/` AND THE SEGMENT COUNT MUST BE EVEN. A Firestore
    path alternates collection / document, so an odd count names a COLLECTION —
    there is no document at it to `get`, `put` or CAS. Refusing is the only
    honest answer; see the module header on why nothing is silently rewritten."""
    var segs = _split_key_segments(key)
    if len(segs) < 2 or len(segs) % 2 != 0:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("object key '") + key + String(
                "' is not a Firestore DOCUMENT path: a document path has an EVEN"
                " number of segments (collection/document, collection/document/"
                "collection/document, …) and this one has "
            ) + String(len(segs)),
        )
    for i in range(len(segs)):
        validate_firestore_id(segs[i], key)
    var collection = String("")
    for i in range(len(segs) - 1):
        if i > 0:
            collection += String("/")
        collection += segs[i]
    var out = List[String]()
    out.append(collection^)
    out.append(String(segs[len(segs) - 1]))
    return out^


def collection_from_prefix(prefix: Path) raises -> String:
    """The collection id a `list_with_delimiter` prefix names.

    ⛔ ROOT IS REFUSED and a NESTED collection is refused. Firestore's
    `documents:runQuery` runs against ONE parent — the database root — so it can
    enumerate a TOP-LEVEL collection and nothing else; there is no
    list-all-collections verb on the document API at all. Answering an empty
    list for either would be a listing that silently omits everything, which is
    the worst possible failure for a reap pass."""
    var raw = prefix.raw()
    if raw.byte_length() == 0:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String(
                "list_with_delimiter over the ROOT prefix is refused: Firestore's"
                " document API has no list-all-collections verb, and an empty"
                " answer would be indistinguishable from an empty database. Name"
                " a collection, e.g. 'service/'"
            ),
        )
    # Drop the directory-hint trailing `/` that `Path` preserves.
    var bs = raw.as_bytes()
    var end = len(bs)
    if end > 0 and bs[end - 1] == UInt8(47):
        end -= 1
    var name = String(raw[byte=0:end])
    var segs = _split_key_segments(name)
    if len(segs) != 1:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("list_with_delimiter prefix '") + raw + String(
                "' names a NESTED collection. Firestore's documents:runQuery is"
                " rooted at the database, so only a TOP-LEVEL collection can be"
                " enumerated through this client"
            ),
        )
    validate_firestore_id(segs[0], raw)
    return String(segs[0])


def key_from_document_name(name: String) raises -> String:
    """Recover the object key from a Firestore resource name.

    `projects/p/databases/db/documents/service/api` -> `service/api`
    — i.e. everything after `/documents/`, which IS the object key by
    construction of `split_document_path`. Reading the key back off the SERVER's
    own name (rather than re-composing it from the request) is what makes
    `list_with_delimiter` return keys a caller can feed straight back to
    `get`."""
    var marker = String("/documents/")
    var at = name.find(marker)
    if at < 0:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("Firestore returned the document name '") + name + String(
                "', which carries no '/documents/' segment, so no object key can"
                " be recovered from it"
            ),
        )
    # The marker ends in ASCII `/`, so the cut is a char boundary: the key's
    # UTF-8 bytes as they are.
    return String(name[byte=at + marker.byte_length() : name.byte_length()])


# =============================================================================
# §3 — Value mapping: object bytes <-> the `value` stringValue.
# =============================================================================


def bytes_to_document_text(bytes: List[UInt8], key: String) raises -> String:
    """Object body -> the `value` field's string. REFUSES a byte outside
    printable ASCII — see the module header for why this conformer is
    text-valued and what the additive widening would look like."""
    var out = String("")
    for i in range(len(bytes)):
        var b = bytes[i]
        if b < UInt8(32) or b > UInt8(126):
            raise _store_error(
                String(STORE_KIND_MALFORMED),
                String("object body for key '") + key + String(
                    "' contains byte "
                ) + String(Int(b)) + String(
                    " at offset "
                ) + String(i) + String(
                    ", outside printable ASCII. This conformer stores a body as"
                    " a Firestore `stringValue`; a binary body needs the"
                    " `bytesValue` (base64) form, which this package's dep"
                    " closure does not carry"
                ),
            )
        out += chr(Int(b))
    return out^


def document_text_to_bytes(text: String) -> List[UInt8]:
    """The `value` field's string -> the object body bytes."""
    var b = text.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def document_body_fields(text: String) -> FsValue:
    """The single-field document `{"value": {"stringValue": "<text>"}}`."""
    var keys = List[String]()
    keys.append(String(FS_STORE_VALUE_FIELD))
    var values = List[FsValue]()
    values.append(FsValue.string(String(text)))
    return FsValue.map_of(keys^, values^)


def document_body_text(doc: FirestoreDocument, key: String) raises -> String:
    """Read the `value` field back out of a fetched document.

    ⚠ A DOCUMENT WITHOUT THE FIELD IS A REFUSAL, NOT AN EMPTY BODY. An empty
    body is a legitimate stored value (`put(path, [])`), so defaulting a missing
    field to `""` would make a document written by something else — or by a
    future field-name change — read as a successfully-stored empty object. That
    is a silent wrong answer where a refusal costs one log line."""
    if not doc.has_field(String(FS_STORE_VALUE_FIELD)):
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("the Firestore document at '") + key + String(
                "' carries no '"
            ) + String(FS_STORE_VALUE_FIELD) + String(
                "' field, so it was not written by this conformer and its body"
                " cannot be read"
            ),
        )
    var v = doc.get_field(String(FS_STORE_VALUE_FIELD))
    if v.type_tag != FS_T_STRING:
        raise _store_error(
            String(STORE_KIND_MALFORMED),
            String("the Firestore document at '") + key + String(
                "' has a non-string '"
            ) + String(FS_STORE_VALUE_FIELD) + String("' field"),
        )
    return v.as_string()


def _committed_meta(
    key: String, text: String, update_time: String
) -> ObjectMeta:
    """The `ObjectMeta` for a just-committed write. The server `updateTime` goes
    in BOTH `etag` and `version` — see the module header on why `etag` is the
    field that matters."""
    return ObjectMeta(
        location=String(key),
        size=Int64(text.byte_length()),
        etag=String(update_time),
        last_modified_unix_ms=Int64(-1),
        version=String(update_time),
    )


def _collection_scan(collection: String) -> StructuredQuery:
    """A bare scan of the top-level `collection`: no filter, no order, so it
    rides the automatic single-field index and never wants a composite one.
    Built as the generated message, so no JSON is written by hand."""
    var from_ = List[StructuredQuery_CollectionSelector]()
    from_.append(
        StructuredQuery_CollectionSelector(
            collection_id=collection.copy(), all_descendants=False
        )
    )
    return StructuredQuery(
        select=None,
        from_=from_^,
        where=None,
        order_by=List[StructuredQuery_Order](),
        start_at=None,
        end_at=None,
        offset=Int32(0),
        limit=None,
        find_nearest=None,
    )


# =============================================================================
# §4 — FirestoreConditionalStore[T].
# =============================================================================


struct FirestoreConditionalStore[
    C: Connector, S: GcpTokenSource = FixedBearer
](
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A `ConditionalWriteStore` over ONE Firestore database.

    Generic over the connector `C` exactly as `FirestoreClient` is, so the
    SAME conformer runs over TLS in production and over a `ScriptedConnector`
    (canned HTTP answers, ZERO sockets) under test — which is what makes the
    taxonomy testable hermetically: a test queues the literal 409 / 400 / 404
    envelope Google sends and asserts the `StoreError` this conformer emits
    for it.

    Construction:

        var store = FirestoreConditionalStore[ScriptedConnector](
            FirestoreClient[ScriptedConnector](
                connector^, project, database, bearer,
            ),
            database,
        )

    Encapsulation: the client is held behind `ArcPointer` and reached
    MUTABLY from immutable `self` via `ArcPointer.__getitem__` (a CONCRETE
    tracked origin — the Arc's own allocation), never a byte-slab + wildcard.
    The `mut self` on the client's verbs is real and load-bearing: it is what
    lets a long-lived handle's refreshing token source refetch a token before it
    expires, so a store that outlives one hour keeps working."""

    var _client: ArcPointer[FirestoreClient[Self.C, Self.S]]
    var _database: String

    def __init__(
        out self, var client: FirestoreClient[Self.C, Self.S], var database: String
    ):
        """Construct over a moved-in client. `database` is carried only to name
        the resource in a raised error (`firestore://<db>/<coll>/<doc>`) — the
        client already holds the one it dials, and this must be the same
        string."""
        self._client = ArcPointer[FirestoreClient[Self.C, Self.S]](client^)
        self._database = database^

    @always_inline
    def database(self) -> String:
        """The Firestore database this store is bound to."""
        return String(self._database)

    def client_ref(ref self) -> ref [self._client] FirestoreClient[Self.C, Self.S]:
        """Borrow the underlying client. Returns a reference rooted at the Arc —
        never a raw pointer."""
        return self._client[]

    # -------------------------------------------------------------------------
    # ObjectStore base-trait conformance.
    # -------------------------------------------------------------------------

    def head(self, path: Path) raises -> ObjectMeta:
        """Object size + CAS handle, no body — a Firestore GET of the document.

        ⚠ FIRESTORE HAS NO METADATA-ONLY READ. `GetObject` on GCS is a genuine
        HEAD; a Firestore document GET returns the whole document, so this costs
        a full read. It is kept as `head` rather than made to fail because a
        last-writer-wins publish (head + CAS) and a head-then-delete both
        need the ETAG and the EXISTS answer, and a store whose `head` raises
        cannot serve either."""
        var key = path.raw()
        var parts = split_document_path(key)
        var uri = firestore_resource_uri(self._database, parts[0], parts[1])
        try:
            ref client = self._client[]
            var doc = client.get_document(parts[0], parts[1])
            var text = document_body_text(doc, key)
            return ObjectMeta(
                location=String(key),
                size=Int64(text.byte_length()),
                etag=String(doc.update_time),
                last_modified_unix_ms=Int64(-1),
                version=String(doc.update_time),
            )
        except e:
            raise map_firestore_error_to_store_error(
                String("head"), uri, String(e)
            )

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        """Every document directly under a TOP-LEVEL collection, as objects whose
        `location` is the full object key.

        `common_prefixes` IS ALWAYS EMPTY, and that is a property of the store
        rather than an omission: an object key's `/` separates a collection from
        a document, so there is no such thing as a partial key under `service/`
        that is not itself a document. A sub-collection would be a 4-segment key,
        which `documents:runQuery` rooted at the database does not reach — and
        `collection_from_prefix` refuses to be asked for one rather than
        answering an empty list."""
        var collection = collection_from_prefix(prefix)
        var uri = firestore_resource_uri(
            self._database, collection, String("")
        )
        var docs: List[FirestoreDocument]
        try:
            ref client = self._client[]
            docs = client.run_structured_query(_collection_scan(collection))
        except e:
            raise map_firestore_error_to_store_error(
                String("list_with_delimiter"), uri, String(e)
            )
        var objects = List[ObjectMeta]()
        for i in range(len(docs)):
            var key = key_from_document_name(docs[i].name)
            # ⚠ A DOCUMENT THIS CONFORMER DID NOT WRITE IS LISTED WITH size=-1,
            # NOT REFUSED. `document_body_text` RAISES on a missing `value`
            # field — correctly, for a `get` — but a listing that aborts on one
            # foreign document cannot enumerate at all, and enumeration is what
            # the reap pass exists to do. `-1` is this file's established
            # unknown (`ObjectMeta.last_modified_unix_ms` uses it for exactly
            # this), so the anomaly is REPORTED rather than either hidden or
            # fatal, and any `get` of that key still refuses loudly.
            #
            # ⛔ The alternative was to raise here, and it fails for the WRONG
            # REASON: a caller enumerating keys reads only `location`, so a
            # foreign document would break a verb over a field that verb never
            # looks at.
            var size = Int64(-1)
            try:
                size = Int64(document_body_text(docs[i], key).byte_length())
            except:
                size = Int64(-1)
            objects.append(
                ObjectMeta(
                    location=String(key),
                    size=size,
                    etag=String(docs[i].update_time),
                    last_modified_unix_ms=Int64(-1),
                    version=String(docs[i].update_time),
                )
            )
        return ListResult(objects^, List[String]())

    def coalesce_policy(self) -> CoalescePolicy:
        """The standard default. Range coalescing is meaningless here — a
        document read is one request for the whole body — but the trait requires
        an answer and the default is the one every other conformer gives."""
        return CoalescePolicy.default()

    # -------------------------------------------------------------------------
    # ConditionalWriteStore verb set.
    # -------------------------------------------------------------------------

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        """PUT the body at `path` conditioned on `precond`.

          * create-if-absent  -> `:commit` with currentDocument {"exists":false}
          * if-match(version) -> `:commit` with currentDocument {"updateTime":…}
          * none              -> a commit with no precondition (upsert)

        Returns the committed `ObjectMeta` with the NEW updateTime in BOTH `etag`
        and `version`, so a caller can chain the next CAS without a re-read.

        ⚠ `WritePrecondition.if_none_match(<etag>)` — the MinIO exact-etag create
        variant — is served by the SAME `exists:false` precondition as the `*`
        form, because Firestore has no exact-version create. That is STRICTLY
        STRONGER than what the caller asked for (it refuses if any document is
        present, not only one at that version), so it can reject a write the
        caller expected to land but can never admit one it expected to be
        refused. `WritePrecondition.is_create()` already unifies the two arms."""
        var key = path.raw()
        var parts = split_document_path(key)
        var uri = firestore_resource_uri(self._database, parts[0], parts[1])
        var text = bytes_to_document_text(bytes, key)
        var fields = document_body_fields(text)

        if precond.is_create():
            try:
                ref client = self._client[]
                var res = client.create_if_absent(parts[0], parts[1], fields)
                return _committed_meta(key, text, res.update_time)
            except e:
                raise map_firestore_error_to_store_error(
                    String("conditional_put"), uri, String(e)
                )

        if precond.is_if_match():
            if precond.etag.byte_length() == 0:
                raise _store_error(
                    String(STORE_KIND_MALFORMED),
                    String(
                        "compare_and_swap on '"
                    ) + key + String(
                        "' was given an EMPTY version handle. Firestore's CAS"
                        " precondition is the document's server updateTime; pass"
                        " the `etag` returned by a prior write or by head()."
                        " Sending an empty one would be an INVALID_ARGUMENT that"
                        " reads like a lost race"
                    ),
                )
            try:
                ref client = self._client[]
                var res2 = client.update_if_unchanged(
                    parts[0], parts[1], fields, precond.etag
                )
                return _committed_meta(key, text, res2.update_time)
            except e:
                raise map_firestore_error_to_store_error(
                    String("compare_and_swap"), uri, String(e)
                )

        try:
            ref client = self._client[]
            var doc = client.patch_document(parts[0], parts[1], fields)
            return _committed_meta(key, text, doc.update_time)
        except e:
            raise map_firestore_error_to_store_error(
                String("put"), uri, String(e)
            )

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        """Write only if the document's current `updateTime` equals
        `expected_version`. On a stale handle this raises
        `StoreError[PRECONDITION] … status=412` — the signal a last-writer-wins
        caller retries on."""
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        """Unconditional create-or-overwrite."""
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get(self, path: Path) raises -> List[UInt8]:
        """The whole object body. An absent document raises
        `StoreError[NOT_FOUND] … status=404`, which is what a reader turns into
        an "absent" answer rather than a raise."""
        var key = path.raw()
        var parts = split_document_path(key)
        var uri = firestore_resource_uri(self._database, parts[0], parts[1])
        try:
            ref client = self._client[]
            var doc = client.get_document(parts[0], parts[1])
            return document_text_to_bytes(document_body_text(doc, key))
        except e:
            raise map_firestore_error_to_store_error(
                String("get"), uri, String(e)
            )

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        """`[start, start+length)` of the body.

        ⚠ THIS READS THE WHOLE DOCUMENT AND SLICES. Firestore has no ranged
        document read; there is no way to make this cheaper and pretending
        otherwise would be worse than saying so. A short read raises rather than
        returning fewer bytes, as `GcsConditionalStore.get_range` does."""
        if length <= Int64(0):
            return List[UInt8]()
        var body = self.get(path)
        var s = Int(start)
        var n = Int(length)
        if s < 0 or s + n > len(body):
            raise _store_error(
                String(STORE_KIND_MALFORMED),
                String("get_range on '") + path.raw() + String(
                    "': requested ["
                ) + String(s) + String(", ") + String(s + n) + String(
                    ") of a "
                ) + String(len(body)) + String("-byte object (short read)"),
            )
        var out = List[UInt8](capacity=n)
        for i in range(s, s + n):
            out.append(body[i])
        return out^

    def delete(self, path: Path) raises -> None:
        """DELETE the document. IDEMPOTENT — an absent document is a success, per
        the trait.

        ⚠ THE SWALLOW IS ON THE **TYPED** NOT-FOUND SENTINEL, tested BEFORE the
        error is mapped. `is_not_found_error` is a PREFIX test and the client's
        five sentinel prefixes are disjoint, so an absent DATABASE — an HTTP 404
        whose body says NOT_FOUND — cannot reach this arm. Deciding it after the
        mapping, or on a substring, would make `delete` return success against a
        database that does not exist."""
        var key = path.raw()
        var parts = split_document_path(key)
        var uri = firestore_resource_uri(self._database, parts[0], parts[1])
        try:
            ref client = self._client[]
            client.delete_document(parts[0], parts[1])
        except e:
            if is_not_found_error(String(e)):
                return
            raise map_firestore_error_to_store_error(
                String("delete"), uri, String(e)
            )
