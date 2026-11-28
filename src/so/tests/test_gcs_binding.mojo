# =============================================================================
# add_sql_binding over gs://: a SQL name bound to Parquet objects of a GCS
# bucket, and read by SQL on the session, over a fake GCS store
# =============================================================================
#
# Each test builds a Session, seals credentials on it through
# SessionCredentials (what komira_credential_add, _set and _seal do), encodes a
# komira.plan.v1.WireBoundSource with the generated codec and binds it with
# add_sql_binding_with; statements run through sql_result_with over the same
# connectors, so the file systems a statement reads through are the ones
# store_opener builds from the session's bindings and sealed credentials. The
# GCS store is objectstore_gcs's in-memory FakeGcsStorageBackend behind
# `_Buckets` below, which StoreConnectors' GCS factory builds from a bucket's
# GcsAccess as the production factory builds the gRPC backend: bucket `raw`
# (t/a.parquet, t/b.parquet, u/c.parquet) is served only at Google's endpoint
# and bucket `emu` (t/a.parquet, holding c's rows) only at the emulator's
# (https://gcs.emulator.test:4443); a backend built with any token but _TOKEN
# refuses every verb as the service refuses an unauthenticated call. S3 is
# komira_test_fake_s3 (bucket `lake`, key AKIDRIGHT). No socket is opened, and
# no name is resolved. StoreFs's GCS arm itself is test_gcs_store_fs's.
#
# What each test holds:
#   * test_a_gcs_object_answers_what_the_local_file_answers: a table bound to
#     gs://raw/t/a.parquet answers the rows, a filter and a count the same
#     bytes answer as a local file.
#   * test_a_gcs_glob_reads_every_matching_object: a glob binds the objects
#     it matches and no other; a glob matching nothing is PARQUET_GLOB_NO_MATCH.
#   * test_an_endpoint_of_the_sources_own_is_read: gs://emu at the emulator's
#     endpoint answers its rows, gcs:// and GS:// read as gs://, and gs://emu at
#     Google's endpoint is the store's NOT_FOUND at the binding.
#   * test_one_statement_reads_gcs_and_s3: a UNION ALL of a GCS table and an
#     S3 table answers both objects' rows.
#   * test_the_token_sealed_now_is_the_one_read: re-sealing the name with a
#     token the store refuses refuses the next statement at execute, and the
#     right token answers again.
#   * test_a_refused_token_is_refused_at_the_binding: the footer is read at
#     the binding, so a token the store refuses is PERMISSION_DENIED from
#     add_sql_binding, holding no token, and nothing is bound.
#   * test_each_gcs_refusal_is_named_word_for_word: every gs:// refusal, exact
#     text, none holding a token, and none binds the name.
#   * test_a_gcs_bucket_is_read_one_way_per_session: a second table with the
#     same settings binds; another credential name or another endpoint is
#     BIND_STORE_CONFLICT.
#   * test_a_name_sealed_again_as_another_kind_refuses_the_statement: a
#     BearerToken holding the right token, an AwsKeys and a GcpServiceAccount
#     sealed under the bound name each refuse the next statement at step bind
#     with CREDENTIAL_KIND_MISMATCH word for word; a GcpToken again answers.
# =============================================================================

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from aws_core import FixedClock
from objectstore_gcs import (
    GCS_GRPC_HOST,
    GCS_GRPC_PORT,
    FakeGcsStorageBackend,
    GcsStorageBackend,
    ListPageRaw,
    ObjectMetaRaw,
)
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
    KOMIRA_CRED_BEARER,
    KOMIRA_CRED_GCP_SERVICE_ACCOUNT,
    KOMIRA_CRED_GCP_TOKEN,
    KOMIRA_FIELD_FILE,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_TOKEN,
    KOMIRA_STEP_BIND,
    GcsAccess,
    Session,
    StoreConnectors,
    add_sql_binding_with,
    register_parquet,
    sql_result_with,
)

comptime _TOKEN = "ya29.fake-token-the-store-answers"
comptime _WRONG_TOKEN = "ya29.fake-token-the-store-refuses"
comptime _EMU = "https://gcs.emulator.test:4443"
comptime _EMU_HOST = "gcs.emulator.test"
comptime _EMU_PORT: UInt16 = 4443
comptime _KEY_ID = "AKIDRIGHT"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"


comptime _NOT_HTTPS = (
    "a gs:// endpoint must start with https://: Cloud Storage is read over"
    " gRPC on TLS, with no plaintext route"
)
comptime _A_PATH = "a gs:// endpoint must not carry a path"
comptime _NO_HOST = "a gs:// endpoint names no host"
comptime _BAD_PORT = "a gs:// endpoint's port must be a number from 1 to 65535"


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


