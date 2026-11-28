"""The relational encoder of komira._plan, case by case: the scan's sources
and the checks of a scan's declared columns, the field every aggregate and
window function derives over each input type that changes it, join
nullability and renaming, a residual typed by side, the window stacking and its
shadow names, every refusal by its exact class and full message, and the
argument checks. test_plan_rel_goldens.py holds the encoder to plans the
engine built.

    test_plan_rel.py
"""

import sys

from komira._errors import UnsupportedOperation
from komira._ops import (
    Agg,
    Aggregate,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Frame,
    Join,
    Limit,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Union,
    When,
    WindowExpr,
    Write,
    WriteTarget,
)
from komira._plan import binding_source, encode_plan, parquet_source
from komira._plan._expr import encode_residual
from komira.plan.v1 import plan_pb2 as pb
from komira.plan.v1 import plan_vocabulary_pb2 as vocab


def type_id(arrow):
    return getattr(vocab, "ARROW_TYPE_" + arrow.upper()) - 1


def column(name, arrow, nullable=True, **slots):
    """A file's column as libkomira describes it: `arrow` is the Arrow type's
    name, e.g. "int64"; its dictionary index type is INT32."""
    slots.setdefault("dict_index_type_id", 4)
    return pb.WireField(name=name, arrow_type_id=type_id(arrow), nullable=nullable, **slots)


def scan_of(path, *fields, fmt="parquet"):
    """A scan of `path` declaring `fields`, and the sources it reads."""
    node = Scan(path, fmt, tuple(Field(f.name, arrow_name(f)) for f in fields))
    schema = pb.WireSchema(fields=fields)
    return node, {path: parquet_source(path, schema.SerializeToString())}


def arrow_name(f):
    return vocab.ArrowType.Name(f.arrow_type_id + 1).removeprefix("ARROW_TYPE_").lower()


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


ORDERS_FIELDS = (
    column("o_id", "int64", False, dtype_code=vocab._DT_INT64, metadata_keys=["unit"], metadata_values=["id"]),
    column("c_id", "int64", dtype_code=vocab._DT_INT64),
    column("qty", "int32", dtype_code=vocab._DT_INT32),
    column("price", "float64", dtype_code=vocab._DT_FLOAT64),
    column("amount", "decimal128", decimal_precision=12, decimal_scale=2),
    column("ts", "timestamp_us", dtype_code=vocab._DT_INT64, tz="UTC"),
    column("s", "string"),
)
ORDERS, ORDERS_SOURCES = scan_of("/data/orders.parquet", *ORDERS_FIELDS)
CUSTOMERS_FIELDS = (column("c_id", "int64", False), column("region", "string"))
CUSTOMERS, CUSTOMERS_SOURCES = scan_of("/data/customers.parquet", *CUSTOMERS_FIELDS)
BOTH = {**ORDERS_SOURCES, **CUSTOMERS_SOURCES}


def root(plan, sources=ORDERS_SOURCES):
    return encode_plan(plan, sources).plan


def out_fields(plan, sources=ORDERS_SOURCES):
    return [(f.name, arrow_name(f), f.nullable) for f in root(plan, sources).output_schema.fields]


# --- the envelope and its arguments -----------------------------------------


def test_the_envelope_is_format_4_and_carries_only_the_plan():
    out = encode_plan(ORDERS, ORDERS_SOURCES)
    assert out.format_version == 4
    assert [d.name for d, _ in out.ListFields()] == ["format_version", "plan"]


def test_a_plan_that_is_not_a_node_is_refused():
    refuses(lambda: encode_plan(ColRef("a"), {}), TypeError, "plan must be a plan node, not ColRef")


def test_sources_that_are_not_a_mapping_are_refused():
    refuses(
        lambda: encode_plan(ORDERS, [("/data/orders.parquet", None)]),
        TypeError,
        "sources must be a mapping of paths to sources, not list",
    )


def test_a_write_root_is_format_5_and_carries_its_target():
    out = encode_plan(Write(ORDERS, WriteTarget("/out/o.parquet", "parquet", "zstd")), ORDERS_SOURCES)
    assert out.format_version == 5
    assert [d.name for d, _ in out.ListFields()] == ["format_version", "plan", "write_target"]
    assert out.write_target.path == "/out/o.parquet"
    assert out.write_target.format == vocab.WFMT_PARQUET
    assert out.write_target.codec == vocab.WCOMP_ZSTD
    assert out.plan == encode_plan(ORDERS, ORDERS_SOURCES).plan


