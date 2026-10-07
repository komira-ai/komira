# =============================================================================
# komira_parquet/tests/test_flat_read_types_are_never_nested.mojo
#
# A nested Arrow column cannot come out of this package's flat read path. Two
# facts carry that, and each is asserted below:
#
#   (1) the parquet TYPE MAP never returns a nested (child-carrying) Arrow
#       type, swept over its whole input domain (`test_*_never_returns_*`,
#       `test_group_node_maps_to_string_not_to_a_nested_type`);
#   (2) `copy_column_ref`, the column copier of the read path, RAISES on a
#       child-carrying column (`test_copy_column_ref_raises_on_a_nested_column`).
#
# A consumer that cannot take a nested column relies on both, so an edit that
# falsifies one turns `komira_parquet` red instead of turning a slow answer
# into a hard failure downstream. The nested reconstruction helpers
# (`nested.mojo`) are not wired into the flat read path; the day they are,
# (1) and (2) go red here, which is the point of the file.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.list_array import ListArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.varlen_width_guard import carries_children

from komira_parquet_api.types import ParquetType
from komira_parquet_api.metadata import SchemaElement
from komira_parquet.decode_helpers import (
    _parquet_type_to_arrow_type_opt,
    _schema_element_to_arrow_type,
    schema_element_arrow_type,
)


# -----------------------------------------------------------------------------
# Fact (1) — the parquet type map, swept over its whole input domain.
#
# The map is three pure functions. Sweeping RAW numeric values rather than the
# eight named `ParquetType` constants is deliberate: a new physical type added
# to the thrift enum lands as an unnamed value and must still not map to a
# nested Arrow type. Same for `converted_type`, which is a raw Thrift int.
# -----------------------------------------------------------------------------

comptime _PTYPE_SWEEP_MAX = 64
comptime _CONVERTED_SWEEP_MAX = 64


def test_parquet_type_map_never_returns_a_nested_type() raises:
    """`_parquet_type_to_arrow_type_opt` over every physical type value.

    FACT (1). If this goes red, a flat read can produce a nested column.
    """
    for raw in range(_PTYPE_SWEEP_MAX):
        var at = _parquet_type_to_arrow_type_opt(ParquetType(UInt8(raw)))
        assert_false(
            carries_children(at),
            "_parquet_type_to_arrow_type_opt mapped physical type "
            + String(raw)
            + " to a CHILD-CARRYING Arrow type",
        )


def test_annotated_type_map_never_returns_a_nested_type() raises:
    """`_schema_element_to_arrow_type` over physical x ConvertedType.

    The DECIMAL / UINT / DATE / narrow-int annotations are re-labels of a
    fixed-width storage class; none of them may open a nested arm.
    """
    for raw in range(_PTYPE_SWEEP_MAX):
        var pt = ParquetType(UInt8(raw))
        # -1 is the "annotation absent" sentinel the metadata reader uses.
        var at_none = _schema_element_to_arrow_type(pt, -1)
        assert_false(
            carries_children(at_none),
            "unannotated physical type "
            + String(raw)
            + " mapped to a CHILD-CARRYING Arrow type",
        )
        for ct in range(_CONVERTED_SWEEP_MAX):
            var at = _schema_element_to_arrow_type(pt, ct)
            assert_false(
                carries_children(at),
                "physical type "
                + String(raw)
                + " + ConvertedType "
                + String(ct)
                + " mapped to a CHILD-CARRYING Arrow type",
            )


def test_group_node_maps_to_string_not_to_a_nested_type() raises:
    """A GROUP node (`not elem.type`) is the ONLY nested SHAPE parquet has.

    It maps to STRING -- the fact (1) leans on. A GROUP
    node that started returning LIST / STRUCT / MAP is exactly the edit this
    assertion exists to catch.
    """
    var group = SchemaElement("g", type=None, num_children=2)
    var at = schema_element_arrow_type(group)
    assert_true(
        at == ArrowType.STRING,
        "a parquet GROUP node must map to STRING (decode_helpers.mojo)",
    )
    assert_false(
        carries_children(at),
        "a parquet GROUP node mapped to a CHILD-CARRYING Arrow type",
    )
    # A repeated group -- the LIST / MAP shape -- takes the same arm.
    var repeated = SchemaElement("r", type=None, num_children=1)
    assert_false(
        carries_children(schema_element_arrow_type(repeated)),
        "a repeated parquet GROUP node mapped to a CHILD-CARRYING type",
    )


