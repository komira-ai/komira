# =============================================================================
# test_plan_wire_codec_encode_refusals.mojo — the ENCODER's half of the codec
# ledger: shapes `plan_to_bytes` refuses by name, and the arms it carries that
# no other test round-trips.
# =============================================================================
#
# Every plan below is built through a public factory or a public field of a
# public type (`ParquetSource.hive_dir_scan`, `ParamValue.tag`, the bare
# `LogicalPlan(tag, schema)` ctor, `set_estimated_groups`), so each state is
# one a caller can hand to `plan_to_bytes`. For each, the test states what the
# codec must do with it and asserts it:
#
#   REFUSED BY NAME   the encoder raises the `PLAN_WIRE_*` token the codec
#                     ledger (`plan_wire_codec.mojo`) documents, naming the
#                     part it refused. A codec that encoded around the part
#                     would write a smaller plan than the caller built.
#   CARRIED           the plan round-trips: the decoded plan renders the same
#                     (`structural_hash`) AND the part the render cannot see is
#                     read back off the decoded IR and compared.
#
# No golden bytes: every check is a value read back through the codec's own
# decoder or a refusal token, so a `format_version` bump changes nothing here.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from komira_plan_expr.partition_pred_pod import PartitionPredicatePod
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_AGG,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_STABILITY_STABLE,
    UDF_PAR_MERGEABLE,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
)
from komira_plan_stats.table_stats import TableStats, ColumnStats
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import ScanBinding, scan_kind_id
from komira_scan_source.scan_params import (
    ParamValue,
    ScanParams,
    PARAM_BYTES,
)
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

from komira_proto_codec import decode_proto
from komira_plan_proto.plan import WirePlanEnvelope

from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_codec import (
    PLAN_WIRE_UNSUPPORTED_DTYPE,
    PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET,
    PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
    PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY,
    PLAN_WIRE_UNSUPPORTED_TABLE_STATS,
    PLAN_WIRE_UNSUPPORTED_PARAM_TAG,
    PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS,
    PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    return sb.build()


def _parquet_scan(path: String) raises -> LogicalPlan:
    """A scan through the positional factory a frontend calls for a parquet
    path: `LogicalPlan.scan(path, SOURCE_PARQUET, schema)`."""
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _orc_binding(var params: ScanParams) raises -> ScanBinding:
    return ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("t"),
        params=params^,
        schema=_schema(),
        fingerprint=UInt64(11),
        structural_id=UInt64(12),
        gate=PushdownGate.conjunctive_comparison(),
    )


def _encode_error(p: LogicalPlan) raises -> String:
    """The text `plan_to_bytes` raised, or "" when it returned bytes."""
    try:
        _ = plan_to_bytes(p)
    except e:
        return String(e)
    return String("")


def _decode_error(var bytes: List[UInt8]) raises -> String:
    """The text `plan_from_bytes` raised, or "" when it returned a plan."""
    try:
        var p = plan_from_bytes(bytes^)
        _ = p.structural_hash()
    except e:
        return String(e)
    return String("")


def _assert_encode_refused(
    what: String, p: LogicalPlan, token: String, detail: String
) raises:
    var text = _encode_error(p)
    assert_true(
        text != "",
        what + ": plan_to_bytes returned bytes. The codec ledger refuses this"
        + " shape; encoding it writes a plan smaller than the one built.",
    )
    assert_true(
        text.startswith(token),
        what + ": refused, but not by " + token + ". Got: " + text,
    )
    assert_true(
        detail in text,
        what + ": the refusal does not name `" + detail + "`. Got: " + text,
    )


# =============================================================================
# Parquet sources the wire cannot describe
# =============================================================================


def test_a_hive_dir_scan_is_refused_at_encode() raises:
    """`hive_dir_scan` with no predicate: the first operand of the `or` fires
    and the message reports the predicate as absent."""
    var src = ParquetSource(String("/data/t"), _schema())
    src.hive_dir_scan = True
    var plan = LogicalPlan.scan_from_source(SourceVariant(src^), _schema())
    _assert_encode_refused(
        String("hive_dir_scan"), plan, PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET,
        String("hive_dir_scan=True, hive_predicate=False"),
    )