def test_a_write_target_without_a_codec_gets_the_formats_default():
    for fmt, wire_format, wire_codec in (
        ("parquet", vocab.WFMT_PARQUET, vocab.WCOMP_SNAPPY),
        ("csv", vocab.WFMT_CSV, vocab.WCOMP_UNCOMPRESSED),
        ("jsonl", vocab.WFMT_JSONL, vocab.WCOMP_UNCOMPRESSED),
    ):
        out = encode_plan(Write(ORDERS, WriteTarget("/out/o", fmt)), ORDERS_SOURCES)
        assert (out.write_target.format, out.write_target.codec) == (wire_format, wire_codec), fmt


def test_each_explicit_codec_is_its_wire_value():
    for codec, wire in (
        ("snappy", vocab.WCOMP_SNAPPY),
        ("uncompressed", vocab.WCOMP_UNCOMPRESSED),
        ("zstd", vocab.WCOMP_ZSTD),
        ("gzip", vocab.WCOMP_GZIP),
        ("lz4", vocab.WCOMP_LZ4),
    ):
        out = encode_plan(Write(ORDERS, WriteTarget("/out/o.parquet", "parquet", codec)), ORDERS_SOURCES)
        assert out.write_target.codec == wire, codec


def test_a_write_over_a_composed_plan_encodes_the_plan_under_it():
    child = Limit(Filter(ORDERS, Compare("gt", ColRef("qty"), Lit(1))), 3)
    out = encode_plan(Write(child, WriteTarget("/out/o.csv", "csv")), ORDERS_SOURCES)
    assert out.plan == encode_plan(child, ORDERS_SOURCES).plan
    assert out.format_version == 5 and out.HasField("write_target")


def test_a_plan_without_a_write_has_no_write_target():
    out = encode_plan(ORDERS, ORDERS_SOURCES)
    assert out.format_version == 4 and not out.HasField("write_target")


# --- scans ------------------------------------------------------------------


def test_a_parquet_scan_reads_its_whole_schema_as_one_local_file():
    plan = root(ORDERS)
    assert plan.scan.source.parquet.paths == ["/data/orders.parquet"]
    assert plan.scan.source.parquet.fs_is_local
    assert not plan.scan.source.parquet.has_name and plan.scan.source.parquet.mtime_ns == 0
    assert plan.scan.has_schema and list(plan.scan.schema.fields) == list(ORDERS_FIELDS)
    assert list(plan.output_schema.fields) == list(ORDERS_FIELDS)
    assert plan.scan.source_kind == vocab.SOURCE_KIND_COLUMNAR
    assert not plan.scan.has_projection and not plan.scan.has_filter and not plan.scan.has_row_count


def test_a_scan_output_drops_the_files_table_metadata():
    schema = pb.WireSchema(fields=[column("a", "int64")], metadata_keys=["k"], metadata_values=["v"])
    node = Scan("/data/t.parquet", "parquet", (Field("a", "int64"),))
    plan = root(node, {"/data/t.parquet": parquet_source("/data/t.parquet", schema.SerializeToString())})
    assert list(plan.scan.schema.metadata_keys) == ["k"]
    assert list(plan.output_schema.metadata_keys) == []


def test_a_binding_scan_takes_the_binding_whole_and_its_layout():
    binding = pb.WireScanBinding(
        kind_name="komira.csv",
        name="/data/e.csv",
        schema=pb.WireSchema(fields=[column("k", "int64")]),
        fingerprint=7,
        orientation=vocab.SOURCE_KIND_ROW,
        variant_tag=vocab.SOURCE_VARIANT_CSV,
    )
    node = Scan("/data/e.csv", "csv", (Field("k", "int64"),))
    plan = root(node, {"/data/e.csv": binding_source(binding.SerializeToString())})
    assert plan.scan.source.binding == binding
    assert plan.scan.source_kind == vocab.SOURCE_KIND_ROW
    assert list(plan.output_schema.fields) == list(binding.schema.fields)


def binding_scan(fmt, variant, orientation=vocab.SOURCE_KIND_ROW):
    binding = pb.WireScanBinding(
        kind_name="komira.x",
        schema=pb.WireSchema(fields=[column("k", "int64")]),
        orientation=orientation,
        variant_tag=variant,
    )
    node = Scan("/data/x", fmt, (Field("k", "int64"),))
    return node, {"/data/x": binding_source(binding.SerializeToString())}


