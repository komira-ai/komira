# =============================================================================
# test_iceberg_rest_test_catalog.mojo — the in-process REST catalog as a
#   transport: config, routing, create and its inspection helpers.
#   Idempotency and scripting are in test_iceberg_rest_test_catalog_scripting
#   .mojo; requirements and update rules in test_iceberg_metadata_apply.mojo
#   and test_iceberg_metadata_updates.mojo.
# =============================================================================
#
# The catalog is driven directly through `send` with hand-built requests, and
# through the REST client's create and load calls. Each case names the behaviour
# it holds; each error is asserted by its exact status, type and message.
#   * config: the answer carries the prefix only when one is set, `endpoints`
#     only when listed (an empty list is still listed), and the idempotency
#     lifetime only when advertised.
#   * routing: every path that is not a tables collection or a table is a 404
#     NoSuchPathException naming the path; a missing namespace and a missing
#     table are 404s of their own; the tables collection takes only POST;
#     segments are percent-decoded, and an escape that is not two hex digits
#     is kept as written.
#   * create: a staged create stores nothing and has no metadata-location; a
#     direct create stores the table; an existing table is a 409.
#   * inspection: the recorded requests, the stored metadata and the errors
#     for an unknown table.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from json import JsonValue, parse_json_value

from iceberg_catalog.iceberg_rest_catalog_client import (
    COMMIT_APPLIED,
    COMMIT_CONFLICT,
    COMMIT_UNKNOWN,
    IcebergRestCatalog,
    StaticBearerToken,
)
from iceberg_catalog.iceberg_rest_errors import (
    ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED,
)
from iceberg_catalog.iceberg_rest_test_catalog import (
    CommitFault,
    InMemoryIcebergRestCatalog,
)
from iceberg_catalog.iceberg_rest_transport import (
    IcebergRestRequest,
    IcebergRestResponse,
)
from iceberg_catalog.iceberg_table_changes import (
    CreateTableRequest,
    NewSnapshot,
    TableRequirement,
    TableUpdate,
    commit_table_body,
)


comptime _SCHEMA: String = (
    '{"type":"struct","fields":[{"id":1,"name":"id","required":true,'
    '"type":"long"},{"id":2,"name":"v","required":false,"type":"string"}]}'
)
comptime _TABLES: String = "/v1/p/namespaces/db/tables"
comptime _TABLE: String = "/v1/p/namespaces/db/tables/t"
comptime _Client = IcebergRestCatalog[
    InMemoryIcebergRestCatalog, StaticBearerToken
]


# =============================================================================
# helpers.
# =============================================================================


def _catalog() -> InMemoryIcebergRestCatalog:
    var c = InMemoryIcebergRestCatalog(String("p"), String("s3://wh"))
    c.create_namespace(String("db"))
    return c^


def _get(path: String) -> IcebergRestRequest:
    return IcebergRestRequest(
        String("catalog.example.com"),
        443,
        String(path),
        List[String](),
        List[String](),
    )


def _post(
    path: String, body: String, key: String = String("")
) -> IcebergRestRequest:
    var names = List[String]()
    var values = List[String]()
    if key.byte_length() > 0:
        names.append(String("Idempotency-Key"))
        values.append(String(key))
    return IcebergRestRequest.post(
        String("catalog.example.com"),
        443,
        String(path),
        names^,
        values^,
        String(body),
    )


def _create_body(
    name: String,
    stage: Bool = False,
    location: String = String(""),
    properties: String = String(""),
) -> String:
    var s = String('{"name":"') + name + String('","schema":') + _SCHEMA
    if location.byte_length() > 0:
        s += String(',"location":"') + location + String('"')
    if properties.byte_length() > 0:
        s += String(',"properties":') + properties
    if stage:
        s += String(',"stage-create":true}')
    else:
        s += String(',"stage-create":false}')
    return s^


def _create(mut c: InMemoryIcebergRestCatalog, name: String) raises:
    var r = c.send(_post(_TABLES, _create_body(name)))
    assert_equal(r.status, 200)


def _seeded() raises -> InMemoryIcebergRestCatalog:
    var c = _catalog()
    _create(c, String("t"))
    return c^


