# =============================================================================
# add_sql_binding: a SQL name bound to a local path, an S3 object or an Azure
# blob, and read by SQL on the session
# =============================================================================
#
# Each test builds a Session, seals credentials on it through
# SessionCredentials (what komira_credential_add, _set and _seal do), encodes a
# komira.plan.v1.WireBoundSource with the generated codec and binds it with
# add_sql_binding_with over in-memory fakes: komira_test_fake_s3 (bucket
# `lake`, answering only requests signed with the access key id AKIDRIGHT)
# and komira_test_fake_azure (containers `box` and `other`). No socket is
# opened. Statements run through sql_result_with over the same fakes, so the
# file systems a statement reads through are the ones store_opener builds
# from the session's bindings and sealed credentials.
#
# What each test holds:
#   * test_an_s3_object_answers_what_the_local_file_answers: a table bound to
#     s3://lake/t/a.parquet answers the rows, a filter and a count the same
#     bytes answer as a local file registered with register_parquet.
#   * test_an_s3_glob_reads_every_matching_object_in_key_order: a glob binds
#     the two objects it matches, not the third under another prefix, and
#     a glob matching nothing is PARQUET_GLOB_NO_MATCH naming it.
#   * test_an_azure_blob_answers_with_a_key_or_a_sas: a table bound to
#     az://box/t/a.parquet with an AzureKey, and one bound to az://other with
#     an AzureSas, each answer the file's rows; an anonymous source whose
#     location names no account is refused by azure_url, naming why.
#   * test_one_statement_reads_s3_and_azure: a UNION ALL of an S3 table and an
#     Azure table answers both objects' rows: one run reads two stores.
#   * test_the_value_sealed_now_is_the_one_read: re-sealing the credential's
#     name with a key the store refuses makes the next statement refused at
#     execute with the store's PERMISSION_DENIED, and sealing the right key
#     again makes it answer: the run reads the value sealed when it starts.
#   * test_a_refused_key_is_refused_at_the_binding: the footer is read when
#     the source is bound, so a key the store refuses is the store's
#     PERMISSION_DENIED from add_sql_binding, and nothing is bound.
#   * test_rebinding_a_name_replaces_its_table: a name bound to a local file
#     and then to an S3 object answers the object's rows, then the local file
#     again; a refused rebinding leaves the table it had.
#   * test_register_parquet_replaces_a_taken_name: registering a second file
#     under a taken name answers the second file (it used to keep the first).
#   * test_each_refusal_is_named_word_for_word: every refusal of the module,
#     exact text, and none binds the name.
#   * test_no_refusal_carries_a_secret: with a known key id, secret, account
#     key and SAS sealed, no refusal text holds any of them, and a location
#     with user information is refused without being echoed; Azure's
#     container@account form is not taken for user information, and
#     user:password@ in it is.
#   * test_a_bucket_is_read_one_way_per_session: a second table on the same
#     bucket with the same settings binds; with another credential name it is
#     BIND_STORE_CONFLICT; after the first table is rebound elsewhere, it binds.
#   * test_a_credential_that_no_longer_fits_refuses_the_statement_at_bind:
#     re-sealing the bound credential's name as another kind refuses the next
#     statement at step bind with CREDENTIALS_INVALID, recorded on the session.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from aws_core import FixedClock
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_proto.bound_source import (
    AddressingStyleWire,
    WireBoundSource,
    WireFileSource,
    WireSourceAccess,
)
from proto_codec import encode_proto
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult
from sdk_exec.run_control import RunControl

from komira_test_fake_azure import FakeAzureConnector
from komira_test_fake_s3 import FakeS3Connector
from so import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_CRED_AWS_PROFILE,
    KOMIRA_CRED_AZURE_KEY,
    KOMIRA_CRED_AZURE_SAS,
    KOMIRA_FIELD_ACCOUNT,
    KOMIRA_FIELD_KEY,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_PROFILE,
    KOMIRA_FIELD_SAS,
    KOMIRA_FIELD_SECRET,
    KOMIRA_STEP_BIND,
    Session,
    StoreConnectors,
    add_sql_binding_with,
    register_parquet,
    sql_result_with,
)

comptime _Connectors = StoreConnectors[
    FakeS3Connector, FakeAzureConnector, FixedClock
]

