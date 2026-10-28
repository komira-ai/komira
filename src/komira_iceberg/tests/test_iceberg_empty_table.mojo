# =============================================================================
# test_iceberg_empty_table.mojo — a table created and never committed to reads
#   back as ZERO rows.
# =============================================================================
#
# `build_table_metadata_json` supports the empty table: `current_snapshot_id` of
# -1 means "no current snapshot", emitted as `"current-snapshot-id":-1` with an
# empty `snapshots` array, which pyiceberg and DuckDB treat as none. The reader
# must read what the writer declares canonical: a table made of two objects
# (`v1.metadata.json` and the `version-hint.text` pointer) reads as zero rows,
# not as an error. A raise on an empty table is indistinguishable, to a caller
# with a `try`, from a corrupt table, and swallowing it turns "this table is
# broken" into "this table is empty".
#
# What each test proves (and the defect it catches):
#   1. A never-committed table reads as zero rows (a reader that scans the empty
#      snapshots array finds no snapshot and raises).
#   2. The empty metadata carries the -1 spelling and an empty snapshots array
#      (the two facts the reader keys on).
#   3. A pointer naming a snapshot the table does not contain is CORRUPT and
#      still raises: the check is on the sign of the id, not on an empty
#      `snapshots` array.
#
# Hermetic: an in-memory store, no filesystem, no network, no clock dependence.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    build_table_metadata_json,
    SnapshotInfo,
)
from komira_iceberg.iceberg_reader import read_live_rows_from


comptime _LOCATION: String = "warehouse/empty_table"


def _schema() -> IcebergSchema:
    """Three columns are enough to prove the read path."""
    var s = IcebergSchema(0)
    s.add(String("run_id"), ICE_T_STRING, True)
    s.add(String("started_at"), ICE_T_LONG, False)
    s.add(String("row_name"), ICE_T_STRING, False)
    return s^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _create_empty_table(
    mut store: InMemoryConditionalStore, var uuid: String
) raises:
    """The empty-table shape: TWO PUTs, no Avro, no Parquet, no commit."""
    var meta = build_table_metadata_json(
        uuid^,
        String(_LOCATION),
        _schema(),
        List[SnapshotInfo](),
        Int64(-1),           # no current snapshot: an EMPTY table.
        Int64(0),
        Int64(1788220800000),
    )
    _ = store.put(
        Path.parse(String(_LOCATION) + String("/metadata/v1.metadata.json")),
        _bytes(meta),
    )
    _ = store.put(
        Path.parse(String(_LOCATION) + String("/metadata/version-hint.text")),
        _bytes(String("1")),
    )


# -----------------------------------------------------------------------------
# The empty table. A reader that scans the empty snapshots array raises
#   "_current_snapshot_manifest_list: current snapshot object not found".
# -----------------------------------------------------------------------------
def test_a_freshly_created_table_reads_back_as_zero_rows() raises:
    var store = InMemoryConditionalStore()
    _create_empty_table(store, String("00000000-0000-4000-8000-000000000001"))
    var rows = read_live_rows_from(store, String(_LOCATION), _schema())
    assert_equal(
        len(rows),
        0,
        "a never-committed-to table reads as ZERO ROWS — not as an"
        " error, and not as rows",
    )


def test_the_empty_metadata_is_the_shape_the_writer_declares_canonical() raises:
    """Pins the two facts the reader keys on, so a metadata-emitter change that
    breaks the empty shape fails HERE."""
    var meta = build_table_metadata_json(
        String("00000000-0000-4000-8000-000000000002"),
        String(_LOCATION),
        _schema(),
        List[SnapshotInfo](),
        Int64(-1),
        Int64(0),
        Int64(1788220800000),
    )
    assert_true(
        meta.find(String('"current-snapshot-id":-1')) >= 0,
        "the empty table's pointer must be the Iceberg -1 spelling",
    )
    assert_true(
        meta.find(String('"snapshots":[]')) >= 0,
        "the empty table carries an EMPTY snapshots array",
    )


# -----------------------------------------------------------------------------
# The other arm, which must keep raising. A pointer naming a snapshot that is NOT
# in the table's own snapshots array is CORRUPT — not empty. Conflating the two
# is how "this table is broken" silently becomes "this table has no rows".
# -----------------------------------------------------------------------------
def test_a_dangling_current_snapshot_id_still_raises() raises:
    var store = InMemoryConditionalStore()
    var meta = build_table_metadata_json(
        String("00000000-0000-4000-8000-000000000003"),
        String(_LOCATION),
        _schema(),
        List[SnapshotInfo](),
        Int64(7),            # names snapshot 7; the array holds none.
        Int64(1),
        Int64(1788220800000),
    )
    _ = store.put(
        Path.parse(String(_LOCATION) + String("/metadata/v1.metadata.json")),
        _bytes(meta),
    )
    _ = store.put(
        Path.parse(String(_LOCATION) + String("/metadata/version-hint.text")),
        _bytes(String("1")),
    )
    var raised = False
    try:
        _ = read_live_rows_from(store, String(_LOCATION), _schema())
    except e:
        raised = True
        assert_true(
            String(e).find(String("current snapshot object not found")) >= 0,
            String(e),
        )
    assert_true(
        raised,
        "a pointer naming a snapshot the table does not contain is CORRUPT and"
        " must keep raising — it is not the empty-table case",
    )


def main() raises:
    test_a_freshly_created_table_reads_back_as_zero_rows()
    test_the_empty_metadata_is_the_shape_the_writer_declares_canonical()
    test_a_dangling_current_snapshot_id_still_raises()
    print("test_iceberg_empty_table: ALL PASS")
