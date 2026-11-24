# =============================================================================
# resolve_iceberg_table, the scan binding and local_path_of
# =============================================================================
#
# What each test proves:
#   * test_a_directory_resolves_through_its_version_hint: a table directory reads
#     `metadata/v<N>.metadata.json` for the N in `version-hint.text` (with or
#     without a trailing newline or slash), and the ref names the metadata
#     path, the root, the location, the pinned snapshot and the columns.
#   * test_no_version_hint_is_refused_naming_the_path: a directory with no hint is
#     ICEBERG_TABLE_VERSION_UNKNOWN naming the directory; a hint that is no
#     number, and a hint naming a metadata file that is not there, are
#     ICEBERG_METADATA_INVALID.
#   * test_a_metadata_file_resolves_directly: a `*.metadata.json` file takes the
#     parent of its `metadata/` directory as the root, and its own directory
#     when it is not in one.
#   * test_file_uris_scheme_refusal_and_missing_paths: a `file:` URI of either
#     spelling resolves; any other scheme and a host are
#     ICEBERG_PATH_UNSUPPORTED; a path that is not there is
#     ICEBERG_METADATA_INVALID.
#   * test_every_supported_type_maps_to_its_arrow_field: boolean, int, long,
#     float, double, string, date, timestamp (no zone), timestamptz (UTC) and
#     decimal(9, 2) map to nullable Arrow fields.
#   * test_unsupported_types_are_refused_naming_the_column: uuid, binary, fixed,
#     time, a struct, and decimals past 38 digits or with no precision are
#     ICEBERG_TYPE_UNSUPPORTED naming the column and type, at resolve.
#   * test_snapshots_pin_and_time_travel_reads_that_snapshots_schema: the
#     current snapshot and current schema by default; `snapshot_from_id` pins
#     that snapshot and its schema-id (the current schema when it has none); an
#     unknown id is ICEBERG_SNAPSHOT_NOT_FOUND; a table with no snapshot pins -1.
#   * test_format_version_three_is_refused_at_resolve: the refusal names
#     the version.
#   * test_binding_identity: the binding carries the kind, params, schema, a
#     pinned snapshot token, the zonemap gate and an identity that changes
#     with the snapshot and with `allow_moved_paths`.
#   * test_a_binding_reads_back_and_refuses_other_kinds: `iceberg_table_ref_of`
#     returns the pinned table, refuses a binding of another kind, and refuses a
#     metadata file that no longer lists the snapshot; `is_iceberg_binding`
#     tells the kind from another binding and from a legacy source.
#   * test_local_paths_and_relocation: bare paths and file: URIs read as local
#     paths; with allow_moved_paths a URI under the recorded location (of any
#     scheme, with or without a trailing slash, never a sibling that merely
#     shares the prefix) moves under the root; without it another scheme is
#     refused.

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from runtime_paths import test_tmpdir
from scan_source.parquet_source import ParquetSource
from scan_source.pushdown_gate import GATE_SHAPED
from scan_source.scan_binding import (
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_PINNED,
    scan_kind_id,
)
from scan_source.source_variant import SourceVariant
from iceberg_scan.table_fixture import (
    fixture_metadata_json,
    fixture_snapshot_json,
    fixture_text_bytes,
)
from iceberg_scan.table_ref import (
    iceberg_arrow_type,
    iceberg_scan_binding,
    iceberg_table_ref_of,
    is_iceberg_binding,
    local_path_of,
    resolve_iceberg_table,
)


comptime _FIELDS = String(
    '{"id": 1, "name": "id", "required": true, "type": "long"}, '
    '{"id": 2, "name": "region", "required": false, "type": "string"}'
)
comptime _SPEC = String(
    '{"name": "region", "transform": "identity", "source-id": 2, "field-id": 1000}'
)


def _write_text(path: String, text: String) raises:
    var data = fixture_text_bytes(text)
    var fh = open(path, "w")
    fh.write_bytes(Span(data))
    fh.close()