def test_each_format_reads_its_own_binding_variants():
    row, columnar = vocab.SOURCE_KIND_ROW, vocab.SOURCE_KIND_COLUMNAR
    for fmt, variant, layout in [
        ("csv", "CSV", row),
        ("json", "JSON", row),
        ("ndjson", "JSON", row),
        ("orc", "ORC", columnar),
        ("avro", "AVRO", row),
        ("arrow", "ARROW_UNCOMPRESSED", columnar),
        ("arrow", "ARROW_LZ4_FRAME", columnar),
        ("arrow", "ARROW_ZSTD", columnar),
    ]:
        node, sources = binding_scan(fmt, getattr(vocab, "SOURCE_VARIANT_" + variant), layout)
        scan = root(node, sources).scan
        assert scan.source.binding.variant_tag == getattr(vocab, "SOURCE_VARIANT_" + variant), fmt
        assert scan.source_kind == layout, fmt


def test_a_binding_of_another_format_is_refused():
    node, sources = binding_scan("csv", vocab.SOURCE_VARIANT_JSON)
    refuses(
        lambda: encode_plan(node, sources),
        ValueError,
        "the scan of '/data/x' is csv, and its source is a binding of kind 'komira.x'",
    )
    node, sources = binding_scan("parquet", vocab.SOURCE_VARIANT_CSV)
    refuses(
        lambda: encode_plan(node, sources),
        ValueError,
        "the scan of '/data/x' is parquet, and its source is a binding of kind 'komira.x'",
    )


def test_a_binding_without_a_layout_is_refused():
    node, sources = binding_scan("csv", vocab.SOURCE_VARIANT_CSV, vocab.SOURCE_KIND_UNSET)
    refuses(
        lambda: encode_plan(node, sources),
        UnsupportedOperation,
        "the binding of '/data/x' declares no columnar or row layout (orientation 256), "
        "so its scan cannot be encoded",
    )


def test_a_parquet_source_for_another_format_is_refused():
    node = Scan("/data/orders.parquet", "csv", ORDERS.schema)
    refuses(
        lambda: encode_plan(node, ORDERS_SOURCES),
        ValueError,
        "the scan of '/data/orders.parquet' is csv, and its source is Parquet",
    )


def test_a_source_with_no_payload_is_refused():
    refuses(
        lambda: encode_plan(ORDERS, {"/data/orders.parquet": pb.WireScanSource()}),
        ValueError,
        "the source of '/data/orders.parquet' holds neither a Parquet file nor a binding",
    )


def test_a_scan_without_a_source_is_refused():
    refuses(
        lambda: encode_plan(ORDERS, CUSTOMERS_SOURCES),
        KeyError,
        "no source for the scan of '/data/orders.parquet'; the sources are for: /data/customers.parquet",
    )


def test_a_source_that_is_not_a_wire_source_is_refused():
    refuses(
        lambda: encode_plan(ORDERS, {"/data/orders.parquet": b""}),
        TypeError,
        "the source of '/data/orders.parquet' must be a WireScanSource, not bytes",
    )


def test_declared_columns_must_be_the_files():
    fields = (column("a", "int64"), column("b", "string"))
    sources = {"/data/t.parquet": parquet_source("/data/t.parquet", pb.WireSchema(fields=fields).SerializeToString())}
    for declared, said in [
        ((Field("a", "int32"), Field("b", "string")), "a int32, b string"),
        ((Field("b", "string"), Field("a", "int64")), "b string, a int64"),
        ((Field("a", "int64"),), "a int64"),
    ]:
        refuses(
            lambda: encode_plan(Scan("/data/t.parquet", "parquet", declared), sources),
            ValueError,
            f"the scan of '/data/t.parquet' declares the columns {said}; the file has a int64, b string",
        )


def test_the_source_helpers_check_their_arguments():
    refuses(lambda: parquet_source(b"/p", b""), TypeError, "path must be a str, not bytes")
    refuses(lambda: parquet_source("", b""), ValueError, "path must not be empty")
    refuses(lambda: parquet_source("/p", "schema"), TypeError, "schema must be bytes, not str")
    refuses(lambda: binding_source(None), TypeError, "binding must be bytes, not NoneType")
    assert parquet_source("/p", bytearray()).parquet.paths == ["/p"]
    assert binding_source(memoryview(b"")).WhichOneof("payload") == "binding"


# --- filter, project, sort, limit, top-n, distinct ----------------------------


def test_a_filter_keeps_its_inputs_fields_whole():
    plan = root(Filter(ORDERS, Compare("gt", ColRef("qty"), Lit(0))))
    assert list(plan.output_schema.fields) == list(ORDERS_FIELDS)
    assert plan.filter.predicate.binary_op.left.col_ref.name == "qty"