def test_a_hive_predicate_alone_is_refused_at_encode() raises:
    """A partition predicate with `hive_dir_scan` False: the second operand
    alone must refuse, and the message reports the predicate as present (the
    `_present_hive` True arm). An encoder that tested only `hive_dir_scan`
    would drop the predicate and scan every partition."""
    var src = ParquetSource(String("/data/t.parquet"), _schema())
    src.hive_predicate = Optional(PartitionPredicatePod.empty())
    var plan = LogicalPlan.scan_from_source(SourceVariant(src^), _schema())
    _assert_encode_refused(
        String("hive_predicate"), plan, PLAN_WIRE_UNSUPPORTED_HIVE_PARQUET,
        String("hive_dir_scan=False, hive_predicate=True"),
    )


def test_a_cloud_descriptor_is_refused_at_encode() raises:
    """A source whose `FsDescriptorPod` names S3 at a LOCAL-looking path: the
    descriptor witness refuses (the path witness alone would accept it)."""
    var src = ParquetSource(String("/data/t.parquet"), _schema())
    var cloud = src.with_fs_descriptor(
        FsDescriptorPod.cloud(FS_SCHEME_S3, String("bucket"), 0)
    )
    var plan = LogicalPlan.scan_from_source(SourceVariant(cloud^), _schema())
    _assert_encode_refused(
        String("cloud descriptor"), plan, PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
        String("names a non-local filesystem"),
    )


def test_every_object_store_scheme_in_a_path_is_refused_at_encode() raises:
    """`ParquetSource` stamps the descriptor LOCAL, so the path is the only
    witness for these. Each of the six spellings `_cloud_scheme_of` knows is
    refused and named; dropping any one arm makes that path encode with
    `fs_is_local=true`, a local read of an object-store URI."""
    var paths: List[String] = [
        String("s3://b/k.parquet"),
        String("gs://b/k.parquet"),
        String("gcs://b/k.parquet"),
        String("az://c/k.parquet"),
        String("abfs://c/k.parquet"),
        String("abfss://c/k.parquet"),
    ]
    var schemes: List[String] = [
        String("s3"), String("gs"), String("gcs"),
        String("az"), String("abfs"), String("abfss"),
    ]
    for i in range(len(paths)):
        _assert_encode_refused(
            paths[i], _parquet_scan(paths[i]), PLAN_WIRE_UNSUPPORTED_REMOTE_FS,
            String("names the '") + schemes[i] + "' object store",
        )


def test_a_local_path_holding_a_scheme_mid_string_still_encodes() raises:
    """The control for the test above: the scheme check is a PREFIX check, and
    a local path may contain `gs://` after its first byte. A check that
    searched the whole path would refuse a plan that encodes correctly."""
    var plan = _parquet_scan(String("/data/gs://not-a-bucket/t.parquet"))
    var text = _encode_error(plan)
    assert_equal(text, String(""), "a local path was refused: " + text)
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())


# =============================================================================
# Scan leaves the wire cannot carry
# =============================================================================


def test_an_in_memory_scan_is_refused_at_encode() raises:
    """`LogicalPlan.scan(name, SOURCE_IN_MEMORY, schema)` holds live batches in
    the IR; there is no description to encode."""
    var plan = LogicalPlan.scan(String("registry_t"), SOURCE_IN_MEMORY, _schema())
    _assert_encode_refused(
        String("in-memory scan"), plan, PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY,
        String("InMemorySource"),
    )


def test_a_variant_tag_outside_every_arm_is_refused_at_encode() raises:
    """The kw-only binding ctor takes any tag. Tag 10 (one past
    SOURCE_VARIANT_BINDING) is neither parquet, in-memory nor binding-backed;
    the encoder must refuse it rather than pick an arm."""
    var sv = SourceVariant(tag=UInt8(10), binding=_orc_binding(ScanParams()))
    var plan = LogicalPlan.scan_from_source(sv^, _schema())
    _assert_encode_refused(
        String("variant tag 10"), plan, PLAN_WIRE_UNSUPPORTED_SOURCE_IN_MEMORY,
        String("SourceVariant tag 10 is neither parquet nor binding-backed"),
    )