# ---- the GCS store -------------------------------------------------------------


struct _Buckets(GcsStorageBackend, Movable, Deinitable):
    """Bucket `raw` (t/a.parquet, t/b.parquet, u/c.parquet) at Google's
    endpoint and bucket `emu` (t/a.parquet, holding c's rows) at the
    emulator's, in a FakeGcsStorageBackend (the fake models one bucket). A
    backend built with any token but _TOKEN refuses every verb as the
    service refuses an unauthenticated call, and a bucket its endpoint does
    not serve is not found."""

    var _store: FakeGcsStorageBackend
    var _bucket: String
    var _authorized: Bool

    def __init__(out self, access: GcsAccess) raises:
        var store = FakeGcsStorageBackend()
        var bucket = String("")
        if access.host == GCS_GRPC_HOST and access.port == GCS_GRPC_PORT:
            bucket = String("raw")
            _ = store.conditional_create(bucket, "t/a.parquet", _bytes_a())
            _ = store.conditional_create(bucket, "t/b.parquet", _bytes_b())
            _ = store.conditional_create(bucket, "u/c.parquet", _bytes_c())
        elif access.host == _EMU_HOST and access.port == _EMU_PORT:
            bucket = String("emu")
            _ = store.conditional_create(bucket, "t/a.parquet", _bytes_c())
        self._store = store^
        self._bucket = bucket^
        self._authorized = access.token == _TOKEN

    def _check(self, method: String, bucket: String, key: String) raises:
        if not self._authorized:
            raise Error(
                String("StoreError[PERMISSION_DENIED] ") + method + " gs://"
                + bucket + "/" + key + " status=403 grpc_code=16 (UNAUTHENTICATED)"
            )
        if bucket != self._bucket:
            raise Error(
                String("StoreError[NOT_FOUND] ") + method + " gs://" + bucket
                + "/" + key + " status=404 grpc_code=5 (NOT_FOUND)"
            )

    def conditional_create(
        mut self, bucket: String, key: String, data: List[UInt8]
    ) raises -> Int64:
        self._check("WriteObject", bucket, key)
        return self._store.conditional_create(bucket, key, data)

    def compare_and_swap(
        mut self,
        bucket: String,
        key: String,
        data: List[UInt8],
        expected_generation: Int64,
    ) raises -> Int64:
        self._check("WriteObject", bucket, key)
        return self._store.compare_and_swap(bucket, key, data, expected_generation)

    def read_range(
        mut self,
        bucket: String,
        key: String,
        read_offset: Int64,
        read_limit: Int64,
    ) raises -> List[UInt8]:
        self._check("ReadObject", bucket, key)
        return self._store.read_range(bucket, key, read_offset, read_limit)

    def get_object(mut self, bucket: String, key: String) raises -> ObjectMetaRaw:
        self._check("GetObject", bucket, key)
        return self._store.get_object(bucket, key)

    def delete_object(mut self, bucket: String, key: String) raises:
        self._check("DeleteObject", bucket, key)
        self._store.delete_object(bucket, key)

    def list_objects(
        mut self,
        bucket: String,
        prefix: String,
        page_token: String,
        delimiter: String = String(""),
    ) raises -> ListPageRaw:
        self._check("ListObjects", bucket, prefix)
        return self._store.list_objects(bucket, prefix, page_token, delimiter)


comptime _Connectors = StoreConnectors[
    FakeS3Connector, FakeAzureConnector, _Buckets, FixedClock
]


def _mk_gcs(access: GcsAccess) raises -> _Buckets:
    return _Buckets(access)


def _mk_s3() raises -> FakeS3Connector:
    """Bucket `lake`: t/a.parquet and t/b.parquet, signed with AKIDRIGHT."""
    var c = FakeS3Connector(key_id=_KEY_ID)
    c.seed_bytes("t/a.parquet", _bytes_a())
    c.seed_bytes("t/b.parquet", _bytes_b())
    return c^


def _mk_azure() raises -> FakeAzureConnector:
    return FakeAzureConnector()


def _connectors() -> _Connectors:
    return _Connectors(
        _mk_s3, _mk_s3, _mk_azure, _mk_azure, _mk_gcs, FixedClock(1790000000)
    )


# ---- the session --------------------------------------------------------------