def _error_line(r: IcebergRestResponse) raises -> String:
    """`<status> <type>: <message>`, after checking the envelope's code is the
    status."""
    var e = parse_json_value(r.body).get(String("error"))
    assert_equal(e.get(String("code")).as_int64(), Int64(r.status))
    return (
        String(r.status)
        + String(" ")
        + e.get(String("type")).as_string()
        + String(": ")
        + e.get(String("message")).as_string()
    )


def _md(c: InMemoryIcebergRestCatalog) raises -> JsonValue:
    return parse_json_value(c.metadata_json(String("db"), String("t")))


def _location(r: IcebergRestResponse) raises -> String:
    return parse_json_value(r.body).get(String("metadata-location")).as_string()


def _props_body(name: String, value: String) -> String:
    return (
        String('{"requirements":[],"updates":[{"action":"set-properties",')
        + String('"updates":{"')
        + name
        + String('":"')
        + value
        + String('"}}]}')
    )


def _snapshot(id: Int64, seq: Int64) -> TableUpdate:
    return TableUpdate.add_snapshot(
        NewSnapshot(
            id,
            None,
            seq,
            1000,
            0,
            String("s3://wh/m.avro"),
            String("append"),
            List[String](),
            List[String](),
        )
    )


def _snapshot_body(id: Int64, seq: Int64) raises -> String:
    var ups = List[TableUpdate]()
    ups.append(_snapshot(id, seq))
    ups.append(TableUpdate.set_branch(String("main"), id))
    return commit_table_body(List[TableRequirement](), ups)


def _one(s: String) -> List[String]:
    var l = List[String]()
    l.append(String(s))
    return l^


def _raise_text_send(
    mut c: InMemoryIcebergRestCatalog, var req: IcebergRestRequest
) -> String:
    """The message `send` raised, or "" when it answered."""
    try:
        _ = c.send(req)
    except e:
        return String(e)
    return String("")


# =============================================================================
# config.
# =============================================================================


def test_config_without_prefix_has_empty_overrides() raises:
    var c = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    var r = c.send(_get(String("/v1/config")))
    assert_equal(r.status, 200)
    assert_equal(r.body, String('{"defaults":{},"overrides":{}}'))


def test_config_carries_the_prefix_override() raises:
    var c = _catalog()
    var r = c.send(_get(String("/v1/config")))
    assert_equal(r.status, 200)
    assert_equal(
        r.body, String('{"defaults":{},"overrides":{"prefix":"p"}}')
    )


def test_config_with_a_warehouse_query_is_still_config() raises:
    var c = _catalog()
    var r = c.send(_get(String("/v1/config?warehouse=w%201")))
    assert_equal(r.status, 200)
    assert_equal(
        r.body, String('{"defaults":{},"overrides":{"prefix":"p"}}')
    )


def test_config_lists_endpoints_when_set() raises:
    var c = _catalog()
    var eps = List[String]()
    eps.append(String("GET /a"))
    eps.append(String("POST /b"))
    c.list_endpoints(eps^)
    var r = c.send(_get(String("/v1/config")))
    assert_equal(
        r.body,
        String(
            '{"defaults":{},"overrides":{"prefix":"p"},"endpoints":["GET'
            ' /a","POST /b"]}'
        ),
    )


def test_config_lists_an_empty_endpoints_list() raises:
    var c = _catalog()
    c.list_endpoints(List[String]())
    var r = c.send(_get(String("/v1/config")))
    assert_equal(
        r.body,
        String('{"defaults":{},"overrides":{"prefix":"p"},"endpoints":[]}'),
    )


def test_config_advertises_the_idempotency_lifetime() raises:
    var c = _catalog()
    c.advertise_idempotency()
    var r = c.send(_get(String("/v1/config")))
    assert_equal(
        r.body,
        String(
            '{"defaults":{},"overrides":{"prefix":"p"},'
            '"idempotency-key-lifetime":"PT30M"}'
        ),
    )


def test_client_reads_prefix_endpoints_and_idempotency_from_config() raises:
    var plain = _catalog()
    var c0 = _Client(
        String("h"), plain^, StaticBearerToken(String(""))
    )
    assert_false(c0.supports_idempotency())
    assert_equal(c0.prefix(), String("p"))
    c0.require_endpoint(String("GET /anything"))

    var listed = _catalog()
    var eps = List[String]()
    eps.append(String("GET /a"))
    listed.list_endpoints(eps^)
    listed.advertise_idempotency()
    var c1 = _Client(
        String("h"), listed^, StaticBearerToken(String(""))
    )
    assert_true(c1.supports_idempotency())
    c1.require_endpoint(String("GET /a"))
    var msg = String("")
    try:
        c1.require_endpoint(String("POST /b"))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        ICEBERG_CATALOG_ENDPOINT_UNSUPPORTED
        + String(": the catalog does not list 'POST /b'"),
    )