def test_a_filter_over_an_unknown_column_is_refused_by_the_node():
    e = raised(lambda: Filter(ORDERS, Compare("gt", ColRef("nope"), Lit(0))))
    assert type(e) is KeyError


def test_a_project_aliases_only_what_its_name_changes():
    plan = root(Project(ORDERS, (("o_id", ColRef("o_id")), ("id", ColRef("o_id")), ("one", Lit(1)))))
    kinds = [e.WhichOneof("node") for e in plan.project.exprs]
    assert kinds == ["col_ref", "alias", "alias"]
    assert plan.project.exprs[1].alias.name == "id"
    assert not plan.project.is_cse_introduced


def test_a_projected_column_drops_its_metadata():
    f = root(Project(ORDERS, (("o_id", ColRef("o_id")),))).output_schema.fields[0]
    assert (f.name, f.nullable, list(f.metadata_keys), f.dtype_code) == ("o_id", False, [], vocab._DT_INT64)


def test_sort_and_top_n_carry_one_direction_and_placement_per_key():
    keys = (SortKey("c_id", descending=True), SortKey("s", nulls_first=True), SortKey("o_id"))
    for plan, node in [(Sort(ORDERS, keys), "sort"), (TopN(ORDERS, keys, 0), "topn")]:
        msg = getattr(root(plan), node)
        assert (list(msg.keys), list(msg.descending), list(msg.nulls_first)) == (
            ["c_id", "s", "o_id"],
            [True, False, False],
            [False, True, False],
        )
    assert root(TopN(ORDERS, keys, 0)).topn.n == 0


def test_a_limit_carries_its_count_and_offset():
    plan = root(Limit(ORDERS, 0, 7))
    assert (plan.limit.n, plan.limit.offset) == (0, 7)
    assert list(plan.output_schema.fields) == list(ORDERS_FIELDS)


def test_a_distinct_compares_every_column():
    plan = root(Distinct(ORDERS))
    assert not plan.distinct.has_columns and list(plan.distinct.columns) == []


def test_a_distinct_over_a_subset_is_refused():
    refuses(
        lambda: encode_plan(Distinct(ORDERS, ("c_id", "s")), ORDERS_SOURCES),
        UnsupportedOperation,
        "a Distinct over the columns c_id, s cannot be encoded: the engine's distinct "
        "compares every column; select those columns first",
    )


# --- aggregates ---------------------------------------------------------------


def typed_input(*fields):
    """A scan of `fields` and its sources."""
    return scan_of("/data/typed.parquet", *fields)


def agg_field(func, f, k=None, args=1):
    node, sources = typed_input(f)
    a = Agg(func, (ColRef(f.name),) * args, k)
    out = root(Aggregate(node, (), (("r", a),)), sources).output_schema.fields[0]
    return out


def test_sum_widens_as_the_engine_does():
    for arrow, want in [
        ("bool", "int64"),
        ("int8", "int64"),
        ("int16", "int64"),
        ("int32", "int64"),
        ("int64", "int64"),
        ("uint8", "uint64"),
        ("uint16", "uint64"),
        ("uint32", "uint64"),
        ("uint64", "uint64"),
        ("float32", "float64"),
        ("float64", "float64"),
        ("string", "string"),
    ]:
        f = agg_field("sum", column("x", arrow))
        assert (arrow_name(f), f.nullable) == (want, True), (arrow, f)


def test_a_decimal_sum_is_decimal_38_at_the_inputs_scale():
    f = agg_field("sum", column("x", "decimal128", decimal_precision=12, decimal_scale=2))
    assert (arrow_name(f), f.decimal_precision, f.decimal_scale) == ("decimal128", 38, 2)
    f = agg_field("sum", column("x", "decimal128", decimal_precision=0, decimal_scale=0))
    assert (f.decimal_precision, f.decimal_scale) == (0, 0)


def test_a_sum_drops_the_inputs_zone():
    f = agg_field("sum", column("x", "timestamp_us", tz="UTC"))
    assert (arrow_name(f), f.tz) == ("timestamp_us", "")


