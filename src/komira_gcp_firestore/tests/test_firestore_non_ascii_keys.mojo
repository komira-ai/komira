# =============================================================================
# test_firestore_non_ascii_keys.mojo — an object key or document id that is not
#   ASCII keeps its UTF-8 bytes through every helper that cuts one out of a
#   longer string: the object-key splitter (`split_document_path`), the list
#   prefix reader (`collection_from_prefix`), the listed-name reader
#   (`key_from_document_name`), the query's entry key (`DocumentStore.query`)
#   and the change feed's document id (`FirestoreWatchListener`); and the
#   key or prefix text a `StoreError` message carries (`defuse_classifier_tokens`,
#   under both `map_firestore_error_to_store_error` and a local refusal).
# =============================================================================
#
# The defect these cases catch: each helper once rebuilt the text one byte at a
# time with `chr(byte)`, which reads every UTF-8 byte as its own code point, so
# `é` (C3 A9) came back as `Ã©` (C3 83 C2 A9). An ASCII key round-trips either
# way, so every other test in the package passed over it.
#
# The ids hold a two-, a three- and a four-byte character each. Every case
# compares whole Strings (byte-equal) and, where a request is involved, reads
# the request the client wrote: a key that is mangled on the way OUT names a
# different document even when the answer is scripted to look right.
#
# `main` runs every case and reports each failure by name before it raises, so
# one run shows which of the six sites is wrong.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_firestore.document_store import (
    FirestoreDocumentStore,
    _last_path_segment,
)
from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore.firestore_conditional_store import (
    FirestoreConditionalStore,
    collection_from_prefix,
    key_from_document_name,
    split_document_path,
)
from komira_gcp_firestore.firestore_store_errors import (
    defuse_classifier_tokens,
    firestore_resource_uri,
    map_firestore_error_to_store_error,
)
from komira_gcp_firestore.firestore_listen_proto import (
    FsDocument,
    LE_DOCUMENT_CHANGE,
    LE_DOCUMENT_DELETE,
    LE_TARGET_CHANGE,
    ListenEvent,
    TCT_NO_CHANGE,
)
from komira_gcp_firestore.firestore_scripted import ScriptedFirestore
from komira_gcp_firestore.firestore_value import FsValue
from komira_gcp_firestore.firestore_watch_listener import (
    FIRESTORE_SEGMENT_ID,
    FirestoreWatchConfig,
    FirestoreWatchListener,
    ScriptedListenSource,
)
from komira_http_core.transport.scripted import ScriptedConnector
from komira_objectstore.path import Path
from komira_snapshotter.change_stream_trait import CDC_OP_MODIFY, CDC_OP_REMOVE


comptime _PROJECT: StaticString = "example-project"
comptime _DATABASE: StaticString = "example-db"
comptime _DOCS: StaticString = "projects/example-project/databases/example-db/documents/"

# Two-, three- and four-byte UTF-8 sequences in one id and one collection.
comptime _ID: StaticString = "é-1-漢-🙂"
comptime _COLL: StaticString = "tä漢🙂"
# What the per-byte `chr` rebuild makes of `é`: a request or key carrying this
# was mangled.
comptime _MANGLED_E: StaticString = "Ã©"