def _snapshots() -> List[String]:
    var snaps = List[String]()
    snaps.append(fixture_snapshot_json(11, 1, "x/snap-11.avro", 0))
    snaps.append(fixture_snapshot_json(12, 2, "x/snap-12.avro", 0))
    return snaps^


def _table(
    name: String,
    location: String,
    fields: String = _FIELDS,
    current: Int64 = 12,
    hint: String = "1\n",
) raises -> String:
    """A table directory with `metadata/v1.metadata.json` and a hint."""
    var root = test_tmpdir() + "/" + name
    makedirs(root + "/metadata", exist_ok=True)
    var snaps = List[String]()
    if current >= 0:
        snaps = _snapshots()
    _write_text(
        root + "/metadata/v1.metadata.json",
        fixture_metadata_json(location, fields, _SPEC, snaps, current),
    )
    if hint.byte_length() > 0:
        _write_text(root + "/metadata/version-hint.text", hint)
    return root^


def _error_of(path: String) -> String:
    try:
        _ = resolve_iceberg_table(path, False, None)
    except e:
        return String(e)
    return String("(accepted)")


def test_a_directory_resolves_through_its_version_hint() raises:
    var root = _table("ref_hint", "file:///w/t")
    var t = resolve_iceberg_table(root, False, None)
    assert_equal(t.metadata_path, root + "/metadata/v1.metadata.json")
    assert_equal(t.table_root, root)
    assert_equal(t.location, "file:///w/t")
    assert_false(t.allow_moved_paths)
    assert_equal(t.format_version, 2)
    assert_equal(t.snapshot_id, 12)
    assert_equal(t.schema_id, 0)
    assert_equal(len(t.columns), 2)
    assert_equal(t.columns[1].name, "region")
    assert_equal(t.arrow_schema.num_columns(), 2)
    assert_equal(t.arrow_schema.field_name(0), "id")
    assert_true(t.arrow_schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(t.arrow_schema.field_arrow_type(1) == ArrowType.STRING)
    # The trailing slash and a hint without a newline read the same table.
    var again = resolve_iceberg_table(root + "/", True, None)
    assert_equal(again.table_root, root)
    assert_true(again.allow_moved_paths)
    var bare_hint = _table("ref_hint_bare", "file:///w/t", hint="  1")
    assert_equal(
        resolve_iceberg_table(bare_hint, False, None).metadata_path,
        bare_hint + "/metadata/v1.metadata.json",
    )


def test_no_version_hint_is_refused_naming_the_path() raises:
    var no_hint = _table("ref_no_hint", "file:///w/t", hint="")
    assert_equal(
        _error_of(no_hint),
        "ICEBERG_TABLE_VERSION_UNKNOWN: "
        + no_hint
        + " has no metadata/version-hint.text; name the .metadata.json file",
    )
    var junk = _table("ref_junk_hint", "file:///w/t", hint="latest\n")
    assert_equal(
        _error_of(junk),
        "ICEBERG_METADATA_INVALID: "
        + junk
        + "/metadata/version-hint.text does not hold a version number",
    )
    var long_hint = _table("ref_long_hint", "file:///w/t", hint="12345678901")
    assert_equal(
        _error_of(long_hint),
        "ICEBERG_METADATA_INVALID: "
        + long_hint
        + "/metadata/version-hint.text does not hold a version number",
    )
    var gone = _table("ref_gone", "file:///w/t", hint="9\n")
    assert_equal(
        _error_of(gone),
        "ICEBERG_METADATA_INVALID: cannot read the metadata file '"
        + gone
        + "/metadata/v9.metadata.json'",
    )


def test_a_metadata_file_resolves_directly() raises:
    var root = _table("ref_file", "file:///w/t")
    var named = root + "/metadata/00007-9c12d441.metadata.json"
    _write_text(named, fixture_metadata_json("file:///w/t", _FIELDS, _SPEC, _snapshots(), 12))
    var t = resolve_iceberg_table(named, False, None)
    assert_equal(t.metadata_path, named)
    assert_equal(t.table_root, root)
    var loose = test_tmpdir() + "/ref_file_loose"
    makedirs(loose, exist_ok=True)
    _write_text(loose + "/t.metadata.json", fixture_metadata_json("/w/t", _FIELDS, _SPEC, _snapshots(), 12))
    var u = resolve_iceberg_table(loose + "/t.metadata.json", False, None)
    assert_equal(u.table_root, loose)


def test_file_uris_scheme_refusal_and_missing_paths() raises:
    var root = _table("ref_uri", "file:///w/t")
    var long_form = resolve_iceberg_table("file://" + root, False, None)
    assert_equal(long_form.table_root, root)
    var short_form = resolve_iceberg_table("file:" + root, False, None)
    assert_equal(short_form.table_root, root)
    assert_equal(
        _error_of("s3://bucket/warehouse/t"),
        "ICEBERG_PATH_UNSUPPORTED: 's3://bucket/warehouse/t' has the scheme 's3';"
        " only local files (a bare path or a file: URI) are read",
    )
    assert_equal(
        _error_of("file://somehost/warehouse/t"),
        "ICEBERG_PATH_UNSUPPORTED: 'file://somehost/warehouse/t' names a host;"
        " only local files are read",
    )
    var missing = test_tmpdir() + "/ref_not_there"
    assert_equal(
        _error_of(missing),
        "ICEBERG_METADATA_INVALID: no table at '" + missing + "'",
    )
    var bad = test_tmpdir() + "/ref_bad_metadata.metadata.json"
    _write_text(bad, "{ this is not metadata")
    assert_true(_error_of(bad).startswith("ICEBERG_METADATA_INVALID: not JSON: "))


def test_every_supported_type_maps_to_its_arrow_field() raises:
    var fields = String(
        '{"id": 1, "name": "c_bool", "required": false, "type": "boolean"}, '
        '{"id": 2, "name": "c_int", "required": false, "type": "int"}, '
        '{"id": 3, "name": "c_long", "required": true, "type": "long"}, '
        '{"id": 4, "name": "c_float", "required": false, "type": "float"}, '
        '{"id": 5, "name": "c_double", "required": false, "type": "double"}, '
        '{"id": 6, "name": "c_string", "required": false, "type": "string"}, '
        '{"id": 7, "name": "c_date", "required": false, "type": "date"}, '
        '{"id": 8, "name": "c_ts", "required": false, "type": "timestamp"}, '
        '{"id": 9, "name": "c_tstz", "required": false, "type": "timestamptz"}, '
        '{"id": 10, "name": "c_dec", "required": false, "type": "decimal(9, 2)"}'
    )
    var root = _table("ref_types", "file:///w/t", fields)
    var t = resolve_iceberg_table(root, False, None)
    var s = t.arrow_schema.copy()
    assert_equal(s.num_columns(), 10)
    assert_true(s.field_arrow_type(0) == ArrowType.BOOL)
    assert_true(s.field_arrow_type(1) == ArrowType.INT32)
    assert_true(s.field_arrow_type(2) == ArrowType.INT64)
    assert_true(s.field_arrow_type(3) == ArrowType.FLOAT32)
    assert_true(s.field_arrow_type(4) == ArrowType.FLOAT64)
    assert_true(s.field_arrow_type(5) == ArrowType.STRING)
    assert_true(s.field_arrow_type(6) == ArrowType.DATE32)
    assert_true(s.field_arrow_type(7) == ArrowType.TIMESTAMP_US)
    assert_equal(s.field_tz(7), "")
    assert_true(s.field_arrow_type(8) == ArrowType.TIMESTAMP_US)
    assert_equal(s.field_tz(8), "UTC")
    assert_true(s.field_arrow_type(9) == ArrowType.DECIMAL128)
    assert_equal(s.field_decimal_precision(9), 9)
    assert_equal(s.field_decimal_scale(9), 2)
    for i in range(10):
        assert_true(s.field_nullable(i))
    assert_true(iceberg_arrow_type("long", "x") == ArrowType.INT64)


def _unsupported_message(n: Int, type_json: String) raises -> String:
    var fields = (
        String('{"id": 1, "name": "ok", "required": false, "type": "long"}, ')
        + '{"id": 2, "name": "odd", "required": false, "type": '
        + type_json
        + "}"
    )
    return _error_of(_table("ref_unsupported_" + String(n), "file:///w/t", fields))


def _unsupported(type_text: String) -> String:
    return (
        "ICEBERG_TYPE_UNSUPPORTED: column 'odd' has the type '"
        + type_text
        + "', which is not read yet"
    )


def test_unsupported_types_are_refused_naming_the_column() raises:
    assert_equal(_unsupported_message(0, '"uuid"'), _unsupported("uuid"))
    assert_equal(_unsupported_message(1, '"binary"'), _unsupported("binary"))
    assert_equal(_unsupported_message(2, '"fixed[16]"'), _unsupported("fixed[16]"))
    assert_equal(_unsupported_message(3, '"time"'), _unsupported("time"))
    assert_equal(
        _unsupported_message(4, '"decimal(40, 2)"'), _unsupported("decimal(40,2)")
    )
    assert_equal(
        _unsupported_message(5, '"decimal(0, 0)"'), _unsupported("decimal(0,0)")
    )
    assert_equal(
        _unsupported_message(6, '"decimal(x, 2)"'), _unsupported("decimal(x,2)")
    )
    assert_equal(_unsupported_message(7, '"decimal(5)"'), _unsupported("decimal(5)"))
    var nested = _unsupported_message(8, '{"type": "struct", "fields": []}')
    assert_true(
        nested.startswith("ICEBERG_TYPE_UNSUPPORTED: column 'odd' has the type '{")
    )


def test_snapshots_pin_and_time_travel_reads_that_snapshots_schema() raises:
    var root = test_tmpdir() + "/ref_time_travel"
    makedirs(root + "/metadata", exist_ok=True)
    var text = String(
        '{"format-version": 2, "location": "/w/t", "last-sequence-number": 2,'
        ' "current-schema-id": 1,'
        ' "schemas": ['
        '{"type": "struct", "schema-id": 0, "fields": ['
        '{"id": 1, "name": "id", "required": true, "type": "long"}]},'
        '{"type": "struct", "schema-id": 1, "fields": ['
        '{"id": 1, "name": "id", "required": true, "type": "long"},'
        '{"id": 2, "name": "note", "required": false, "type": "string"}]}],'
        ' "default-spec-id": 0,'
        ' "partition-specs": [{"spec-id": 0, "fields": []}],'
        ' "snapshots": ['
        '{"snapshot-id": 1, "sequence-number": 1, "timestamp-ms": 1788300000001,'
        ' "manifest-list": "a.avro", "schema-id": 0},'
        '{"snapshot-id": 2, "sequence-number": 2, "timestamp-ms": 1788300000002,'
        ' "manifest-list": "b.avro"}],'
        ' "current-snapshot-id": 2}'
    )
    var path = root + "/metadata/t.metadata.json"
    _write_text(path, text)
    var current = resolve_iceberg_table(path, False, None)
    assert_equal(current.snapshot_id, 2)
    assert_equal(current.schema_id, 1)
    assert_equal(len(current.columns), 2)
    var older = resolve_iceberg_table(path, False, Int64(1))
    assert_equal(older.snapshot_id, 1)
    assert_equal(older.schema_id, 0)
    assert_equal(len(older.columns), 1)
    var no_schema_id = resolve_iceberg_table(path, False, Int64(2))
    assert_equal(no_schema_id.schema_id, 1)
    try:
        _ = resolve_iceberg_table(path, False, Int64(99))
        assert_true(False, "an unknown snapshot resolved")
    except e:
        assert_equal(
            String(e), "ICEBERG_SNAPSHOT_NOT_FOUND: the table has no snapshot 99"
        )
    var empty = _table("ref_no_snapshot", "file:///w/t", current=-1)
    assert_equal(resolve_iceberg_table(empty, False, None).snapshot_id, -1)


def test_format_version_three_is_refused_at_resolve() raises:
    var root = test_tmpdir() + "/ref_v3"
    makedirs(root, exist_ok=True)
    var path = root + "/t.metadata.json"
    _write_text(path, '{"format-version": 3, "location": "/w/t"}')
    assert_equal(
        _error_of(path),
        "OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED: format-version 3",
    )


def test_binding_identity() raises:
    var root = _table("ref_binding", "file:///w/t")
    var t = resolve_iceberg_table(root, False, None)
    var b = iceberg_scan_binding(t)
    assert_equal(b.kind_name, "komira.iceberg.table")
    assert_equal(b.kind_id, scan_kind_id("komira.iceberg.table"))
    assert_equal(b.name, t.metadata_path)
    assert_equal(b.params.get_str("metadata_path"), t.metadata_path)
    assert_equal(b.params.get_str("table_root"), root)
    assert_false(b.params.get_bool("allow_moved_paths"))
    assert_equal(b.params.get_i64("snapshot_id"), 12)
    assert_equal(b.params.get_i64("schema_id"), 0)
    assert_equal(b.schema.num_columns(), 2)
    assert_equal(b.schema.field_name(1), "region")
    assert_equal(b.snapshot_policy, SNAPSHOT_PINNED)
    assert_equal(b.snapshot_token, UInt64(12))
    assert_equal(b.orientation, SCAN_ORIENTATION_COLUMNAR)
    assert_equal(b.fingerprint, b.structural_id)
    assert_equal(b.pushdown_gate.mode, GATE_SHAPED)
    assert_false(b.pushdown_gate.require_stat_friendly_col)
    # The same table resolved again has the same identity; a different
    # snapshot or relocation flag has another.
    var same = iceberg_scan_binding(resolve_iceberg_table(root, False, None))
    assert_equal(same.fingerprint, b.fingerprint)
    var older = iceberg_scan_binding(resolve_iceberg_table(root, False, Int64(11)))
    assert_true(older.fingerprint != b.fingerprint)
    var moved = iceberg_scan_binding(resolve_iceberg_table(root, True, None))
    assert_true(moved.fingerprint != b.fingerprint)
    assert_true(moved.params.get_bool("allow_moved_paths"))
    var empty = _table("ref_binding_empty", "file:///w/t", current=-1)
    var e = iceberg_scan_binding(resolve_iceberg_table(empty, False, None))
    assert_equal(e.snapshot_token, UInt64(0))
    assert_equal(e.params.get_i64("snapshot_id"), -1)


def test_a_binding_reads_back_and_refuses_other_kinds() raises:
    var root = _table("ref_readback", "file:///w/t")
    var t = resolve_iceberg_table(root, True, Int64(11))
    var b = iceberg_scan_binding(t)
    var back = iceberg_table_ref_of(b)
    assert_equal(back.metadata_path, t.metadata_path)
    assert_equal(back.table_root, t.table_root)
    assert_equal(back.snapshot_id, 11)
    assert_equal(back.schema_id, 0)
    assert_true(back.allow_moved_paths)
    assert_equal(len(back.columns), 2)
    assert_true(is_iceberg_binding(SourceVariant.from_binding(b.copy())))
    var other = b.copy()
    other.kind_name = String("komira.other")
    assert_false(is_iceberg_binding(SourceVariant.from_binding(other.copy())))
    try:
        _ = iceberg_table_ref_of(other)
        assert_true(False, "a binding of another kind was read as a table")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_METADATA_INVALID: a 'komira.other' binding is not an Iceberg table",
        )
    var legacy = SourceVariant(ParquetSource("x.parquet", t.arrow_schema.copy()))
    assert_false(is_iceberg_binding(legacy))
    # The metadata file no longer lists the snapshot.
    _write_text(
        t.metadata_path,
        fixture_metadata_json("file:///w/t", _FIELDS, _SPEC, List[String](), -1),
    )
    try:
        _ = iceberg_table_ref_of(b)
        assert_true(False, "a snapshot that is gone was read")
    except e:
        assert_equal(
            String(e), "ICEBERG_SNAPSHOT_NOT_FOUND: the table has no snapshot 11"
        )