def _seal_token(mut s: Session, name: String, token: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_GCP_TOKEN, name)
    s.credentials.set(id, KOMIRA_FIELD_TOKEN, token.as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_bearer(mut s: Session, name: String, token: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_BEARER, name)
    s.credentials.set(id, KOMIRA_FIELD_TOKEN, token.as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_aws(mut s: Session, name: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_AWS_KEYS, name)
    s.credentials.set(id, KOMIRA_FIELD_KEY_ID, String(_KEY_ID).as_bytes())
    s.credentials.set(id, KOMIRA_FIELD_SECRET, String(_SECRET).as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _seal_service_account(mut s: Session, name: String) raises:
    var id = s.credentials.add(KOMIRA_CRED_GCP_SERVICE_ACCOUNT, name)
    s.credentials.set(id, KOMIRA_FIELD_FILE, String("service-account.json").as_bytes())
    s.credentials.seal(id, KOMIRA_BIND_SESSION)


def _session() raises -> Session:
    """GcpTokens `gcs` and `gcs-other` (the right token) and `gcs-wrong`,
    BearerToken `bearer` (the right token), GcpServiceAccount `sa` and AwsKeys
    `s3-etl`."""
    var s = Session()
    _seal_token(s, "gcs", _TOKEN)
    _seal_token(s, "gcs-other", _TOKEN)
    _seal_token(s, "gcs-wrong", _WRONG_TOKEN)
    _seal_bearer(s, "bearer", _TOKEN)
    _seal_service_account(s, "sa")
    _seal_aws(s, "s3-etl")
    return s^


def _source(
    location: String,
    credential: String = "gcs",
    endpoint: String = "",
    region: String = "",
    addressing: Int = 0,
    hive: Bool = False,
) raises -> List[UInt8]:
    """The bytes of a WireBoundSource naming a WireFileSource."""
    var access = WireSourceAccess(
        credential, endpoint, region, AddressingStyleWire(addressing), String("")
    )
    var files = WireFileSource(location, Optional[WireSourceAccess](access^), hive)
    return encode_proto(WireBoundSource(1, Optional[WireFileSource](files^)))


def _bind(mut s: Session, name: String, var source: List[UInt8]) raises:
    add_sql_binding_with(s, name, source^, KOMIRA_BIND_SESSION, _connectors())


def _refused(mut s: Session, name: String, var source: List[UInt8]) -> String:
    try:
        add_sql_binding_with(s, name, source^, KOMIRA_BIND_SESSION, _connectors())
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


def _write(dir: String, name: String, bytes: List[UInt8]) raises -> String:
    makedirs(dir, exist_ok=True)
    var path = dir + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


# ---- a gs:// binding read by SQL --------------------------------------------------


def test_a_gcs_object_answers_what_the_local_file_answers() raises:
    var s = _session()
    var dir = test_tmpdir() + "/bind_gcs_local"
    register_parquet(s, "local_a", _write(dir, "a.parquet", _bytes_a()))
    _bind(s, "remote_a", _source("gs://raw/t/a.parquet"))
    var q = " WHERE id >= 10 AND id < 31 ORDER BY id"
    var local = _ints(_sql(s, "SELECT id FROM local_a" + q))
    var remote = _ints(_sql(s, "SELECT id FROM remote_a" + q))
    _same(remote, local, "filtered ids")
    _same(remote, _range(10, 21), "the rows written")
    assert_equal(_count(s, "remote_a"), 40)


def test_a_gcs_glob_reads_every_matching_object() raises:
    var s = _session()
    _bind(s, "t_all", _source("gs://raw/t/*.parquet"))
    var want = _range(0, 40)
    want.extend(_range(100, 9))
    _same(_sorted(_ints(_sql(s, "SELECT id FROM t_all"))), want, "t/, not u/")
    assert_equal(
        _refused(s, "none", _source("gs://raw/v/*.parquet")),
        "PARQUET_GLOB_NO_MATCH: no file matches 'gs://raw/v/*.parquet'",
    )


def test_an_endpoint_of_the_sources_own_is_read() raises:
    var s = _session()
    _bind(s, "emu_a", _source("gs://emu/t/a.parquet", "gcs", _EMU))
    _same(_ints(_sql(s, "SELECT id FROM emu_a ORDER BY id")), _range(500, 3), "emu")
    _bind(s, "alias_b", _source("gcs://raw/t/b.parquet"))
    _same(_ints(_sql(s, "SELECT id FROM alias_b ORDER BY id")), _range(100, 9), "gcs://")
    _bind(s, "upper_b", _source("GS://raw/t/b.parquet"))
    _same(_ints(_sql(s, "SELECT id FROM upper_b ORDER BY id")), _range(100, 9), "GS://")
    # Google's endpoint does not serve `emu`: the endpoint reached the store.
    # A fresh session, since this one reads gs://emu at the emulator's
    # endpoint and would refuse the second way with BIND_STORE_CONFLICT.
    var fresh = _session()
    var refused = _refused(fresh, "x", _source("gs://emu/t/a.parquet"))
    assert_true(
        refused.find("StoreError[NOT_FOUND] GetObject gs://emu/t/a.parquet") >= 0,
        refused,
    )


def test_one_statement_reads_gcs_and_s3() raises:
    var s = _session()
    _bind(s, "gcs_a", _source("gs://raw/t/a.parquet"))
    _bind(
        s,
        "s3_b",
        _source("s3://lake/t/b.parquet", "s3-etl", "http://127.0.0.1:9000", "us-east-1"),
    )
    var want = _range(0, 40)
    want.extend(_range(100, 9))
    _same(
        _sorted(_ints(_sql(s, "SELECT id FROM gcs_a UNION ALL SELECT id FROM s3_b"))),
        want,
        "both stores",
    )


def test_the_token_sealed_now_is_the_one_read() raises:
    var s = _session()
    _bind(s, "remote_a", _source("gs://raw/t/a.parquet"))
    assert_equal(_count(s, "remote_a"), 40)
    _seal_token(s, "gcs", _WRONG_TOKEN)
    var refused = _sql_refusal(s, "SELECT count(*) FROM remote_a")
    assert_true(refused.startswith("execute: "), refused)
    assert_true("StoreError[PERMISSION_DENIED]" in refused, refused)
    assert_true("gs://raw/t/a.parquet" in refused, refused)
    assert_true(refused.find(_WRONG_TOKEN) < 0, refused)
    _seal_token(s, "gcs", _TOKEN)
    assert_equal(_count(s, "remote_a"), 40)


def test_a_refused_token_is_refused_at_the_binding() raises:
    var s = _session()
    var refused = _refused(s, "remote_a", _source("gs://raw/t/a.parquet", "gcs-wrong"))
    assert_true("StoreError[PERMISSION_DENIED]" in refused, refused)
    assert_true("gs://raw/t/a.parquet" in refused, refused)
    assert_true(refused.find(_WRONG_TOKEN) < 0, refused)
    assert_true(
        _sql_refusal(s, "SELECT count(*) FROM remote_a").startswith("bind: ")
    )


def test_each_gcs_refusal_is_named_word_for_word() raises:
    var s = _session()
    var at = String("add_sql_binding name=t: ")
    var loc = String("gs://raw/t/a.parquet")
    var no_credential = (
        "CREDENTIALS_NOT_FOUND: " + at + "the source names no credential, or"
        " ambient, which this library does not resolve; name a sealed credential"
    )
    var got = List[String]()
    var want = List[String]()
    got.append(_refused(s, "t", _source(loc, "")))
    want.append(no_credential)
    got.append(_refused(s, "t", _source(loc, "ambient")))
    want.append(no_credential)
    got.append(_refused(s, "t", _source(loc, "anonymous")))
    want.append(
        "BIND_SOURCE_UNSUPPORTED: " + at
        + "credential=anonymous: unsigned gs:// reads are not served"
    )
    got.append(_refused(s, "t", _source(loc, "sa")))
    want.append(
        "BIND_SOURCE_UNSUPPORTED: " + at + "credential=sa: a GcpServiceAccount"
        " is not read by this library; seal a GcpToken"
    )
    got.append(_refused(s, "t", _source(loc, "s3-etl")))
    want.append(
        "CREDENTIAL_KIND_MISMATCH: " + at
        + "credential=s3-etl does not fit a gs:// source"
    )
    got.append(_refused(s, "t", _source(loc, "bearer")))
    want.append(
        "CREDENTIAL_KIND_MISMATCH: " + at
        + "credential=bearer does not fit a gs:// source"
    )
    got.append(_refused(s, "t", _source("s3://lake/t/a.parquet", "gcs", "", "us-east-1")))
    want.append(
        "CREDENTIAL_KIND_MISMATCH: " + at + "credential=gcs does not fit a s3:// source"
    )
    got.append(_refused(s, "t", _source("az://box/t/a.parquet", "gcs")))
    want.append(
        "CREDENTIAL_KIND_MISMATCH: " + at + "credential=gcs does not fit a az:// source"
    )
    got.append(_refused(s, "t", _source(loc, "nobody")))
    want.append(
        "CREDENTIAL_UNBOUND: credential=nobody has no sealed value on this session"
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "", "us-east1")))
    want.append(
        "BIND_SOURCE_UNSUPPORTED: " + at + "a gs:// source takes no region"
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "", "", 2)))
    want.append(
        "BIND_SOURCE_UNSUPPORTED: " + at
        + "a gs:// source takes no addressing: each gRPC call names its bucket"
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "http://gcs.emulator.test:4443")))
    want.append(
        "STORAGE_URL_REFUSED: " + at + _NOT_HTTPS
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "https://gcs.emulator.test/storage/v1")))
    want.append(
        "STORAGE_URL_REFUSED: " + at + _A_PATH
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "https://gcs.emulator.test:0")))
    want.append(
        "STORAGE_URL_REFUSED: " + at + _BAD_PORT
    )
    got.append(_refused(s, "t", _source("gs:///t/a.parquet")))
    want.append(
        "STORAGE_URL_REFUSED: " + at + "a gs:// location names no bucket"
    )
    got.append(_refused(s, "t", _source("gs://raw/t/")))
    want.append(
        "BIND_SCOPE_NOT_A_TABLE: " + at
        + "gs://raw/t/ is a scope, not a table; name an object or a glob"
    )
    got.append(_refused(s, "t", _source("gs://raw")))
    want.append(
        "BIND_SCOPE_NOT_A_TABLE: " + at
        + "gs://raw is a scope, not a table; name an object or a glob"
    )
    got.append(_refused(s, "t", _source("gs://raw/t/a.parquet#generation=1")))
    want.append(
        "STORAGE_URL_REFUSED: " + at
        + "a location must not carry a query or a fragment"
    )
    got.append(_refused(s, "t", _source("gs://" + _TOKEN + "@raw/t/a.parquet")))
    want.append(
        "STORAGE_URL_REFUSED: " + at + "a location must not carry user"
        " information; a credential is named by the source, never written into"
        " its location"
    )
    got.append(_refused(s, "t", _source(loc, "gcs", "", "", 0, True)))
    want.append(
        "BIND_SOURCE_UNSUPPORTED: " + at
        + "Hive partitioning is not read from an object store yet"
    )
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "case " + String(i))
        assert_true(got[i].find(_TOKEN) < 0, "case " + String(i) + " holds the token")
        assert_true(got[i].find(_WRONG_TOKEN) < 0, "case " + String(i))
    # None of them bound the name.
    assert_true(_sql_refusal(s, "SELECT * FROM t").startswith("bind: "))


