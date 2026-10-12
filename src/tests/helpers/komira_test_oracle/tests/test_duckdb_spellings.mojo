# The harness's DuckDB TSV reader held to bytes the pinned DuckDB wrote:
# spellings.tsv is the sql_oracle :spellings (sql/spellings.sql), one row
# per kind of value. Each cell must read as the value its SQL literal names.
#
# Defects these catch: a reader written against a transcription of DuckDB's
# output that DuckDB does not actually write (the exponent's sign and
# leading zero, `-nan`, a quoted cell across lines, `""`), and a DuckDB
# bump that changes a spelling (this test goes red before any answer is
# misread).

from std.memory import bitcast
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import CanonText, duckdb_tsv_canon, parse_canon, parse_duckdb_tsv

comptime _SCHEMA = "id:int64\twhat:string\ti64:int64?\tu64:uint64?\tf64:float64?\tf32:float32?\tdec:decimal128(9,2)?\ts:string?\tb:bool?"


def _read() raises -> CanonText:
    var like = parse_canon(
        String("#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n") + _SCHEMA + "\n"
    )
    return duckdb_tsv_canon(parse_duckdb_tsv(Path("spellings.tsv").read_text()), like)


def _bits64(cell: String) -> String:
    return String(cell[byte = cell.find("|") + 1 : cell.byte_length()])


def _hex64(x: Float64) -> String:
    return String("0x") + hex(bitcast[DType.uint64](x), prefix="").upper()


def _hex32(x: Float32) -> String:
    var h = hex(bitcast[DType.uint32](x), prefix="").upper()
    var pad = String("")
    for _ in range(8 - h.byte_length()):
        pad += "0"
    return String("0x") + pad + h


def test_every_spelling() raises:
    var t = _read()
    assert_equal(t.num_rows(), 10)
    var r = t.rows.copy()
    # Each row's `what`, in id order: the file is what sql/spellings.sql says.
    var whats: List[String] = ["zeros", "nulls", "extremes", "nan", "inf", "least", "tenth", "large", "small", "negnan"]
    for i in range(10):
        assert_equal(r[i][1], whats[i])
    # zeros
    assert_equal(r[0][2], "0")
    assert_equal(r[0][4], "-0.0|0x8000000000000000")
    assert_equal(r[0][5], "-0.0|0x80000000")
    assert_equal(r[0][6], "0e-2")
    assert_equal(r[0][7], "")
    assert_equal(r[0][8], "false")
    # nulls: every nullable column
    for c in range(2, 9):
        assert_equal(r[1][c], "\\N")
    # extremes
    assert_equal(r[2][2], "-9223372036854775808")
    assert_equal(r[2][3], "18446744073709551615")
    assert_equal(_bits64(r[2][4]), "0x7FEFFFFFFFFFFFFF")
    assert_equal(_bits64(r[2][5]), "0x7F7FFFFF")
    assert_equal(r[2][6], "-999999999e-2")
    assert_equal(r[2][7], "tab\\tnl\\ncr\\rend")
    # nan
    assert_equal(r[3][4], "NaN")
    assert_equal(r[3][5], "NaN")
    assert_equal(r[3][6], "1e-2")
    assert_equal(r[3][7], "say \"hi\"")
    # inf
    assert_equal(r[4][2], "9223372036854775807")
    assert_equal(r[4][4], "inf|0x7FF0000000000000")
    assert_equal(r[4][5], "-inf|0xFF800000")
    assert_equal(r[4][6], "-1e-2")
    assert_equal(r[4][7], "\\\\N")
    # least: the least subnormals
    assert_equal(_bits64(r[5][4]), "0x0000000000000001")
    assert_equal(_bits64(r[5][5]), "0x00000001")
    assert_equal(r[5][6], "1230e-2")
    assert_equal(r[5][7], "back\\\\slash é 世界 😀")
    # tenth, large, small
    assert_equal(_bits64(r[6][4]), _hex64(0.1))
    assert_equal(_bits64(r[6][5]), _hex32(Float32(0.1)))
    assert_equal(r[6][7], "NULL")
    assert_equal(_bits64(r[7][4]), _hex64(1e300))
    assert_equal(_bits64(r[7][5]), _hex32(Float32(1e30)))
    assert_equal(r[7][7], " lead and trail ")
    assert_equal(_bits64(r[8][4]), _hex64(1.5e-07))
    assert_equal(_bits64(r[8][5]), _hex32(Float32(-2.5)))
    assert_equal(r[8][6], "-150e-2")
    # negnan: -nan is a NaN; a lone quote
    assert_equal(r[9][4], "NaN")
    assert_equal(_bits64(r[9][5]), _hex32(Float32(123456.7)))
    assert_equal(r[9][7], "\"")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