def test_schema_element_arrow_type_never_returns_a_nested_type() raises:
    """The PUBLIC entry the scan calls, over leaves, groups and timestamps.

    `schema_element_arrow_type` is what `field_from_schema_element` and a
    reader's column setup consult, so it is the surface that has to hold.
    """
    # Leaf elements, annotated and not, with and without a LogicalType
    # TIMESTAMP unit (which takes precedence over the physical map).
    for raw in range(_PTYPE_SWEEP_MAX):
        for ct_i in range(-1, _CONVERTED_SWEEP_MAX):
            var ct: Optional[Int] = None
            if ct_i >= 0:
                ct = ct_i
            var leaf = SchemaElement(
                "c",
                type=ParquetType(UInt8(raw)),
                converted_type=ct,
            )
            assert_false(
                carries_children(schema_element_arrow_type(leaf)),
                "leaf physical "
                + String(raw)
                + " / converted "
                + String(ct_i)
                + " mapped to a CHILD-CARRYING Arrow type",
            )
    # The LogicalType TIMESTAMP arm (units 0..4 covers MILLIS/MICROS/NANOS
    # plus the two values outside the union's vocabulary).
    for unit in range(5):
        var ts = SchemaElement(
            "t",
            type=ParquetType.INT64,
            logical_timestamp_unit=unit,
            logical_timestamp_is_utc=True,
        )
        assert_false(
            carries_children(schema_element_arrow_type(ts)),
            "LogicalType TIMESTAMP unit "
            + String(unit)
            + " mapped to a CHILD-CARRYING Arrow type",
        )


# -----------------------------------------------------------------------------
# Fact (2) — `copy_column_ref` raises on a child-carrying column.
# -----------------------------------------------------------------------------


def test_copy_column_ref_raises_on_a_nested_column() raises:
    """FACT (2). The parquet read path's own copier refuses a nested column.

    The refusal is DOUBLE-guarded, and
    that is why this test asserts the guard's NAME and not merely that
    something raised. Deleting `check_fixed_width_dispatch` from
    `copy_column_ref`'s fixed-width arm still raises -- from
    `_elem_byte_width`'s `arrow_fixed_byte_width`, one layer down. A test
    that only asserted `raised` would have stayed GREEN over that deletion.
    """
    var lists = List[List[Int]]()
    for i in range(8):
        var inner = List[Int]()
        inner.append(i)
        inner.append(-i)
        lists.append(inner^)
    var col = Column.from_list(ListArray.from_int_lists(lists))
    assert_true(
        carries_children(col.arrow_type),
        "fixture is not a child-carrying column -- the test would be vacuous",
    )
    var raised = False
    var msg = String("")
    try:
        var out = copy_column_ref(col, 8)
        _ = out^
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "copy_column_ref ACCEPTED a nested column on"
        " the parquet read path",
    )
    assert_true(
        "ArrowFixedWidthFallthrough" in msg,
        "copy_column_ref raised, but not the NAMED guard: " + msg,
    )
    assert_true(
        "copy_column_ref" in msg,
        "the raise must name its own site: " + msg,
    )


def test_copy_column_ref_still_copies_a_fixed_width_column() raises:
    """NON-REGRESSION: the guard above must not be a blanket refusal."""
    var arr = PrimitiveArray[DType.int64].allocate(8)
    var p = arr._typed_ptr_mut()
    for i in range(8):
        p.unsafe_offset(i)[] = Scalar[DType.int64](i)
    var col = Column.from_primitive[DType.int64](arr^)
    var out = copy_column_ref(col, 8)
    assert_equal(out._length, 8, "copy_column_ref INT64 row count")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