# =============================================================================
# routing.
# =============================================================================


def test_paths_that_are_not_tables_are_404_no_such_path() raises:
    var c = _catalog()
    var paths = List[String]()
    paths.append(String("/v1/nope"))
    paths.append(String("/v1/other/namespaces/db/tables/t"))
    paths.append(String("/v1/namespaces/db/tables/t"))
    paths.append(String("/v1/p/namespaces/db"))
    paths.append(String("/v1/p/namespaces/db/views/t"))
    paths.append(String("/v1/p/namespaces/db/tables/t/extra"))
    paths.append(String("/v1/p/namespaces/db/tables/t/extra/more"))
    for i in range(len(paths)):
        var r = c.send(_get(paths[i]))
        assert_equal(
            _error_line(r), String("404 NoSuchPathException: ") + paths[i]
        )
        var p = c.send(_post(paths[i], String("{}")))
        assert_equal(
            _error_line(p), String("404 NoSuchPathException: ") + paths[i]
        )


def test_without_a_prefix_tables_live_under_v1_namespaces() raises:
    var c = InMemoryIcebergRestCatalog(String(""), String("s3://wh"))
    c.create_namespace(String("db"))
    var made = c.send(
        _post(String("/v1/namespaces/db/tables"), _create_body(String("t")))
    )
    assert_equal(made.status, 200)
    var got = c.send(_get(String("/v1/namespaces/db/tables/t")))
    assert_equal(got.status, 200)
    var wrong = c.send(_get(String("/v1/p/namespaces/db/tables/t")))
    assert_equal(
        _error_line(wrong),
        String("404 NoSuchPathException: /v1/p/namespaces/db/tables/t"),
    )


def test_missing_namespace_is_404_for_every_request_kind() raises:
    var c = _catalog()
    var expect = String(
        "404 NoSuchNamespaceException: Namespace does not exist: nope"
    )
    var get_t = c.send(_get(String("/v1/p/namespaces/nope/tables/t")))
    assert_equal(_error_line(get_t), expect)
    var create = c.send(
        _post(String("/v1/p/namespaces/nope/tables"), _create_body(String("t")))
    )
    assert_equal(_error_line(create), expect)
    var commit = c.send(
        _post(String("/v1/p/namespaces/nope/tables/t"), String("{}"))
    )
    assert_equal(_error_line(commit), expect)
    var collection_get = c.send(_get(String("/v1/p/namespaces/nope/tables")))
    assert_equal(_error_line(collection_get), expect)


def test_get_of_a_missing_table_is_404_no_such_table() raises:
    var c = _catalog()
    var r = c.send(_get(_TABLE))
    assert_equal(
        _error_line(r),
        String("404 NoSuchTableException: Table does not exist: db.t"),
    )


def test_get_on_the_tables_collection_is_405() raises:
    var c = _catalog()
    var r = c.send(_get(_TABLES))
    assert_equal(
        _error_line(r),
        String("405 MethodNotAllowed: /v1/p/namespaces/db/tables"),
    )


def test_segments_are_percent_decoded_through_the_client() raises:
    var c = _catalog()
    c.create_namespace(String("my db"))
    var cl = _Client(String("h"), c^, StaticBearerToken(String("")))
    var req = CreateTableRequest(
        String("a/b é"), parse_json_value(_SCHEMA), stage_create=False
    )
    var made = cl.create_table(String("my db"), req)
    assert_equal(
        made.metadata_location,
        String("s3://wh/my db/a/b é/metadata/v1.metadata.json"),
    )
    var loaded = cl.load_table_metadata(String("my db"), String("a/b é"))
    assert_equal(loaded.metadata_location, made.metadata_location)
    ref rec = cl.transport_ref()
    assert_true(rec.has_table(String("my db"), String("a/b é")))
    assert_equal(
        rec.request_paths[len(rec.request_paths) - 1],
        String("/v1/p/namespaces/my%20db/tables/a%2Fb%20%C3%A9"),
    )


