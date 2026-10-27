# =============================================================================
# NaN min/max statistics through can_prune_row_group and rg_all_match_row_group.
#
# A NaN bound compares false with everything, so a pruner that reads
# `mx > v` or `mn <= v` off it answers "no row can match" for a range that
# proves nothing, and drops a row group holding matching rows.
#
# What each test proves:
#   * for every comparison operator (=, <>, <, <=, >, >=), with the literal
#     on either side, for DOUBLE and FLOAT columns, and for each bound shape
#     (NaN min, NaN max, both NaN, NaN beside -0.0 and +0.0, quiet, negative
#     and signalling NaN bit patterns), the row group is kept;
#   * the NaN fix does not blunt the pruner: the same operators over finite
#     bounds still prune what the range rules out, so the "kept" answers
#     above are the NaN rule and not a pruner that stopped pruning;
#   * AND / OR over a NaN-bound column keep the row group exactly as a
#     kept leaf does (OR of a kept leaf and a pruned one is kept; AND with
#     a pruned finite leaf is still pruned);
#   * all-match never fires over a NaN-bound float column, for any operator,
#     and all_match_row_count does not count such a row group.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    RowGroup,
    SchemaElement,
    Statistics,
)
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_parquet.rg_pruner import all_match_row_count, can_prune_row_group, rg_all_match_row_group


def _le(v: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(width):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))
    return out^


def _f64(v: Float64) -> List[UInt8]:
    return _le(bitcast[DType.uint64](v), 8)


def _f32(v: Float32) -> List[UInt8]:
    return _le(UInt64(bitcast[DType.uint32](v)), 4)


def _nan64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _nan32(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


def _chunk(t: ParquetType, var mn: List[UInt8], var mx: List[UInt8]) -> ColumnChunk:
    var stats = Statistics(null_count=0, min_value=mn^, max_value=mx^)
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=List[String](),
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=10,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=4,
        statistics=stats^,
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


# d DOUBLE with the given bounds; f FLOAT with the same bounds narrowed;
# k DOUBLE [1.0, 2.0], finite.
def _file(mn: Float64, mx: Float64) -> FileMetaData:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=3),
        SchemaElement(name="d", type=ParquetType.DOUBLE),
        SchemaElement(name="f", type=ParquetType.FLOAT),
        SchemaElement(name="k", type=ParquetType.DOUBLE),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.DOUBLE, _f64(mn), _f64(mx)),
        _chunk(ParquetType.FLOAT, _f32(Float32(mn)), _f32(Float32(mx))),
        _chunk(ParquetType.DOUBLE, _f64(1.0), _f64(2.0)),
    ]
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=columns^, total_byte_size=0, num_rows=10))
    return FileMetaData(version=2, schema=schema^, num_rows=10, row_groups=groups^)


def _file_f32_bits(mn: UInt32, mx: UInt32) -> FileMetaData:
    """A FLOAT column whose bounds are the given raw bit patterns (a Float64
    round trip would quieten a signalling NaN)."""
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=1),
        SchemaElement(name="f", type=ParquetType.FLOAT),
    ]
    var columns: List[ColumnChunk] = [_chunk(ParquetType.FLOAT, _le(UInt64(mn), 4), _le(UInt64(mx), 4))]
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=columns^, total_byte_size=0, num_rows=10))
    return FileMetaData(version=2, schema=schema^, num_rows=10, row_groups=groups^)


def _cmp(op: UInt8, col: String, v: Float64) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(ScalarValue.from_float(v)))


def _rcmp(op: UInt8, v: Float64, col: String) -> Expr:
    return Expr.binary(op, Expr.literal(ScalarValue.from_float(v)), Expr.col_ref(col))


def _prunes(md: FileMetaData, e: Expr) -> Bool:
    return can_prune_row_group(md.row_groups[0], md, e)


def _all(md: FileMetaData, e: Expr) -> Bool:
    return rg_all_match_row_group(md.row_groups[0], md, e)


def _ops() -> List[UInt8]:
    return [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]


def _lits() -> List[Float64]:
    return [5.0, 0.0, -0.0, -5.0]


def _keeps_every_operator(md: FileMetaData) raises:
    """No operator, literal or side prunes column d or f of `md`."""
    var ops = _ops()
    var lits = _lits()
    for c in range(2):
        var col = String("d") if c == 0 else String("f")
        for i in range(len(ops)):
            for j in range(len(lits)):
                assert_false(_prunes(md, _cmp(ops[i], col, lits[j])))
                assert_false(_prunes(md, _rcmp(ops[i], lits[j], col)))
                assert_false(_all(md, _cmp(ops[i], col, lits[j])))
                assert_false(_all(md, _rcmp(ops[i], lits[j], col)))


def test_nan_min() raises:
    _keeps_every_operator(_file(_nan64(0x7FF8000000000000), 2.0))


def test_nan_max() raises:
    _keeps_every_operator(_file(1.0, _nan64(0x7FF8000000000000)))


