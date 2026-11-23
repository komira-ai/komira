"""The plan encoder's user functions (komira._plan): the UdfRef each kind of
function gets (kind, code, argument and return types, stability, null mode,
read set set, empty or absent), the table that gives one index to each
distinct UdfRef in the order the encoder first meets them, the komira/python
descriptor bytes of each kind, the output schema of a call and of a
MapBatches node, and the refusal of a type the runtime does not carry.

    test_plan_udf.py
"""

import sys

from komira._errors import UnsupportedOperation
from komira._ops import (
    Agg,
    Aggregate,
    Alias,
    Arith,
    ColRef,
    Compare,
    Field,
    Filter,
    Join,
    Limit,
    Lit,
    MapBatches,
    Project,
    Scan,
    UdfCall,
    UdfSpec,
)
from komira._plan import encode_expr, encode_plan, expr_field, parquet_source
from komira._plan._udf import UdfTable, _check_carried
from komira.plan.v1 import plan_pb2 as pb
from komira.plan.v1 import plan_vocabulary_pb2 as vocab

DIGEST = bytes(range(32))
OTHER = bytes(range(1, 33))
# The DType code a field of each carried Arrow type has: the type's own for a
# numeric one, int64 for a timestamp, none for the others.
DTYPES = {n: getattr(vocab, "_DT_" + n.upper()) for n in ("bool", "int8", "int16", "int32", "int64", "float32", "float64")}
DTYPES.update({n: vocab._DT_INT64 for n in ("timestamp_s", "timestamp_ms", "timestamp_us", "timestamp_ns")})

# What a refusal says of a type the runtime does not carry, of a timestamp_ns
# a values function is given, and how it names the item or the field of a
# nested type whose child is the one refused.
NOT_CARRIED = "which the komira/python runtime does not carry"
VALUES_NS = "which a values function cannot take: datetime.datetime holds microseconds"
LIST_ITEM = "{arrow}, whose item has the Arrow type {child}"
STRUCT_FIELD = "{arrow}, whose field '{name}' has the Arrow type {child}"


def type_id(arrow):
    return getattr(vocab, "ARROW_TYPE_" + arrow.upper()) - 1


def column(name, arrow, nullable=True, **slots):
    """A column as libkomira describes it (the field a column reference
    carries is the same one)."""
    slots.setdefault("dict_index_type_id", 4)
    if arrow in DTYPES:
        slots.setdefault("dtype_code", DTYPES[arrow])
    return pb.WireField(name=name, arrow_type_id=type_id(arrow), nullable=nullable, **slots)


def nested(name, arrow, *children, **slots):
    """A list or struct column with one flat level of (name, Arrow type) children."""
    return column(
        name,
        arrow,
        child_names=[n for n, _ in children],
        child_type_ids=[type_id(t) for _, t in children],
        child_nullables=[True] * len(children),
        **slots,
    )


def scan_of(path, *fields):
    node = Scan(
        path,
        "parquet",
        tuple(Field(f.name, vocab.ArrowType.Name(f.arrow_type_id + 1).removeprefix("ARROW_TYPE_").lower()) for f in fields),
    )
    schema = pb.WireSchema(fields=fields)
    return node, {path: parquet_source(path, schema.SerializeToString())}


FIELDS = (
    column("é", "int32"),
    column("z", "float64"),
    column("a", "int64"),
    column("b", "int32"),
    column("c", "float64"),
    column("k", "int64", False, metadata_keys=["unit"], metadata_values=["id"]),
    column("s", "string"),
    column("f", "float32"),
    column("bl", "bool"),
    column("bn", "binary"),
    column("lb", "large_binary"),
    column("ls", "large_string"),
    column("dt", "date32"),
    column("t_ms", "timestamp_ms"),
    column("t_ns", "timestamp_ns"),
    column("t_utc", "timestamp_us", tz="UTC"),
    column("dec", "decimal128", decimal_precision=10, decimal_scale=2),
    nested("li", "list", ("item", "int64")),
    nested("lls", "large_list", ("item", "string")),
    nested("st", "struct", ("a", "int64"), ("b", "string")),
    nested("l_tns", "list", ("item", "timestamp_ns")),
    nested("l_dec", "list", ("item", "decimal128")),
    nested("l_l", "list", ("item", "list")),
    nested("s_l", "struct", ("a", "int64"), ("b", "list")),
    column("u8", "uint8"),
    column("h", "float16"),
    column("mp", "map"),
)
BY_NAME = {f.name: f for f in FIELDS}
# The columns a function that takes values can read, one per carried type.
VALUES_COLUMNS = ("a", "b", "f", "z", "bl", "s", "ls", "bn", "lb", "dt", "t_ms", "t_utc", "dec", "li", "lls", "st")
T, SOURCES = scan_of("/data/t.parquet", *FIELDS)
U, U_SOURCES = scan_of("/data/u.parquet", column("a", "int64"), column("w", "int64"))


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def scalar(**over):
    fields = dict(
        name="m.g",
        kind="scalar",
        form="package",
        entry="m:g",
        code=(),
        return_type="int64",
        stability="immutable",
        null_mode="propagate",
        batch_format="values",
    )
    fields.update(over)
    return UdfSpec(**fields)