def test_lowercase_and_boundary_hex_escapes_decode() raises:
    var c = _catalog()
    var names = List[String]()
    var escapes = List[String]()
    names.append(String("é"))
    escapes.append(String("%c3%a9"))
    names.append(String("😀"))
    escapes.append(String("%F0%9F%98%80"))
    names.append(String("😀2"))
    escapes.append(String("%f0%9f%98%802"))
    names.append(String("JJ"))
    escapes.append(String("%4A%4a"))
    names.append(String("0O"))
    escapes.append(String("%30%4F"))
    names.append(String("9o"))
    escapes.append(String("%39%6f"))
    names.append(String("xA"))
    escapes.append(String("x%41"))
    for i in range(len(names)):
        _create(c, names[i])
        var r = c.send(_get(_TABLES + String("/") + escapes[i]))
        assert_equal(r.status, 200)
        assert_equal(
            parse_json_value(r.body)
            .get(String("metadata"))
            .get(String("location"))
            .as_string(),
            String("s3://wh/db/") + names[i],
        )


def test_escapes_that_are_not_two_hex_digits_are_kept_as_written() raises:
    var c = _catalog()
    var names = List[String]()
    names.append(String("t%g1"))
    names.append(String("t%1g"))
    names.append(String("t%:1"))
    names.append(String("t%@1"))
    names.append(String("t%G1"))
    names.append(String("t%`1"))
    names.append(String("t%.1"))
    names.append(String("t%4"))
    names.append(String("t%"))
    for i in range(len(names)):
        _create(c, names[i])
        var r = c.send(_get(_TABLES + String("/") + names[i]))
        assert_equal(r.status, 200)


# =============================================================================
# create.
# =============================================================================


def test_staged_create_stores_nothing_and_has_no_location() raises:
    var c = _catalog()
    var r = c.send(_post(_TABLES, _create_body(String("t"), stage=True)))
    assert_equal(r.status, 200)
    var body = parse_json_value(r.body)
    assert_equal(body.num_members(), 2)
    assert_false(body.has(String("metadata-location")))
    assert_equal(body.key_at(0), String("metadata"))
    assert_equal(body.key_at(1), String("config"))
    assert_equal(
        body.get(String("metadata")).get(String("location")).as_string(),
        String("s3://wh/db/t"),
    )
    assert_false(c.has_table(String("db"), String("t")))
    assert_equal(c.applied_commits, 0)
    var missing = c.send(_get(_TABLE))
    assert_equal(missing.status, 404)


def test_direct_create_stores_the_table_at_version_one() raises:
    var c = _catalog()
    var r = c.send(_post(_TABLES, _create_body(String("t"))))
    assert_equal(r.status, 200)
    assert_equal(
        _location(r), String("s3://wh/db/t/metadata/v1.metadata.json")
    )
    assert_true(c.has_table(String("db"), String("t")))
    var got = c.send(_get(_TABLE))
    assert_equal(got.status, 200)
    assert_equal(got.body, r.body)
    assert_equal(c.applied_commits, 0)


def test_create_of_an_existing_table_is_409() raises:
    var c = _seeded()
    var direct = c.send(_post(_TABLES, _create_body(String("t"))))
    assert_equal(
        _error_line(direct),
        String(
            "409 AlreadyExistsException: Table already exists: db.t"
        ),
    )
    var staged = c.send(_post(_TABLES, _create_body(String("t"), stage=True)))
    assert_equal(
        _error_line(staged),
        String(
            "409 AlreadyExistsException: Table already exists: db.t"
        ),
    )


def test_create_location_comes_from_the_request_or_the_warehouse() raises:
    var c = _catalog()
    var own = c.send(
        _post(
            _TABLES,
            _create_body(String("a"), location=String("s3://other/a")),
        )
    )
    assert_equal(
        _location(own), String("s3://other/a/metadata/v1.metadata.json")
    )
    var warehouse = c.send(_post(_TABLES, _create_body(String("b"))))
    assert_equal(
        _location(warehouse), String("s3://wh/db/b/metadata/v1.metadata.json")
    )