comptime _RIGHT_KEY = "AKIDRIGHT"
comptime _WRONG_KEY = "AKIDWRONG"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
comptime _ACCOUNT = "devstoreaccount1"
comptime _AZURE_KEY = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
comptime _SAS = "sv=2026-10-01&sp=r&sig=c2VjcmV0LXNpZ25hdHVyZQ"
comptime _S3_ENDPOINT = "http://127.0.0.1:9000"
comptime _AZURE_ENDPOINT = "http://127.0.0.1:10000"


# ---- the data ----------------------------------------------------------------


def _batch(first: Int, n: Int) raises -> RecordBatch:
    """Rows id = first .. first + n - 1."""
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(first + i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    return rb.build(sb.build())


def _bytes_a() raises -> List[UInt8]:
    """40 rows from id 0, in row groups of 7."""
    return write_record_batch_to_parquet_bytes(_batch(0, 40), max_rows_per_rg=7)


def _bytes_b() raises -> List[UInt8]:
    """9 rows from id 100."""
    return write_record_batch_to_parquet_bytes(_batch(100, 9), max_rows_per_rg=4)


def _bytes_c() raises -> List[UInt8]:
    """3 rows from id 500."""
    return write_record_batch_to_parquet_bytes(_batch(500, 3), max_rows_per_rg=4)


def _write(dir: String, name: String, bytes: List[UInt8]) raises -> String:
    makedirs(dir, exist_ok=True)
    var path = dir + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


# ---- the stores --------------------------------------------------------------


def _mk_s3() raises -> FakeS3Connector:
    """Bucket `lake`: t/a.parquet, t/b.parquet and u/c.parquet; requests
    must be signed with AKIDRIGHT."""
    var c = FakeS3Connector(key_id=_RIGHT_KEY)
    c.seed_bytes("t/a.parquet", _bytes_a())
    c.seed_bytes("t/b.parquet", _bytes_b())
    c.seed_bytes("u/c.parquet", _bytes_c())
    return c^


def _mk_azure() raises -> FakeAzureConnector:
    """Container `box`: t/a.parquet; container `other`: t/b.parquet."""
    var c = FakeAzureConnector()
    c.seed("box", "t/a.parquet", _bytes_a())
    c.seed("other", "t/b.parquet", _bytes_b())
    return c^


def _connectors() -> _Connectors:
    return _Connectors(_mk_s3, _mk_s3, _mk_azure, _mk_azure, FixedClock(1790000000))


# ---- the session -------------------------------------------------------------


def _seal_aws(mut s: Session, name: String, key_id: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_AWS_KEYS, name)
    s.credentials.set(id, KOMIRA_FIELD_KEY_ID, key_id.as_bytes())
    s.credentials.set(id, KOMIRA_FIELD_SECRET, String(_SECRET).as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_azure_key(mut s: Session, name: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_AZURE_KEY, name)
    s.credentials.set(id, KOMIRA_FIELD_ACCOUNT, String(_ACCOUNT).as_bytes())
    s.credentials.set(id, KOMIRA_FIELD_KEY, String(_AZURE_KEY).as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_azure_sas(mut s: Session, name: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_AZURE_SAS, name)
    s.credentials.set(id, KOMIRA_FIELD_ACCOUNT, String(_ACCOUNT).as_bytes())
    s.credentials.set(id, KOMIRA_FIELD_SAS, String(_SAS).as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_profile(mut s: Session, name: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_AWS_PROFILE, name)
    s.credentials.set(id, KOMIRA_FIELD_PROFILE, String("etl").as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _session() raises -> Session:
    """A session with AwsKeys `s3-etl` (the right key), AwsKeys `s3-other`
    (the right key too), AzureKey `az-key`, AzureSas `az-sas` and AwsProfile
    `profile`."""
    var s = Session()
    _seal_aws(s, "s3-etl", _RIGHT_KEY)
    _seal_aws(s, "s3-other", _RIGHT_KEY)
    _seal_azure_key(s, "az-key")
    _seal_azure_sas(s, "az-sas")
    _seal_profile(s, "profile")
    return s^


def _source(
    location: String,
    credential: String = "",
    endpoint: String = "",
    region: String = "",
    addressing: Int = 0,
    signing_service: String = "",
    hive: Bool = False,
) raises -> List[UInt8]:
    """The bytes of a WireBoundSource naming a WireFileSource."""
    var access = WireSourceAccess(
        credential,
        endpoint,
        region,
        AddressingStyleWire(addressing),
        signing_service,
    )
    var files = WireFileSource(
        location, Optional[WireSourceAccess](access^), hive
    )
    return encode_proto(WireBoundSource(1, Optional[WireFileSource](files^)))


def _s3(location: String, credential: String = "s3-etl") raises -> List[UInt8]:
    return _source(location, credential, _S3_ENDPOINT, "us-east-1")


def _az(location: String, credential: String = "az-key") raises -> List[UInt8]:
    return _source(location, credential, _AZURE_ENDPOINT)


def _bind(mut s: Session, name: String, var source: List[UInt8]) raises:
    add_sql_binding_with(s, name, source^, KOMIRA_BIND_SESSION, _connectors())


def _refused(
    mut s: Session, name: String, var source: List[UInt8], scope: Int32 = 1
) -> String:
    """The refusal text of a binding expected to be refused."""
    try:
        add_sql_binding_with(s, name, source^, scope, _connectors())
    except e:
        return String(e)
    return String("<bound>")


def _sql(mut s: Session, sql: String) raises -> ArrowResult:
    return sql_result_with(s, sql, RunControl(), _connectors())


def _sql_refusal(mut s: Session, sql: String) -> String:
    try:
        _ = sql_result_with(s, sql, RunControl(), _connectors())
    except e:
        return String(e)
    return String("<answered>")


def _ints(result: ArrowResult) raises -> List[Int]:
    var out = List[Int]()
    for b in range(len(result.batches)):
        ref batch = result.batches[b]
        var a = batch.column_at(0).as_primitive[DType.int64]()
        for i in range(batch.num_rows()):
            out.append(Int(a.get(i)))
    return out^


def _sorted(var v: List[Int]) -> List[Int]:
    for i in range(1, len(v)):
        var j = i
        while j > 0 and v[j - 1] > v[j]:
            v.swap_elements(j - 1, j)
            j -= 1
    return v^


def _same(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _range(first: Int, n: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append(first + i)
    return out^


def _count(mut s: Session, table: String) raises -> Int:
    return _ints(_sql(s, "SELECT count(*) FROM " + table))[0]


# ---- reads -------------------------------------------------------------------


def test_an_s3_object_answers_what_the_local_file_answers() raises:
    var s = _session()
    var dir = test_tmpdir() + "/bind_s3_local"
    register_parquet(s, "local_a", _write(dir, "a.parquet", _bytes_a()))
    _bind(s, "remote_a", _s3("s3://lake/t/a.parquet"))
    var q = " WHERE id >= 10 AND id < 31 ORDER BY id"
    var local = _ints(_sql(s, "SELECT id FROM local_a" + q))
    var remote = _ints(_sql(s, "SELECT id FROM remote_a" + q))
    _same(remote, local, "filtered ids")
    _same(remote, _range(10, 21), "the rows written")
    assert_equal(_count(s, "remote_a"), 40)
    # The name folds case, as every table name does.
    assert_equal(_count(s, "REMOTE_A"), 40)


def test_an_s3_glob_reads_every_matching_object_in_key_order() raises:
    var s = _session()
    _bind(s, "t_all", _s3("s3://lake/t/*.parquet"))
    var ids = _sorted(_ints(_sql(s, "SELECT id FROM t_all")))
    var want = _range(0, 40)
    want.extend(_range(100, 9))
    _same(ids, want, "both objects under t/, not u/c.parquet")
    assert_equal(
        _refused(s, "none", _s3("s3://lake/v/*.parquet")),
        "PARQUET_GLOB_NO_MATCH: no file matches 's3://lake/v/*.parquet'",
    )


def test_an_azure_blob_answers_with_a_key_or_a_sas() raises:
    var s = _session()
    _bind(s, "box_a", _az("az://box/t/a.parquet"))
    _same(
        _ints(_sql(s, "SELECT id FROM box_a ORDER BY id")),
        _range(0, 40),
        "AzureKey",
    )
    _bind(s, "other_b", _az("az://other/t/b.parquet", "az-sas"))
    _same(
        _ints(_sql(s, "SELECT id FROM other_b ORDER BY id")),
        _range(100, 9),
        "AzureSas",
    )
    # An anonymous source has no credential to take the account from, so its
    # location must name one; the short form names none.
    assert_equal(
        _refused(s, "x", _source("az://other/t/b.parquet", "anonymous", _AZURE_ENDPOINT)),
        "azure_url: the Azure URL names no account and none is configured",
    )


def test_one_statement_reads_s3_and_azure() raises:
    var s = _session()
    _bind(s, "s3_b", _s3("s3://lake/t/b.parquet"))
    _bind(s, "az_a", _az("az://box/t/a.parquet"))
    var ids = _sorted(
        _ints(_sql(s, "SELECT id FROM s3_b UNION ALL SELECT id FROM az_a"))
    )
    var want = _range(0, 40)
    want.extend(_range(100, 9))
    _same(ids, want, "both stores")


def test_the_value_sealed_now_is_the_one_read() raises:
    var s = _session()
    _bind(s, "remote_a", _s3("s3://lake/t/a.parquet"))
    assert_equal(_count(s, "remote_a"), 40)
    _seal_aws(s, "s3-etl", _WRONG_KEY)
    var refused = _sql_refusal(s, "SELECT count(*) FROM remote_a")
    assert_true(refused.startswith("execute: "), refused)
    assert_true("StoreError[PERMISSION_DENIED]" in refused, refused)
    assert_true("s3://lake/t/a.parquet" in refused, refused)
    _seal_aws(s, "s3-etl", _RIGHT_KEY)
    assert_equal(_count(s, "remote_a"), 40)


def test_a_refused_key_is_refused_at_the_binding() raises:
    var s = _session()
    _seal_aws(s, "wrong", _WRONG_KEY)
    var refused = _refused(s, "remote_a", _s3("s3://lake/t/a.parquet", "wrong"))
    assert_true("StoreError[PERMISSION_DENIED]" in refused, refused)
    assert_true("s3://lake/t/a.parquet" in refused, refused)
    assert_true(refused.find(_WRONG_KEY) < 0, refused)
    assert_equal(
        _sql_refusal(s, "SELECT count(*) FROM remote_a").startswith("bind: "),
        True,
    )


def test_rebinding_a_name_replaces_its_table() raises:
    var s = _session()
    var dir = test_tmpdir() + "/bind_replace"
    var c_path = _write(dir, "c.parquet", _bytes_c())
    _bind(s, "t", _source(c_path))
    _same(_ints(_sql(s, "SELECT id FROM t ORDER BY id")), _range(500, 3), "local")
    _bind(s, "T", _s3("s3://lake/t/b.parquet"))
    _same(_ints(_sql(s, "SELECT id FROM t ORDER BY id")), _range(100, 9), "s3")
    _bind(s, "t", _source(c_path))
    _same(_ints(_sql(s, "SELECT id FROM t ORDER BY id")), _range(500, 3), "local again")
    # A refused rebinding leaves the table as it was.
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "nobody")),
        "CREDENTIAL_UNBOUND: credential=nobody has no sealed value on this session",
    )
    _same(_ints(_sql(s, "SELECT id FROM t ORDER BY id")), _range(500, 3), "kept")


def test_register_parquet_replaces_a_taken_name() raises:
    var s = Session()
    var dir = test_tmpdir() + "/bind_register_twice"
    register_parquet(s, "t", _write(dir, "a.parquet", _bytes_a()))
    assert_equal(_count(s, "t"), 40)
    register_parquet(s, "t", _write(dir, "c.parquet", _bytes_c()))
    assert_equal(_count(s, "t"), 3)


def test_each_refusal_is_named_word_for_word() raises:
    var s = _session()
    var ok = _s3("s3://lake/t/a.parquet")
    assert_equal(
        _refused(s, "t", ok.copy(), 2),
        "BIND_SCOPE_UNSUPPORTED: add_sql_binding scope=2: only"
        " KOMIRA_BIND_SESSION (1) binds a source",
    )
    assert_equal(
        _refused(s, "", ok.copy()), "TABLE_NAME_EMPTY: a table name must not be empty"
    )
    var truncated = List[UInt8]()
    truncated.append(0x0A)
    assert_equal(
        _refused(s, "t", truncated^),
        "BIND_SOURCE_MALFORMED: add_sql_binding name=t: the source is not a"
        " komira.plan.v1.WireBoundSource",
    )
    assert_equal(
        _refused(s, "t", List[UInt8]()),
        "BIND_SOURCE_MALFORMED: add_sql_binding name=t: the source names no kind",
    )
    assert_equal(
        _refused(s, "t", _source("gs://lake/t/a.parquet", "s3-etl")),
        "STORAGE_URL_REFUSED: add_sql_binding name=t: no store of this library"
        " reads 'gs://' locations; s3:// and az:// (abfs://, abfss://) are read",
    )
    assert_equal(
        _refused(s, "t", _source("https://example.com/a.parquet", "s3-etl")),
        "STORAGE_URL_REFUSED: add_sql_binding name=t: no store of this library"
        " reads 'https://' locations; s3:// and az:// (abfs://, abfss://) are read",
    )
    assert_equal(
        _refused(s, "t", _source("s3://lake/t/a.parquet?x=1", "s3-etl", "", "us-east-1")),
        "STORAGE_URL_REFUSED: add_sql_binding name=t: a location must not carry"
        " a query or a fragment",
    )
    assert_equal(
        _refused(s, "t", _source("s3://lake/t/", "s3-etl", "", "us-east-1")),
        "BIND_SCOPE_NOT_A_TABLE: add_sql_binding name=t: s3://lake/t/ is a"
        " scope, not a table; name an object or a glob",
    )
    assert_equal(
        _refused(s, "t", _source("s3://lake/t/a.parquet", "s3-etl")),
        "STORAGE_REGION_UNKNOWN: add_sql_binding name=t: s3://lake/t/a.parquet"
        " names no region; give the source its region",
    )
    var no_credential = String(
        "CREDENTIALS_NOT_FOUND: add_sql_binding name=t: the source names no"
        " credential, or ambient, which this library does not resolve; name a"
        " sealed credential"
    )
    assert_equal(_refused(s, "t", _s3("s3://lake/t/a.parquet", "")), no_credential)
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "ambient")), no_credential
    )
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "anonymous")),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: credential=anonymous:"
        " unsigned s3:// reads are not served",
    )
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "nobody")),
        "CREDENTIAL_UNBOUND: credential=nobody has no sealed value on this session",
    )
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "az-key")),
        "CREDENTIAL_KIND_MISMATCH: add_sql_binding name=t: credential=az-key"
        " does not fit a s3:// source",
    )
    assert_equal(
        _refused(s, "t", _az("az://box/t/a.parquet", "s3-etl")),
        "CREDENTIAL_KIND_MISMATCH: add_sql_binding name=t: credential=s3-etl"
        " does not fit a az:// source",
    )
    assert_equal(
        _refused(s, "t", _s3("s3://lake/t/a.parquet", "profile")),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: credential=profile:"
        " an AwsProfile is not read by this library; seal AwsKeys",
    )
    assert_equal(
        _refused(
            s,
            "t",
            _source("s3://lake/t/a.parquet", "s3-etl", _S3_ENDPOINT, "us-east-1", 0, "", True),
        ),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: Hive partitioning is"
        " not read from an object store yet",
    )
    assert_equal(
        _refused(
            s,
            "t",
            _source("s3://lake/t/a.parquet", "s3-etl", _S3_ENDPOINT, "us-east-1", 0, "glue"),
        ),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: a file source takes no"
        " signing service",
    )
    assert_equal(
        _refused(s, "t", _source("az://box/t/a.parquet", "az-key", _AZURE_ENDPOINT, "us-east-1")),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: an az:// source takes"
        " no region",
    )
    assert_equal(
        _refused(s, "t", _source("s3://lake/t/a.parquet", "s3-etl", "ftp://h", "us-east-1")),
        "STORAGE_URL_REFUSED: add_sql_binding name=t: an endpoint must start"
        " with http:// or https://",
    )
    assert_equal(
        _refused(s, "t", _source("s3://lake/t/a.parquet", "s3-etl", "http://h/?a=b", "us-east-1")),
        "STORAGE_URL_REFUSED: add_sql_binding name=t: an endpoint must not carry"
        " a query or a fragment",
    )
    assert_equal(
        _refused(s, "t", _source("/data/a.parquet", "s3-etl")),
        "CREDENTIAL_KIND_MISMATCH: add_sql_binding name=t: credential=s3-etl"
        " does not fit a local path",
    )
    assert_equal(
        _refused(s, "t", _source("/data/a.parquet", "", "", "us-east-1")),
        "BIND_SOURCE_UNSUPPORTED: add_sql_binding name=t: a local path takes no"
        " endpoint, region or addressing",
    )
    # None of them bound the name.
    assert_equal(_sql_refusal(s, "SELECT * FROM t").startswith("bind: "), True)


