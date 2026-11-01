# =============================================================================
# test_iceberg_snapshot_summary.mojo — the snapshot-summary extra-KV falsifiers.
# =============================================================================
#
# An ingest process stamps the last-applied stream position into the Iceberg
# snapshot `summary` map on each commit and DERIVES the resume point on startup
# by reading the latest committed snapshot's summary: there is no separate
# checkpoint store, so the position write and the data write are ONE atomic
# commit. `SnapshotInfo` carries an `extra_summary: List[SummaryKV]`,
# `snapshot_json` emits those entries into the summary object, the writer stamps
# them via `commit_with_summary`, and `read_current_snapshot_summary` reads them
# back from the committed metadata.json.
#
# THE FALSIFIERS (over a real on-disk LocalFs store, no cloud):
#   (1) `commit_with_summary` stamps extra summary KVs -> a read-back of the
#       current snapshot's summary returns them.
#   (2) The position round-trips ACROSS a fresh reader handle (the exactly-once
#       precondition: the resume point comes from the committed table, not from
#       any in-process state).
#   (3) An empty extra_summary leaves only the count fields (no spurious keys).
#   (4) Multiple commits: the LATEST snapshot's summary wins (the resume point
#       is the most-recent committed position).
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    IcebergTableWriter,
    RowCell,
    make_long_cell,
    make_string_cell,
    build_parquet_data_file,
    gen_table_uuid,
    SummaryKV,
    read_current_snapshot_summary,
    summary_value_for,
)
from komira_libc.posix import _read_env


# The scratch directory is the test action's own TEST_TMPDIR; a run without one
# fails rather than falling back to a path other runs share.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test needs its own scratch directory")
    return d


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING, required=True)
    return s^


def _row(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _commit_one(
    mut writer: IcebergTableWriter[LocalFsConditionalStore],
    schema: IcebergSchema,
    rows: List[List[RowCell]],
    extra: List[SummaryKV],
    tag: String,
) raises:
    var key = writer.data_dir() + "/d-" + tag + ".parquet"
    var bytes = build_parquet_data_file(schema, rows)
    writer.put_object(key, bytes.copy())
    var dfs = List[DataFileInfo]()
    dfs.append(
        DataFileInfo(String(key), len(bytes), len(rows), List[ColumnBound]())
    )
    _ = writer.commit_with_summary(dfs^, List[DataFileInfo](), extra)


def test_summary_kv_stamped_and_read_back() raises:
    """(1) + (2): `commit_with_summary` stamps a per-shard position into the
    snapshot summary; a FRESH reader handle derives it from the committed
    metadata.json (no in-process state).

    A summary KV dropped on write, or ignored by the reader, makes
    `summary_value_for` return "" and loses the exactly-once resume point."""
    var root = _scratch_dir() + String("/summary_basic")
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("alice")))
    var extra = List[SummaryKV]()
    extra.append(SummaryKV(String("ingest.shard.a"), String("seq-000123")))
    extra.append(SummaryKV(String("ingest.shard.b"), String("seq-000456")))
    _commit_one(writer, schema, rows, extra, String("c1"))

    # A FRESH store handle + reader — the resume position comes from the
    # COMMITTED table, not from the writer's in-process state.
    var store2 = LocalFsConditionalStore(root.copy())
    var summary = read_current_snapshot_summary(store2, location)
    assert_equal(
        summary_value_for(summary, String("ingest.shard.a")),
        String("seq-000123"),
        "shard-A position read back from committed summary",
    )
    assert_equal(
        summary_value_for(summary, String("ingest.shard.b")),
        String("seq-000456"),
        "shard-B position read back from committed summary",
    )
    # An absent key returns "" (the cold-start signal).
    assert_equal(
        summary_value_for(summary, String("ingest.shard.z")),
        String(""),
        "absent shard key => empty (cold start for that shard)",
    )


def test_empty_summary_preserves_shipped_count_fields() raises:
    """(3): an empty extra_summary is byte-compatible with the shipped path —
    the shipped count fields (operation / added / total) are still present, and
    NO spurious ingest.* keys leak."""
    var root = _scratch_dir() + String("/summary_empty")
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )
    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("alice")))
    _commit_one(writer, schema, rows, List[SummaryKV](), String("c1"))

    # Read the raw metadata.json — the shipped summary fields are still there.
    var meta_key = location + "/metadata/v1.metadata.json"
    var mb = writer.get_object(meta_key)
    var meta = String("")
    for i in range(len(mb)):
        meta += chr(Int(mb[i]))
    assert_true(meta.find('"operation":"append"') >= 0, "operation retained")
    assert_true(meta.find('"added-records":"1"') >= 0, "added-records retained")
    assert_true(meta.find('"total-records":"1"') >= 0, "total-records retained")
    assert_false(meta.find("ingest.") >= 0, "no spurious ingest.* key on empty summary")


def test_latest_snapshot_summary_wins() raises:
    """(4): after multiple commits the LATEST snapshot's summary is what the
    reader derives — the resume point is the MOST-RECENT committed position.

    A reader that returned the FIRST snapshot's summary (or unioned all) would
    give a stale resume point, and the ingest would re-apply already-applied
    records (or skip records)."""
    var root = _scratch_dir() + String("/summary_latest")
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    var rows1 = List[List[RowCell]]()
    rows1.append(_row(Int64(1), String("a")))
    var e1 = List[SummaryKV]()
    e1.append(SummaryKV(String("ingest.shard.a"), String("seq-100")))
    _commit_one(writer, schema, rows1, e1, String("c1"))

    var rows2 = List[List[RowCell]]()
    rows2.append(_row(Int64(2), String("b")))
    var e2 = List[SummaryKV]()
    e2.append(SummaryKV(String("ingest.shard.a"), String("seq-200")))
    _commit_one(writer, schema, rows2, e2, String("c2"))

    var store2 = LocalFsConditionalStore(root.copy())
    var summary = read_current_snapshot_summary(store2, location)
    assert_equal(
        summary_value_for(summary, String("ingest.shard.a")),
        String("seq-200"),
        "latest snapshot's position wins (seq-200, not seq-100)",
    )


def main() raises:
    test_summary_kv_stamped_and_read_back()
    test_empty_summary_preserves_shipped_count_fields()
    test_latest_snapshot_summary_wins()
    print("test_iceberg_snapshot_summary: ALL PASS")