def test_a_pick_keeps_the_inputs_type_zone_and_decimal_only():
    for func in ("min", "max", "first", "last", "any_value"):
        f = agg_field(func, column("x", "timestamp_us", False, tz="UTC", metadata_keys=["k"], metadata_values=["v"]))
        assert (arrow_name(f), f.tz, f.nullable, list(f.metadata_keys)) == ("timestamp_us", "UTC", True, []), func
        f = agg_field(func, column("x", "decimal128", decimal_precision=12, decimal_scale=2))
        assert (f.decimal_precision, f.decimal_scale) == (12, 2), func
    f = agg_field("max", column("x", "decimal256", decimal_precision=60, decimal_scale=3))
    assert (f.decimal_precision, f.decimal_scale) == (60, 3)
    f = agg_field("max", column("x", "decimal128", decimal_precision=12, decimal_scale=13))
    assert (f.decimal_precision, f.decimal_scale) == (0, 0)
    f = agg_field("min", column("x", "list", child_names=["item"], child_type_ids=[type_id("int64")], child_nullables=[True]))
    assert (arrow_name(f), list(f.child_names)) == ("list", [])
    f = agg_field("min", column("x", "string", tz="UTC"))
    assert f.tz == ""


def test_the_counts_and_fixed_type_aggregates():
    x = column("x", "bool", False)
    for func, args, want, nullable in [
        ("count", 1, "int64", False),
        ("count", 0, "int64", False),
        ("count_distinct", 1, "int64", False),
        ("regr_count", 2, "int64", False),
        ("count_if", 1, "int64", True),
        ("bool_and", 1, "bool", True),
        ("bool_or", 1, "bool", True),
        ("mean", 1, "float64", True),
        ("median", 1, "float64", True),
        ("var_pop", 1, "float64", True),
        ("stddev_pop", 1, "float64", True),
        ("sem", 1, "float64", True),
        ("kahan_sum", 1, "float64", True),
        ("skewness", 1, "float64", True),
        ("kurtosis_pop", 1, "float64", True),
        ("var_samp", 1, "float64", True),
        ("covar_samp", 2, "float64", True),
        ("regr_avgx", 2, "float64", True),
        ("regr_avgy", 2, "float64", True),
        ("regr_sxx", 2, "float64", True),
        ("regr_sxy", 2, "float64", True),
        ("regr_syy", 2, "float64", True),
        ("regr_intercept", 2, "float64", True),
        ("regr_r2", 2, "float64", True),
    ]:
        f = agg_field(func, x, args=args)
        assert (arrow_name(f), f.nullable) == (want, nullable), func


def test_count_of_nothing_fills_no_slot_and_every_aggregate_is_named():
    plan = root(Aggregate(ORDERS, ("c_id",), (("n", Agg("count")),)))
    e = plan.aggregate.agg_exprs[0]
    assert (e.func, e.has_child0, e.has_child1, e.has_alias_name, e.alias_name) == (
        vocab.AGG_COUNT, False, False, True, "n",
    )
    assert [g.col_ref.name for g in plan.aggregate.group_by] == ["c_id"]
    assert [f.name for f in plan.output_schema.fields] == ["c_id", "n"]
    assert not plan.aggregate.has_estimated_groups


def test_regression_and_covariance_slots_hold_x_first_and_corr_keeps_order():
    y, x = ColRef("price"), ColRef("qty")
    for func, first in [
        ("corr", "price"),
        ("covar_pop", "qty"),
        ("covar_samp", "qty"),
        ("regr_slope", "qty"),
        ("regr_r2", "qty"),
        ("regr_count", "qty"),
    ]:
        e = root(Aggregate(ORDERS, (), (("r", Agg(func, (y, x))),))).aggregate.agg_exprs[0]
        names = (e.child0.col_ref.name, e.child1.col_ref.name)
        assert names == (first, "qty" if first == "price" else "price"), func


def test_quantile_cont_fills_the_value_slot_then_the_fraction_slot_and_is_a_nullable_float64():
    plan = root(Aggregate(ORDERS, (), (("q", Agg("quantile_cont", (ColRef("qty"), Lit(0.25)))),)))
    e = plan.aggregate.agg_exprs[0]
    assert e.func == vocab.AGG_QUANTILE_CONT and e.has_child0 and e.has_child1
    assert not e.has_child2 and not e.has_child3
    assert e.child0.col_ref.name == "qty"
    assert (e.child1.literal.dtype_code, e.child1.literal.float_val) == (vocab._DT_FLOAT64, 0.25)
    f = plan.output_schema.fields[0]
    assert (f.name, arrow_name(f), f.nullable) == ("q", "float64", True)