def row(**over):
    fields = dict(name="m.r", kind="row", entry="m:r", read_set=("a", "c"))
    fields.update(over)
    return scalar(**fields)


def frame(**over):
    fields = dict(
        name="m.f",
        kind="map_batches_frame",
        entry="m:f",
        return_type=(("x", "int64"), ("y", "float64")),
        read_set=("a",),
    )
    fields.update(over)
    return scalar(**fields)


def project(plan, *items):
    return Project(plan, tuple(items))


def encoded(plan, sources=SOURCES):
    return encode_plan(plan, sources)


def first_ref(plan):
    return encoded(plan).udfs[0]


def call_ref(spec, *args):
    return first_ref(project(T, ("r", UdfCall(spec, args))))


def test_a_scalar_call_is_an_index_and_a_ref():
    spec = scalar(return_type="float64", stability="stable", null_mode="manual")
    env = encoded(project(T, ("r", UdfCall(spec, (ColRef("a"), Arith("add", ColRef("c"), Lit(1.5)))))))
    assert len(env.udfs) == 1
    out = env.plan.project.exprs[0]
    assert out.alias.name == "r"
    apply = out.alias.child.udf_apply
    assert apply.udf_index == 0
    assert [a.col_ref.name for a in apply.args[:1]] == ["a"]
    assert apply.args[1].HasField("binary_op")
    ref = env.udfs[0]
    assert ref.kind == pb.SCALAR
    assert ref.stability == pb.UDF_STABILITY_STABLE
    assert ref.null_mode == pb.UDF_NULL_MANUAL
    assert not ref.HasField("read_set")
    assert ref.return_type == column("out", "float64")
    assert list(ref.arg_types) == [column("a", "int64"), column("expr", "float64")]
    assert ref.code.runtime == "komira/python"
    assert ref.code.form == pb.PACKAGE
    assert ref.code.entry == "m:g"
    assert list(ref.code.code) == []
    assert ref.code.descriptor_version == 1


def test_a_call_column_has_the_return_type_under_the_alias_name():
    for dtype in ("int32", "int64", "float64"):
        env = encoded(project(T, ("r", UdfCall(scalar(return_type=dtype), (ColRef("a"),)))))
        assert list(env.plan.output_schema.fields) == [column("r", dtype)], dtype
    call = UdfCall(scalar(), (ColRef("a"),))
    assert expr_field(call, FIELDS) == column("out", "int64")
    assert expr_field(Alias(call, "n"), FIELDS) == column("n", "int64")
    both = project(T, ("a", ColRef("a")), ("r", call))
    assert list(encoded(both).plan.output_schema.fields) == [column("a", "int64"), column("r", "int64")]


def test_each_kind_sets_its_kind_and_a_read_set_only_for_row_and_frame():
    ref = call_ref(scalar(), ColRef("a"))
    assert ref.kind == pb.SCALAR and not ref.HasField("read_set")
    ref = call_ref(scalar(kind="map_batches_column"), ColRef("a"))
    assert ref.kind == pb.MAP_BATCHES_COLUMN and not ref.HasField("read_set")
    ref = call_ref(row(), ColRef("a"), ColRef("c"))
    assert ref.kind == pb.ROW
    assert ref.HasField("read_set") and list(ref.read_set.columns) == ["a", "c"]
    assert list(ref.arg_types) == [column("a", "int64"), column("c", "float64")]
    ref = first_ref(MapBatches(T, frame(read_set=("a", "c"))))
    assert ref.kind == pb.MAP_BATCHES_FRAME
    assert ref.HasField("read_set") and list(ref.read_set.columns) == ["a", "c"]
    assert list(ref.arg_types) == [column("a", "int64"), column("c", "float64")]


def test_an_empty_read_set_is_set_and_an_absent_one_is_not():
    empty = call_ref(row(read_set=()))
    assert empty.HasField("read_set") and list(empty.read_set.columns) == []
    assert list(empty.arg_types) == []
    assert empty.SerializeToString(deterministic=True).endswith(b"\x9a\x01\x00")
    frame_ref = first_ref(MapBatches(T, frame(read_set=())))
    assert frame_ref.HasField("read_set") and list(frame_ref.read_set.columns) == []
    assert list(frame_ref.arg_types) == []
    absent = call_ref(scalar(), ColRef("a"))
    assert not absent.HasField("read_set")
    assert b"\x9a\x01" not in absent.SerializeToString(deterministic=True)


