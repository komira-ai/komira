# =============================================================================
# test_iceberg_partitioned_write.mojo — partitioned write + merge.
# =============================================================================
#
# The partitioned-write falsifiers over an in-memory ConditionalWriteStore:
#
#   1. ROUTING — `route_rows_to_partitions` places each row in the partition
#      its partition-value tuple names (bucket(N, id) + identity(region)); rows
#      with the same partition value co-locate, different values separate.
#   2. READ-BACK — a partitioned table (multiple partition data files) commits
#      and reads back EVERY row through merge-on-read (no row lost to
#      partitioning).
#   3. CROSS-PARTITION DELETE — an equality delete by key masks a row REGARDLESS
#      of which partition it lives in (the delete files are unpartitioned, so
#      they are GLOBAL by key). The deleted key and a survivor may be in
#      DIFFERENT partitions.
#   4. PARTITION-VALUE STATS — the committed manifest's entries carry the
#      partition VALUES (the partition struct is non-empty), recoverable by the
#      manifest reader.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_T_INT,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    IcebergTableWriter,
    RowCell,
    make_long_cell,
    make_string_cell,
    build_parquet_data_file,
    col_types_of,
    build_equality_delete_file,
    gen_table_uuid,
    PartitionSpec,
    partition_value_of,
    route_rows_to_partitions,
    read_partition_values_from_manifest,
)




def _people_schema() -> IcebergSchema:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("region"), ICE_T_STRING, required=True)
    return schema^


def _row(id: Int64, var region: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    return r^


def _has_id(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return True
    return False


def _region_spec() -> PartitionSpec:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))  # partition by region
    return spec^


def _eq_delete_rows_by_id(ids: List[Int64]) -> List[List[RowCell]]:
    var rows = List[List[RowCell]]()
    for i in range(len(ids)):
        var r = List[RowCell]()
        r.append(make_long_cell(ids[i]))
        rows.append(r^)
    return rows^


# =============================================================================
# 1 — routing: rows land in the partition their value names.
# =============================================================================


def test_route_rows_to_partitions() raises:
    """route_rows_to_partitions groups rows by partition value: two us-east rows
    into ONE partition, one us-west into ANOTHER — every row accounted for,
    none duplicated."""
    var schema = _people_schema()
    var spec = _region_spec()

    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("us-east")))
    rows.append(_row(Int64(2), String("us-west")))
    rows.append(_row(Int64(3), String("us-east")))

    var parts = route_rows_to_partitions(spec, schema, rows)
    # two distinct partitions (us-east, us-west).
    assert_equal(len(parts), 2, "two distinct partitions")

    # every input row is present exactly once across all partitions.
    var total = 0
    var seen_east = 0
    var seen_west = 0
    for p in range(len(parts)):
        total += len(parts[p].rows)
        # the partition value tuple is a single region cell.
        assert_equal(
            len(parts[p].partition_values),
            1,
            "one partition field -> one partition value",
        )
        var region = parts[p].partition_values[0].as_string()
        if region == String("us-east"):
            seen_east = len(parts[p].rows)
        elif region == String("us-west"):
            seen_west = len(parts[p].rows)
    assert_equal(total, 3, "all 3 rows routed, none dropped/duplicated")
    assert_equal(seen_east, 2, "two us-east rows co-located")
    assert_equal(seen_west, 1, "one us-west row")


# =============================================================================
# 2 — read-back: a partitioned table reads back every row.
# =============================================================================


def test_partitioned_table_reads_back_every_row() raises:
    """A partitioned table (one data file per partition) reads back EVERY row
    through merge-on-read — partitioning does not lose rows."""
    var location = String("warehouse/pw2/people")
    var schema = _people_schema()
    var spec = _region_spec()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("us-east")))
    rows.append(_row(Int64(2), String("us-west")))
    rows.append(_row(Int64(3), String("us-east")))
    rows.append(_row(Int64(4), String("eu-west")))

    var parts = route_rows_to_partitions(spec, schema, rows)
    var dfs = List[DataFileInfo]()
    for p in range(len(parts)):
        ref part = parts[p]
        var key = (
            writer.data_dir()
            + "/"
            + part.partition_key
            + "/d-"
            + String(p)
            + ".parquet"
        )
        var bytes = build_parquet_data_file(schema, part.rows)
        writer.put_object(key, bytes.copy())
        # carry the partition VALUES onto the data-file info (stats).
        var di = DataFileInfo(
            String(key), len(bytes), len(part.rows), List[ColumnBound]()
        )
        di = di^.with_partition(
            part.partition_avro.copy(), part.partition_types.copy()
        )
        dfs.append(di^)
    _ = writer.commit_with_spec(dfs^, List[DataFileInfo](), spec.copy())

    var live = writer.read_live_rows()
    assert_equal(len(live), 4, "all 4 rows across partitions read back")
    assert_true(_has_id(live, Int64(1)), "id 1")
    assert_true(_has_id(live, Int64(2)), "id 2")
    assert_true(_has_id(live, Int64(3)), "id 3")
    assert_true(_has_id(live, Int64(4)), "id 4")