def test_scan_table_stats_are_refused_at_encode() raises:
    """`ScanData.table_stats` steer join order and have no wire slot."""
    var stats = TableStats(7, List[String](), List[ColumnStats]())
    var plan = LogicalPlan.scan(
        String("/data/t.parquet"), SOURCE_PARQUET, _schema(),
        None, None, None, Optional(stats^),
    )
    _assert_encode_refused(
        String("ScanData.table_stats"), plan, PLAN_WIRE_UNSUPPORTED_TABLE_STATS,
        String("ScanData for '/data/t.parquet' carries TableStats"),
    )


def test_binding_table_stats_are_refused_at_encode() raises:
    """The binding's own `stats` slot, refused separately from ScanData's."""
    var b = _orc_binding(ScanParams())
    b.stats = Optional(TableStats(7, List[String](), List[ColumnStats]()))
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=b^), _schema()
    )
    _assert_encode_refused(
        String("ScanBinding.stats"), plan, PLAN_WIRE_UNSUPPORTED_TABLE_STATS,
        String("ScanBinding 't' carries TableStats"),
    )


def test_a_param_with_an_undeclared_tag_is_refused_at_encode() raises:
    """`ParamValue.tag` is a public field; 6 is one past PARAM_BYTES. The
    encoder must refuse rather than write a tag no reader can name."""
    var v = ParamValue.of_str(String("x"))
    v.tag = UInt8(6)
    var p = ScanParams()
    p.put(String("odd"), v^)
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=_orc_binding(p^)),
        _schema(),
    )
    _assert_encode_refused(
        String("param tag 6"), plan, PLAN_WIRE_UNSUPPORTED_PARAM_TAG,
        String("ScanParams key 'odd' carries tag 6"),
    )


def test_a_bytes_param_round_trips_as_bytes() raises:
    """PARAM_BYTES shares the string slot with PARAM_STR on the wire; the tag
    is what tells them apart. A decoder that read every string-slot param back
    as PARAM_STR would change the param's type and its hash."""
    var p = ScanParams()
    p.put(String("blob"), ParamValue.of_bytes(String("\x01\x02raw")))
    var plan = LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=_orc_binding(p^)),
        _schema(),
    )
    var back = plan_from_bytes(plan_to_bytes(plan))
    ref sv = back.scan_data_ref().source
    ref params = sv.binding_ref().params
    assert_equal(params.num_params(), 1)
    assert_equal(params.key_at(0), String("blob"))
    var got = params.value_at(0)
    assert_equal(Int(got.tag), Int(PARAM_BYTES), "the bytes param lost its tag")
    assert_equal(got.s, String("\x01\x02raw"))
    assert_equal(back.structural_hash(), plan.structural_hash())


# =============================================================================
# DTypes
# =============================================================================


def test_every_unsigned_and_half_dtype_round_trips_through_a_cast() raises:
    """The five DTypes no other test sends through `_dtype_to_wire` /
    `_dtype_from_wire`. Each cast's target is read back off the decoded IR,
    so a table that mapped two of them to one code is red."""
    var targets: List[DType] = [
        DType.uint8, DType.uint16, DType.uint32, DType.uint64, DType.float16,
    ]
    var exprs = ExprArray()
    for i in range(len(targets)):
        exprs.append(
            Expr.alias(
                Expr.cast(Expr.col_ref(String("a")), targets[i]),
                String("c") + String(i),
            )
        )
    var plan = LogicalPlan.project(exprs^, _parquet_scan(String("/d/t.parquet")))
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    ref d = back.project_data_ref()
    assert_equal(len(d.exprs), len(targets))
    for i in range(len(targets)):
        var cast = d.exprs[i].alias_child()
        assert_equal(
            cast.cast_target(), targets[i],
            String("cast ") + String(i) + " decoded to the wrong DType",
        )


def test_a_dtype_with_no_wire_code_is_refused_at_encode() raises:
    """bfloat16 has no code in the table. The encoder must refuse it by name
    rather than derive a code from the arrow type (lossy)."""
    var exprs = ExprArray()
    exprs.append(
        Expr.alias(Expr.cast(Expr.col_ref(String("a")), DType.bfloat16), "h")
    )
    var plan = LogicalPlan.project(exprs^, _parquet_scan(String("/d/t.parquet")))
    _assert_encode_refused(
        String("bfloat16 cast"), plan, PLAN_WIRE_UNSUPPORTED_DTYPE,
        String("no wire code for DType 'bfloat16'"),
    )