def test_both_nan() raises:
    _keeps_every_operator(_file(_nan64(0x7FF8000000000000), _nan64(0x7FF8000000000000)))


def test_nan_beside_signed_zero() raises:
    var nan = _nan64(0x7FF8000000000000)
    _keeps_every_operator(_file(-0.0, nan))
    _keeps_every_operator(_file(0.0, nan))
    _keeps_every_operator(_file(nan, 0.0))
    _keeps_every_operator(_file(nan, -0.0))


def test_nan_bit_patterns() raises:
    # Negative quiet NaN, and a signalling NaN with a payload, in each slot.
    var neg = _nan64(0xFFF8000000000000)
    var sig = _nan64(0x7FF0000000000001)
    _keeps_every_operator(_file(neg, 2.0))
    _keeps_every_operator(_file(1.0, neg))
    _keeps_every_operator(_file(sig, 2.0))
    _keeps_every_operator(_file(1.0, sig))
    _keeps_every_operator(_file(sig, neg))


def test_float32_nan_bit_patterns() raises:
    # FLOAT bounds as raw bits: a Float32 NaN widened to Float64 stays NaN.
    var ok = bitcast[DType.uint32](Float32(1.0))
    var ops = _ops()
    var lits = _lits()
    var pats: List[UInt32] = [0x7FC00000, 0xFFC00000, 0x7F800001]
    for p in range(len(pats)):
        var variants = List[FileMetaData]()
        variants.append(_file_f32_bits(pats[p], ok))
        variants.append(_file_f32_bits(ok, pats[p]))
        variants.append(_file_f32_bits(pats[p], pats[p]))
        for m in range(len(variants)):
            for i in range(len(ops)):
                for j in range(len(lits)):
                    assert_false(_prunes(variants[m], _cmp(ops[i], "f", lits[j])))
                    assert_false(_prunes(variants[m], _rcmp(ops[i], lits[j], "f")))
                    assert_false(_all(variants[m], _cmp(ops[i], "f", lits[j])))


def test_issue_example_both_nan_gt() raises:
    var nan = _nan64(0x7FF8000000000000)
    var md = _file(nan, nan)
    # A row holding 14.5 satisfies d > 5.0: the group must be kept.
    assert_false(_prunes(md, _cmp(BIN_GT, "d", 5.0)))


def test_finite_bounds_still_prune() raises:
    var md = _file(1.0, 2.0)
    for c in range(2):
        var col = String("d") if c == 0 else String("f")
        assert_true(_prunes(md, _cmp(BIN_EQ, col, 5.0)))
        assert_true(_prunes(md, _cmp(BIN_LT, col, 1.0)))
        assert_true(_prunes(md, _cmp(BIN_LE, col, 0.5)))
        assert_true(_prunes(md, _cmp(BIN_GT, col, 2.0)))
        assert_true(_prunes(md, _cmp(BIN_GE, col, 5.0)))
        assert_true(_prunes(md, _rcmp(BIN_LT, 5.0, col)))
        assert_false(_prunes(md, _cmp(BIN_NE, col, 5.0)))
        assert_false(_prunes(md, _cmp(BIN_GT, col, 1.5)))
    # Zero bounds of both signs compare equal, as before.
    var z = _file(-0.0, 0.0)
    assert_false(_prunes(z, _cmp(BIN_EQ, "d", 0.0)))
    assert_false(_prunes(z, _cmp(BIN_EQ, "d", -0.0)))
    assert_true(_prunes(z, _cmp(BIN_GT, "d", 0.0)))
    assert_true(_prunes(z, _cmp(BIN_LT, "d", -0.0)))


def test_and_or_over_nan_bounds() raises:
    var nan = _nan64(0x7FF8000000000000)
    var md = _file(nan, nan)
    # k is [1.0, 2.0]: k > 5.0 prunes, d > 5.0 is kept.
    assert_true(_prunes(md, _cmp(BIN_GT, "k", 5.0)))
    var or_e = Expr.binary(BIN_OR, _cmp(BIN_GT, "d", 5.0), _cmp(BIN_GT, "k", 5.0))
    assert_false(_prunes(md, or_e))
    var and_kept = Expr.binary(BIN_AND, _cmp(BIN_GT, "d", 5.0), _cmp(BIN_LT, "k", 9.0))
    assert_false(_prunes(md, and_kept))
    var and_pruned = Expr.binary(BIN_AND, _cmp(BIN_GT, "d", 5.0), _cmp(BIN_GT, "k", 5.0))
    assert_true(_prunes(md, and_pruned))


def test_all_match_row_count_does_not_count_nan_group() raises:
    var nan = _nan64(0x7FF8000000000000)
    var md = _file(nan, nan)
    # The group is neither all-match nor pruned: undecided, so no count.
    assert_false(Bool(all_match_row_count(md, _cmp(BIN_GT, "d", 5.0))))
    assert_false(Bool(all_match_row_count(md, _cmp(BIN_LT, "d", 5.0))))
    assert_false(Bool(all_match_row_count(md, _cmp(BIN_NE, "d", 5.0))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