# =============================================================================
# 3 — cross-partition equality delete.
# =============================================================================


def test_equality_delete_masks_across_partitions() raises:
    """An equality delete by key masks a row REGARDLESS of partition. id=2 lives
    in us-west; id=1,3 in us-east; the delete of id=2 masks it across the
    partition boundary, survivors in the OTHER partition are untouched. The
    delete files are unpartitioned, so they are global by key; a delete scoped
    to one partition would leave the row in the other."""
    var location = String("warehouse/pw3/people")
    var schema = _people_schema()
    var spec = _region_spec()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("us-east")))
    rows.append(_row(Int64(2), String("us-west")))
    rows.append(_row(Int64(3), String("us-east")))

    var parts = route_rows_to_partitions(spec, schema, rows)
    var dfs = List[DataFileInfo]()
    for p in range(len(parts)):
        ref part = parts[p]
        var key = (
            writer.data_dir()
            + "/"
            + part.partition_key
            + "/d-"
            + String(p)
            + ".parquet"
        )
        var bytes = build_parquet_data_file(schema, part.rows)
        writer.put_object(key, bytes.copy())
        var di = DataFileInfo(
            String(key), len(bytes), len(part.rows), List[ColumnBound]()
        )
        di = di^.with_partition(
            part.partition_avro.copy(), part.partition_types.copy()
        )
        dfs.append(di^)
    _ = writer.commit_with_spec(dfs^, List[DataFileInfo](), spec.copy())

    # equality-delete id=2 (lives in us-west partition).
    var del_key = writer.data_dir() + "/eqdel-0002.avro"
    var del_ids = List[Int64]()
    del_ids.append(Int64(2))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)
    var eq_types = List[Int]()
    eq_types.append(ICE_T_LONG)
    var del_bytes = build_equality_delete_file(
        eq_field_ids, eq_types, _eq_delete_rows_by_id(del_ids)
    )
    writer.put_object(del_key, del_bytes.copy())
    var deletes = List[DataFileInfo]()
    var eids = List[Int]()
    eids.append(1)
    deletes.append(
        DataFileInfo(
            String(del_key),
            len(del_bytes),
            1,
            List[ColumnBound](),
            ICE_DATA_CONTENT_EQUALITY_DELETES,
            eids^,
            Int64(0),
        )
    )
    _ = writer.commit_with_spec(
        List[DataFileInfo](), deletes^, spec.copy()
    )

    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "N-1 after cross-partition delete")
    assert_true(_has_id(live, Int64(1)), "id 1 (us-east) survives")
    assert_true(
        not _has_id(live, Int64(2)),
        "id 2 (us-west) masked across the partition boundary",
    )
    assert_true(_has_id(live, Int64(3)), "id 3 (us-east) survives")


# =============================================================================
# 4 — partition-value stats present in the manifest.
# =============================================================================


def test_manifest_carries_partition_values() raises:
    """The committed manifest's data-file entries carry the partition VALUES
    (the partition struct is NON-EMPTY) — recoverable by
    read_partition_values_from_manifest (an empty partition struct would leave
    no partition value to recover)."""
    var location = String("warehouse/pw4/people")
    var schema = _people_schema()
    var spec = _region_spec()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )

    var rows = List[List[RowCell]]()
    rows.append(_row(Int64(1), String("us-east")))
    rows.append(_row(Int64(2), String("us-west")))

    var parts = route_rows_to_partitions(spec, schema, rows)
    var dfs = List[DataFileInfo]()
    for p in range(len(parts)):
        ref part = parts[p]
        var key = (
            writer.data_dir()
            + "/"
            + part.partition_key
            + "/d-"
            + String(p)
            + ".parquet"
        )
        var bytes = build_parquet_data_file(schema, part.rows)
        writer.put_object(key, bytes.copy())
        var di = DataFileInfo(
            String(key), len(bytes), len(part.rows), List[ColumnBound]()
        )
        di = di^.with_partition(
            part.partition_avro.copy(), part.partition_types.copy()
        )
        dfs.append(di^)
    var result = writer.commit_with_spec(
        dfs^, List[DataFileInfo](), spec.copy()
    )

    # recover the partition values from the committed data manifest.
    var manifest_bytes = writer.get_object(result.manifest_key)
    var pvals = read_partition_values_from_manifest(
        manifest_bytes, spec.copy(), schema.copy()
    )
    # one partition value per data file; each is a single region string cell.
    assert_equal(len(pvals), 2, "two data-file partition tuples recovered")
    var seen_east = False
    var seen_west = False
    for i in range(len(pvals)):
        assert_equal(
            len(pvals[i]), 1, "one partition field -> one value per file"
        )
        var region = pvals[i][0].as_string()
        if region == String("us-east"):
            seen_east = True
        elif region == String("us-west"):
            seen_west = True
    assert_true(seen_east, "us-east partition value recovered")
    assert_true(seen_west, "us-west partition value recovered")


def main() raises:
    test_route_rows_to_partitions()
    test_partitioned_table_reads_back_every_row()
    test_equality_delete_masks_across_partitions()
    test_manifest_carries_partition_values()
    print("test_iceberg_partitioned_write: ALL PASS")
