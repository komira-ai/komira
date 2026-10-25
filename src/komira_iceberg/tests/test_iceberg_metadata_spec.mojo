# =============================================================================
# test_iceberg_metadata_spec.mojo — metadata.json against the Iceberg v2 spec.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. schema_json emits {type, schema-id, fields:[{id,name,required,type}]}:
#      a reader binds columns by `id`, so a wrong id or spelling breaks reads.
#   2. build_table_metadata_json carries every field the v2 spec requires, the
#      `main` branch ref when a snapshot is current, none when the table is
#      empty, and the partition spec ids (999 unpartitioned, 1000-based).
#   3. snapshot_json carries the spec's snapshot fields and the summary keys.
#   4. partition_spec_fields_json is the bare fields array (what a manifest
#      header carries); partition_spec_json wraps it with the spec id.
#   5. The summary reader returns every key, an empty list for a table never
#      committed, and non-ASCII values byte for byte.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_false, assert_raises

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_iceberg import (
    ICE_T_BOOLEAN,
    ICE_T_INT,
    ICE_T_LONG,
    ICE_T_FLOAT,
    ICE_T_DOUBLE,
    ICE_T_STRING,
    IcebergSchema,
    PartitionSpec,
    SnapshotInfo,
    SummaryKV,
    schema_json,
    unpartitioned_spec_json,
    partition_spec_json,
    partition_spec_fields_json,
    delete_spec_of,
    snapshot_json,
    name_mapping_json,
    build_table_metadata_json,
    transform_name,
    read_current_snapshot_summary,
    summary_value_for,
)


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _schema() -> IcebergSchema:
    var s = IcebergSchema(0)
    s.add(String("id"), ICE_T_LONG, required=True)
    s.add(String("name"), ICE_T_STRING)
    return s^


def _snapshot(id: Int64, seq: Int64, parent: Int64) -> SnapshotInfo:
    return SnapshotInfo(
        id, seq, Int64(1700000000000), String("loc/metadata/snap.avro"),
        1, Int64(5), 2, Int64(9), 0, parent,
    )


def test_schema_json_shape() raises:
    assert_equal(
        schema_json(_schema()),
        String(
            '{"type":"struct","schema-id":0,"fields":['
            '{"id":1,"name":"id","required":true,"type":"long"},'
            '{"id":2,"name":"name","required":false,"type":"string"}]}'
        ),
    )


def test_metadata_has_every_required_v2_field() raises:
    var snaps = List[SnapshotInfo]()
    snaps.append(_snapshot(11, 1, -1))
    var md = build_table_metadata_json(
        String("11111111-2222-3333-4444-555555555555"),
        String("file:///tbl"),
        _schema(),
        snaps,
        Int64(11),
        Int64(1),
        Int64(1700000000000),
    )
    var _key_list: List[String] = [
        '"format-version":2',
        '"table-uuid":"11111111-2222-3333-4444-555555555555"',
        '"location":"file:///tbl"',
        '"last-sequence-number":1',
        '"last-updated-ms":1700000000000',
        '"last-column-id":2',
        '"schemas":[{"type":"struct"',
        '"current-schema-id":0',
        '"partition-specs":[{"spec-id":0,"fields":[]}]',
        '"default-spec-id":0',
        '"last-partition-id":999',
        '"sort-orders":[{"order-id":0,"fields":[]}]',
        '"default-sort-order-id":0',
        '"current-snapshot-id":11',
        '"snapshots":[{"snapshot-id":11',
        '"snapshot-log":[{"timestamp-ms":1700000000000,"snapshot-id":11}]',
        '"metadata-log":[]',    ]
    for key in _key_list:
        assert_true(_has(md, key), "metadata.json lacks " + key)
    # The main branch names the current snapshot (the spec requires the two
    # to agree).
    assert_true(
        _has(md, '"refs":{"main":{"snapshot-id":11,"type":"branch"}}'),
        "refs.main must name current-snapshot-id",
    )