def test_a_gcs_bucket_is_read_one_way_per_session() raises:
    var s = _session()
    _bind(s, "a", _source("gs://raw/t/a.parquet"))
    _bind(s, "b", _source("gs://raw/t/b.parquet"))
    assert_equal(_count(s, "b"), 9)
    var conflict = String(
        "BIND_STORE_CONFLICT: add_sql_binding name=c: gs://raw is read by table"
        " 'a' with another credential or other settings; one session reads a"
        " bucket one way"
    )
    assert_equal(_refused(s, "c", _source("gs://raw/u/c.parquet", "gcs-other")), conflict)
    assert_equal(
        _refused(s, "c", _source("gs://raw/u/c.parquet", "gcs", "https://storage.googleapis.com")),
        conflict,
    )
    # Another bucket of the same store is read its own way.
    _bind(s, "c", _source("gs://emu/t/a.parquet", "gcs-other", _EMU))
    assert_equal(_count(s, "c"), 3)


def test_a_name_sealed_again_as_another_kind_refuses_the_statement() raises:
    var s = _session()
    _bind(s, "remote_a", _source("gs://raw/t/a.parquet"))
    var want = String(
        "bind: CREDENTIAL_KIND_MISMATCH: credential=gcs: table 'remote_a' reads"
        " gs://raw with a GcpToken, and the value sealed under the name now is"
        " of kind "
    )
    # A BearerToken holding the very token the store answers is still not
    # sent to it.
    _seal_bearer(s, "gcs", _TOKEN)
    assert_equal(_sql_refusal(s, "SELECT count(*) FROM remote_a"), want + "BearerToken")
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("CREDENTIAL_KIND_MISMATCH"))
    _seal_aws(s, "gcs")
    assert_equal(_sql_refusal(s, "SELECT count(*) FROM remote_a"), want + "AwsKeys")
    _seal_service_account(s, "gcs")
    assert_equal(
        _sql_refusal(s, "SELECT count(*) FROM remote_a"), want + "GcpServiceAccount"
    )
    _seal_token(s, "gcs", _TOKEN)
    assert_equal(_count(s, "remote_a"), 40)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
