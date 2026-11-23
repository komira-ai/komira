# =============================================================================
# plan_iceberg_scan: the files and deletes of a pinned snapshot
# =============================================================================
#
# Tables are written to the scratch directory with the fixture builders (no data
# file is opened by the planner, so none is written). What each test proves:
#   * test_files_are_listed_in_manifest_then_entry_order: every live data file of
#     two manifests, in that order, with its local path and its stored path, the
#     bound columns with their types and field ids, and the plan's counts.
#   * test_deleted_entries_are_dropped_and_existing_ones_kept: status 2 is not
#     read, status 0 and 1 are.
#   * test_entries_are_skipped_by_bounds_and_partition_values: a filter drops
#     the files whose bounds or identity partition value cannot match, counted.
#   * test_a_manifest_is_skipped_by_its_summaries_without_being_opened: the
#     skipped manifest's file does not exist and the plan succeeds; the same
#     plan with no filter names the manifest it cannot read.
#   * test_delete_files_apply_by_sequence_number_and_partition: a position delete
#     applies at an equal sequence number, an equality delete only at a greater
#     one; partitions scope both; `referenced_data_file` names one file in
#     another partition; a delete that applies to no data file is not listed; a
#     DELETED delete entry applies to none.
#   * test_an_equality_delete_of_an_unpartitioned_spec_applies_everywhere: it
#     reaches every partition, a position delete of that spec reaches none.
#   * test_unreadable_files_are_refused_by_name: an ORC data file, a PUFFIN delete
#     file, an equality delete over an id the schema lacks or listing no id, and
#     a delete file in a data manifest are refused; an ORC file the filter skips
#     and a PUFFIN delete that applies to nothing are not.
#   * test_a_v1_snapshot_lists_its_manifests_inline: v1 metadata and manifests.
#   * test_a_table_with_no_snapshot_has_columns_and_no_files.
#   * test_moved_tables_read_under_the_new_root: the manifests are found under the
#     root; without allow_moved_paths the old location is refused.
#   * test_time_travel_plans_the_named_snapshot.

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from avro.ocf_header import AVRO_CODEC_NULL
from plan_expr.expr import BIN_EQ, BIN_GT, Expr
from plan_expr.scalar_value import ScalarValue
from runtime_paths import test_tmpdir
from iceberg_scan.scan_planner import IcebergPlannedScan, plan_iceberg_scan
from iceberg_scan.table_fixture import (
    FixtureEntry,
    FixtureManifest,
    FixtureSummary,
    FixtureValue,
    fixture_long_bytes,
    fixture_manifest,
    fixture_manifest_list,
    fixture_metadata_json,
    fixture_snapshot_json,
    fixture_text_bytes,
)
from iceberg_scan.table_ref import iceberg_scan_binding, resolve_iceberg_table


comptime _FIELDS = String(
    '{"id": 1, "name": "id", "required": true, "type": "long"}, '
    '{"id": 2, "name": "region", "required": false, "type": "string"}, '
    '{"id": 3, "name": "x", "required": false, "type": "double"}'
)
comptime _SPEC = String(
    '{"name": "region", "transform": "identity", "source-id": 2, "field-id": 1000}'
)


def _put(path: String, data: List[UInt8]) raises:
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()


def _root(name: String) raises -> String:
    var root = test_tmpdir() + "/" + name
    makedirs(root + "/metadata", exist_ok=True)
    return root^


def _uri(root: String, tail: String) -> String:
    return "file://" + root + tail


def _names() -> List[String]:
    var out = List[String]()
    out.append("region")
    return out^


def _types() -> List[String]:
    var out = List[String]()
    out.append("string")
    return out^


def _entry(root: String, name: String, region: String) -> FixtureEntry:
    var e = FixtureEntry(_uri(root, "/data/" + name))
    e.partition.append(FixtureValue.of_text(region))
    return e^


def _write_manifest(
    root: String, name: String, entries: List[FixtureEntry]
) raises -> String:
    """Writes a manifest of the partition column `region`; returns its URI."""
    _put(
        root + "/metadata/" + name,
        fixture_manifest(entries, _names(), _types(), AVRO_CODEC_NULL),
    )
    return _uri(root, "/metadata/" + name)


