# =============================================================================
# test_iceberg_schema_evolution.mojo — add-column schema evolution.
# =============================================================================
#
# A source evolves its schema (a new attribute appears in a source row). The
# writer supports ADD-COLUMN with a schema-id bump on commit:
#
#   1. ADD-COLUMN BUMPS SCHEMA-ID — evolve_add_column assigns a NEW field-id
#      (next in order) and a NEW schema_id (prior + 1); the added column is
#      NULLABLE (Iceberg requires added columns to be optional).
#   2. OLD-FILE NULL-FILL — a data file written under the PRIOR schema (fewer
#      columns) reads back under the NEW schema with the added column NULL.
#   3. NEW-FILE CARRIES THE COLUMN — a data file written AFTER the add carries
#      the new column's value, read back correctly.
#   4. SCHEMA-ID BUMP ON COMMIT — the metadata.json current-schema-id reflects
#      the evolved schema after the commit that introduces it, and the earlier
#      schema stays in `schemas` for the snapshots written under it.
#
# Not supported: drop-column, rename-column, and partition-spec evolution.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
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
    col_types_of,
    gen_table_uuid,
    evolve_add_column,
)




def _people_schema_v0() -> IcebergSchema:
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("name"), ICE_T_STRING, required=True)
    return schema^


def _row2(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _row3(id: Int64, var name: String, var email: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    r.append(make_string_cell(email^))
    return r^


def _find_row(rows: List[List[RowCell]], id: Int64) raises -> List[RowCell]:
    for i in range(len(rows)):
        if rows[i][0].as_long() == id:
            var out = List[RowCell]()
            for c in range(len(rows[i])):
                out.append(rows[i][c].copy())
            return out^
    raise Error("id " + String(id) + " not found")


# =============================================================================
# 1 — add-column bumps the schema-id + assigns a new field-id.
# =============================================================================


def test_add_column_bumps_schema_id() raises:
    """evolve_add_column: the new schema has schema_id+1, one more field, and the
    added column gets the next field-id + is NULLABLE (Iceberg requires added
    columns be optional)."""
    var v0 = _people_schema_v0()
    assert_equal(v0.schema_id, 0, "base schema-id 0")
    assert_equal(v0.num_fields(), 2, "base has 2 fields")
    assert_equal(v0.last_column_id(), 2, "base last-column-id 2")

    var v1 = evolve_add_column(v0, String("email"), ICE_T_STRING)
    assert_equal(v1.schema_id, 1, "evolved schema-id bumped to 1")
    assert_equal(v1.num_fields(), 3, "evolved has 3 fields")
    assert_equal(v1.last_column_id(), 3, "evolved last-column-id 3")
    # the added column: field-id 3, name email, NULLABLE.
    ref added = v1.fields[2]
    assert_equal(added.field_id, 3, "added field-id is next in order (3)")
    assert_equal(added.name, String("email"), "added name email")
    assert_true(not added.required, "added column is NULLABLE (optional)")
    # existing field-ids are STABLE (id=1, name=2 unchanged).
    assert_equal(v1.fields[0].field_id, 1, "id field-id stable at 1")
    assert_equal(v1.fields[1].field_id, 2, "name field-id stable at 2")


# =============================================================================
# 2 + 3 + 4 — old file null-fills, new file carries, schema-id bumps on commit.
# =============================================================================


def test_old_file_nullfills_new_column_after_evolution() raises:
    """The end-to-end schema-evolution proof:
      commit 1 (schema v0, 2 cols): rows (1,'alice'), (2,'bob').
      evolve: add nullable column 'email' -> schema v1 (3 cols).
      commit 2 (schema v1, 3 cols): row (3,'carol','carol@x').
      read back under v1:
        * the OLD rows (1,2) — written under v0 (2 cols) — project 'email' NULL.
        * the NEW row (3) carries 'carol@x'.
        * metadata current-schema-id == 1 (bumped on the evolving commit).

    A reader that raised on a data file with fewer columns than the current
    schema, or a writer whose schema is fixed at construction, would fail
    here."""
    var location = String("warehouse/se2/people")
    var v0 = _people_schema_v0()
    var store = InMemoryConditionalStore()
    var writer = IcebergTableWriter[InMemoryConditionalStore](
        store^, location, v0.copy(), gen_table_uuid()
    )

    # commit 1 under v0 (2 columns).
    var rows0 = List[List[RowCell]]()
    rows0.append(_row2(Int64(1), String("alice")))
    rows0.append(_row2(Int64(2), String("bob")))
    var k0 = writer.data_dir() + "/d-0001.parquet"
    var b0 = build_parquet_data_file(v0, rows0)
    writer.put_object(k0, b0.copy())
    var dfs0 = List[DataFileInfo]()
    dfs0.append(DataFileInfo(String(k0), len(b0), 2, List[ColumnBound]()))
    _ = writer.commit_append(dfs0^)

    # evolve: add nullable column email -> v1 (3 columns). Rebind the writer's
    # schema (schema-id bumps on the NEXT commit's metadata).
    var v1 = evolve_add_column(v0, String("email"), ICE_T_STRING)
    writer.set_schema(v1.copy())

    # commit 2 under v1 (3 columns).
    var rows1 = List[List[RowCell]]()
    rows1.append(_row3(Int64(3), String("carol"), String("carol@x")))
    var k1 = writer.data_dir() + "/d-0002.parquet"
    var b1 = build_parquet_data_file(v1, rows1)
    writer.put_object(k1, b1.copy())
    var dfs1 = List[DataFileInfo]()
    dfs1.append(DataFileInfo(String(k1), len(b1), 1, List[ColumnBound]()))
    _ = writer.commit_append(dfs1^)

    # read back under v1 (3 columns): old rows null-fill email; new row carries.
    var live = writer.read_live_rows()
    assert_equal(len(live), 3, "all 3 rows read back under evolved schema")

    var r1 = _find_row(live, Int64(1))
    assert_equal(len(r1), 3, "old row has 3 cells (null-filled to new arity)")
    assert_equal(r1[1].as_string(), String("alice"), "old row name preserved")
    assert_true(
        r1[2].is_null(),
        "old row's added 'email' column projects NULL (null-fill)",
    )

    var r3 = _find_row(live, Int64(3))
    assert_equal(len(r3), 3, "new row has 3 cells")
    assert_equal(r3[1].as_string(), String("carol"), "new row name")
    assert_true(not r3[2].is_null(), "new row's email is NON-null")
    assert_equal(
        r3[2].as_string(), String("carol@x"), "new row carries the email value"
    )

    # metadata current-schema-id bumped to 1 on the evolving commit.
    var meta_key = (
        location + "/metadata/v2.metadata.json"
    )
    var meta = String("")
    var mb = writer.get_object(meta_key)
    for i in range(len(mb)):
        meta += chr(Int(mb[i]))
    assert_true(
        meta.find('"current-schema-id":1') >= 0,
        "metadata current-schema-id bumped to 1 after add-column",
    )


def main() raises:
    test_add_column_bumps_schema_id()
    test_old_file_nullfills_new_column_after_evolution()
    print("test_iceberg_schema_evolution: ALL PASS")