def test_stability_and_null_mode_are_carried():
    stabilities = {
        "immutable": pb.UDF_STABILITY_IMMUTABLE,
        "stable": pb.UDF_STABILITY_STABLE,
        "volatile": pb.UDF_STABILITY_VOLATILE,
    }
    modes = {"manual": pb.UDF_NULL_MANUAL, "propagate": pb.UDF_NULL_PROPAGATE}
    for name, value in stabilities.items():
        assert call_ref(scalar(stability=name), ColRef("a")).stability == value
    for name, value in modes.items():
        assert call_ref(scalar(null_mode=name), ColRef("a")).null_mode == value


def test_a_package_has_no_code_digest_and_a_bundle_has_one():
    package = call_ref(scalar(), ColRef("a")).code
    assert package.form == pb.PACKAGE and list(package.code) == []
    bundle = call_ref(scalar(form="bundle", code=(("bundle", DIGEST),)), ColRef("a")).code
    assert bundle.form == pb.BUNDLE
    assert bundle.entry == "m:g"
    assert [(d.role, d.sha256) for d in bundle.code] == [("bundle", DIGEST)]
    assert call_ref(scalar(form="bundle", code=(("bundle", OTHER),)), ColRef("a")).code != bundle


def test_one_function_called_twice_is_one_ref():
    spec = scalar()
    plan = project(T, ("p", UdfCall(spec, (ColRef("a"),))), ("q", UdfCall(spec, (ColRef("a"),))))
    env = encoded(plan)
    assert len(env.udfs) == 1
    indexes = [e.alias.child.udf_apply.udf_index for e in env.plan.project.exprs]
    assert indexes == [0, 0]


def test_two_functions_are_two_refs_in_the_order_first_met():
    first, second = scalar(entry="m:one", name="m.one"), scalar(entry="m:two", name="m.two")
    plan = project(
        T,
        ("p", UdfCall(second, (ColRef("a"),))),
        ("q", UdfCall(first, (ColRef("a"),))),
        ("r", UdfCall(second, (ColRef("a"),))),
    )
    env = encoded(plan)
    assert [u.code.entry for u in env.udfs] == ["m:two", "m:one"]
    indexes = [e.alias.child.udf_apply.udf_index for e in env.plan.project.exprs]
    assert indexes == [0, 1, 0]


def test_a_function_called_on_other_argument_types_is_another_ref():
    spec = scalar()
    plan = project(T, ("p", UdfCall(spec, (ColRef("a"),))), ("q", UdfCall(spec, (ColRef("b"),))))
    env = encoded(plan)
    assert len(env.udfs) == 2
    assert [u.arg_types[0].arrow_type_id for u in env.udfs] == [type_id("int64"), type_id("int32")]
    assert [e.alias.child.udf_apply.udf_index for e in env.plan.project.exprs] == [0, 1]


def test_an_outer_call_comes_before_the_calls_in_its_arguments():
    inner, outer = scalar(name="m.in", entry="m:in", return_type="float64"), scalar(name="m.out", entry="m:out")
    call = UdfCall(outer, (UdfCall(inner, (ColRef("a"),)),))
    env = encoded(project(T, ("r", call)))
    assert [u.code.entry for u in env.udfs] == ["m:out", "m:in"]
    apply = env.plan.project.exprs[0].alias.child.udf_apply
    assert apply.udf_index == 0
    assert apply.args[0].udf_apply.udf_index == 1
    assert list(env.udfs[0].arg_types) == [column("out", "float64")]
    assert list(env.udfs[1].arg_types) == [column("a", "int64")]


def test_refs_are_met_from_the_leaves_to_the_root():
    lower, upper = frame(name="m.low", entry="m:low"), scalar(name="m.up", entry="m:up")
    plan = project(MapBatches(T, lower), ("r", UdfCall(upper, (ColRef("x"),))))
    env = encoded(plan)
    assert [u.code.entry for u in env.udfs] == ["m:low", "m:up"]
    assert env.plan.project.exprs[0].alias.child.udf_apply.udf_index == 1
    assert env.plan.project.child.map_batches.udf_index == 0


def test_arguments_take_the_fields_their_expressions_derive():
    ref = call_ref(
        scalar(null_mode="manual"),
        ColRef("k"),
        ColRef("b"),
        Arith("add", ColRef("b"), Lit(1)),
        Arith("mul", ColRef("a"), ColRef("c")),
        Lit(7),
    )
    assert list(ref.arg_types) == [
        column("k", "int64", False),
        column("b", "int32"),
        column("expr", "int32"),
        column("expr", "float64"),
        expr_field(Lit(7), FIELDS),
    ]
    assert list(ref.arg_types[0].metadata_keys) == []