def test_no_refusal_carries_a_secret() raises:
    var s = _session()
    var refusals = List[String]()
    refusals.append(
        _refused(s, "t", _source("s3://AKIDRIGHT:topsecret@lake/a.parquet", "s3-etl"))
    )
    refusals.append(
        _refused(s, "t", _source("s3://lake/a.parquet", "s3-etl", "http://u:topsecret@h", "us-east-1"))
    )
    refusals.append(_refused(s, "t", _s3("s3://lake/t/a.parquet", "az-key")))
    refusals.append(_refused(s, "t", _az("az://box/t/a.parquet", "s3-etl")))
    refusals.append(_refused(s, "t", _az("az://box/t/missing.parquet", "az-sas")))
    refusals.append(_refused(s, "t", _s3("s3://lake/t/missing.parquet")))
    assert_equal(
        refusals[0],
        "STORAGE_URL_REFUSED: add_sql_binding name=t: a location must not carry"
        " user information; a credential is named by the source, never written"
        " into its location",
    )
    assert_equal(
        refusals[1],
        "STORAGE_URL_REFUSED: add_sql_binding name=t: an endpoint must not carry"
        " user information",
    )
    # Azure's container@account form is a container, not user information:
    # it is refused only for naming Azure's own endpoint while the source
    # names the emulator's.
    var hadoop = _refused(
        s, "t", _az("abfss://box@devstoreaccount1.dfs.core.windows.net/t/a.parquet")
    )
    assert_true(hadoop.startswith("azure_url: "), hadoop)
    refusals.append(hadoop^)
    var user = _refused(
        s, "t", _az("abfss://u:topsecret@devstoreaccount1.dfs.core.windows.net/a.parquet")
    )
    assert_true(user.startswith("STORAGE_URL_REFUSED: "), user)
    refusals.append(user^)
    for i in range(len(refusals)):
        ref r = refusals[i]
        assert_true(r != "<bound>", "refusal " + String(i) + " bound")
        for secret in [
            String("topsecret"),
            String(_RIGHT_KEY),
            String(_SECRET),
            String(_AZURE_KEY),
            String(_SAS),
            String("c2VjcmV0LXNpZ25hdHVyZQ"),
        ]:
            assert_true(r.find(secret) < 0, "refusal " + String(i) + " holds a secret")


