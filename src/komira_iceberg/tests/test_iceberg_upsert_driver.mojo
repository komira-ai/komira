# =============================================================================
# test_iceberg_upsert_driver.mojo — the end-to-end file-based upsert driver.
# =============================================================================
#
# The end-to-end write path over a real on-disk LocalFs store, partition specs,
# schema evolution and merge-on-read deletes together:
#
#   commit 1 (schema v0, PARTITIONED by region, 2 cols):
#       write partitioned Parquet data (us-east / us-west partitions).
#   commit 2: EQUALITY-DELETE a key (id=2, lives in us-west).
#   commit 3: ADD a column ('email', nullable) -> schema v1 (3 cols).
#   commit 4 (schema v1, PARTITIONED, 3 cols):
#       append MORE partitioned data carrying the new column.
#   read back under v1:
#       * right partitions — every surviving row present, in its partition.
#       * deletes honored — id=2 masked ACROSS the partition boundary AND across
#         an old (pre-add-column) data file.
#       * old rows NULL-FILL the added 'email' column.
#       * new rows carry 'email'.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    ICE_DATA_CONTENT_EQUALITY_DELETES,
    IcebergSchema,
    DataFileInfo,
    ColumnBound,
    IcebergTableWriter,
    RowCell,
    make_long_cell,
    make_string_cell,
    build_parquet_data_file,
    build_equality_delete_file,
    gen_table_uuid,
    PartitionSpec,
    route_rows_to_partitions,
    evolve_add_column,
)
from komira_libc.posix import _read_env


# The scratch directory is the test action's own TEST_TMPDIR; a run without one
# fails rather than falling back to a path other runs share.
def _scratch_dir() raises -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test needs its own scratch directory")
    return d


# =============================================================================
# Helpers.
# =============================================================================


def _v0_schema() -> IcebergSchema:
    """id (long, required) + region (string, required)."""
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("region"), ICE_T_STRING, required=True)
    return s^


def _region_spec() -> PartitionSpec:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("region"))  # partition by region (field-id 2)
    return spec^