def test_empty_table_has_no_main_ref() raises:
    var md = build_table_metadata_json(
        String("u"),
        String("loc"),
        _schema(),
        List[SnapshotInfo](),
        Int64(-1),
        Int64(0),
        Int64(5),
    )
    assert_true(_has(md, '"current-snapshot-id":-1'))
    assert_true(_has(md, '"snapshots":[]'))
    assert_false(_has(md, '"refs"'))


def test_name_mapping_property_binds_columns_by_name() raises:
    assert_equal(
        name_mapping_json(_schema()),
        String(
            '[{"field-id":1,"names":["id"]},{"field-id":2,"names":["name"]}]'
        ),
    )
    var md = build_table_metadata_json(
        String("u"), String("loc"), _schema(), List[SnapshotInfo](),
        Int64(-1), Int64(0), Int64(5),
    )
    assert_true(
        _has(
            md,
            '"properties":{"schema.name-mapping.default":"[{\\"field-id\\":1,',
        )
    )


def test_partition_spec_ids_and_json() raises:
    var spec = PartitionSpec(0)
    spec.add_bucket(1, 16, String("id_bucket"))
    spec.add_identity(2, String("name"))
    assert_equal(
        partition_spec_fields_json(spec),
        String(
            '[{"name":"id_bucket","transform":"bucket[16]","source-id":1,'
            '"field-id":1000},'
            '{"name":"name","transform":"identity","source-id":2,'
            '"field-id":1001}]'
        ),
    )
    assert_equal(
        partition_spec_json(spec),
        String('{"spec-id":0,"fields":') + partition_spec_fields_json(spec)
        + String("}"),
    )
    assert_equal(partition_spec_fields_json(PartitionSpec(0)), String("[]"))
    assert_equal(
        partition_spec_json(PartitionSpec(0)), unpartitioned_spec_json()
    )
    assert_equal(
        partition_spec_json(PartitionSpec(3)),
        String('{"spec-id":3,"fields":[]}'),
    )
    var md = build_table_metadata_json(
        String("u"), String("loc"), _schema(), List[SnapshotInfo](),
        Int64(-1), Int64(0), Int64(5), spec,
    )
    assert_true(_has(md, '"default-spec-id":0'))
    assert_true(_has(md, '"last-partition-id":1001'))
    # The table spec comes first (the default); the unpartitioned spec the
    # delete manifests are written under follows, under its own id.
    assert_true(
        _has(
            md,
            '"partition-specs":[{"spec-id":0,"fields":[{"name":"id_bucket"',
        )
    )
    assert_true(_has(md, '{"spec-id":1,"fields":[]}]'))
    assert_equal(transform_name(1, 16), String("bucket[16]"))
    with assert_raises():
        _ = transform_name(7, 0)


def test_prior_schemas_stay_in_the_schemas_array() raises:
    var old = _schema()
    var evolved = IcebergSchema(1)
    evolved.add(String("id"), ICE_T_LONG, required=True)
    evolved.add(String("name"), ICE_T_STRING)
    evolved.add(String("extra"), ICE_T_DOUBLE)
    var prior = List[String]()
    prior.append(schema_json(old))
    var md = build_table_metadata_json(
        String("u"), String("loc"), evolved, List[SnapshotInfo](),
        Int64(-1), Int64(0), Int64(5), PartitionSpec(0), prior^,
    )
    assert_true(
        _has(
            md,
            '"schemas":[{"type":"struct","schema-id":0,"fields":['
            '{"id":1,"name":"id","required":true,"type":"long"},'
            '{"id":2,"name":"name","required":false,"type":"string"}]},'
            '{"type":"struct","schema-id":1,"fields":[',
        )
    )
    assert_true(_has(md, '"current-schema-id":1'))
    assert_true(_has(md, '"last-column-id":3'))


def test_delete_spec_is_unpartitioned_with_its_own_id() raises:
    var spec = PartitionSpec(0)
    spec.add_identity(2, String("name"))
    var d = delete_spec_of(spec)
    assert_true(d.is_unpartitioned())
    assert_equal(d.spec_id, 1)
    # An unpartitioned table's delete manifests use its own spec.
    var u = delete_spec_of(PartitionSpec(4))
    assert_true(u.is_unpartitioned())
    assert_equal(u.spec_id, 4)
    # An unpartitioned table lists only its own spec.
    var md = build_table_metadata_json(
        String("u"), String("loc"), _schema(), List[SnapshotInfo](),
        Int64(-1), Int64(0), Int64(5),
    )
    assert_true(_has(md, '"partition-specs":[{"spec-id":0,"fields":[]}],'))


