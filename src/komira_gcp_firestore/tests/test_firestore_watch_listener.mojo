# =============================================================================
# test_firestore_watch_listener.mojo — falsifier: the FirestoreWatch
#   Listener conformer maps ListenEvents -> ChangeRecords (scripted, no network).
# =============================================================================
#
# CDC-Firestore ChangeSource. The FirestoreWatchListener conforms to
# BOTH `ChangeStreamListener` + `MultiShardChangeStreamListener` (like the
# DynamoDbStreamsListener), wrapping a Firestore Listen SOURCE. It is generic over
# the source so a SCRIPTED source drives it offline (mirrors how the DynamoDb
# listener is driven by a ScriptedDynamoTransport). Its poll(cursor):
#   * drains buffered ListenEvents from the source;
#   * DocumentChange -> a MODIFY ChangeRecord (Firestore doesn't distinguish
#     create/update; equality-delete+append IS upsert-safe), mapping the doc
#     fields onto RowCells via fs_fields_to_row_cells + extracting the KEY cell(s)
#     by key-column name from the doc id;
#   * DocumentDelete / DocumentRemove -> a REMOVE ChangeRecord (key only);
#   * threads the composite (read_time, resume_token) cursor from the batch's
#     resumable TargetChange into next_cursor;
#   * stamps each record's sequence_number = the normalized read_time.
#
# THE FALSIFIERS (analog of test_cdc_ingest_dynamodb_multishard):
#   (1) A DocumentChange decodes to a MODIFY ChangeRecord: op=MODIFY, the KEY cell
#       is the extracted document id, the new_image is the fields projected onto
#       the schema columns.
#   (2) A DocumentDelete decodes to a REMOVE ChangeRecord: op=REMOVE, the KEY cell
#       is the document id, new_image empty. The key tuple is FULL-SCHEMA-WIDTH so
#       the apply's _project_key can position it.
#   (3) The composite cursor is THREADED: after a batch terminated by a resumable
#       TargetChange, next_cursor decodes back to that TargetChange's read_time +
#       resume_token, and each record's sequence_number == the normalized
#       read_time.
#   (4) list_shard_ids returns exactly ONE synthetic segment; open_shard threads
#       the after-cursor into the source's open_watch.
#
# FAILS ON CURRENT CODE (pre-fix): FirestoreWatchListener / the
# FirestoreListenSource seam / the extraction helpers do not exist -> this file
# does not COMPILE.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_snapshotter.change_stream_trait import (
    ChangeRecord,
    ChangeBatch,
    CDC_OP_MODIFY,
    CDC_OP_REMOVE,
)

# The cell model, from the zero-dep leaf. This test used to import
# `ICE_T_STRING / ICE_T_LONG / IcebergSchema / RowCell` from `komira_iceberg`;
# it needs only the cell, and the target no longer links the Iceberg graph.
from komira_rowcell import RowCell


from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    FsDocument,
    LE_TARGET_CHANGE,
    LE_DOCUMENT_CHANGE,
    LE_DOCUMENT_DELETE,
    TCT_NO_CHANGE,
)
from komira_gcp_firestore.firestore_value import FsValue
from komira_gcp_firestore.firestore_cdc_cursor import (
    read_time_to_sequence,
    decode_firestore_cursor,
)
from komira_gcp_firestore.firestore_watch_listener import (
    FirestoreWatchListener,
    FirestoreListenSource,
    ScriptedListenSource,
    FirestoreWatchConfig,
    FIRESTORE_SEGMENT_ID,
)


# -----------------------------------------------------------------------------
# Fixtures: a (id string PK, title string, count long) schema. The document id
# (last path segment) is the KEY column "id".
# -----------------------------------------------------------------------------


def _config() -> FirestoreWatchConfig:
    var cols = List[String]()
    cols.append(String("id"))
    cols.append(String("title"))
    cols.append(String("count"))
    # key column = "id" (the document id), extracted from the doc's resource name.
    return FirestoreWatchConfig(cols^, String("id"))


def _doc_change(doc_id: String, var title: String, count: Int64) -> ListenEvent:
    """A DocumentChange ListenEvent for a doc `<...>/documents/coll/<doc_id>`
    with fields {title, count}."""
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("title"))
    vals.append(FsValue.string(title^))
    keys.append(String("count"))
    vals.append(FsValue.integer(String(count)))
    var fields = FsValue.map_of(keys^, vals^)
    var name = String("projects/p/databases/d/documents/coll/") + doc_id
    return ListenEvent(
        LE_DOCUMENT_CHANGE, -1, FsDocument(name^, fields^), True
    )