def _contains(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


def _scripted_store(
    mut t: ScriptedFirestore,
) raises -> FirestoreConditionalStore[ScriptedConnector]:
    var c = FirestoreClient[ScriptedConnector](
        t.take_connector(), String(_PROJECT), String(_DATABASE), String("test-bearer")
    )
    return FirestoreConditionalStore[ScriptedConnector](c^, String(_DATABASE))


def _doc_json(name: String, value: String) -> String:
    return (
        String('{"name":"')
        + name
        + String('","fields":{"value":{"stringValue":"')
        + value
        + String('"}},"updateTime":"2026-10-01T12:00:01.000000Z"}')
    )


# =============================================================================
# (1) `split_document_path` (via `_split_key_segments`): the collection path and
#     the document id of every get / put / CAS key.
# =============================================================================


def test_split_document_path_keeps_each_segment_utf8() raises:
    var key = String(_COLL) + "/" + String(_ID)
    var parts = split_document_path(key)
    assert_equal(len(parts), 2)
    assert_equal(parts[0], String(_COLL))
    assert_equal(parts[1], String(_ID))

    # A nested document: every segment, not only the last, is cut whole.
    var nested = String(_COLL) + "/é/漢/" + String(_ID)
    var np = split_document_path(nested)
    assert_equal(np[0], String(_COLL) + "/é/漢")
    assert_equal(np[1], String(_ID))

    # The 1500-byte id cap counts the id's own bytes, not a widened copy: a
    # 1500-byte id of two-byte characters is accepted (widened it is 3000).
    var big = String("")
    for _ in range(750):
        big += "é"
    assert_equal(big.byte_length(), 1500)
    var bp = split_document_path(String("t/") + big)
    assert_equal(bp[1], big)


def _refusal_of_split(key: String) -> String:
    try:
        _ = split_document_path(key)
    except e:
        return String(e)
    return String("")


def test_split_document_path_still_sees_an_empty_segment() raises:
    """The slices start after each `/` and the last one runs to the end, so an
    empty segment at either end or between two `/` is still an empty String,
    and `validate_firestore_id` refuses it naming the reason (a slice that
    swallowed the `/` would hand it a 1-byte "/" segment instead)."""
    var keys = List[String]()
    keys.append(String("t/"))
    keys.append(String("/t"))
    keys.append(String("t//x/y"))
    for i in range(len(keys)):
        var msg = _refusal_of_split(keys[i])
        assert_true(
            _contains(msg, String("EMPTY path segment")),
            keys[i] + " is refused for its empty segment, got: " + msg,
        )


# =============================================================================
# (2) `collection_from_prefix`: the collection a listing prefix names.
# =============================================================================


def test_collection_from_prefix_keeps_utf8() raises:
    assert_equal(
        collection_from_prefix(Path.parse(String(_COLL) + "/")), String(_COLL)
    )
    assert_equal(collection_from_prefix(Path.parse(String(_COLL))), String(_COLL))


# =============================================================================
# (3) `key_from_document_name`: the object key of a listed document.
# =============================================================================


def test_key_from_document_name_keeps_utf8() raises:
    var key = String(_COLL) + "/" + String(_ID)
    assert_equal(key_from_document_name(String(_DOCS) + key), key)

    # A name without the marker is refused, not cut at some other offset.
    var refused = String("")
    try:
        _ = key_from_document_name(String("projects/p/") + key)
    except e:
        refused = String(e)
    assert_true(
        _contains(refused, String("no '/documents/' segment")),
        "a name without /documents/ is refused, got: " + refused,
    )


# =============================================================================
# (1)+(2)+(3) end to end on the conditional store: the request names the
#     document (or collection) byte for byte, and a listed key feeds back.
# =============================================================================


def test_get_sends_the_document_name_byte_for_byte() raises:
    var key = String(_COLL) + "/" + String(_ID)
    var full = String(_DOCS) + key
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        String('[{"found":')
        + _doc_json(full, String("v"))
        + String(',"readTime":"2026-10-01T12:00:00Z"}]'),
    )
    var store = _scripted_store(t)
    var body = store.get(Path.parse(key))
    assert_equal(len(body), 1)
    var sent = t.call_text(0)
    assert_true(_contains(sent, full), "the BatchGet names " + full)
    assert_false(_contains(sent, String(_MANGLED_E)), "no widened byte is sent")


def test_list_scans_the_collection_and_returns_utf8_keys() raises:
    var key = String(_COLL) + "/" + String(_ID)
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        String('[{"document":')
        + _doc_json(String(_DOCS) + key, String("v"))
        + String(',"readTime":"2026-10-01T12:00:00Z"}]'),
    )
    var store = _scripted_store(t)
    var res = store.list_with_delimiter(Path.parse(String(_COLL) + "/"))
    var sent = t.call_text(0)
    assert_true(
        _contains(sent, String('"collectionId":"') + String(_COLL) + '"'),
        "the RunQuery scans " + String(_COLL),
    )
    assert_false(_contains(sent, String("Ã")), "no widened byte is sent")
    assert_equal(len(res.objects), 1)
    assert_equal(res.objects[0].location, key)
    assert_equal(res.objects[0].size, Int64(1))


# =============================================================================
# (4) `DocumentStore.query` (via `_last_path_segment`): each entry's key.
# =============================================================================