def test_quantile_cont_refuses_a_fraction_that_is_not_a_float_literal_in_range():
    for bad in (ColRef("price"), Lit(1), Lit(True), Lit("0.5"), Lit(1.5), Lit(-0.1), Lit(float("nan"))):
        node = Aggregate(ORDERS, (), (("q", Agg("quantile_cont", (ColRef("qty"), bad))),))
        refuses(
            lambda: encode_plan(node, ORDERS_SOURCES),
            UnsupportedOperation,
            "the aggregate 'q' is quantile_cont, whose second argument is the "
            f"fraction: a float literal in [0, 1], not {bad!r}",
        )


def test_largest_k_is_the_engines_two_only():
    e = root(Aggregate(ORDERS, (), (("t", Agg("largest_k", (ColRef("price"),), 2)),))).aggregate.agg_exprs[0]
    assert e.func == vocab.AGG_LARGEST_K and e.has_child0 and not e.has_child1
    refuses(
        lambda: encode_plan(Aggregate(ORDERS, (), (("t", Agg("largest_k", (ColRef("price"),), 3)),)), ORDERS_SOURCES),
        UnsupportedOperation,
        "the aggregate 't' keeps the largest 3 values, and the engine's largest_k keeps 2: "
        "use largest_k with k=2",
    )


# --- joins --------------------------------------------------------------------


def join_fields(how, **kw):
    return out_fields(Join(ORDERS, CUSTOMERS, how, **kw), BOTH)


def test_join_outputs_pad_the_null_supplying_side():
    keys = {"left_on": ("c_id",), "right_on": ("c_id",)}
    left = [(f.name, arrow_name(f), f.nullable) for f in ORDERS_FIELDS]
    right = [("c_id_right", "int64", False), ("region", "string", True)]

    def padded(fields):
        return [(n, t, True) for n, t, _ in fields]

    assert join_fields("inner", **keys) == left + right
    assert join_fields("cross") == left + right
    assert join_fields("left", **keys) == left + padded(right)
    assert join_fields("right", **keys) == padded(left) + right
    assert join_fields("full", **keys) == padded(left) + padded(right)
    assert join_fields("semi", **keys) == left
    assert join_fields("anti", **keys) == left


def test_a_join_carries_keys_type_and_the_engines_choice_of_algorithm():
    plan = root(Join(ORDERS, CUSTOMERS, "anti", ("c_id",), ("c_id",)), BOTH)
    j = plan.join
    assert (list(j.left_on), list(j.right_on), j.join_type, j.algo_hint, j.has_residual) == (
        ["c_id"], ["c_id"], vocab.JOIN_ANTI, vocab.JOIN_ALGO_AUTO, False,
    )
    assert j.left.scan.source.parquet.paths == ["/data/orders.parquet"]
    assert j.right.scan.source.parquet.paths == ["/data/customers.parquet"]
    assert list(j.right.output_schema.fields) == list(CUSTOMERS_FIELDS)


def test_a_residual_reads_each_column_from_its_own_side():
    """`c_id` is an int64 on both sides; a CASE yielding the right side's float
    makes its literal 0 a float only when the right side is read."""
    right_fields = (column("c_id", "float64"), column("region", "string"))
    right, right_sources = scan_of("/data/customers.parquet", *right_fields)
    case = When(((Compare("gt", ColRef("price", "left"), Lit(0)), ColRef("c_id", "right")),), Lit(0))
    residual = Compare("gt", case, Lit(1.0))
    plan = root(Join(ORDERS, right, "inner", residual=residual), {**ORDERS_SOURCES, **right_sources})
    j = plan.join
    assert j.has_residual and not j.left_on
    default = j.residual.binary_op.left.when.default_expr.literal
    assert default.dtype_code == vocab._DT_FLOAT64, default
    sides = j.residual.binary_op.left.when.cases[0]
    assert sides.condition.binary_op.left.col_ref.side == vocab.COL_SIDE_LEFT
    assert sides.result.col_ref.side == vocab.COL_SIDE_RIGHT


def test_a_residual_column_its_side_lacks_is_refused_naming_that_side():
    e = raised(lambda: encode_residual(ColRef("price", "right"), ORDERS_FIELDS, CUSTOMERS_FIELDS))
    assert type(e) is KeyError, repr(e)
    assert e.args[0] == "no column named 'price' in this frame; the frame's columns are: c_id, region", e.args[0]


# --- unions -------------------------------------------------------------------


def test_a_union_has_its_first_inputs_fields():
    plan = root(Union((ORDERS, Filter(ORDERS, Compare("gt", ColRef("qty"), Lit(0))))))
    assert len(plan.union_all.children) == 2
    assert list(plan.output_schema.fields) == list(ORDERS_FIELDS)