def test_a_call_in_a_filter_an_aggregate_and_a_join_residual_adds_its_ref():
    spec = scalar()
    call = UdfCall(spec, (ColRef("a"),))
    env = encoded(Filter(T, Compare("gt", call, Lit(1))))
    assert len(env.udfs) == 1
    pred = env.plan.filter.predicate.binary_op.left
    assert pred.udf_apply.udf_index == 0
    env = encoded(Aggregate(T, (), (("n", Agg("sum", (call,))),)))
    assert len(env.udfs) == 1
    assert env.plan.aggregate.agg_exprs[0].child0.udf_apply.udf_index == 0
    sided = UdfCall(spec, (ColRef("w", "right"),))
    join = Join(T, U, "inner", ("a",), ("a",), Compare("gt", sided, Lit(1)))
    env = encoded(join, {**SOURCES, **U_SOURCES})
    assert len(env.udfs) == 1
    assert list(env.udfs[0].arg_types) == [column("w", "int64")]
    assert env.plan.join.residual.binary_op.left.udf_apply.udf_index == 0


def test_a_plan_with_no_call_has_no_udfs():
    assert len(encoded(Limit(T, 1)).udfs) == 0


def test_encode_expr_needs_a_table_for_a_call():
    call = UdfCall(scalar(), (ColRef("a"),))
    refuses(
        lambda: encode_expr(call, FIELDS),
        UnsupportedOperation,
        "the call of m.g cannot be encoded without a table for its UdfRef; pass udfs",
    )
    table = UdfTable()
    other = UdfCall(scalar(entry="m:o"), (ColRef("a"),))
    assert encode_expr(call, FIELDS, table).udf_apply.udf_index == 0
    assert encode_expr(other, FIELDS, table).udf_apply.udf_index == 1
    assert encode_expr(call, FIELDS, table).udf_apply.udf_index == 0
    assert [u.code.entry for u in table.refs] == ["m:g", "m:o"]
    assert encode_expr(ColRef("a"), FIELDS).col_ref.name == "a"


def test_the_table_identifies_a_ref_by_its_bytes():
    table = UdfTable()
    one = pb.UdfRef(kind=pb.SCALAR)
    same = pb.UdfRef(kind=pb.SCALAR)
    other = pb.UdfRef(kind=pb.ROW)
    other.read_set.SetInParent()
    assert table.add(one) == 0
    assert table.add(same) == 0
    assert table.add(other) == 1
    assert table.add(pb.UdfRef(kind=pb.ROW)) == 2
    assert len(table.refs) == 3


FA = b"\x0a\x0b\x0a\x01a\x10\x05\x18\x05\x20\x01\x40\x04"
FC = b"\x0a\x0b\x0a\x01c\x10\x0c\x18\x0c\x20\x01\x40\x04"
FZ = b"\x0a\x0b\x0a\x01z\x10\x0c\x18\x0c\x20\x01\x40\x04"
FE = b"\x0a\x0c\x0a\x02\xc3\xa9\x10\x04\x18\x04\x20\x01\x40\x04"


def test_the_descriptor_of_a_scalar_names_entry_shape_and_format():
    ref = call_ref(scalar(), ColRef("a"))
    assert ref.code.descriptor == b"\x0a\x03m:g\x10\x01\x38\x01"


def test_the_descriptor_of_a_column_batch_function():
    ref = call_ref(scalar(kind="map_batches_column", entry="m:c", batch_format="arrow"), ColRef("a"))
    assert ref.code.descriptor == b"\x0a\x03m:c\x10\x04\x38\x02"


def test_the_descriptor_of_a_row_function_records_its_columns():
    ref = call_ref(row(), ColRef("a"), ColRef("c"))
    assert ref.code.descriptor == b"\x0a\x03m:r\x10\x02\x32\x1a" + FA + FC + b"\x38\x01"


def test_the_descriptor_of_a_row_function_with_no_columns_records_an_empty_set():
    ref = call_ref(row(read_set=()))
    assert ref.code.descriptor == b"\x0a\x03m:r\x10\x02\x32\x00\x38\x01"


def test_the_descriptor_of_a_frame_function():
    ref = first_ref(MapBatches(T, frame(batch_format="arrow")))
    assert ref.code.descriptor == b"\x0a\x03m:f\x10\x08\x32\x0d" + FA + b"\x38\x02"
    empty = first_ref(MapBatches(T, frame(read_set=())))
    assert empty.code.descriptor == b"\x0a\x03m:f\x10\x08\x32\x00\x38\x01"


def test_a_long_entry_is_length_prefixed_by_a_two_byte_varint():
    entry = "m:" + "x" * 200
    ref = call_ref(scalar(entry=entry), ColRef("a"))
    assert ref.code.descriptor == b"\x0a\xca\x01m:" + b"x" * 200 + b"\x10\x01\x38\x01"
    assert ref.code.entry == entry