def _row2(id: Int64, var region: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    return r^


def _row3(id: Int64, var region: String, var email: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(region^))
    r.append(make_string_cell(email^))
    return r^


def _eq_delete_rows_by_id(ids: List[Int64]) -> List[List[RowCell]]:
    var rows = List[List[RowCell]]()
    for i in range(len(ids)):
        var r = List[RowCell]()
        r.append(make_long_cell(ids[i]))
        rows.append(r^)
    return rows^


def _has_id(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            return True
    return False


def _find_row(rows: List[List[RowCell]], id: Int64) raises -> List[RowCell]:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            var out = List[RowCell]()
            for c in range(len(rows[i])):
                out.append(rows[i][c].copy())
            return out^
    raise Error("id " + String(id) + " not found in live rows")


def _region_of(rows: List[List[RowCell]], id: Int64) raises -> String:
    var r = _find_row(rows, id)
    return r[1].as_string()


def _commit_partitioned(
    mut writer: IcebergTableWriter[LocalFsConditionalStore],
    schema: IcebergSchema,
    spec: PartitionSpec,
    rows: List[List[RowCell]],
    tag: String,
) raises:
    """Route `rows` to partitions, write one Parquet data file per partition,
    attach the partition tuple, and commit under `spec`."""
    var parts = route_rows_to_partitions(spec, schema, rows)
    var dfs = List[DataFileInfo]()
    for p in range(len(parts)):
        ref part = parts[p]
        var key = (
            writer.data_dir()
            + "/"
            + part.partition_key
            + "/d-"
            + tag
            + "-"
            + String(p)
            + ".parquet"
        )
        var bytes = build_parquet_data_file(schema, part.rows)
        writer.put_object(key, bytes.copy())
        var di = DataFileInfo(
            String(key), len(bytes), len(part.rows), List[ColumnBound]()
        )
        dfs.append(
            di^.with_partition(
                part.partition_avro.copy(), part.partition_types.copy()
            )
        )
    _ = writer.commit_with_spec(dfs^, List[DataFileInfo](), spec.copy())


# =============================================================================
# THE GATE.
# =============================================================================


def test_upsert_driver_over_localfs() raises:
    """THE GATE: partitioned write -> equality-delete -> add-column ->
    append -> read-back correct, over a REAL on-disk LocalFs store.

    Verifies together: right partitions, deletes honored across partitions AND
    across old data files, old rows null-fill the added column, new rows carry
    it, and schema-id bumps on the evolving commit."""
    # A per-run unique root so repeated runs don't collide on the durable store.
    var root = _scratch_dir() + String("/ice_p1_gate")
    var location = root + "/warehouse/db/people"
    var v0 = _v0_schema()
    var spec = _region_spec()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, v0.copy(), gen_table_uuid()
    )

    # ---- commit 1 (seq 1): partitioned Parquet, schema v0 (2 cols) ----
    var rows0 = List[List[RowCell]]()
    rows0.append(_row2(Int64(1), String("us-east")))
    rows0.append(_row2(Int64(2), String("us-west")))
    rows0.append(_row2(Int64(3), String("us-east")))
    _commit_partitioned(
        writer, v0, spec, rows0, String("c1")
    )

    # ---- commit 2 (seq 2): equality-delete id=2 (in us-west) ----
    var del_key = writer.data_dir() + "/eqdel-c2.avro"
    var del_ids = List[Int64]()
    del_ids.append(Int64(2))
    var eq_field_ids = List[Int]()
    eq_field_ids.append(1)  # equality on id (field-id 1)
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

    # ---- commit 3: ADD COLUMN 'email' (nullable) -> schema v1 (3 cols) ----
    var v1 = evolve_add_column(v0, String("email"), ICE_T_STRING)
    writer.set_schema(v1.copy())

    # ---- commit 4 (seq 3): append MORE partitioned data under v1 (3 cols) ----
    var rows1 = List[List[RowCell]]()
    rows1.append(_row3(Int64(4), String("us-east"), String("dave@x")))
    rows1.append(_row3(Int64(5), String("eu-west"), String("erin@x")))
    _commit_partitioned(
        writer, v1, spec, rows1, String("c4")
    )

    # ---- read back under v1 (3 cols) ----
    var live = writer.read_live_rows()

    # 4 surviving rows: 1, 3 (old, us-east), 4 (new, us-east), 5 (new, eu-west).
    # id=2 was equality-deleted (it lived in us-west — masked ACROSS partitions
    # AND across an OLD pre-add-column data file).
    assert_equal(len(live), 4, "exactly 4 live rows after upsert cycle")
    assert_true(_has_id(live, Int64(1)), "id 1 survives (old, us-east)")
    assert_true(
        not _has_id(live, Int64(2)),
        "id 2 masked — cross-partition (us-west) + cross-old-file delete",
    )
    assert_true(_has_id(live, Int64(3)), "id 3 survives (old, us-east)")
    assert_true(_has_id(live, Int64(4)), "id 4 present (new, us-east)")
    assert_true(_has_id(live, Int64(5)), "id 5 present (new, eu-west)")

    # right partitions — each row read back carries its region.
    assert_equal(_region_of(live, Int64(1)), String("us-east"), "id1 region")
    assert_equal(_region_of(live, Int64(3)), String("us-east"), "id3 region")
    assert_equal(_region_of(live, Int64(4)), String("us-east"), "id4 region")
    assert_equal(_region_of(live, Int64(5)), String("eu-west"), "id5 region")

    # OLD rows (1, 3) written under v0 (2 cols) null-fill the added 'email'.
    var r1 = _find_row(live, Int64(1))
    assert_equal(len(r1), 3, "old row null-filled to 3-col arity")
    assert_true(
        r1[2].is_null(), "old row's added 'email' column projects NULL"
    )
    var r3 = _find_row(live, Int64(3))
    assert_true(r3[2].is_null(), "old row id3 'email' NULL")

    # NEW rows (4, 5) carry the 'email' value.
    var r4 = _find_row(live, Int64(4))
    assert_equal(len(r4), 3, "new row has 3 cells")
    assert_true(not r4[2].is_null(), "new row id4 'email' non-null")
    assert_equal(r4[2].as_string(), String("dave@x"), "id4 email value")
    var r5 = _find_row(live, Int64(5))
    assert_equal(r5[2].as_string(), String("erin@x"), "id5 email value")

    # schema-id bumped to 1 on the evolving commit's metadata. The metadata
    # VERSION is the COMMIT count (add-column's `set_schema` is NOT a commit):
    # commit 1 -> v1, commit 2 (delete) -> v2, set_schema (no commit),
    # commit 4 (append under v1) -> v3. So the evolving append landed on v3.
    var meta_key = location + "/metadata/v3.metadata.json"
    var mb = writer.get_object(meta_key)
    var meta = String("")
    for i in range(len(mb)):
        meta += chr(Int(mb[i]))
    assert_true(
        meta.find('"current-schema-id":1') >= 0,
        "current-schema-id bumped to 1 after add-column commit",
    )
    # and the partition spec is recorded (identity on region).
    assert_true(
        meta.find('"transform":"identity"') >= 0,
        "partition spec (identity region) recorded in metadata",
    )


def main() raises:
    test_upsert_driver_over_localfs()
    print("test_iceberg_upsert_driver: ALL PASS")