def test_a_union_of_differently_typed_inputs_is_refused():
    one, s1 = scan_of("/data/one.parquet", column("a", "int64", False))
    for other_field, said in [
        (column("a", "int32", False), "Arrow type id 4 and nullable False"),
        (column("a", "int64", True), "Arrow type id 5 and nullable True"),
    ]:
        other, s2 = scan_of("/data/two.parquet", other_field)
        refuses(
            lambda: encode_plan(Union((one, other)), {**s1, **s2}),
            UnsupportedOperation,
            f"Union: the column 'a' of input 1 has {said}, and the first input's has 5 and False; "
            "the engine's union takes inputs of one schema, so cast the columns to one type first",
        )


# --- windows ------------------------------------------------------------------


def window_plan(*items, child=None):
    return root(Project(child or ORDERS, tuple(items)))


def stack(plan):
    """The partition-by nodes under a project, the lowest first."""
    nodes, p = [], plan.project.child
    while p.WhichOneof("node") == "partition_by":
        nodes.append(p.partition_by)
        p = p.partition_by.child
    return nodes[::-1]


BY_O = (SortKey("o_id"),)


def window_field(win, f):
    node, sources = typed_input(column("o_id", "int64", False), f)
    plan = root(Project(node, (("w", win),)), sources)
    return stack(plan)[0], plan.project.child.output_schema.fields[-1]


def test_the_field_of_each_window_function():
    x = column("x", "int32", False, metadata_keys=["k"], metadata_values=["v"])
    for win, want, nullable in [
        (WindowExpr("row_number", order_by=BY_O), "int64", False),
        (WindowExpr("rank", order_by=BY_O), "int64", False),
        (WindowExpr("dense_rank", order_by=BY_O), "int64", False),
        (WindowExpr("ntile", offset=3, order_by=BY_O), "int64", False),
        (WindowExpr("percent_rank", order_by=BY_O), "float64", False),
        (WindowExpr("cume_dist", order_by=BY_O), "float64", False),
        (WindowExpr("count", "x"), "int64", False),
        (WindowExpr("avg", "x"), "float64", False),
        (WindowExpr("sum", "x"), "int64", False),
        (WindowExpr("min", "x"), "int32", False),
        (WindowExpr("max", "x"), "int32", False),
        (WindowExpr("first_value", "x", order_by=BY_O), "int32", False),
        (WindowExpr("last_value", "x", order_by=BY_O), "int32", False),
        (WindowExpr("lag", "x", 1, order_by=BY_O), "int32", True),
        (WindowExpr("lead", "x", 0, order_by=BY_O), "int32", True),
        (WindowExpr("nth_value", "x", 1, order_by=BY_O), "int32", True),
    ]:
        _, f = window_field(win, x)
        assert (f.name, arrow_name(f), f.nullable) == ("w", want, nullable), win.func
        carries = win.func in ("first_value", "last_value", "lag", "lead", "nth_value")
        assert list(f.metadata_keys) == (["k"] if carries else []), win.func


def test_a_window_sum_is_int64_over_signed_ints_and_float64_otherwise():
    for arrow, want in [("int8", "int64"), ("int64", "int64"), ("uint8", "float64"), ("float32", "float64"), ("decimal128", "float64")]:
        _, f = window_field(WindowExpr("sum", "x"), column("x", arrow))
        assert (arrow_name(f), f.nullable) == (want, False), arrow


def test_a_window_min_keeps_only_the_type_and_nullability():
    _, f = window_field(WindowExpr("min", "x"), column("x", "decimal128", True, decimal_precision=9, decimal_scale=2))
    assert (arrow_name(f), f.nullable, f.decimal_precision) == ("decimal128", True, 0)
    _, f = window_field(WindowExpr("lag", "x", 1, order_by=BY_O), column("x", "decimal128", False, decimal_precision=9, decimal_scale=2))
    assert (f.decimal_precision, f.decimal_scale, f.nullable) == (9, 2, True)


def test_a_window_expression_carries_its_function_column_offset_and_null_default():
    node, _ = window_field(WindowExpr("lag", "x", 2, ("o_id",), (SortKey("o_id", descending=True),)), column("x", "int64"))
    e = node.partition_exprs[0]
    assert (e.func, e.column, e.offset, e.has_default, e.alias_name) == (vocab.PF_LAG, "x", 2, False, "w")
    assert e.default_value == pb.WireScalar(kind=vocab.SCALAR_KIND_DTYPE, time_unit=vocab.SCALAR_TIME_UNIT_MICRO)
    assert (list(node.partition_keys), list(node.order_keys), list(node.descending)) == (["o_id"], ["o_id"], [True])
    node, _ = window_field(WindowExpr("rank", order_by=BY_O), column("x", "int64"))
    assert node.partition_exprs[0].column == ""