def test_the_read_set_and_the_recorded_fields_ascend_by_utf8_bytes():
    spec = row(read_set=("a", "z", "é"))
    ref = call_ref(spec, ColRef("a"), ColRef("z"), ColRef("é"))
    assert list(ref.read_set.columns) == ["a", "z", "é"]
    assert [f.name for f in ref.arg_types] == ["a", "z", "é"]
    assert ref.code.descriptor == b"\x0a\x03m:r\x10\x02\x32\x28" + FA + FZ + FE + b"\x38\x01"
    framed = first_ref(MapBatches(T, frame(read_set=("a", "z", "é"))))
    assert list(framed.read_set.columns) == ["a", "z", "é"]
    assert [f.name for f in framed.arg_types] == ["a", "z", "é"]
    assert framed.code.descriptor == b"\x0a\x03m:f\x10\x08\x32\x28" + FA + FZ + FE + b"\x38\x01"


def test_the_descriptor_records_a_not_null_column_without_a_nullable_bit():
    ref = first_ref(MapBatches(T, frame(read_set=("k",))))
    fk = b"\x0a\x01k\x10\x05\x18\x05\x40\x04"
    assert ref.code.descriptor == b"\x0a\x03m:f\x10\x08\x32\x0b\x0a\x09" + fk + b"\x38\x01"
    assert ref.arg_types[0] == column("k", "int64", False)


def test_a_frame_node_outputs_the_columns_of_its_return_type():
    env = encoded(MapBatches(T, frame(read_set=("a", "c"))))
    node = env.plan.map_batches
    assert node.udf_index == 0
    assert len(node.group_by) == 0
    assert node.child.scan.has_schema
    assert list(env.plan.output_schema.fields) == [column("x", "int64"), column("y", "float64")]
    ref = env.udfs[0]
    want = column("out", "struct", True, dtype_code=0)
    want.children.extend([column("x", "int64"), column("y", "float64")])
    assert ref.return_type == want
    assert list(ref.return_type.child_names) == []


def test_a_frame_over_a_projection_reads_the_projections_fields():
    plan = MapBatches(project(T, ("m", Arith("add", ColRef("b"), Lit(1))), ("a", ColRef("a"))), frame(read_set=("a", "m")))
    ref = first_ref(plan)
    assert list(ref.read_set.columns) == ["a", "m"]
    assert list(ref.arg_types) == [column("a", "int64"), column("m", "int32")]
    over = MapBatches(plan, frame(name="m.g2", entry="m:g2", read_set=("x",)))
    env = encoded(over)
    assert [u.code.entry for u in env.udfs] == ["m:f", "m:g2"]
    assert env.udfs[1].arg_types[0] == column("x", "int64")
    assert env.plan.map_batches.udf_index == 1
    assert env.plan.map_batches.child.map_batches.udf_index == 0


def test_one_frame_function_over_the_same_column_type_is_one_ref():
    twin = frame(read_set=("a",), return_type=(("a", "int64"),))
    env = encoded(MapBatches(MapBatches(T, twin), twin))
    assert len(env.udfs) == 1
    assert env.plan.map_batches.udf_index == 0
    assert env.plan.map_batches.child.map_batches.udf_index == 0


def message(fn, what, arrow, tail=NOT_CARRIED):
    return f"{fn}: the {what} has the Arrow type {arrow}, {tail}"


def shape(f):
    """What a field says of its type: the slots a runtime reads."""
    return (
        f.name,
        f.arrow_type_id,
        f.nullable,
        f.decimal_precision,
        f.decimal_scale,
        f.tz,
        list(f.child_names),
        list(f.child_type_ids),
        list(f.child_nullables),
        len(f.children),
    )


def test_an_argument_of_a_type_the_runtime_does_not_carry_is_refused():
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("a"), ColRef("u8")))))),
        UnsupportedOperation,
        message("m.g", "argument 1", "uint8"),
    )
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(kind="map_batches_column"), (ColRef("h"),))))),
        UnsupportedOperation,
        message("m.g", "argument 0", "float16"),
    )
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("mp"),))))),
        UnsupportedOperation,
        message("m.g", "argument 0", "map"),
    )
    refuses(
        lambda: expr_field(UdfCall(scalar(), (ColRef("h"),)), FIELDS),
        UnsupportedOperation,
        message("m.g", "argument 0", "float16"),
    )


def test_a_list_or_struct_argument_with_a_child_the_runtime_does_not_carry_is_refused():
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("l_dec"),))))),
        UnsupportedOperation,
        message("m.g", "argument 0", LIST_ITEM.format(arrow="list", child="decimal128")),
    )
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("a"), ColRef("l_l")))))),
        UnsupportedOperation,
        message("m.g", "argument 1", LIST_ITEM.format(arrow="list", child="list")),
    )
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("s_l"),))))),
        UnsupportedOperation,
        message("m.g", "argument 0", STRUCT_FIELD.format(arrow="struct", name="b", child="list")),
    )


