# A session's credentials read through SecretCapability, and an S3 read with
# them: the right key reads the object, a wrong one is refused by name.
#
# The session's `secret_bindings` and `secret_store` are what
# `SecretCapability.open_connection_for` takes; `node_id_of(name, field)` is
# the capability's node. The S3 tests compose what the run call does once
# libkomira links the engine: reveal an AwsKeys credential's two fields into
# an `AwsCredential`, give it to an `S3ScanFs` over a fake S3 (no socket) that
# accepts only the access key id `AKIDRIGHT`, and run SQL over a table in the
# bucket.
#
# Rows:
#   * test_a_capability_reveals_each_field_once: key_id and secret come back
#     byte for byte, one store resolve per reveal.
#   * test_a_new_value_is_revealed_under_the_same_node: sealing a new secret
#     keeps the field's node id and the capability reveals the new value.
#   * test_a_node_the_session_never_bound_reveals_nothing: an unbound node
#     raises and the consumer is never called.
#   * test_a_field_dropped_by_a_reseal_reveals_nothing: the node of a session
#     token that a later seal left out raises the store's own error, naming
#     the credential and field and no value, and the consumer is never
#     called.
#   * test_the_right_key_reads_the_object: the sealed key's credential reads
#     the 40 rows of the object.
#   * test_a_wrong_key_is_refused_by_name: a credential sealed with another key
#     id is refused at step execute with StoreError[PERMISSION_DENIED] and the
#     store's InvalidAccessKeyId, word for word (so it holds neither the key
#     id nor the secret).
#   * test_resealing_the_right_key_reads_again: after the wrong key, sealing
#     the right one under the same name reads the object.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from aws_core import AwsCredential, FixedClock, StaticCredsSource
from http_client.client import HttpClientConfig
from objectstore_s3 import S3Config, S3ScanFs
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_expr.fs_descriptor_pod import FS_SCHEME_S3, FsDescriptorPod
from scan_source.parquet_source import ParquetSource
from secret_registry.credential_consumer import CredentialConsumer
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_EXECUTE, SqlOutcome, run_sql_with
from sdk_exec.secret_capability import SecretCapability

from komira_test_fake_s3 import FakeS3Connector
from so import (
    KOMIRA_BIND_SESSION,
    KOMIRA_CRED_AWS_KEYS,
    KOMIRA_FIELD_KEY_ID,
    KOMIRA_FIELD_SECRET,
    KOMIRA_FIELD_SESSION_TOKEN,
    SessionCredentials,
    SessionSecretStore,
)

comptime _Opener = S3ScanFs[FakeS3Connector, StaticCredsSource, FixedClock]
comptime _RIGHT_KEY = "AKIDRIGHT"
comptime _WRONG_KEY = "AKIDWRONG"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"


struct _Text(CredentialConsumer, Movable):
    """Copies each revealed value into `text` and counts the reveals."""

    var text: String
    var count: Int

    def __init__(out self):
        self.text = String("")
        self.count = 0

    def consume(mut self, secret: Span[UInt8, _]) raises:
        self.count += 1
        self.text = String(StringSlice(from_utf8=secret))


def _seal_aws(mut c: SessionCredentials, name: String, key_id: String, secret: String) raises:
    var id = c.add(KOMIRA_CRED_AWS_KEYS, name)
    c.set(id, KOMIRA_FIELD_KEY_ID, key_id.as_bytes())
    c.set(id, KOMIRA_FIELD_SECRET, secret.as_bytes())
    c.seal(id, KOMIRA_BIND_SESSION)


def _reveal(c: SessionCredentials, name: String, field: Int32) raises -> String:
    """One field of a sealed credential, through its SecretCapability."""
    var consumer = _Text()
    SecretCapability(c.node_id_of(name, field)).open_connection_for[
        SessionSecretStore, _Text
    ](c.secret_bindings(), c.secret_store(), consumer)
    assert_equal(consumer.count, 1, "one reveal")
    return consumer.text.copy()


def _aws_credential(c: SessionCredentials, name: String) raises -> AwsCredential:
    """What the run call builds from an AwsKeys credential."""
    return AwsCredential(
        _reveal(c, name, KOMIRA_FIELD_KEY_ID),
        _reveal(c, name, KOMIRA_FIELD_SECRET),
        String(""),
    )


# ---- the store -------------------------------------------------------------