def frame_of(win):
    node, _ = window_field(win, column("x", "int64"))
    f = node.partition_exprs[0].frame
    names = (
        vocab.FrameUnits.Name(f.units),
        vocab.FrameBound.Name(f.start_tag),
        f.start_offset,
        vocab.FrameBound.Name(f.end_tag),
        f.end_offset,
    )
    return names


def test_a_window_without_a_frame_gets_the_binders():
    assert frame_of(WindowExpr("sum", "x")) == (
        "FRAME_UNITS_ROWS", "FRAME_BOUND_UNBOUNDED_PRECEDING", 0, "FRAME_BOUND_UNBOUNDED_FOLLOWING", 0,
    )
    assert frame_of(WindowExpr("sum", "x", order_by=BY_O)) == (
        "FRAME_UNITS_RANGE", "FRAME_BOUND_UNBOUNDED_PRECEDING", 0, "FRAME_BOUND_CURRENT_ROW", 0,
    )


def test_a_frame_offset_is_a_count_in_the_bounds_direction():
    win = WindowExpr("sum", "x", order_by=BY_O, frame=Frame("rows", "preceding", "following", 3, 2))
    assert frame_of(win) == ("FRAME_UNITS_ROWS", "FRAME_BOUND_PRECEDING", 3, "FRAME_BOUND_FOLLOWING", 2)


def test_one_partition_by_per_window_in_item_order_and_none_for_plain_items():
    plan = window_plan(
        ("a", WindowExpr("row_number", order_by=BY_O)),
        ("p", ColRef("price")),
        ("b", WindowExpr("count", "s")),
    )
    assert [n.partition_exprs[0].alias_name for n in stack(plan)] == ["a", "b"]
    assert [e.WhichOneof("node") for e in plan.project.exprs] == ["col_ref", "alias", "col_ref"]
    assert [f.name for f in plan.output_schema.fields] == ["a", "p", "b"]
    assert stack(window_plan(("p", ColRef("price")))) == []


def test_a_window_named_like_an_input_column_is_computed_under_a_shadow_name():
    plan = window_plan(("o_id", ColRef("o_id")), ("price", WindowExpr("max", "price")))
    assert stack(plan)[0].partition_exprs[0].alias_name == "_w_shadow_1_price"
    item = plan.project.exprs[1].alias
    assert (item.name, item.child.col_ref.name) == ("price", "_w_shadow_1_price")
    f = plan.output_schema.fields[1]
    assert (f.name, arrow_name(f)) == ("price", "float64")


def test_a_shadow_name_the_input_has_is_refused():
    node, sources = typed_input(column("a", "int64"), column("_w_shadow_0_a", "int64"))
    refuses(
        lambda: encode_plan(Project(node, (("a", WindowExpr("max", "a")),)), sources),
        UnsupportedOperation,
        "the window 'a' would be computed as the column '_w_shadow_0_a', which its input "
        "already has; rename that column first",
    )


def test_a_window_ordered_with_nulls_first_carries_the_placement_of_every_key():
    win = WindowExpr("rank", order_by=(SortKey("o_id"), SortKey("s", nulls_first=True)))
    node = stack(window_plan(("r", win)))[0]
    assert list(node.order_keys) == ["o_id", "s"]
    assert list(node.nulls_first) == [False, True]


def test_a_window_with_the_default_null_placement_leaves_nulls_first_empty():
    win = WindowExpr("rank", order_by=(SortKey("o_id"), SortKey("s", descending=True)))
    node = stack(window_plan(("r", win)))[0]
    assert list(node.descending) == [False, True]
    assert list(node.nulls_first) == []


def test_an_aggregate_window_with_an_offset_is_refused():
    for func in ("sum", "avg", "min", "max"):
        refuses(
            lambda: encode_plan(Project(ORDERS, (("r", WindowExpr(func, "price", 1)),)), ORDERS_SOURCES),
            UnsupportedOperation,
            f"the window 'r' is a {func} with offset 1, and an aggregate window reads the rows "
            "of its frame: give the rows as a Frame",
        )


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("plan_rel: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
