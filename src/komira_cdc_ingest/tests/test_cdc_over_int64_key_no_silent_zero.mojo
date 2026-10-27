# =============================================================================
# test_cdc_over_int64_key_no_silent_zero.mojo — an over-Int64 key is refused.
# =============================================================================
#
# A change source can deliver an integer key too large for Int64 as a canonical
# decimal STRING cell. The Iceberg write path (`build_parquet_data_file` for data,
# `build_equality_delete_file` for equality deletes) writes a LONG column from the
# cell's integral arm; a STRING cell has none, so a silent write would encode the
# key as 0. Two distinct large keys would both become 0, and the equality delete
# of one would mask the other key's row.
#
# The encode boundary reconciles each cell's type against the declared column type
# (`reconcile_cell_type`) and RAISES on a value that cannot be represented (a
# STRING cell for a LONG column) rather than coercing it to 0. A genuine NULL for
# a nullable column still writes NULL, and an in-range integer key still works.
#
# What each test proves:
#   (1) A >Int64 integer KEY (a STRING cell in a LONG key column) driven through
#       the full apply -> commit -> read_live_rows path raises, rather than
#       silently encoding 0.
#   (2) Two distinct >Int64 keys at the equality-delete encode boundary raise.
#   (3) A small in-range integer key (a real LONG cell) still works end to end.
#   (4) A genuine NULL cell for a nullable LONG column writes NULL (not 0), reads
#       back NULL, and does not wrongly raise.
#
# Over an on-disk Iceberg store; no cloud and no network.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)

from komira_snapshotter.change_stream_trait import (
    ChangeRecord,
    ChangeBatch,
    make_insert_record,
)

from komira_iceberg import (
    ICE_T_LONG,
    ICE_T_STRING,
    IcebergSchema,
    IcebergTableWriter,
    DataFileInfo,
    ColumnBound,
    RowCell,
    make_long_cell,
    make_string_cell,
    make_null_cell,
    gen_table_uuid,
    build_parquet_data_file,
    build_equality_delete_file,
    read_parquet_data_file,
    col_types_of,
)

from komira_cdc_ingest import (
    CdcApplyConfig,
    ShardPositions,
    apply_batch,
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
# Fixtures: a LONG-keyed table (id long PK + name string).
# =============================================================================


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING, required=True)
    return s^


def _config() -> CdcApplyConfig:
    var ids = List[Int]()
    ids.append(1)  # equality-delete on id (field-id 1)
    return CdcApplyConfig(_schema(), ids^)


# A full row whose `id` cell is a STRING cell (an over-Int64 integer),
# in the LONG key column position. A change source delivers an over-Int64
# integer as a value-preserving canonical-decimal STRING.
def _row_over_int64(var id_decimal: String, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_string_cell(id_decimal^))  # STRING cell in a LONG column
    r.append(make_string_cell(name^))
    return r^


def _row_long(id: Int64, var name: String) -> List[RowCell]:
    var r = List[RowCell]()
    r.append(make_long_cell(id))
    r.append(make_string_cell(name^))
    return r^


def _insert_over_int64(
    var id_decimal: String, var name: String, var seq: String
) -> ChangeRecord:
    return make_insert_record(
        _row_over_int64(String(id_decimal), String("k")),
        _row_over_int64(id_decimal^, name^),
        seq^,
    )


def _insert_long(id: Int64, var name: String, var seq: String) -> ChangeRecord:
    return make_insert_record(
        _row_long(id, String("k")), _row_long(id, name^), seq^
    )


def _has_id_long(rows: List[List[RowCell]], id: Int64) -> Bool:
    for i in range(len(rows)):
        if not rows[i][0].is_null() and rows[i][0].as_long() == id:
            return True
    return False