def _publish(
    root: String,
    location: String,
    var manifests: List[FixtureManifest],
    extra_specs: String = "",
) raises:
    """Writes snapshot 1 (sequence number 1) over `manifests`, and the table."""
    _put(root + "/metadata/snap-1.avro", fixture_manifest_list(manifests, AVRO_CODEC_NULL))
    var snaps = List[String]()
    snaps.append(
        fixture_snapshot_json(1, 1, location + "/metadata/snap-1.avro", 0)
    )
    _put(
        root + "/metadata/v1.metadata.json",
        _bytes(fixture_metadata_json(location, _FIELDS, _SPEC, snaps, 1, extra_specs)),
    )
    _put(root + "/metadata/version-hint.text", _bytes("1"))


def _bytes(text: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in text.as_bytes():
        out.append(b)
    return out^


def _plan(
    root: String,
    moved: Bool = False,
    var filter: Optional[Expr] = None,
    snapshot: Optional[Int64] = None,
) raises -> IcebergPlannedScan:
    var binding = iceberg_scan_binding(resolve_iceberg_table(root, moved, snapshot))
    return plan_iceberg_scan(binding, filter)


def _where(column: String, op: UInt8, var lit: ScalarValue) -> Optional[Expr]:
    return Optional[Expr](Expr.binary(op, Expr.col_ref(column), Expr.literal(lit^)))


def _summary(lower: String, upper: String) -> FixtureSummary:
    var s = FixtureSummary()
    s.lower = Optional[List[UInt8]](fixture_text_bytes(lower))
    s.upper = Optional[List[UInt8]](fixture_text_bytes(upper))
    return s^


def _error_of(root: String, moved: Bool = False) -> String:
    try:
        _ = _plan(root, moved)
    except e:
        return String(e)
    return String("(planned)")


def test_files_are_listed_in_manifest_then_entry_order() raises:
    var root = _root("plan_order")
    var first = List[FixtureEntry]()
    first.append(_entry(root, "a1.parquet", "eu"))
    first.append(_entry(root, "a2.parquet", "us"))
    var second = List[FixtureEntry]()
    second.append(_entry(root, "a3.parquet", "eu"))
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "m0.avro", first)))
    manifests.append(FixtureManifest(_write_manifest(root, "m1.avro", second)))
    _publish(root, _uri(root, ""), manifests^)
    var planned = _plan(root)
    ref spec = planned.spec
    assert_equal(len(spec.column_names), 3)
    assert_equal(spec.column_names[1], "region")
    assert_true(spec.column_types[0] == ArrowType.INT64)
    assert_true(spec.column_types[1] == ArrowType.STRING)
    assert_true(spec.column_types[2] == ArrowType.FLOAT64)
    assert_equal(spec.column_field_ids[2], 3)
    assert_equal(len(spec.data_files), 3)
    assert_equal(spec.data_files[0].path, root + "/data/a1.parquet")
    assert_equal(spec.data_files[0].stored_path, _uri(root, "/data/a1.parquet"))
    assert_equal(spec.data_files[1].path, root + "/data/a2.parquet")
    assert_equal(spec.data_files[2].path, root + "/data/a3.parquet")
    assert_equal(len(spec.deletes), 0)
    assert_equal(len(spec.data_files[0].position_deletes), 0)
    assert_equal(planned.counts.manifests_read, 2)
    assert_equal(planned.counts.manifests_skipped, 0)
    assert_equal(planned.counts.data_files, 3)
    assert_equal(planned.counts.data_files_skipped, 0)
    assert_equal(planned.counts.delete_files, 0)
    # A second plan of the snapshot lists the same files in the same order.
    var again = _plan(root)
    for i in range(3):
        assert_equal(again.spec.data_files[i].path, spec.data_files[i].path)


