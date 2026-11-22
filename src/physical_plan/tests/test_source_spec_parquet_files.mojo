# =============================================================================
# test_source_spec_parquet_files -- the SOURCE_PARQUET arm for several files
# =============================================================================
#
# `SourceSpecPod.parquet_files` names every file of a source and the Hive
# partition constants of each; the first file is `parquet_path`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from arrow.arrow_types import ArrowType
from arrow.schema import Field
from plan_expr.expr import Expr
from physical_plan.physical_plan import SourceSpecPod


def _paths() -> List[String]:
    var out = List[String]()
    out.append("dt=2026-10-01/a.parquet")
    out.append("dt=2026-10-02/b.parquet")
    return out^


def _cols() -> List[Field]:
    var out = List[Field]()
    out.append(Field("dt", ArrowType.DATE32, False))
    return out^


def _row(value: String) -> List[String]:
    var out = List[String]()
    out.append(value)
    return out^


def _values() -> List[List[String]]:
    var out = List[List[String]]()
    out.append(_row("2026-10-01"))
    out.append(_row("2026-10-02"))
    return out^


def test_a_plain_file_spec_lists_no_files() raises:
    var s = SourceSpecPod.parquet("a.parquet", None, None, True)
    assert_equal(s.parquet_path, "a.parquet")
    assert_equal(len(s.parquet_paths), 0)
    assert_equal(len(s.parquet_partition_cols), 0)
    assert_equal(len(s.parquet_partition_values), 0)


def test_files_without_partition_columns_keep_the_list_and_the_first_path() raises:
    var proj = List[String]()
    proj.append("k")
    var s = SourceSpecPod.parquet_files(
        _paths(),
        List[Field](),
        List[List[String]](),
        Optional(proj^),
        None,
    )
    assert_equal(s.parquet_path, "dt=2026-10-01/a.parquet")
    assert_equal(len(s.parquet_paths), 2)
    assert_equal(s.parquet_paths[1], "dt=2026-10-02/b.parquet")
    assert_true(s.parquet_spec_is_total)
    assert_equal(len(s.parquet_projection.value()), 1)
    assert_false(Bool(s.parquet_filter))
    assert_equal(len(s.parquet_partition_cols), 0)


def test_partition_columns_and_values_are_kept_per_file() raises:
    var s = SourceSpecPod.parquet_files(_paths(), _cols(), _values(), None, None)
    assert_equal(len(s.parquet_partition_cols), 1)
    assert_equal(s.parquet_partition_cols[0].name, "dt")
    assert_equal(len(s.parquet_partition_values), 2)
    assert_equal(s.parquet_partition_values[0][0], "2026-10-01")
    assert_equal(s.parquet_partition_values[1][0], "2026-10-02")
    assert_true(s.parquet_spec_is_total)


def test_a_pushed_filter_is_kept() raises:
    var s = SourceSpecPod.parquet_files(
        _paths(),
        List[Field](),
        List[List[String]](),
        None,
        Optional(Expr.col_ref("k")),
    )
    assert_equal(String(s.parquet_filter.value()), String(Expr.col_ref("k")))


def test_an_empty_file_list_names_no_path() raises:
    var s = SourceSpecPod.parquet_files(
        List[String](), List[Field](), List[List[String]](), None, None
    )
    assert_equal(s.parquet_path, "")
    assert_equal(len(s.parquet_paths), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