def carried(f, spec=None):
    """What `_check_carried` says of the one argument `f` of `spec`."""
    return _check_carried(spec or scalar(), [f])


def refused_argument(f, arrow):
    refuses(lambda: carried(f), UnsupportedOperation, message("m.g", "argument 0", arrow))


def test_a_decimal_column_with_a_precision_or_scale_out_of_range_is_refused():
    for precision, scale in ((0, 0), (0, 2), (39, 0), (100, 2), (5, 6), (1, 2), (38, 39)):
        refused_argument(column("d", "decimal128", decimal_precision=precision, decimal_scale=scale), "decimal128")
    refuses(
        lambda: carried(column("d", "decimal128", decimal_precision=0, decimal_scale=0), row(read_set=("d",))),
        UnsupportedOperation,
        message("m.r", "column 'd'", "decimal128"),
    )


def test_a_decimal_column_with_a_precision_and_scale_in_range_is_carried():
    for precision, scale in ((1, 0), (1, 1), (10, 2), (38, 0), (38, 38)):
        assert carried(column("d", "decimal128", decimal_precision=precision, decimal_scale=scale)) is None


def test_a_list_column_with_other_than_one_item_is_refused():
    refused_argument(nested("l2", "list", ("item", "int64"), ("item", "string")), "list")
    refused_argument(nested("l2", "large_list", ("item", "int64"), ("item", "string")), "large_list")
    refused_argument(nested("l0", "list"), "list")
    refused_argument(nested("l0", "large_list"), "large_list")
    assert carried(nested("l1", "list", ("item", "int64"))) is None
    assert carried(nested("l1", "large_list", ("item", "string"))) is None


def test_a_struct_column_with_no_child_is_refused():
    refused_argument(nested("s0", "struct"), "struct")
    refuses(
        lambda: carried(nested("s0", "struct"), frame(read_set=("s0",))),
        UnsupportedOperation,
        message("m.f", "column 's0'", "struct"),
    )
    assert carried(nested("s1", "struct", ("a", "int64"))) is None


def test_a_struct_with_children_in_field_16_takes_flat_fields_and_refuses_a_list_field():
    flat = column("st", "struct", children=[column("a", "int64"), column("b", "string")])
    assert carried(flat) is None
    listed = column("st", "struct", children=[column("a", "int64"), nested("b", "list", ("item", "int64"))])
    refused_argument(listed, STRUCT_FIELD.format(arrow="struct", name="b", child="list"))


def test_a_read_set_column_of_a_type_the_runtime_does_not_carry_is_refused():
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(row(read_set=("a", "u8")), (ColRef("a"), ColRef("u8")))))),
        UnsupportedOperation,
        message("m.r", "column 'u8'", "uint8"),
    )
    refuses(
        lambda: encoded(MapBatches(T, frame(read_set=("a", "h")))),
        UnsupportedOperation,
        message("m.f", "column 'h'", "float16"),
    )
    refuses(
        lambda: encoded(MapBatches(T, frame(read_set=("l_dec",)))),
        UnsupportedOperation,
        message("m.f", "column 'l_dec'", LIST_ITEM.format(arrow="list", child="decimal128")),
    )


def test_a_nested_call_with_an_unsupported_argument_is_refused_by_the_outer_call():
    inner = UdfCall(scalar(name="m.in", entry="m:in", return_type="int32"), (ColRef("u8"),))
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (inner,))))),
        UnsupportedOperation,
        message("m.in", "argument 0", "uint8"),
    )


def test_a_timestamp_ns_argument_of_a_values_function_is_refused():
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("a"), ColRef("t_ns")))))),
        UnsupportedOperation,
        message("m.g", "argument 1", "timestamp_ns", VALUES_NS),
    )
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(row(read_set=("a", "t_ns")), (ColRef("a"), ColRef("t_ns")))))),
        UnsupportedOperation,
        message("m.r", "column 't_ns'", "timestamp_ns", VALUES_NS),
    )
    refuses(
        lambda: encoded(MapBatches(T, frame(read_set=("t_ns",)))),
        UnsupportedOperation,
        message("m.f", "column 't_ns'", "timestamp_ns", VALUES_NS),
    )
    refuses(
        lambda: expr_field(UdfCall(scalar(), (ColRef("t_ns"),)), FIELDS),
        UnsupportedOperation,
        message("m.g", "argument 0", "timestamp_ns", VALUES_NS),
    )


def test_a_list_of_timestamp_ns_argument_of_a_values_function_is_refused():
    refuses(
        lambda: encoded(project(T, ("r", UdfCall(scalar(), (ColRef("l_tns"),))))),
        UnsupportedOperation,
        message("m.g", "argument 0", LIST_ITEM.format(arrow="list", child="timestamp_ns"), VALUES_NS),
    )


