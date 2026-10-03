# =============================================================================
# Integration test for JsonSource + the SourceVariant JSON arm.
# =============================================================================
#
# Coverage:
#   T1  JsonSource ctor + schema + fingerprint stability across moves/clones.
#   T2  SourceVariant.from(JsonSource) tag + dispatch round-trip.
#   T3  materialize_jsonl_to_batch consumes JsonSource's schema
#       and produces the expected RecordBatch (covers the materializer path
#       that ctx.read_json_batch routes through internally).
#
# NOTE: the EngineContext-level driver `ctx.read_json_batch(path, schema)`
# is exercised by the SDK suite; this test focuses on the komira_core
# source + komira_jsonl surfaces. Splitting the coverage two-way keeps each
# test under the compile-time template-instantiation budget while still
# covering the contract (JsonSource conforms to SourceLike; SourceVariant JSON arm
# round-trips; the materializer accepts the JsonSource-attached schema).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.source.json_source import JsonSource
from komira_core.source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_JSON,
)

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory this run may write scratch files into: the runner's
    private, per-run scratch directory (never a shared `/tmp` path)."""
    return test_tmpdir()


def _schema_i64(name: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    return sb.build()


def test_json_source_ctor_and_schema() raises:
    print("T1: JsonSource ctor + schema + fingerprint stability")
    var src = JsonSource((_scratch_dir() + String("/foo.jsonl")), _schema_i64(String("id")))
    var fp1 = src.fingerprint()
    var sch = src.schema()
    assert_equal(sch.num_columns(), 1)
    assert_equal(String(sch.field_name(0)), String("id"))

    # Clone preserves identity (cache-discrimination contract).
    var c = src.copy()
    var fp2 = c.fingerprint()
    assert_equal(fp1, fp2)

    # Two different paths -> different fingerprints.
    var src2 = JsonSource((_scratch_dir() + String("/bar.jsonl")), _schema_i64(String("id")))
    var fp3 = src2.fingerprint()
    assert_true(fp1 != fp3)

    # estimate_rows() == -1 (unknown).
    assert_equal(src.estimate_rows(), -1)
    print("  PASS")


def test_source_variant_json_arm() raises:
    print("T2: SourceVariant JSON arm tag + dispatch round-trip")
    var src = JsonSource((_scratch_dir() + String("/foo.jsonl")), _schema_i64(String("id")))
    var sv = SourceVariant(src^)
    assert_equal(Int(sv.tag), Int(SOURCE_VARIANT_JSON))
    assert_equal(String(sv.kind_name()), String("json"))
    # schema + fingerprint dispatch through SourceVariant work.
    var sch = sv.schema()
    assert_equal(sch.num_columns(), 1)
    var fp = sv.fingerprint()
    # Round-trip via copy preserves tag.
    var sv2 = sv.copy()
    assert_equal(Int(sv2.tag), Int(SOURCE_VARIANT_JSON))
    assert_equal(sv2.fingerprint(), fp)
    print("  PASS")


def test_materializer_via_jsonsource_schema() raises:
    print("T3: materialize_jsonl_to_batch consumes JsonSource schema shape")
    # The same schema attached to a JsonSource flows through
    # ctx.read_json_batch's call to materialize_jsonl_to_batch internally.
    # Drive that path directly with an in-memory JSONL byte buffer.
    var input = String('{"id":1}\n{"id":2}\n{"id":3}\n')
    var bytes = input.as_bytes()
    var src = JsonSource(
        (_scratch_dir() + String("/synthetic.jsonl")),
        _schema_i64(String("id")),
    )
    # `materialize_jsonl_to_batch` consumes the schema, so we materialize
    # from the source's cached copy (mirror of what _compile_json_scan does).
    var schema_for_materialize = src.schema()
    var batch = materialize_jsonl_to_batch(bytes, schema_for_materialize^)
    assert_equal(batch._num_rows, 3)
    assert_equal(batch.schema.num_columns(), 1)
    print("  PASS")


def main() raises:
    print("test_read_json_batch_e2e — JSON source integration suite")
    test_json_source_ctor_and_schema()
    test_source_variant_json_arm()
    test_materializer_via_jsonsource_schema()
    print("test_read_json_batch_e2e — all tests PASSED")