def test_create_sets_properties_and_the_initial_metadata() raises:
    var c = _catalog()
    var r = c.send(
        _post(
            _TABLES,
            _create_body(
                String("t"),
                properties=String('{"owner":"me","format":"parquet"}'),
            ),
        )
    )
    assert_equal(r.status, 200)
    var md = parse_json_value(r.body).get(String("metadata"))
    assert_equal(md.get(String("format-version")).as_int64(), Int64(2))
    assert_equal(
        md.get(String("table-uuid")).as_string(),
        String("00000000-0000-4000-8000-000000000001"),
    )
    assert_equal(
        md.get(String("properties")).serialize(),
        String('{"owner":"me","format":"parquet"}'),
    )
    assert_equal(md.get(String("current-schema-id")).as_int64(), Int64(0))
    assert_equal(md.get(String("last-column-id")).as_int64(), Int64(2))
    assert_equal(
        md.get(String("schemas")).element_at(0).get(String("schema-id"))
        .as_int64(),
        Int64(0),
    )
    assert_equal(md.get(String("default-spec-id")).as_int64(), Int64(0))
    assert_equal(md.get(String("last-partition-id")).as_int64(), Int64(999))
    assert_equal(
        md.get(String("partition-specs")).serialize(),
        String('[{"spec-id":0,"fields":[]}]'),
    )
    assert_equal(md.get(String("default-sort-order-id")).as_int64(), Int64(0))
    assert_equal(
        md.get(String("sort-orders")).serialize(),
        String('[{"order-id":0,"fields":[]}]'),
    )
    assert_equal(md.get(String("snapshots")).array_len(), 0)
    assert_equal(md.get(String("current-snapshot-id")).as_int64(), Int64(-1))


def test_each_create_gets_the_next_table_uuid() raises:
    var c = _catalog()
    _create(c, String("a"))
    _create(c, String("b"))
    var dup = c.send(_post(_TABLES, _create_body(String("a"))))
    assert_equal(dup.status, 409)
    var third = c.send(_post(_TABLES, _create_body(String("c"), stage=True)))
    assert_equal(
        c.metadata(String("db"), String("a")).table_uuid,
        String("00000000-0000-4000-8000-000000000001"),
    )
    assert_equal(
        c.metadata(String("db"), String("b")).table_uuid,
        String("00000000-0000-4000-8000-000000000002"),
    )
    assert_equal(
        parse_json_value(third.body)
        .get(String("metadata"))
        .get(String("table-uuid"))
        .as_string(),
        String("00000000-0000-4000-8000-000000000003"),
    )


def test_client_create_staged_and_direct() raises:
    var c = _catalog()
    var cl = _Client(String("h"), c^, StaticBearerToken(String("")))
    var staged_req = CreateTableRequest(
        String("s"), parse_json_value(_SCHEMA), stage_create=True
    )
    var staged = cl.create_table(String("db"), staged_req)
    assert_equal(staged.metadata_location, String(""))
    assert_equal(staged.metadata.last_column_id, 2)
    var direct_req = CreateTableRequest(
        String("d"), parse_json_value(_SCHEMA), stage_create=False
    )
    direct_req.location = String("s3://elsewhere/d")
    direct_req.set_property(String("k"), String("v"))
    var direct = cl.create_table(String("db"), direct_req)
    assert_equal(
        direct.metadata_location,
        String("s3://elsewhere/d/metadata/v1.metadata.json"),
    )
    assert_equal(direct.metadata.location, String("s3://elsewhere/d"))
    assert_equal(direct.metadata.property(String("k")).value(), String("v"))
    ref rec = cl.transport_ref()
    assert_false(rec.has_table(String("db"), String("s")))
    assert_true(rec.has_table(String("db"), String("d")))
    var loaded = cl.load_table_metadata(String("db"), String("d"))
    assert_equal(loaded.metadata_location, direct.metadata_location)
    assert_equal(loaded.metadata_json, direct.metadata_json)


# =============================================================================
# inspection helpers.
# =============================================================================