def test_snapshot_operation_is_carried() raises:
    var s = _snapshot(30, 3, 22)
    assert_equal(s.operation, String("append"))
    s.operation = String("overwrite")
    assert_true(_has(snapshot_json(s), '"summary":{"operation":"overwrite"'))
    assert_equal(s.copy().operation, String("overwrite"))
    var d = SnapshotInfo(
        Int64(31), Int64(4), Int64(5), String("m.avro"), 0, Int64(0), 1,
        Int64(2), 0, Int64(30), List[SummaryKV](), String("delete"),
    )
    assert_true(_has(snapshot_json(d), '"operation":"delete"'))


def test_snapshot_json_fields_and_summary() raises:
    var s = _snapshot(22, 2, 11)
    s.extra_summary.append(SummaryKV(String("pos"), String("a\"b")))
    var js = snapshot_json(s)
    var _key_list: List[String] = [
        '"snapshot-id":22',
        '"parent-snapshot-id":11',
        '"sequence-number":2',
        '"timestamp-ms":1700000000000',
        '"summary":{"operation":"append"',
        '"added-data-files":"1"',
        '"added-records":"5"',
        '"total-data-files":"2"',
        '"total-records":"9"',
        '"pos":"a\\"b"',
        '"manifest-list":"loc/metadata/snap.avro"',
        '"schema-id":0',    ]
    for key in _key_list:
        assert_true(_has(js, key), "snapshot lacks " + key)
    # No parent: the key is absent (a root snapshot).
    assert_false(_has(snapshot_json(_snapshot(1, 1, -1)), "parent-snapshot-id"))


def _put_metadata(
    mut store: InMemoryConditionalStore, md: String
) raises:
    _ = store.put(
        Path.parse(String("tbl/metadata/v1.metadata.json")),
        List[UInt8](md.as_bytes()),
    )
    _ = store.put(
        Path.parse(String("tbl/metadata/version-hint.text")),
        List[UInt8](String("1").as_bytes()),
    )


def test_summary_reader_returns_every_key_byte_for_byte() raises:
    var s = _snapshot(5, 1, -1)
    s.extra_summary.append(SummaryKV(String("shard-1"), String("seq-é日")))
    s.extra_summary.append(SummaryKV(String("shard-2"), String("l1\nl2")))
    var snaps = List[SnapshotInfo]()
    snaps.append(s^)
    var md = build_table_metadata_json(
        String("u"), String("tbl"), _schema(), snaps, Int64(5), Int64(1),
        Int64(9),
    )
    var store = InMemoryConditionalStore()
    _put_metadata(store, md)
    var kvs = read_current_snapshot_summary(store, String("tbl"))
    assert_equal(summary_value_for(kvs, String("operation")), String("append"))
    assert_equal(summary_value_for(kvs, String("total-records")), String("9"))
    assert_equal(
        summary_value_for(kvs, String("shard-1")), String("seq-é日")
    )
    assert_equal(summary_value_for(kvs, String("shard-2")), String("l1\nl2"))
    assert_equal(summary_value_for(kvs, String("absent")), String(""))


def test_summary_reader_of_a_never_committed_table_is_empty() raises:
    var store = InMemoryConditionalStore()
    var kvs = read_current_snapshot_summary(store, String("nothing"))
    assert_equal(len(kvs), 0)


def test_summary_reader_matches_the_current_snapshot_by_id() raises:
    var older = _snapshot(5, 1, -1)
    older.extra_summary.append(SummaryKV(String("who"), String("older")))
    var newer = _snapshot(6, 2, 5)
    newer.extra_summary.append(SummaryKV(String("who"), String("newer")))
    var snaps = List[SnapshotInfo]()
    snaps.append(older^)
    snaps.append(newer^)
    var md = build_table_metadata_json(
        String("u"), String("tbl"), _schema(), snaps, Int64(5), Int64(2),
        Int64(9),
    )
    var store = InMemoryConditionalStore()
    _put_metadata(store, md)
    var kvs = read_current_snapshot_summary(store, String("tbl"))
    # current-snapshot-id is 5, the FIRST snapshot: matched by id, not position.
    assert_equal(summary_value_for(kvs, String("who")), String("older"))