def test_local_paths_and_relocation() raises:
    var root = _table("ref_paths", "file:///warehouse/db/orders")
    var moved = resolve_iceberg_table(root, True, None)
    var fixed = resolve_iceberg_table(root, False, None)
    var data = "file:///warehouse/db/orders/data/f.parquet"
    assert_equal(local_path_of(data, moved), root + "/data/f.parquet")
    assert_equal(local_path_of("file:///warehouse/db/orders", moved), root)
    assert_equal(
        local_path_of("file:///warehouse/db/orders2/x.parquet", moved),
        "/warehouse/db/orders2/x.parquet",
    )
    assert_equal(local_path_of("/warehouse/db/orders/data/g.parquet", moved), root + "/data/g.parquet")
    assert_equal(local_path_of(data, fixed), "/warehouse/db/orders/data/f.parquet")
    assert_equal(local_path_of("file:/a/b", fixed), "/a/b")
    assert_equal(local_path_of("/a/b", fixed), "/a/b")
    assert_equal(local_path_of("rel/b", fixed), "rel/b")
    assert_equal(local_path_of("FILE:///a/b", fixed), "/a/b")
    try:
        _ = local_path_of("file://somehost/a", fixed)
        assert_true(False, "a host was accepted")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_PATH_UNSUPPORTED: 'file://somehost/a' names a host;"
            " only local files are read",
        )

    var remote = _table("ref_paths_s3", "s3://bucket/orders/")
    var moved_s3 = resolve_iceberg_table(remote, True, None)
    var fixed_s3 = resolve_iceberg_table(remote, False, None)
    assert_equal(
        local_path_of("s3://bucket/orders/data/x.parquet", moved_s3),
        remote + "/data/x.parquet",
    )
    try:
        _ = local_path_of("s3://bucket/orders/data/x.parquet", fixed_s3)
        assert_true(False, "an s3 path was accepted")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_PATH_UNSUPPORTED: 's3://bucket/orders/data/x.parquet' has the"
            " scheme 's3'; only local files (a bare path or a file: URI) are read",
        )

    # A scheme may hold digits, `+`, `-` and `.`; a drive letter and a bare
    # name are paths.
    try:
        _ = local_path_of("my-scheme+x.y://host/p", fixed)
        assert_true(False, "a made-up scheme was accepted")
    except e:
        assert_equal(
            String(e),
            "ICEBERG_PATH_UNSUPPORTED: 'my-scheme+x.y://host/p' has the scheme"
            " 'my-scheme+x.y'; only local files (a bare path or a file: URI) are read",
        )
    assert_equal(local_path_of("C:/x", fixed), "C:/x")
    assert_equal(local_path_of("plain", fixed), "plain")
    assert_equal(local_path_of("1abc:/x", fixed), "1abc:/x")

    # A recorded location that names a host cannot be a prefix of anything.
    var hosted = _table("ref_paths_host", "file://somehost/t")
    var moved_host = resolve_iceberg_table(hosted, True, None)
    assert_equal(local_path_of("/a/b", moved_host), "/a/b")

    var unlocated = _table("ref_paths_empty", "")
    var no_location = resolve_iceberg_table(unlocated, True, None)
    assert_equal(local_path_of("/x/y", no_location), "/x/y")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_directory_resolves_through_its_version_hint]()
    suite.test[test_no_version_hint_is_refused_naming_the_path]()
    suite.test[test_a_metadata_file_resolves_directly]()
    suite.test[test_file_uris_scheme_refusal_and_missing_paths]()
    suite.test[test_every_supported_type_maps_to_its_arrow_field]()
    suite.test[test_unsupported_types_are_refused_naming_the_column]()
    suite.test[test_snapshots_pin_and_time_travel_reads_that_snapshots_schema]()
    suite.test[test_format_version_three_is_refused_at_resolve]()
    suite.test[test_binding_identity]()
    suite.test[test_a_binding_reads_back_and_refuses_other_kinds]()
    suite.test[test_local_paths_and_relocation]()
    suite^.run()