def test_a_timestamp_ns_argument_is_carried_by_a_function_that_takes_arrow_batches():
    spec = scalar(kind="map_batches_column", batch_format="arrow")
    ref = call_ref(spec, ColRef("t_ns"))
    assert list(ref.arg_types) == [column("t_ns", "timestamp_ns")]
    ref = call_ref(spec, ColRef("l_tns"))
    assert list(ref.arg_types) == [nested("l_tns", "list", ("item", "timestamp_ns"))]
    ref = first_ref(MapBatches(T, frame(read_set=("a", "t_ns"), batch_format="arrow")))
    assert list(ref.arg_types) == [column("a", "int64"), column("t_ns", "timestamp_ns")]


def test_a_timestamp_ns_result_of_a_values_function_is_carried():
    ref = call_ref(scalar(return_type="timestamp[ns]"), ColRef("a"))
    assert ref.return_type == column("out", "timestamp_ns")
    ref = call_ref(scalar(return_type="timestamp[ns, tz=UTC]"), ColRef("a"))
    assert ref.return_type == column("out", "timestamp_ns", tz="UTC")


def test_an_argument_of_each_carried_type_is_carried_with_its_parameters():
    for name in VALUES_COLUMNS:
        ref = call_ref(scalar(), ColRef(name))
        assert [shape(f) for f in ref.arg_types] == [shape(BY_NAME[name])], name
        assert ref.arg_types[0].arrow_type_id == BY_NAME[name].arrow_type_id, name
    ref = call_ref(scalar(), ColRef("s"))
    assert list(ref.arg_types) == [column("s", "string")]
    ref = call_ref(scalar(), ColRef("dec"))
    assert list(ref.arg_types) == [column("dec", "decimal128", decimal_precision=10, decimal_scale=2)]
    ref = call_ref(scalar(), ColRef("t_utc"))
    assert list(ref.arg_types) == [column("t_utc", "timestamp_us", tz="UTC")]
    ref = call_ref(scalar(), ColRef("li"))
    assert list(ref.arg_types) == [nested("li", "list", ("item", "int64"))]
    assert list(ref.arg_types[0].child_names) == ["item"]
    ref = call_ref(scalar(), ColRef("lls"))
    assert list(ref.arg_types) == [nested("lls", "large_list", ("item", "string"))]
    ref = call_ref(scalar(), ColRef("st"))
    assert list(ref.arg_types) == [nested("st", "struct", ("a", "int64"), ("b", "string"))]
    ref = call_ref(scalar(), Compare("gt", ColRef("a"), Lit(1)))
    assert [f.arrow_type_id for f in ref.arg_types] == [type_id("bool")]


def test_a_call_takes_any_number_of_arguments_of_any_carried_types():
    names = ("s", "dec", "t_utc", "li", "st", "bl", "a")
    ref = call_ref(scalar(return_type="string"), *[ColRef(n) for n in names])
    assert [f.name for f in ref.arg_types] == list(names)
    assert [shape(f) for f in ref.arg_types] == [shape(BY_NAME[n]) for n in names]
    ref = call_ref(scalar(return_type="string"), *[ColRef(n) for n in VALUES_COLUMNS])
    assert [f.name for f in ref.arg_types] == list(VALUES_COLUMNS)


# (a return type, the Arrow type of its field, the slots the field sets)
RETURN_FIELDS = [
    ("bool", "bool", {}),
    ("int8", "int8", {}),
    ("int16", "int16", {}),
    ("int32", "int32", {}),
    ("int64", "int64", {}),
    ("float32", "float32", {}),
    ("float64", "float64", {}),
    ("string", "string", {}),
    ("large_string", "large_string", {}),
    ("binary", "binary", {}),
    ("large_binary", "large_binary", {}),
    ("date32[day]", "date32", {}),
    ("timestamp[s]", "timestamp_s", {}),
    ("timestamp[ms]", "timestamp_ms", {}),
    ("timestamp[us]", "timestamp_us", {}),
    ("timestamp[ns]", "timestamp_ns", {}),
    ("timestamp[s, tz=UTC]", "timestamp_s", {"tz": "UTC"}),
    ("timestamp[us, tz=Europe/Paris]", "timestamp_us", {"tz": "Europe/Paris"}),
    ("decimal128(1, 0)", "decimal128", {"decimal_precision": 1, "decimal_scale": 0}),
    ("decimal128(38, 38)", "decimal128", {"decimal_precision": 38, "decimal_scale": 38}),
]
RETURN_NESTED = [
    ("list<item: int64>", "list", (("item", "int64"),)),
    ("large_list<item: string>", "large_list", (("item", "string"),)),
    ("list<item: timestamp[ns]>", "list", (("item", "timestamp_ns"),)),
    ("list<item: date32[day]>", "list", (("item", "date32"),)),
    ("struct<a: int64>", "struct", (("a", "int64"),)),
    ("struct<a: int64, b: string, c: timestamp[us]>", "struct", (("a", "int64"), ("b", "string"), ("c", "timestamp_us"))),
]