def test_a_bucket_is_read_one_way_per_session() raises:
    var s = _session()
    _bind(s, "a", _s3("s3://lake/t/a.parquet"))
    _bind(s, "b", _s3("s3://lake/t/b.parquet"))
    assert_equal(_count(s, "b"), 9)
    assert_equal(
        _refused(s, "c", _s3("s3://lake/u/c.parquet", "s3-other")),
        "BIND_STORE_CONFLICT: add_sql_binding name=c: s3://lake is read by"
        " table 'a' with another credential or other settings; one session"
        " reads a bucket one way",
    )
    # Rebinding a table under its own name is not a conflict with itself.
    _bind(s, "a", _s3("s3://lake/t/b.parquet"))
    var c_path = _write(test_tmpdir() + "/bind_conflict", "c.parquet", _bytes_c())
    _bind(s, "a", _source(c_path))
    _bind(s, "b", _source(c_path))
    _bind(s, "c", _s3("s3://lake/u/c.parquet", "s3-other"))
    assert_equal(_count(s, "c"), 3)


def test_a_credential_that_no_longer_fits_refuses_the_statement_at_bind() raises:
    var s = _session()
    _bind(s, "remote_a", _s3("s3://lake/t/a.parquet"))
    _seal_azure_key(s, "s3-etl")
    var refused = _sql_refusal(s, "SELECT count(*) FROM remote_a")
    assert_true(refused.startswith("bind: CREDENTIALS_INVALID: "), refused)
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("CREDENTIALS_INVALID"))
    assert_true(refused.find(_AZURE_KEY) < 0, refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
