# =============================================================================
# test_pplan_wire_roundtrip.mojo: the physical-plan codec round-trips every
# encodable field, and refuses malformed input by name.
#
# The assertion is field-for-field equality (`pplan_fields_equal`), not "it
# decoded": a codec that drops `projection` still decodes, and only a
# comparison of every field on both sides can see the loss.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import Field
from komira_collections.slab import Slab
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_S3
from komira_plan_ir.logical_plan import ExprArray
from komira_physical_plan.physical_plan import (
    MorselOp,
    ParquetRowWindow,
    ParquetSourceData,
)
from komira_pplan_wire import (
    PPLAN_WIRE_BAD_MAGIC,
    PPLAN_WIRE_TRAILING_BYTES,
    PPLAN_WIRE_TRUNCATED,
    pplan_fields_equal,
    pplan_from_bytes,
    pplan_to_bytes,
)


def _mk_rich() raises -> ParquetSourceData:
    """A source with EVERY encodable field set to a NON-DEFAULT value. A plan
    whose fields are all defaults round-trips through a codec that writes
    nothing at all."""
    var proj = List[String]()
    proj.append(String("a"))
    proj.append(String("b"))
    var paths = List[String]()
    paths.append(String("p0.parquet"))
    paths.append(String("p1.parquet"))
    return ParquetSourceData(
        String("events.parquet"),
        Optional[List[String]](proj^),
        Optional[Expr]((col("status") == 1) & (col("amt") > 3)),
        List[Field](),
        None,
        FsDescriptorPod(scheme=FS_SCHEME_S3, bucket=String("buck"), node_id=7),
        True,  # preserve_numeric_dict
        paths^,
        Optional[ParquetRowWindow](ParquetRowWindow(11, 22)),
        False,  # preserve_string_dict
    )


def _mk_ops() raises -> Slab[MorselOp]:
    var ops = Slab[MorselOp]()
    ops.append(MorselOp.filter(col("status") == 1))
    ops.append(MorselOp.filter(col("region") == String("us")))
    var exprs = ExprArray()
    exprs.append(col("a").copy_expr())
    exprs.append(col("b").alias("bb"))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("bb"))
    ops.append(MorselOp.project(exprs^, names^))
    ops.append(MorselOp.limit(5))
    return ops^


def _error_of(var data: List[UInt8]) -> String:
    try:
        _ = pplan_from_bytes(data^)
    except e:
        return String(e)
    return String("")


def test_rich_plan_round_trips_field_for_field() raises:
    var pq = _mk_rich()
    var ops = _mk_ops()
    var bytes = pplan_to_bytes(pq, ops)
    var decoded = pplan_from_bytes(bytes.copy())
    assert_true(pplan_fields_equal(pq, ops, decoded.pq_data, decoded.ops))


def test_encoding_is_deterministic() raises:
    var pq = _mk_rich()
    var ops = _mk_ops()
    var a = pplan_to_bytes(pq, ops)
    var b = pplan_to_bytes(pq, ops)
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i], b[i])


# ---- The comparator must be live: each corruption of ONE decoded field has to
# ---- be detected, otherwise the round-trip assertion above compares nothing.


def _same_after(corruption: Int) raises -> Bool:
    var pq = _mk_rich()
    var ops = _mk_ops()
    var decoded = pplan_from_bytes(pplan_to_bytes(pq, ops))
    if corruption == 0:
        decoded.pq_data.file_path = String("other.parquet")
    elif corruption == 1:
        decoded.pq_data.projection = None
    elif corruption == 2:
        decoded.pq_data.pushed_filter = None
    elif corruption == 3:
        decoded.pq_data.fs_descriptor.node_id = 8
    elif corruption == 4:
        decoded.pq_data.fs_descriptor.bucket = String("other")
    elif corruption == 5:
        decoded.pq_data.preserve_numeric_dict = False
    elif corruption == 6:
        decoded.pq_data.explicit_paths = List[String]()
    elif corruption == 7:
        decoded.pq_data.row_window = Optional[ParquetRowWindow](
            ParquetRowWindow(11, 23)
        )
    elif corruption == 8:
        decoded.pq_data.preserve_string_dict = True
    elif corruption == 9:
        decoded.ops = Slab[MorselOp]()
    elif corruption == 10:
        decoded.pq_data.fs_descriptor.scheme = FsDescriptorPod.local().scheme
    return pplan_fields_equal(pq, ops, decoded.pq_data, decoded.ops)


def test_uncorrupted_control_is_equal() raises:
    assert_true(_same_after(-1))


def test_every_field_corruption_is_detected() raises:
    for c in range(11):
        assert_false(_same_after(c), "corruption not detected: " + String(c))


def test_bad_magic_is_refused_by_name() raises:
    var bytes = pplan_to_bytes(_mk_rich(), _mk_ops())
    bytes[0] = UInt8(0x00)
    assert_true(_error_of(bytes^).find(PPLAN_WIRE_BAD_MAGIC) >= 0)


def test_trailing_byte_is_refused_by_name() raises:
    var bytes = pplan_to_bytes(_mk_rich(), _mk_ops())
    bytes.append(UInt8(0x07))
    assert_true(_error_of(bytes^).find(PPLAN_WIRE_TRAILING_BYTES) >= 0)


def test_truncation_is_refused_by_name() raises:
    var bytes = pplan_to_bytes(_mk_rich(), _mk_ops())
    var cut = List[UInt8]()
    for i in range(len(bytes) - 3):
        cut.append(bytes[i])
    assert_true(_error_of(cut^).find(PPLAN_WIRE_TRUNCATED) >= 0)


def main() raises:
    test_rich_plan_round_trips_field_for_field()
    test_encoding_is_deterministic()
    test_uncorrupted_control_is_equal()
    test_every_field_corruption_is_detected()
    test_bad_magic_is_refused_by_name()
    test_trailing_byte_is_refused_by_name()
    test_truncation_is_refused_by_name()
    print("ok")