def test_deleted_entries_are_dropped_and_existing_ones_kept() raises:
    var root = _root("plan_status")
    var entries = List[FixtureEntry]()
    var added = _entry(root, "added.parquet", "eu")
    var existing = _entry(root, "existing.parquet", "eu")
    existing.status = 0
    var deleted = _entry(root, "deleted.parquet", "eu")
    deleted.status = 2
    entries.append(added^)
    entries.append(deleted^)
    entries.append(existing^)
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "m0.avro", entries)))
    _publish(root, _uri(root, ""), manifests^)
    var planned = _plan(root)
    assert_equal(len(planned.spec.data_files), 2)
    assert_equal(planned.spec.data_files[0].path, root + "/data/added.parquet")
    assert_equal(planned.spec.data_files[1].path, root + "/data/existing.parquet")
    assert_equal(planned.counts.data_files_skipped, 0)


def test_entries_are_skipped_by_bounds_and_partition_values() raises:
    var root = _root("plan_prune_entries")
    var entries = List[FixtureEntry]()
    for k in range(3):
        var e = _entry(root, "f" + String(k) + ".parquet", "eu" if k < 2 else "us")
        e.lower.add(1, fixture_long_bytes(Int64(k * 10 + 1)))
        e.upper.add(1, fixture_long_bytes(Int64(k * 10 + 10)))
        entries.append(e^)
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "m0.avro", entries)))
    _publish(root, _uri(root, ""), manifests^)
    # f0 holds ids 1..10, f1 11..20, f2 21..30 (region us).
    var by_bounds = _plan(root, filter=_where("id", BIN_GT, ScalarValue.from_int64(15)))
    assert_equal(len(by_bounds.spec.data_files), 2)
    assert_equal(by_bounds.spec.data_files[0].path, root + "/data/f1.parquet")
    assert_equal(by_bounds.counts.data_files, 2)
    assert_equal(by_bounds.counts.data_files_skipped, 1)
    var by_region = _plan(root, filter=_where("region", BIN_EQ, ScalarValue.from_string("us")))
    assert_equal(len(by_region.spec.data_files), 1)
    assert_equal(by_region.spec.data_files[0].path, root + "/data/f2.parquet")
    assert_equal(by_region.counts.data_files_skipped, 2)
    var nothing = _plan(root, filter=_where("id", BIN_GT, ScalarValue.from_int64(1000)))
    assert_equal(len(nothing.spec.data_files), 0)
    assert_equal(nothing.counts.data_files_skipped, 3)


def test_a_manifest_is_skipped_by_its_summaries_without_being_opened() raises:
    var root = _root("plan_prune_manifests")
    var present = List[FixtureEntry]()
    present.append(_entry(root, "a.parquet", "b"))
    var manifests = List[FixtureManifest]()
    var m0 = FixtureManifest(_write_manifest(root, "m0.avro", present))
    m0.summaries.append(_summary("a", "c"))
    manifests.append(m0^)
    # The second manifest's file is never written.
    var m1 = FixtureManifest(_uri(root, "/metadata/never-written.avro"))
    m1.summaries.append(_summary("x", "z"))
    manifests.append(m1^)
    _publish(root, _uri(root, ""), manifests^)
    var planned = _plan(root, filter=_where("region", BIN_EQ, ScalarValue.from_string("b")))
    assert_equal(planned.counts.manifests_read, 1)
    assert_equal(planned.counts.manifests_skipped, 1)
    assert_equal(len(planned.spec.data_files), 1)
    assert_equal(
        _error_of(root),
        "ICEBERG_MANIFEST_INVALID: cannot read the manifest '"
        + _uri(root, "/metadata/never-written.avro")
        + "'",
    )


def _delete_entry(
    root: String, name: String, region: String, content: Int
) -> FixtureEntry:
    var e = _entry(root, name, region)
    e.content = content
    return e^