def _doc_delete(doc_id: String) -> ListenEvent:
    """A DocumentDelete ListenEvent for `<...>/documents/coll/<doc_id>`."""
    var name = String("projects/p/databases/d/documents/coll/") + doc_id
    return ListenEvent(
        LE_DOCUMENT_DELETE, -1,
        FsDocument(name^, FsValue.map_of(List[String](), List[FsValue]())),
        True,
    )


def _target_change_resumable(
    var resume_token: List[UInt8], read_seconds: Int64, read_nanos: Int64
) -> ListenEvent:
    """A resumable TargetChange(NO_CHANGE) carrying a resume_token + read_time
    (the CDC checkpoint boundary)."""
    return ListenEvent(
        LE_TARGET_CHANGE, TCT_NO_CHANGE,
        FsDocument(String(""), FsValue.map_of(List[String](), List[FsValue]())),
        False,
        resume_token^,
        True,
        read_seconds,
        read_nanos,
        True,
    )


# =============================================================================
# (1) DocumentChange -> MODIFY ChangeRecord.
# =============================================================================
def test_document_change_maps_to_modify() raises:
    print("  test_document_change_maps_to_modify...")
    var events = List[ListenEvent]()
    events.append(_doc_change(String("doc1"), String("Hello"), Int64(42)))
    var token = List[UInt8]()
    token.append(UInt8(0xAA))
    events.append(_target_change_resumable(token^, Int64(1_800_000_000), Int64(5)))

    var source = ScriptedListenSource(events^)
    var listener = FirestoreWatchListener[ScriptedListenSource](
        source^, _config()
    )
    var cursor = listener.open_shard(String(FIRESTORE_SEGMENT_ID), String(""))
    var batch = listener.poll(cursor)

    assert_equal(len(batch.records), 1, "one DocumentChange -> one record")
    ref rec = batch.records[0]
    assert_equal(rec.op, CDC_OP_MODIFY, "DocumentChange -> MODIFY (upsert-safe)")
    # KEY cell = the extracted doc id, positioned at the "id" column (index 0).
    assert_equal(len(rec.key), 3, "key tuple is FULL-schema-width")
    assert_equal(rec.key[0].as_string(), String("doc1"), "key[0] = doc id")
    # new_image = fields projected onto (id, title, count).
    assert_equal(len(rec.new_image), 3, "new_image full-width")
    assert_equal(rec.new_image[0].as_string(), String("doc1"), "id in new_image")
    assert_equal(rec.new_image[1].as_string(), String("Hello"), "title")
    assert_equal(rec.new_image[2].as_long(), Int64(42), "count")
    print("    OK")


# =============================================================================
# (2) DocumentDelete -> REMOVE ChangeRecord (key full-width).
# =============================================================================
def test_document_delete_maps_to_remove() raises:
    print("  test_document_delete_maps_to_remove...")
    var events = List[ListenEvent]()
    events.append(_doc_delete(String("gone7")))
    var token = List[UInt8]()
    token.append(UInt8(0xBB))
    events.append(_target_change_resumable(token^, Int64(1_800_000_100), Int64(0)))

    var source = ScriptedListenSource(events^)
    var listener = FirestoreWatchListener[ScriptedListenSource](
        source^, _config()
    )
    var cursor = listener.open_shard(String(FIRESTORE_SEGMENT_ID), String(""))
    var batch = listener.poll(cursor)

    assert_equal(len(batch.records), 1, "one DocumentDelete -> one record")
    ref rec = batch.records[0]
    assert_equal(rec.op, CDC_OP_REMOVE, "DocumentDelete -> REMOVE")
    assert_equal(len(rec.key), 3, "key tuple FULL-schema-width (for _project_key)")
    assert_equal(rec.key[0].as_string(), String("gone7"), "key[0] = doc id")
    assert_equal(len(rec.new_image), 0, "REMOVE has empty new_image")
    print("    OK")