def test_a_return_type_of_each_carried_type_is_the_nullable_field_out():
    for dtype, arrow, slots in RETURN_FIELDS:
        ref = call_ref(scalar(return_type=dtype), ColRef("a"))
        assert ref.return_type == column("out", arrow, **slots), dtype
        env = encoded(project(T, ("r", UdfCall(scalar(return_type=dtype), (ColRef("a"),)))))
        assert list(env.plan.output_schema.fields) == [column("r", arrow, **slots)], dtype


def test_a_list_or_struct_return_type_carries_its_flat_children_in_the_child_lists():
    for dtype, arrow, children in RETURN_NESTED:
        ref = call_ref(scalar(return_type=dtype), ColRef("a"))
        assert ref.return_type == nested("out", arrow, *children), dtype
        assert len(ref.return_type.children) == 0, dtype
        env = encoded(project(T, ("r", UdfCall(scalar(return_type=dtype), (ColRef("a"),)))))
        assert list(env.plan.output_schema.fields) == [nested("r", arrow, *children)], dtype
    ref = call_ref(scalar(return_type="list<item: int64>"), ColRef("a"))
    assert list(ref.return_type.child_names) == ["item"]
    assert list(ref.return_type.child_type_ids) == [type_id("int64")]
    assert list(ref.return_type.child_nullables) == [True]


def test_the_expression_field_of_a_call_has_the_return_types_parameters():
    call = UdfCall(scalar(return_type="decimal128(12, 4)"), (ColRef("s"),))
    assert expr_field(call, FIELDS) == column("out", "decimal128", decimal_precision=12, decimal_scale=4)
    call = UdfCall(scalar(return_type="struct<a: int64, b: string>"), (ColRef("li"),))
    assert expr_field(Alias(call, "n"), FIELDS) == nested("n", "struct", ("a", "int64"), ("b", "string"))
    assert expr_field(UdfCall(scalar(return_type="string"), (ColRef("s"),)), FIELDS) == column("out", "string")


def test_a_row_function_records_the_fields_of_its_string_decimal_list_and_struct_columns():
    names = ("dec", "li", "s", "st")
    ref = call_ref(row(read_set=names), *[ColRef(n) for n in names])
    assert list(ref.read_set.columns) == list(names)
    assert [shape(f) for f in ref.arg_types] == [shape(BY_NAME[n]) for n in names]
    recorded = pb.RecordedFields(fields=ref.arg_types)
    assert recorded.SerializeToString(deterministic=True) in ref.code.descriptor
    assert list(ref.arg_types[1].child_names) == ["item"]


def test_a_frame_reads_and_returns_string_decimal_list_and_struct_columns():
    schema = (
        ("s", "string"),
        ("d", "decimal128(10, 2)"),
        ("l", "list<item: int64>"),
        ("t", "timestamp[us, tz=UTC]"),
        ("st", "struct<a: int64, b: string>"),
    )
    spec = frame(read_set=("dec", "li", "st"), return_type=schema, batch_format="arrow")
    env = encoded(MapBatches(T, spec))
    ref = env.udfs[0]
    assert [shape(f) for f in ref.arg_types] == [shape(BY_NAME[n]) for n in ("dec", "li", "st")]
    want = [
        column("s", "string"),
        column("d", "decimal128", decimal_precision=10, decimal_scale=2),
        nested("l", "list", ("item", "int64")),
        column("t", "timestamp_us", tz="UTC"),
        nested("st", "struct", ("a", "int64"), ("b", "string")),
    ]
    assert list(ref.return_type.children) == want
    assert list(ref.return_type.child_names) == []
    assert list(env.plan.output_schema.fields) == want
    assert pb.RecordedFields(fields=ref.arg_types).SerializeToString(deterministic=True) in ref.code.descriptor


def test_a_frame_over_a_list_column_outputs_a_list_column_for_the_next_function():
    lower = frame(name="m.low", entry="m:low", read_set=("li",), return_type=(("l", "list<item: int64>"),))
    upper = frame(name="m.up", entry="m:up", read_set=("l",), return_type=(("n", "int64"),))
    env = encoded(MapBatches(MapBatches(T, lower), upper))
    assert [u.code.entry for u in env.udfs] == ["m:low", "m:up"]
    assert list(env.udfs[1].arg_types) == [nested("l", "list", ("item", "int64"))]
    assert list(env.plan.output_schema.fields) == [column("n", "int64")]


def test_a_call_over_a_missing_column_is_refused_before_it_is_encoded():
    e = raised(lambda: encode_expr(UdfCall(scalar(), (ColRef("nope"),)), FIELDS, UdfTable()))
    assert type(e) is KeyError
    assert e.args[0].startswith("no column named 'nope' in this frame")


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("plan_udf: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