def test_delete_files_apply_by_sequence_number_and_partition() raises:
    var root = _root("plan_deletes")
    var data = List[FixtureEntry]()
    var d_eu = _entry(root, "d_eu.parquet", "eu")
    d_eu.sequence_number = Optional[Int64](1)
    var d_us = _entry(root, "d_us.parquet", "us")
    d_us.sequence_number = Optional[Int64](1)
    var d_new = _entry(root, "d_new_eu.parquet", "eu")
    d_new.sequence_number = Optional[Int64](5)
    data.append(d_eu^)
    data.append(d_us^)
    data.append(d_new^)

    var deletes = List[FixtureEntry]()
    var pos_eu = _delete_entry(root, "pos_eu.parquet", "eu", 1)
    var pos_asia = _delete_entry(root, "pos_asia.parquet", "asia", 1)
    var pos_ref = _delete_entry(root, "pos_ref.parquet", "zz", 1)
    pos_ref.referenced_data_file = Optional[String](_uri(root, "/data/d_us.parquet"))
    var eq_eu = _delete_entry(root, "eq_eu.parquet", "eu", 2)
    eq_eu.equality_ids.append(1)
    var eq_same_sequence = _delete_entry(root, "eq_us.parquet", "us", 2)
    eq_same_sequence.sequence_number = Optional[Int64](1)
    eq_same_sequence.equality_ids.append(1)
    var gone = _delete_entry(root, "pos_gone.parquet", "eu", 1)
    gone.status = 2
    # A delete naming a file by a path of another scheme names none of ours.
    var elsewhere = _delete_entry(root, "pos_s3.parquet", "eu", 1)
    elsewhere.referenced_data_file = Optional[String]("s3://bucket/data/d_eu.parquet")
    deletes.append(pos_eu^)
    deletes.append(pos_asia^)
    deletes.append(pos_ref^)
    deletes.append(eq_eu^)
    deletes.append(eq_same_sequence^)
    deletes.append(gone^)
    deletes.append(elsewhere^)

    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "data.avro", data)))
    var delete_manifest = FixtureManifest(_write_manifest(root, "deletes.avro", deletes))
    delete_manifest.content = 1
    delete_manifest.sequence_number = 3  # the deletes' entries inherit it
    manifests.append(delete_manifest^)
    _publish(root, _uri(root, ""), manifests^)

    var planned = _plan(root)
    ref spec = planned.spec
    assert_equal(len(spec.data_files), 3)
    assert_equal(planned.counts.delete_files, 3)
    assert_equal(len(spec.deletes), 3)
    assert_equal(spec.deletes[0].path, root + "/data/pos_eu.parquet")
    assert_equal(spec.deletes[0].content, 1)
    assert_equal(spec.deletes[0].file_format, "PARQUET")
    assert_equal(len(spec.deletes[0].equality_columns), 0)
    assert_equal(spec.deletes[1].path, root + "/data/pos_ref.parquet")
    assert_equal(spec.deletes[2].path, root + "/data/eq_eu.parquet")
    assert_equal(spec.deletes[2].content, 2)
    assert_equal(len(spec.deletes[2].equality_columns), 1)
    assert_equal(spec.deletes[2].equality_columns[0], "id")
    # d_eu (sequence 1): the position delete (3 >= 1) and the equality delete (1 < 3).
    assert_equal(len(spec.data_files[0].position_deletes), 1)
    assert_equal(spec.data_files[0].position_deletes[0], 0)
    assert_equal(len(spec.data_files[0].equality_deletes), 1)
    assert_equal(spec.data_files[0].equality_deletes[0], 2)
    # d_us: only the delete that names it; the equality delete of its partition
    # has the data file's own sequence number, which is not below it.
    assert_equal(len(spec.data_files[1].position_deletes), 1)
    assert_equal(spec.data_files[1].position_deletes[0], 1)
    assert_equal(len(spec.data_files[1].equality_deletes), 0)
    # d_new_eu (sequence 5) is newer than every delete.
    assert_equal(len(spec.data_files[2].position_deletes), 0)
    assert_equal(len(spec.data_files[2].equality_deletes), 0)
    assert_equal(planned.counts.manifests_read, 2)