def test_document_store_query_key_keeps_utf8() raises:
    var t = ScriptedFirestore()
    t.queue_response(
        200,
        String('[{"document":{"name":"')
        + String(_DOCS)
        + String("profiles/")
        + String(_ID)
        + String('","fields":{"email":{"stringValue":"u1@example.test"}}},')
        + String('"readTime":"2026-10-01T00:00:01Z"}]'),
    )
    var store = FirestoreDocumentStore[ScriptedConnector](
        t.take_connector(), String(_PROJECT), String(_DATABASE), String("test-bearer")
    )
    var entries = store.query(
        String("profiles"), String('{"from":[{"collectionId":"profiles"}]}')
    )
    assert_equal(len(entries), 1)
    assert_equal(entries[0].key, String(_ID))


def test_last_path_segment_edges() raises:
    """The helper under `query`: a name with no `/` is its own id, a trailing
    `/` gives the empty id, and the cut after the last `/` keeps the id whole."""
    assert_equal(_last_path_segment(String(_ID)), String(_ID))
    assert_equal(_last_path_segment(String("coll/")), String(""))
    assert_equal(_last_path_segment(String("é/") + String(_ID)), String(_ID))


# =============================================================================
# (5) `FirestoreWatchListener` (via `_extract_document_id`): the change feed's
#     key column for a change and for a delete.
# =============================================================================


def _watch_config() -> FirestoreWatchConfig:
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("title"))
    return FirestoreWatchConfig(cols^, String("id"))


def test_watch_listener_reports_the_utf8_document_id() raises:
    var name = String(_DOCS) + "coll/" + String(_ID)
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("title"))
    vals.append(FsValue.string(String("t")))
    var events = List[ListenEvent]()
    events.append(
        ListenEvent(
            LE_DOCUMENT_CHANGE,
            -1,
            FsDocument(name.copy(), FsValue.map_of(keys^, vals^)),
            True,
        )
    )
    events.append(
        ListenEvent(
            LE_DOCUMENT_DELETE,
            -1,
            FsDocument(name.copy(), FsValue.map_of(List[String](), List[FsValue]())),
            True,
        )
    )
    # The snapshot boundary: `poll` holds a drain's records until a resumable
    # TargetChange closes it.
    var token = List[UInt8]()
    token.append(UInt8(0xAA))
    events.append(
        ListenEvent(
            LE_TARGET_CHANGE,
            TCT_NO_CHANGE,
            FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]())),
            False,
            token^,
            True,
            Int64(1_800_000_000),
            Int64(5),
            True,
        )
    )
    var listener = FirestoreWatchListener[ScriptedListenSource](
        ScriptedListenSource(events^), _watch_config()
    )
    var cursor = listener.open_shard(String(FIRESTORE_SEGMENT_ID), String(""))
    var batch = listener.poll(cursor)
    assert_equal(len(batch.records), 2)
    assert_equal(batch.records[0].op, CDC_OP_MODIFY)
    assert_equal(batch.records[0].key[0].as_string(), String(_ID))
    assert_equal(batch.records[0].new_image[0].as_string(), String(_ID))
    assert_equal(batch.records[1].op, CDC_OP_REMOVE)
    assert_equal(batch.records[1].key[0].as_string(), String(_ID))


# =============================================================================
# (6) `defuse_classifier_tokens`: the key, prefix or resource text every
#     StoreError message carries. It is copied unchanged apart from the bracket
#     the defuser puts into a classifier token.
# =============================================================================


def test_defuser_copies_non_ascii_text_unchanged() raises:
    var key = String(_COLL) + "/" + String(_ID)
    assert_equal(defuse_classifier_tokens(key), key)
    # A token next to a multi-byte character on either side is still defused,
    # and the characters around it stay whole.
    assert_equal(
        defuse_classifier_tokens(String("é404漢")), String("é4[0]4漢")
    )
    assert_equal(
        defuse_classifier_tokens(String("🙂NotFound") + String(_ID)),
        String("🙂N[o]tFound") + String(_ID),
    )
    assert_equal(
        defuse_classifier_tokens(String("ä412")), String("ä4[1]2")
    )