# =============================================================================
# (3) The composite cursor + sequence_number threaded from the TargetChange.
# =============================================================================
def test_cursor_and_sequence_threaded_from_target_change() raises:
    print("  test_cursor_and_sequence_threaded_from_target_change...")
    var events = List[ListenEvent]()
    events.append(_doc_change(String("a"), String("A"), Int64(1)))
    events.append(_doc_change(String("b"), String("B"), Int64(2)))
    var token = List[UInt8]()
    token.append(UInt8(0x01))
    token.append(UInt8(0x02))
    token.append(UInt8(0x03))
    events.append(
        _target_change_resumable(token^, Int64(1_800_777_000), Int64(123_456_000))
    )

    var source = ScriptedListenSource(events^)
    var listener = FirestoreWatchListener[ScriptedListenSource](
        source^, _config()
    )
    var cursor = listener.open_shard(String(FIRESTORE_SEGMENT_ID), String(""))
    var batch = listener.poll(cursor)

    assert_equal(len(batch.records), 2, "two DocumentChanges")

    # next_cursor decodes back to the TargetChange's read_time + resume_token.
    var d = decode_firestore_cursor(batch.next_cursor)
    assert_true(d.has_position, "batch produced a resumable cursor")
    assert_equal(d.read_time_seconds, Int64(1_800_777_000), "cursor read_time seconds")
    assert_equal(d.read_time_nanos, Int64(123_456_000), "cursor read_time nanos")
    assert_equal(len(d.resume_token), 3, "cursor resume_token bytes")
    assert_equal(Int(d.resume_token[0]), 0x01)
    assert_equal(Int(d.resume_token[2]), 0x03)

    # Each record's sequence_number == the normalized batch read_time.
    var expected_seq = read_time_to_sequence(Int64(1_800_777_000), Int64(123_456_000))
    assert_equal(batch.records[0].sequence_number, expected_seq, "rec0 seq")
    assert_equal(batch.records[1].sequence_number, expected_seq, "rec1 seq")

    # The batch's read_time orders AFTER an older committed position (fixed-width
    # sequences: byte order is numeric order).
    var older = read_time_to_sequence(Int64(1_800_000_000), Int64(0))
    assert_true(batch.records[0].sequence_number > older, "batch newer than older")
    print("    OK")


# =============================================================================
# (4) Single synthetic segment; open_shard threads the after-cursor.
# =============================================================================
def test_single_segment_and_open_threads_cursor() raises:
    print("  test_single_segment_and_open_threads_cursor...")
    var events = List[ListenEvent]()
    var source = ScriptedListenSource(events^)
    var listener = FirestoreWatchListener[ScriptedListenSource](
        source^, _config()
    )
    var segs = listener.list_shard_ids()
    assert_equal(len(segs), 1, "exactly one synthetic segment")
    assert_equal(segs[0], String(FIRESTORE_SEGMENT_ID), "the fixed segment id")

    # open_shard threads the after-cursor into the source's recorded open.
    var after = String("000001800000000000000000042|aabb")
    _ = listener.open_shard(String(FIRESTORE_SEGMENT_ID), after)
    ref src = listener.source_ref()
    assert_equal(
        src.opened_after(),
        after,
        "open_shard threads the after-cursor into open_watch",
    )
    print("    OK")


# =============================================================================
# (5) MALFORMED RESOURCE NAME: an empty/id-less document name is REJECTED.
#
# A DocumentChange whose document.name is empty (or lacks a trailing '/id'
# segment) has NO document id -> NO primary key. Building a key row from an empty
# id would inject an EMPTY-STRING primary-key cell, and an empty-string PK
# equality-collides with any OTHER malformed doc (they'd all share PK "") — the
# equality-delete would then mask the WRONG rows (a silent data-corruption class,
# same family as the FF-1 canonical-decimal fix). The listener must FAIL LOUD
# instead: _extract_document_id raises on an empty id so a malformed push aborts
# the batch rather than corrupting the table with a colliding empty PK.
#
# FAILS ON CURRENT CODE (pre-FIX-2): _extract_document_id returned "" for an empty
# name and _build_key_row happily injected an empty-string PK cell — the mapping
# did NOT raise. This test asserts it now raises.
# =============================================================================
def test_empty_document_name_is_rejected() raises:
    print("  test_empty_document_name_is_rejected...")
    # A DocumentChange with an EMPTY resource name (no id segment).
    var keys = List[String]()
    var vals = List[FsValue]()
    keys.append(String("title"))
    vals.append(FsValue.string(String("Orphan")))
    var fields = FsValue.map_of(keys^, vals^)
    var bad = ListenEvent(
        LE_DOCUMENT_CHANGE, -1, FsDocument(String(""), fields^), True
    )
    var events = List[ListenEvent]()
    events.append(bad^)
    var token = List[UInt8]()
    token.append(UInt8(0xCC))
    events.append(_target_change_resumable(token^, Int64(1_800_000_200), Int64(0)))

    var source = ScriptedListenSource(events^)
    var listener = FirestoreWatchListener[ScriptedListenSource](
        source^, _config()
    )
    var cursor = listener.open_shard(String(FIRESTORE_SEGMENT_ID), String(""))

    var raised = False
    try:
        _ = listener.poll(cursor)
    except e:
        raised = True
    assert_true(
        raised,
        "a DocumentChange with an empty (id-less) resource name must be REJECTED"
        " (empty-PK equality-collision guard), not silently mapped to an empty PK",
    )
    print("    OK")


def main() raises:
    print("test_firestore_watch_listener (ListenEvent -> ChangeRecord"
          " conformer, scripted)")
    test_document_change_maps_to_modify()
    test_document_delete_maps_to_remove()
    test_cursor_and_sequence_threaded_from_target_change()
    test_single_segment_and_open_threads_cursor()
    test_empty_document_name_is_rejected()
    print("ALL PASS")