def test_an_equality_delete_of_an_unpartitioned_spec_applies_everywhere() raises:
    var root = _root("plan_unpartitioned_delete")
    var data = List[FixtureEntry]()
    var eu = _entry(root, "eu.parquet", "eu")
    eu.sequence_number = Optional[Int64](1)
    var us = _entry(root, "us.parquet", "us")
    us.sequence_number = Optional[Int64](1)
    data.append(eu^)
    data.append(us^)
    var deletes = List[FixtureEntry]()
    var eq = FixtureEntry(_uri(root, "/data/eq_all.parquet"))
    eq.content = 2
    eq.equality_ids.append(2)
    var pos = FixtureEntry(_uri(root, "/data/pos_all.parquet"))
    pos.content = 1
    deletes.append(eq^)
    deletes.append(pos^)
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "data.avro", data)))
    _put(
        root + "/metadata/deletes.avro",
        fixture_manifest(deletes, List[String](), List[String](), AVRO_CODEC_NULL),
    )
    var dm = FixtureManifest(_uri(root, "/metadata/deletes.avro"))
    dm.content = 1
    dm.spec_id = 1
    dm.sequence_number = 4
    manifests.append(dm^)
    _publish(root, _uri(root, ""), manifests^, '{"spec-id": 1, "fields": []}')
    var planned = _plan(root)
    assert_equal(len(planned.spec.deletes), 1)
    assert_equal(planned.spec.deletes[0].path, root + "/data/eq_all.parquet")
    assert_equal(planned.spec.deletes[0].equality_columns[0], "region")
    for i in range(2):
        assert_equal(len(planned.spec.data_files[i].equality_deletes), 1)
        assert_equal(planned.spec.data_files[i].equality_deletes[0], 0)
        assert_equal(len(planned.spec.data_files[i].position_deletes), 0)


def _table_with(
    name: String, data: List[FixtureEntry], deletes: List[FixtureEntry]
) raises -> String:
    var root = _root(name)
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(_write_manifest(root, "data.avro", data)))
    if len(deletes) > 0:
        var dm = FixtureManifest(_write_manifest(root, "deletes.avro", deletes))
        dm.content = 1
        dm.sequence_number = 3
        manifests.append(dm^)
    _publish(root, _uri(root, ""), manifests^)
    return root^


def test_unreadable_files_are_refused_by_name() raises:
    var none = List[FixtureEntry]()
    # An ORC data file.
    var orc = List[FixtureEntry]()
    var orc_file = _entry("/t", "o.orc", "eu")
    orc_file.format = "ORC"
    orc.append(orc_file^)
    var orc_root = _table_with("plan_orc", orc, none)
    assert_equal(
        _error_of(orc_root),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: the data file format ORC of file:///t/data/o.orc"
        " is not read; only PARQUET is",
    )
    # ... which a filter that skips it never reads.
    var skipped_orc = List[FixtureEntry]()
    var skipped = _entry("/t", "o.orc", "eu")
    skipped.format = "ORC"
    skipped.lower.add(1, fixture_long_bytes(1))
    skipped.upper.add(1, fixture_long_bytes(5))
    skipped_orc.append(skipped^)
    var skip_root = _table_with("plan_orc_skipped", skipped_orc, none)
    var quiet = _plan(skip_root, filter=_where("id", BIN_GT, ScalarValue.from_int64(100)))
    assert_equal(len(quiet.spec.data_files), 0)

    # A PUFFIN delete file that applies, and one that applies to nothing.
    var data = List[FixtureEntry]()
    var d = _entry("/t", "d.parquet", "eu")
    d.sequence_number = Optional[Int64](1)
    data.append(d^)
    var puffin = List[FixtureEntry]()
    var dv = _delete_entry("/t", "dv.puffin", "eu", 1)
    dv.format = "PUFFIN"
    puffin.append(dv^)
    assert_equal(
        _error_of(_table_with("plan_puffin", data, puffin)),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: the delete file format PUFFIN of"
        " file:///t/data/dv.puffin is not read; only PARQUET and AVRO are",
    )
    var elsewhere = List[FixtureEntry]()
    var other = _delete_entry("/t", "dv2.puffin", "asia", 1)
    other.format = "PUFFIN"
    elsewhere.append(other^)
    var unused = _plan(_table_with("plan_puffin_unused", data, elsewhere))
    assert_equal(len(unused.spec.deletes), 0)

    # Equality deletes over an id the scanned schema lacks, and over none.
    var unknown = List[FixtureEntry]()
    var eq = _delete_entry("/t", "eq.parquet", "eu", 2)
    eq.equality_ids.append(99)
    unknown.append(eq^)
    assert_equal(
        _error_of(_table_with("plan_eq_unknown", data, unknown)),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: the equality delete file"
        " file:///t/data/eq.parquet compares field id 99, which the scanned"
        " schema does not hold",
    )
    var no_ids = List[FixtureEntry]()
    no_ids.append(_delete_entry("/t", "eq0.parquet", "eu", 2))
    assert_equal(
        _error_of(_table_with("plan_eq_no_ids", data, no_ids)),
        "ICEBERG_MANIFEST_INVALID: the equality delete file"
        " file:///t/data/eq0.parquet lists no equality_ids",
    )

    # A delete file in a data manifest, and a data file in a delete manifest.
    var mixed = List[FixtureEntry]()
    mixed.append(_delete_entry("/t", "x.parquet", "eu", 1))
    var mixed_root = _table_with("plan_mixed_data", mixed, none)
    assert_equal(
        _error_of(mixed_root),
        "ICEBERG_MANIFEST_INVALID: the manifest "
        + _uri(mixed_root, "/metadata/data.avro")
        + " holds the file file:///t/data/x.parquet of the other content kind",
    )
    var data_in_deletes = List[FixtureEntry]()
    data_in_deletes.append(_entry("/t", "y.parquet", "eu"))
    var swapped = _table_with("plan_mixed_deletes", data, data_in_deletes)
    assert_equal(
        _error_of(swapped),
        "ICEBERG_MANIFEST_INVALID: the manifest "
        + _uri(swapped, "/metadata/deletes.avro")
        + " holds the file file:///t/data/y.parquet of the other content kind",
    )