def test_mapped_error_names_the_utf8_resource() raises:
    """`map_firestore_error_to_store_error` joins the op, the resource URI and
    the client's error and defuses the join: the URI's key and the key quoted
    in the client's error come out byte for byte."""
    var key = String(_COLL) + "/" + String(_ID)
    var uri = firestore_resource_uri(String(_DATABASE), String(_COLL), String(_ID))
    var err = (
        String("get_document: ")
        + key
        + String(
            " (POST BatchGetDocuments: HTTP 403, PERMISSION_DENIED (code 7),"
            " body 0 bytes)"
        )
    )
    var msg = String(map_firestore_error_to_store_error(String("get"), uri, err))
    assert_true(_contains(msg, String("StoreError[PERMISSION_DENIED]")), msg)
    assert_true(_contains(msg, uri), "the message names " + uri + ", got: " + msg)
    assert_true(
        _contains(msg, String("get_document: ") + key),
        "the client's text keeps the key, got: " + msg,
    )
    assert_false(_contains(msg, String(_MANGLED_E)), "no widened byte: " + msg)

    # A key holding a token next to a non-ASCII character: the token is
    # defused, the character around it is not widened.
    var uri404 = firestore_resource_uri(String(_DATABASE), String(_COLL), String("é404"))
    var msg404 = String(
        map_firestore_error_to_store_error(String("get"), uri404, err)
    )
    assert_true(
        _contains(msg404, String("/é4[0]4 ")),
        "the token is defused in place, got: " + msg404,
    )
    assert_false(_contains(msg404, String("404")), "no live 404: " + msg404)
    assert_false(_contains(msg404, String(_MANGLED_E)), "no widened byte: " + msg404)


def test_local_refusal_names_the_utf8_prefix() raises:
    """A locally raised refusal (`_store_error`) quotes the caller's prefix
    byte for byte."""
    var prefix = String(_COLL) + "/" + String(_ID) + "/"
    var t = ScriptedFirestore()
    var store = _scripted_store(t)
    var msg = String("")
    try:
        _ = store.list_with_delimiter(Path.parse(prefix))
    except e:
        msg = String(e)
    assert_true(_contains(msg, String("StoreError[MALFORMED]")), msg)
    assert_true(_contains(msg, String("NESTED collection")), msg)
    assert_true(
        _contains(msg, String("prefix '") + prefix + String("'")),
        "the refusal quotes " + prefix + ", got: " + msg,
    )
    assert_false(_contains(msg, String(_MANGLED_E)), "no widened byte: " + msg)


def main() raises:
    var failed = List[String]()

    try:
        test_split_document_path_keeps_each_segment_utf8()
    except e:
        failed.append("test_split_document_path_keeps_each_segment_utf8: " + String(e))
    try:
        test_split_document_path_still_sees_an_empty_segment()
    except e:
        failed.append(
            "test_split_document_path_still_sees_an_empty_segment: " + String(e)
        )
    try:
        test_collection_from_prefix_keeps_utf8()
    except e:
        failed.append("test_collection_from_prefix_keeps_utf8: " + String(e))
    try:
        test_key_from_document_name_keeps_utf8()
    except e:
        failed.append("test_key_from_document_name_keeps_utf8: " + String(e))
    try:
        test_get_sends_the_document_name_byte_for_byte()
    except e:
        failed.append("test_get_sends_the_document_name_byte_for_byte: " + String(e))
    try:
        test_list_scans_the_collection_and_returns_utf8_keys()
    except e:
        failed.append(
            "test_list_scans_the_collection_and_returns_utf8_keys: " + String(e)
        )
    try:
        test_document_store_query_key_keeps_utf8()
    except e:
        failed.append("test_document_store_query_key_keeps_utf8: " + String(e))
    try:
        test_last_path_segment_edges()
    except e:
        failed.append("test_last_path_segment_edges: " + String(e))
    try:
        test_watch_listener_reports_the_utf8_document_id()
    except e:
        failed.append("test_watch_listener_reports_the_utf8_document_id: " + String(e))
    try:
        test_defuser_copies_non_ascii_text_unchanged()
    except e:
        failed.append("test_defuser_copies_non_ascii_text_unchanged: " + String(e))
    try:
        test_mapped_error_names_the_utf8_resource()
    except e:
        failed.append("test_mapped_error_names_the_utf8_resource: " + String(e))
    try:
        test_local_refusal_names_the_utf8_prefix()
    except e:
        failed.append("test_local_refusal_names_the_utf8_prefix: " + String(e))

    for i in range(len(failed)):
        print("FAIL " + failed[i])
    if len(failed) > 0:
        raise Error(String(len(failed)) + " of 12 cases failed")
    print("test_firestore_non_ascii_keys: 12 cases passed")