# =============================================================================
# (1) FULL PATH: a >Int64 key through apply -> commit -> read RAISES loud.
# =============================================================================
def test_over_int64_key_raises_not_silent_zero() raises:
    """A >Int64 integer KEY (a STRING cell in a LONG key column, the shape a
    source gives an over-Int64 integer) driven through the FULL apply path RAISES a clear
    error rather than silently encoding LONG 0.

    FAILS if apply_batch does NOT raise: both the data
    row and the equality-delete key encode the LONG key via `as_long()` == 0
    (the STRING cell's unused integral arm), silently corrupting the key.
    """
    var root = (_scratch_dir() + String("/cdc_a1_over_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )
    var config = _config()

    # A single INSERT of a row whose `id` is a >Int64 integer, carried as the
    # canonical-decimal STRING cell.
    var recs = List[ChangeRecord]()
    recs.append(
        _insert_over_int64(
            String("123456789012345678901234567890"),
            String("whale"),
            String("seq-0000000001"),
        )
    )
    var batch = ChangeBatch(recs^, String("next"), False)

    var positions = ShardPositions()
    # The encode boundary (build_parquet_data_file / build_equality_delete_file)
    # must REJECT the STRING-for-LONG cell rather than silently coerce it to 0.
    with assert_raises(contains="not representable in long"):
        _ = apply_batch(writer, config, String("shardId-A"), batch^, positions)

# =============================================================================
# (2) ENCODE BOUNDARY: two distinct >Int64 keys must not collapse to 0.
# =============================================================================
def test_two_distinct_over_int64_keys_no_collision_at_encode() raises:
    """Two DISTINCT >Int64 keys at the equality-delete encode boundary. A
    coercing encode would write both as 0 (a cross-key collision: one key's
    delete would mask the other key's row). The encode RAISES loud, so the
    collision can never form.
    never form.

    FAILS if build_equality_delete_file encodes both distinct large keys as LONG
    0 with NO error (the collision is silent).
    """
    var key_field_ids = List[Int]()
    key_field_ids.append(1)
    var key_types = List[Int]()
    key_types.append(ICE_T_LONG)

    # Two DISTINCT >Int64 integers, each carried as a STRING cell.
    var rows = List[List[RowCell]]()
    var k1 = List[RowCell]()
    k1.append(make_string_cell(String("123456789012345678901234567890")))
    rows.append(k1^)
    var k2 = List[RowCell]()
    k2.append(make_string_cell(String("999999999999999999999999999999")))
    rows.append(k2^)

    with assert_raises(contains="not representable in long"):
        _ = build_equality_delete_file(key_field_ids, key_types, rows)

    # And the DATA-file encode of the same over-Int64 key raises too (both write
    # legs are guarded).
    var schema = _schema()
    var data_rows = List[List[RowCell]]()
    data_rows.append(
        _row_over_int64(
            String("123456789012345678901234567890"), String("whale")
        )
    )
    with assert_raises(contains="not representable in long"):
        _ = build_parquet_data_file(schema, data_rows)


# =============================================================================
# (3) IN-RANGE small integer key STILL WORKS (no false raise).
# =============================================================================
def test_in_range_long_key_still_works() raises:
    """A small IN-RANGE integer key (a real LONG cell) applies + reads back
    correctly — the reconciliation does NOT over-raise on legitimate values."""
    var root = (_scratch_dir() + String("/cdc_a1_inrange_")) + String(
        Int(external_call["getpid", Int32]())
    )
    var location = root + "/warehouse/db/t"
    var schema = _schema()
    var store = LocalFsConditionalStore(root.copy())
    var writer = IcebergTableWriter[LocalFsConditionalStore](
        store^, location, schema.copy(), gen_table_uuid()
    )
    var config = _config()

    var recs = List[ChangeRecord]()
    recs.append(_insert_long(Int64(42), String("minnow"), String("seq-0000000001")))
    recs.append(_insert_long(Int64(7), String("guppy"), String("seq-0000000002")))
    var batch = ChangeBatch(recs^, String("next"), False)

    var positions = ShardPositions()
    var stats = apply_batch(
        writer, config, String("shardId-A"), batch^, positions
    )
    assert_true(stats.committed, "in-range LONG keys committed (no false raise)")

    var live = writer.read_live_rows()
    assert_equal(len(live), 2, "both in-range rows present")
    assert_true(_has_id_long(live, Int64(42)), "id 42 present")
    assert_true(_has_id_long(live, Int64(7)), "id 7 present")


# =============================================================================
# (4) GENUINE NULL for a NULLABLE LONG writes NULL (not 0), reads back NULL.
# =============================================================================
def test_nullable_long_genuine_null_writes_null_not_zero() raises:
    """A genuine NULL cell for a NULLABLE LONG column writes NULL (not the
    coerced 0), reads back NULL, and does NOT wrongly raise from the type
    reconciliation.

    This is the companion invariant to the type-mismatch raise: only a
    TYPE-MISMATCH raises; a legitimately-null value of the matching declared type
    writes real NULL (validity bit cleared, def-levels), never a silent 0.

    The key guarantee this proves is that a null cell writes REAL NULL, not a
    coerced 0: a coerced 0 would read back as a non-null 0, but the round-trip
    reads back NULL. The required
    columns (id/name) carry their real values alongside."""
    # A table with a NULLABLE long column `score` alongside a required id/name.
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("name"), ICE_T_STRING, required=True)
    schema.add(String("score"), ICE_T_LONG, required=False)  # NULLABLE

    var rows = List[List[RowCell]]()
    var r0 = List[RowCell]()
    r0.append(make_long_cell(Int64(1)))
    r0.append(make_string_cell(String("alice")))
    r0.append(make_null_cell(ICE_T_LONG))  # genuine NULL score
    rows.append(r0^)
    var r1 = List[RowCell]()
    r1.append(make_long_cell(Int64(2)))
    r1.append(make_string_cell(String("bob")))
    r1.append(make_null_cell(ICE_T_LONG))  # genuine NULL score
    rows.append(r1^)

    # The encode does NOT raise on the genuine null (its tag matches the column).
    var data_bytes = build_parquet_data_file(schema, rows)
    var decoded = read_parquet_data_file(data_bytes, col_types_of(schema))

    assert_equal(len(decoded), 2, "two rows round-tripped")
    # The nullable score reads back as NULL (not a coerced 0). A coercing write
    # would encode a null cell as 0 and read back a NON-null 0; this asserts it
    # reads back NULL instead.
    assert_true(
        decoded[0][2].is_null(),
        "row 0 nullable LONG genuine null reads back NULL (not coerced 0)",
    )
    assert_true(
        decoded[1][2].is_null(),
        "row 1 nullable LONG genuine null reads back NULL (not coerced 0)",
    )
    # The REQUIRED columns carry their real values (no false raise, no coercion).
    assert_false(decoded[0][0].is_null(), "row 0 id is non-null")
    assert_equal(decoded[0][0].as_long(), Int64(1), "row 0 id = 1")
    assert_equal(decoded[0][1].as_string(), String("alice"), "row 0 name")
    assert_equal(decoded[1][0].as_long(), Int64(2), "row 1 id = 2")
    assert_equal(decoded[1][1].as_string(), String("bob"), "row 1 name")


def test_nullable_long_required_value_alongside_null_write_no_raise() raises:
    """A NULLABLE LONG column mixing a genuine null with a real value does NOT
    wrongly raise at the WRITE boundary (the reconciliation admits both — the
    null matches its declared tag; the value is a real LONG cell). This isolates
    the no-false-raise check from the read-back path.

    It then reads the file back: the leading null stays NULL and the later
    value reads back as 99."""
    var schema = IcebergSchema(0)
    schema.add(String("id"), ICE_T_LONG, required=True)
    schema.add(String("score"), ICE_T_LONG, required=False)  # NULLABLE

    var rows = List[List[RowCell]]()
    var r0 = List[RowCell]()
    r0.append(make_long_cell(Int64(1)))
    r0.append(make_null_cell(ICE_T_LONG))  # genuine NULL score (leading)
    rows.append(r0^)
    var r1 = List[RowCell]()
    r1.append(make_long_cell(Int64(2)))
    r1.append(make_long_cell(Int64(99)))  # real value
    rows.append(r1^)

    # The WRITE must NOT raise — a genuine null + a real value are both
    # representable in the declared column types.
    var data_bytes = build_parquet_data_file(schema, rows)
    assert_true(len(data_bytes) > 0, "nullable-mixed column wrote (no false raise)")
    var decoded = read_parquet_data_file(data_bytes, col_types_of(schema))
    assert_equal(len(decoded), 2, "two rows round-tripped")
    assert_true(decoded[0][1].is_null(), "leading null reads back NULL")
    assert_false(decoded[1][1].is_null(), "later real value is non-null")
    assert_equal(decoded[1][1].as_long(), Int64(99), "later real value is 99")


def main() raises:
    test_over_int64_key_raises_not_silent_zero()
    test_two_distinct_over_int64_keys_no_collision_at_encode()
    test_in_range_long_key_still_works()
    test_nullable_long_genuine_null_writes_null_not_zero()
    test_nullable_long_required_value_alongside_null_write_no_raise()
    print("test_cdc_over_int64_key_no_silent_zero: ALL PASS")