def test_a_v1_snapshot_lists_its_manifests_inline() raises:
    var root = _root("plan_v1")
    var entries = List[FixtureEntry]()
    entries.append(FixtureEntry(_uri(root, "/data/one.parquet")))
    var more = List[FixtureEntry]()
    more.append(FixtureEntry(_uri(root, "/data/two.parquet")))
    _put(
        root + "/metadata/m0.avro",
        fixture_manifest(entries, List[String](), List[String](), AVRO_CODEC_NULL, v1=True),
    )
    _put(
        root + "/metadata/m1.avro",
        fixture_manifest(more, List[String](), List[String](), AVRO_CODEC_NULL, v1=True),
    )
    var text = String(
        '{"format-version": 1, "location": "' + _uri(root, "") + '",'
        ' "schema": {"type": "struct", "fields": ['
        '{"id": 1, "name": "id", "required": true, "type": "long"}]},'
        ' "partition-spec": [],'
        ' "snapshots": [{"snapshot-id": 8, "timestamp-ms": 1788300000000,'
        ' "manifests": ["' + _uri(root, "/metadata/m0.avro") + '", "'
        + _uri(root, "/metadata/m1.avro") + '"]}],'
        ' "current-snapshot-id": 8}'
    )
    _put(root + "/metadata/v1.metadata.json", _bytes(text))
    _put(root + "/metadata/version-hint.text", _bytes("1"))
    var planned = _plan(root)
    assert_equal(len(planned.spec.column_names), 1)
    assert_equal(len(planned.spec.data_files), 2)
    assert_equal(planned.spec.data_files[0].path, root + "/data/one.parquet")
    assert_equal(planned.spec.data_files[1].path, root + "/data/two.parquet")
    assert_equal(planned.counts.manifests_read, 2)

    var empty_root = _root("plan_v1_empty")
    _put(
        empty_root + "/metadata/v1.metadata.json",
        _bytes(
            '{"format-version": 1, "location": "/t", "schema": {"fields": []},'
            ' "snapshots": [{"snapshot-id": 8, "manifests": []}],'
            ' "current-snapshot-id": 8}'
        ),
    )
    _put(empty_root + "/metadata/version-hint.text", _bytes("1"))
    assert_equal(len(_plan(empty_root).spec.data_files), 0)