# =============================================================================
# Plan nodes
# =============================================================================


def _agg_udf() -> UdfData:
    """An AGG UdfData with every tag off its default."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("b", UInt8(4)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("score", UInt8(4)))
    var pk: List[String] = [String("a")]
    return UdfData(
        kind=UDF_KIND_AGG,
        name=String("weighted_score"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(4411),
        call_site_salt=UInt32(5),
        null_mode=UDF_NULL_SKIP_NULL_FAST_PATH,
        stability=UDF_STABILITY_STABLE,
        parallelism_tag=UDF_PAR_MERGEABLE,
        partition_keys=pk^,
        has_vector_path=True,
    )


def _group_by_a() -> ExprArray:
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    return gb^


def _sum_b() -> AggExprArray:
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref(String("b"))), Optional(String("t")))
    )
    return ax^


def test_an_aggregate_udf_round_trips_unbound() raises:
    """`aggregate_with_udf`: the UDF description crosses, every field is read
    back, and the handle does not (the decoder never invents one)."""
    var plan = LogicalPlan.aggregate_with_udf(
        _group_by_a(), _sum_b(), _parquet_scan(String("/d/t.parquet")),
        OwnedPointer[UdfData](_agg_udf()),
    )
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    ref d = back.aggregate_data_ref()
    assert_true(Bool(d.udf), "the decoded aggregate lost its UDF")
    ref u = d.udf.value()[]
    assert_equal(Int(u.kind), Int(UDF_KIND_AGG))
    assert_equal(u.name, String("weighted_score"))
    assert_equal(Int(u.null_mode), Int(UDF_NULL_SKIP_NULL_FAST_PATH))
    assert_equal(Int(u.stability), Int(UDF_STABILITY_STABLE))
    assert_equal(Int(u.parallelism_tag), Int(UDF_PAR_MERGEABLE))
    assert_equal(Int(u.operator_factory_id), 4411)
    assert_equal(Int(u.call_site_salt), 5)
    assert_true(u.has_vector_path)
    assert_equal(len(u.input_columns), 1)
    assert_equal(u.input_columns[0][0], String("b"))
    assert_equal(len(u.output_columns), 1)
    assert_equal(u.output_columns[0][0], String("score"))
    assert_equal(len(u.partition_keys), 1)
    assert_false(Bool(u.registered_handle_id), "the decoder minted a handle")
    assert_equal(
        back.output_schema.num_columns(), plan.output_schema.num_columns()
    )


def _decoded_hint(back: LogicalPlan) raises -> Optional[Int]:
    """The `estimated_groups` the decoded aggregate or distinct node holds."""
    if back.is_aggregate():
        return back.aggregate_data_ref().estimated_groups.copy()
    return back.distinct_data_ref().estimated_groups.copy()


def _assert_hint_never_dropped(what: String, plan: LogicalPlan, hint: Int) raises:
    """An `estimated_groups` hint must not vanish on the way through. What is
    asserted holds whichever layer ends up owning the hint:

      * the encoder refuses the plan, by PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS;
      * or the bytes carry the hint with the value the caller set, and then
          - the decoder restores it: the decoded node holds the same hint, or
          - the decoder refuses it, by the same token and nothing else.

    Today the encoder writes the hint and the decoder refuses it, so a plan
    that encodes never decodes (komira#991, open). The refusal is accepted so
    this test stays green on today's code; a decoder that restores the hint
    (the fix) passes the restored-value check instead. Red: an encoder that
    drops or rewrites the hint, a decoder that decodes the plan WITHOUT the
    hint or with another value, and a refusal by any other token."""
    var enc = _encode_error(plan)
    if enc != "":
        assert_true(
            enc.startswith(PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS),
            what + ": refused at encode by the wrong token: " + enc,
        )
        return
    var bytes = plan_to_bytes(plan)
    var env = decode_proto[WirePlanEnvelope](bytes.copy())
    ref w = env.plan.value()
    var carried = False
    var value = Int64(-1)
    if w.aggregate:
        carried = w.aggregate[0].has_estimated_groups
        value = w.aggregate[0].estimated_groups
    elif w.distinct:
        carried = w.distinct[0].has_estimated_groups
        value = w.distinct[0].estimated_groups
    assert_true(carried, what + ": the encoder dropped the hint silently")
    assert_equal(Int(value), hint, what + ": the encoder wrote another value")
    var decoded = True
    var text = String("")
    var got: Optional[Int] = None
    try:
        var back = plan_from_bytes(bytes^)
        got = _decoded_hint(back)
    except e:
        decoded = False
        text = String(e)
    if decoded:
        assert_true(Bool(got), what + ": the plan decoded WITHOUT the hint")
        assert_equal(
            got.value(), hint, what + ": the plan decoded with another hint"
        )
        return
    # komira#991 (open): the decoder refuses the hint the encoder wrote.
    assert_true(
        text.startswith(PLAN_WIRE_UNSUPPORTED_ESTIMATED_GROUPS),
        what + ": the decoder refused the carried hint by another token: "
        + text,
    )


def test_an_aggregate_estimated_groups_hint_is_never_dropped() raises:
    var plan = LogicalPlan.aggregate(
        _group_by_a(), _sum_b(), _parquet_scan(String("/d/t.parquet"))
    )
    plan.set_estimated_groups(Optional(42))
    _assert_hint_never_dropped(String("aggregate"), plan, 42)


def test_a_distinct_estimated_groups_hint_is_never_dropped() raises:
    var cols: List[String] = [String("a")]
    var plan = LogicalPlan.distinct(
        Optional(cols^), _parquet_scan(String("/d/t.parquet"))
    )
    plan.set_estimated_groups(Optional(9))
    _assert_hint_never_dropped(String("distinct"), plan, 9)


def test_a_distinct_over_every_column_round_trips_with_no_column_list() raises:
    """`DISTINCT` with `columns = None` (every column) and `DISTINCT` with an
    explicit list are different nodes; `has_columns` is what tells them apart
    on the wire. The decoded node must keep None, not become an empty list."""
    var plan = LogicalPlan.distinct(
        Optional[List[String]](None), _parquet_scan(String("/d/t.parquet"))
    )
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    assert_false(
        Bool(back.distinct_data_ref().columns),
        "DISTINCT over every column decoded with a column list",
    )


def test_an_aggregate_with_no_alias_round_trips_with_no_alias() raises:
    """An `AggExpr` with no alias: `has_alias_name` must stay False, so the
    decoded alias is None rather than the empty string."""
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(String("b"))), None))
    var plan = LogicalPlan.aggregate(
        _group_by_a(), ax^, _parquet_scan(String("/d/t.parquet"))
    )
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(back.structural_hash(), plan.structural_hash())
    ref d = back.aggregate_data_ref()
    assert_equal(len(d.agg_exprs), 1)
    assert_false(
        Bool(d.agg_exprs[0].alias_name),
        "an unaliased aggregate decoded with an alias",
    )


def test_a_union_of_no_children_does_not_decode() raises:
    """`LogicalPlan.union` documents "children must be non-empty" and does not
    enforce it. A childless union advertises columns nothing produces, so it
    must not cross. Today the encoder writes it and the decoder refuses it by
    name; an encoder that refused it first, by the same token and naming the
    missing children, is accepted too. Red: the plan decoding, or a refusal by
    another token at either end."""
    var plan = LogicalPlan.union(List[OwnedPointer[LogicalPlan]](), _schema())
    var text = _encode_error(plan)
    if text == "":
        text = _decode_error(plan_to_bytes(plan))
    assert_true(
        text.startswith(PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED),
        "a childless UNION decoded or was refused by another token: " + text,
    )
    assert_true("carries NO children" in text, text)


def test_a_bare_ctor_plan_with_no_arm_does_not_encode() raises:
    """The public `LogicalPlan(tag, schema)` ctor builds a node of any tag.
    Tag 16 is retired and has no message arm, so it must not become bytes.

    Only properties that hold whichever layer refuses are asserted: the encode
    raises, and the message names engine tag 16. (Today the vocabulary's
    `plan_tag_to_wire` raises while the codec builds its own message, so the
    codec's `PLAN_WIRE_UNSUPPORTED_PLAN_TAG` text never appears; see
    komira#991.)"""
    var plan = LogicalPlan(UInt8(16), _schema())
    var text = _encode_error(plan)
    assert_true(text != "", "a plan of retired tag 16 encoded to bytes")
    assert_true("engine tag 16" in text, text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