def test_summary_reader_survives_braces_quotes_and_controls_in_values() raises:
    # Values that look like JSON structure must not end the object early or
    # start another one.
    var nasty = String('}{"snapshot-id":99,"summary":{"x":"y"}} \\ end')
    var ctl = String("a")
    ctl += chr(0x01)
    ctl += String("b")
    var s = _snapshot(5, 1, -1)
    s.extra_summary.append(SummaryKV(String("nasty"), nasty.copy()))
    s.extra_summary.append(SummaryKV(String("ctl"), ctl.copy()))
    var snaps = List[SnapshotInfo]()
    snaps.append(s^)
    var md = build_table_metadata_json(
        String("u"), String("tbl"), _schema(), snaps, Int64(5), Int64(1),
        Int64(9),
    )
    var store = InMemoryConditionalStore()
    _put_metadata(store, md)
    var kvs = read_current_snapshot_summary(store, String("tbl"))
    assert_equal(summary_value_for(kvs, String("nasty")), nasty)
    assert_equal(summary_value_for(kvs, String("ctl")), ctl)
    assert_equal(summary_value_for(kvs, String("total-records")), String("9"))


def test_summary_reader_follows_a_version_the_hint_has_not_reached() raises:
    # v2 was committed (its metadata file exists) but the hint still says 1.
    var one = _snapshot(5, 1, -1)
    one.extra_summary.append(SummaryKV(String("pos"), String("a")))
    var snaps1 = List[SnapshotInfo]()
    snaps1.append(one.copy())
    var md1 = build_table_metadata_json(
        String("u"), String("tbl"), _schema(), snaps1, Int64(5), Int64(1), Int64(9),
    )
    var two = _snapshot(6, 2, 5)
    two.extra_summary.append(SummaryKV(String("pos"), String("b")))
    var snaps2 = List[SnapshotInfo]()
    snaps2.append(one^)
    snaps2.append(two^)
    var md2 = build_table_metadata_json(
        String("u"), String("tbl"), _schema(), snaps2, Int64(6), Int64(2), Int64(10),
    )
    var store = InMemoryConditionalStore()
    _put_metadata(store, md1)
    _ = store.put(
        Path.parse(String("tbl/metadata/v2.metadata.json")),
        List[UInt8](md2.as_bytes()),
    )
    var kvs = read_current_snapshot_summary(store, String("tbl"))
    assert_equal(summary_value_for(kvs, String("pos")), String("b"))


def test_summary_reader_refuses_a_corrupt_pointer() raises:
    var store = InMemoryConditionalStore()
    _ = store.put(
        Path.parse(String("tbl/metadata/version-hint.text")),
        List[UInt8](String("not a number").as_bytes()),
    )
    with assert_raises():
        _ = read_current_snapshot_summary(store, String("tbl"))


def main() raises:
    test_schema_json_shape()
    test_metadata_has_every_required_v2_field()
    test_empty_table_has_no_main_ref()
    test_name_mapping_property_binds_columns_by_name()
    test_partition_spec_ids_and_json()
    test_prior_schemas_stay_in_the_schemas_array()
    test_delete_spec_is_unpartitioned_with_its_own_id()
    test_snapshot_operation_is_carried()
    test_snapshot_json_fields_and_summary()
    test_summary_reader_returns_every_key_byte_for_byte()
    test_summary_reader_of_a_never_committed_table_is_empty()
    test_summary_reader_matches_the_current_snapshot_by_id()
    test_summary_reader_survives_braces_quotes_and_controls_in_values()
    test_summary_reader_follows_a_version_the_hint_has_not_reached()
    test_summary_reader_refuses_a_corrupt_pointer()
    print("test_iceberg_metadata_spec: all passed")