def _object() raises -> List[UInt8]:
    """40 rows, id 0 .. 39, in row groups of 7."""
    var n = 40
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ids.set(i, Int64(i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    return write_record_batch_to_parquet_bytes(rb.build(sb.build()), max_rows_per_rg=7)


def _mk_store() raises -> FakeS3Connector:
    """Bucket `lake` with t/a.parquet, answering only requests signed with
    the access key id AKIDRIGHT."""
    var store = FakeS3Connector(key_id=_RIGHT_KEY)
    store.seed_bytes("t/a.parquet", _object())
    return store^


def _opener(credential: AwsCredential) raises -> _Opener:
    return _Opener(
        S3Config.custom_endpoint("us-east-1", "http://127.0.0.1:9000"),
        _mk_store,
        HttpClientConfig.defaults(),
        StaticCredsSource(credential),
        FixedClock(1790000000),
    )


def _context() raises -> EngineContext:
    """The table remote_a: t/a.parquet of bucket lake."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    var keys = List[String]()
    keys.append("t/a.parquet")
    var ps = ParquetSource.partitioned(
        keys^, sb.build(), List[Field](), List[List[String]]()
    ).with_fs_descriptor(FsDescriptorPod.cloud(FS_SCHEME_S3, "lake", 0))
    ctx.catalog.add_parquet_source("remote_a", ps^)
    return ctx^


def _count(var out: SqlOutcome) raises -> Int:
    if out.refusal:
        assert_true(False, "refused at " + out.refusal.value().step + ": " + out.refusal.value().reason)
    return Int(out.batches[0].column_at(0).as_primitive[DType.int64]().get(0))


# ---- the tests -------------------------------------------------------------


def test_a_capability_reveals_each_field_once() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _RIGHT_KEY, _SECRET)
    var probe = c.secret_store()
    assert_equal(_reveal(c, "raw-etl", KOMIRA_FIELD_KEY_ID), _RIGHT_KEY)
    assert_equal(_reveal(c, "raw-etl", KOMIRA_FIELD_SECRET), _SECRET)
    assert_equal(probe.resolve_count(), 2, "one store resolve per reveal")


def test_a_new_value_is_revealed_under_the_same_node() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _RIGHT_KEY, "first-secret")
    var node = c.node_id_of("raw-etl", KOMIRA_FIELD_SECRET)
    _seal_aws(c, "raw-etl", _RIGHT_KEY, "second-secret")
    assert_equal(c.node_id_of("raw-etl", KOMIRA_FIELD_SECRET), node, "the field keeps its node")
    assert_equal(_reveal(c, "raw-etl", KOMIRA_FIELD_SECRET), "second-secret")


def test_a_node_the_session_never_bound_reveals_nothing() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _RIGHT_KEY, _SECRET)
    var consumer = _Text()
    var raised = False
    try:
        SecretCapability(1000).open_connection_for[SessionSecretStore, _Text](
            c.secret_bindings(), c.secret_store(), consumer
        )
    except:
        raised = True
    assert_true(raised, "an unbound node raised")
    assert_equal(consumer.count, 0, "the consumer was never called")


def test_a_field_dropped_by_a_reseal_reveals_nothing() raises:
    var c = SessionCredentials()
    var id = c.add(KOMIRA_CRED_AWS_KEYS, "temp")
    c.set(id, KOMIRA_FIELD_KEY_ID, "ASIA".as_bytes())
    c.set(id, KOMIRA_FIELD_SECRET, "temp-secret".as_bytes())
    c.set(id, KOMIRA_FIELD_SESSION_TOKEN, "token-value".as_bytes())
    c.seal(id, KOMIRA_BIND_SESSION)
    var node = c.node_id_of("temp", KOMIRA_FIELD_SESSION_TOKEN)
    _seal_aws(c, "temp", "ASIA", "temp-secret")
    var consumer = _Text()
    var message = String("")
    try:
        SecretCapability(node).open_connection_for[SessionSecretStore, _Text](
            c.secret_bindings(), c.secret_store(), consumer
        )
    except e:
        message = String(e)
    assert_equal(message, "SessionSecretStore: no value for temp/3")
    assert_equal(consumer.count, 0, "the consumer was never called")


def test_the_right_key_reads_the_object() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _RIGHT_KEY, _SECRET)
    var ctx = _context()
    var out = run_sql_with(ctx, "SELECT count(*) FROM remote_a", _opener(_aws_credential(c, "raw-etl")))
    assert_equal(_count(out^), 40)


def test_a_wrong_key_is_refused_by_name() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _WRONG_KEY, _SECRET)
    var ctx = _context()
    var out = run_sql_with(ctx, "SELECT count(*) FROM remote_a", _opener(_aws_credential(c, "raw-etl")))
    assert_false(out.ok(), "a wrong key read the object")
    var r = out.refusal.value().copy()
    assert_equal(r.step, String(STEP_EXECUTE))
    # Word for word, so neither the key id nor the secret is in it.
    assert_equal(
        r.reason,
        "StoreError[PERMISSION_DENIED] GetObject s3://lake/t/a.parquet"
        " status=403 s3_code=InvalidAccessKeyId s3_message=fake",
    )


def test_resealing_the_right_key_reads_again() raises:
    var c = SessionCredentials()
    _seal_aws(c, "raw-etl", _WRONG_KEY, _SECRET)
    var ctx = _context()
    var refused = run_sql_with(ctx, "SELECT count(*) FROM remote_a", _opener(_aws_credential(c, "raw-etl")))
    assert_false(refused.ok(), "a wrong key read the object")
    _seal_aws(c, "raw-etl", _RIGHT_KEY, _SECRET)
    assert_equal(c.generation_of("raw-etl"), 2)
    var out = run_sql_with(ctx, "SELECT count(*) FROM remote_a", _opener(_aws_credential(c, "raw-etl")))
    assert_equal(_count(out^), 40)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