def test_a_table_with_no_snapshot_has_columns_and_no_files() raises:
    var root = _root("plan_no_snapshot")
    _put(
        root + "/metadata/v1.metadata.json",
        _bytes(fixture_metadata_json(_uri(root, ""), _FIELDS, _SPEC, List[String](), -1)),
    )
    _put(root + "/metadata/version-hint.text", _bytes("1"))
    var planned = _plan(root)
    assert_equal(len(planned.spec.column_names), 3)
    assert_equal(len(planned.spec.data_files), 0)
    assert_equal(planned.counts.manifests_read, 0)


def test_moved_tables_read_under_the_new_root() raises:
    var root = _root("plan_moved")
    var old = String("file:///old/place/orders")
    var entries = List[FixtureEntry]()
    var e = FixtureEntry(old + "/data/a.parquet")
    e.partition.append(FixtureValue.of_text("eu"))
    entries.append(e^)
    _put(
        root + "/metadata/m0.avro",
        fixture_manifest(entries, _names(), _types(), AVRO_CODEC_NULL),
    )
    var manifests = List[FixtureManifest]()
    manifests.append(FixtureManifest(old + "/metadata/m0.avro"))
    _publish(root, old, manifests^)
    var planned = _plan(root, moved=True)
    assert_equal(len(planned.spec.data_files), 1)
    assert_equal(planned.spec.data_files[0].path, root + "/data/a.parquet")
    assert_equal(planned.spec.data_files[0].stored_path, old + "/data/a.parquet")
    # Without the option the recorded paths are the paths: the first read is
    # of the manifest list, which is not at the old location.
    assert_equal(
        _error_of(root),
        "ICEBERG_MANIFEST_INVALID: cannot read the manifest list '"
        + old
        + "/metadata/snap-1.avro'",
    )


def test_time_travel_plans_the_named_snapshot() raises:
    var root = _root("plan_time_travel")
    var first = List[FixtureEntry]()
    first.append(_entry(root, "old.parquet", "eu"))
    var both = List[FixtureEntry]()
    both.append(_entry(root, "old.parquet", "eu"))
    both.append(_entry(root, "new.parquet", "eu"))
    var m0 = List[FixtureManifest]()
    m0.append(FixtureManifest(_write_manifest(root, "m0.avro", first)))
    var m1 = List[FixtureManifest]()
    m1.append(FixtureManifest(_write_manifest(root, "m1.avro", both)))
    _put(root + "/metadata/snap-1.avro", fixture_manifest_list(m0, AVRO_CODEC_NULL))
    _put(root + "/metadata/snap-2.avro", fixture_manifest_list(m1, AVRO_CODEC_NULL))
    var snaps = List[String]()
    snaps.append(fixture_snapshot_json(1, 1, _uri(root, "/metadata/snap-1.avro"), 0))
    snaps.append(fixture_snapshot_json(2, 2, _uri(root, "/metadata/snap-2.avro"), 0))
    _put(
        root + "/metadata/v1.metadata.json",
        _bytes(fixture_metadata_json(_uri(root, ""), _FIELDS, _SPEC, snaps, 2)),
    )
    _put(root + "/metadata/version-hint.text", _bytes("1"))
    assert_equal(len(_plan(root).spec.data_files), 2)
    var older = _plan(root, snapshot=Optional[Int64](1))
    assert_equal(len(older.spec.data_files), 1)
    assert_equal(older.spec.data_files[0].path, root + "/data/old.parquet")


def main() raises:
    var suite = TestSuite()
    suite.test[test_files_are_listed_in_manifest_then_entry_order]()
    suite.test[test_deleted_entries_are_dropped_and_existing_ones_kept]()
    suite.test[test_entries_are_skipped_by_bounds_and_partition_values]()
    suite.test[test_a_manifest_is_skipped_by_its_summaries_without_being_opened]()
    suite.test[test_delete_files_apply_by_sequence_number_and_partition]()
    suite.test[test_an_equality_delete_of_an_unpartitioned_spec_applies_everywhere]()
    suite.test[test_unreadable_files_are_refused_by_name]()
    suite.test[test_a_v1_snapshot_lists_its_manifests_inline]()
    suite.test[test_a_table_with_no_snapshot_has_columns_and_no_files]()
    suite.test[test_moved_tables_read_under_the_new_root]()
    suite.test[test_time_travel_plans_the_named_snapshot]()
    suite^.run()