def test_inspection_reports_tables_and_the_recorded_requests() raises:
    var c = _catalog()
    assert_false(c.has_table(String("db"), String("t")))
    assert_equal(c.request_count(), 0)
    _create(c, String("t"))
    var body = _props_body(String("k"), String("v"))
    var applied = c.send(_post(_TABLE, body, String("key-1")))
    assert_equal(applied.status, 200)
    var got = c.send(_get(_TABLE))
    assert_equal(got.status, 200)
    assert_true(c.has_table(String("db"), String("t")))
    assert_false(c.has_table(String("db"), String("u")))
    assert_false(c.has_table(String("other"), String("t")))
    assert_equal(c.applied_commits, 1)
    assert_equal(c.request_count(), 3)
    assert_equal(len(c.request_methods), 3)
    assert_equal(c.request_methods[0], String("POST"))
    assert_equal(c.request_methods[2], String("GET"))
    assert_equal(c.request_paths[0], _TABLES)
    assert_equal(c.request_paths[1], _TABLE)
    assert_equal(c.request_paths[2], _TABLE)
    assert_equal(c.request_bodies[0], _create_body(String("t")))
    assert_equal(c.request_bodies[1], body)
    assert_equal(c.request_bodies[2], String(""))
    assert_equal(c.request_keys[0], String(""))
    assert_equal(c.request_keys[1], String("key-1"))
    assert_equal(c.request_keys[2], String(""))
    assert_equal(
        c.metadata_json(String("db"), String("t")),
        _md(c).serialize(),
    )
    var typed = c.metadata(String("db"), String("t"))
    assert_equal(typed.property(String("k")).value(), String("v"))
    assert_equal(typed.location, String("s3://wh/db/t"))


def test_inspection_of_an_unknown_table_raises_by_name() raises:
    var c = _catalog()
    var json_msg = String("")
    try:
        _ = c.metadata_json(String("db"), String("ghost"))
    except e:
        json_msg = String(e)
    assert_equal(json_msg, String("InMemoryIcebergRestCatalog: no table ghost"))
    var typed_msg = String("")
    try:
        _ = c.metadata(String("db"), String("ghost"))
    except e:
        typed_msg = String(e)
    assert_equal(
        typed_msg, String("InMemoryIcebergRestCatalog: no table ghost")
    )


def test_expire_snapshot_removes_it_and_ignores_unknown_tables() raises:
    var c = _seeded()
    var s1 = c.send(_post(_TABLE, _snapshot_body(11, 1)))
    assert_equal(s1.status, 200)
    var s2 = c.send(_post(_TABLE, _snapshot_body(12, 2)))
    assert_equal(s2.status, 200)
    c.expire_snapshot(String("db"), String("t"), 11)
    var md = c.metadata(String("db"), String("t"))
    assert_equal(len(md.snapshots), 1)
    assert_equal(md.snapshots[0].snapshot_id, Int64(12))
    assert_equal(md.main_snapshot_id.value(), Int64(12))
    c.expire_snapshot(String("db"), String("t"), 999)
    assert_equal(len(c.metadata(String("db"), String("t")).snapshots), 1)
    c.expire_snapshot(String("db"), String("ghost"), 12)
    assert_false(c.has_table(String("db"), String("ghost")))


def main() raises:
    test_config_without_prefix_has_empty_overrides()
    test_config_carries_the_prefix_override()
    test_config_with_a_warehouse_query_is_still_config()
    test_config_lists_endpoints_when_set()
    test_config_lists_an_empty_endpoints_list()
    test_config_advertises_the_idempotency_lifetime()
    test_client_reads_prefix_endpoints_and_idempotency_from_config()
    test_paths_that_are_not_tables_are_404_no_such_path()
    test_without_a_prefix_tables_live_under_v1_namespaces()
    test_missing_namespace_is_404_for_every_request_kind()
    test_get_of_a_missing_table_is_404_no_such_table()
    test_get_on_the_tables_collection_is_405()
    test_segments_are_percent_decoded_through_the_client()
    test_lowercase_and_boundary_hex_escapes_decode()
    test_escapes_that_are_not_two_hex_digits_are_kept_as_written()
    test_staged_create_stores_nothing_and_has_no_location()
    test_direct_create_stores_the_table_at_version_one()
    test_create_of_an_existing_table_is_409()
    test_create_location_comes_from_the_request_or_the_warehouse()
    test_create_sets_properties_and_the_initial_metadata()
    test_each_create_gets_the_next_table_uuid()
    test_client_create_staged_and_direct()
    test_inspection_reports_tables_and_the_recorded_requests()
    test_inspection_of_an_unknown_table_raises_by_name()
    test_expire_snapshot_removes_it_and_ignores_unknown_tables()
    print("test_iceberg_rest_test_catalog: ALL PASS")
