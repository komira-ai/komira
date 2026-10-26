# =============================================================================
# FileSource[Jsonl] delegates to JsonSource; the Parquet arm still works
# =============================================================================
#
# `FileSource[F]` holds one concrete source per format. The `Jsonl` arm wraps a
# `JsonSource` and the `Parquet[*]` arms wrap a `ParquetSource`, with exactly
# one `Optional` arm populated according to `F`. The tests build the sources
# from path strings only; no file is read or written.
#
#   1. `FileSource[Jsonl](path, schema)` constructs.
#   2. `schema()` returns the caller-supplied schema (two columns, `x` then
#      `y`).
#   3. `estimate_rows()` is -1 (JSON has no embedded row count).
#   4. `fingerprint()` is the same after `copy()` and is not 0 (it hashes the
#      path and the folded mtime).
#   5. `supports_filter_pushdown()` is False (JSON has no decode-time pruning).
#   6. `json_source_view()` is `Some` on the Jsonl arm and carries the path.
#   7. A `FileSource[Parquet[Uncompressed]]` still reports its schema and
#      exposes `parquet_source_view()` (the Jsonl arm must not displace the
#      Parquet arms).
#
# Which case guards which defect: a Jsonl arm left empty returns an empty
# schema (fails 2), fingerprint 0 (fails 4) and no view (fails 6); a Jsonl arm
# that claims pushdown fails 5; a cascade that populated the wrong arm fails 6
# or 7.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.formats import Jsonl, Parquet
from komira_compression.compression_codecs import Uncompressed
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_EQ

from komira_sdk_exec.file_source import FileSource
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory this execution may use for scratch paths."""
    return test_tmpdir()


# =============================================================================
# Helpers
# =============================================================================


def _test_jsonl_schema() raises -> Schema:
    """Two columns: x (INT64, not null) and y (FLOAT64, nullable)."""
    var b = SchemaBuilder()
    b.add_field(Field(String("x"), ArrowType.INT64, False))
    b.add_field(Field(String("y"), ArrowType.FLOAT64, True))
    return b.build()


def _trivial_predicate() raises -> Expr:
    """A trivial predicate to exercise `supports_filter_pushdown`. The
    predicate is never evaluated (the test only inspects the boolean
    return). `x == x` is a guaranteed-True equality on a present col."""
    return Expr.binary(
        BIN_EQ, Expr.col_ref(String("x")), Expr.col_ref(String("x"))
    )


# =============================================================================
# Tests
# =============================================================================


def test_jsonl_arm_constructs() raises:
    """`FileSource[Jsonl](path, schema)` constructs without raising."""
    var fs = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    # No-op assert — reaching here means the ctor did not raise.
    _ = fs
    assert_true(True)


def test_jsonl_schema_round_trips() raises:
    """`FileSource[Jsonl].schema()` returns the caller-supplied Schema
    verbatim (an empty arm would return an empty Schema)."""
    var fs = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    var s = fs.schema()
    assert_equal(s.num_columns(), 2, "schema should have 2 columns")
    assert_equal(s.field_name(0), String("x"))
    assert_equal(s.field_name(1), String("y"))


def test_jsonl_estimate_rows_is_negative_one() raises:
    """`FileSource[Jsonl].estimate_rows()` returns -1 (unknown): JSON has
    no embedded row-count metadata without a full structural scan."""
    var fs = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    assert_equal(fs.estimate_rows(), -1)


def test_jsonl_fingerprint_stable_across_copy() raises:
    """`FileSource[Jsonl].fingerprint()` is stable across .copy().
    Same (path, mtime) gives the same fingerprint regardless of
    construction order."""
    var fs1 = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    var fs2 = fs1.copy()
    assert_equal(fs1.fingerprint(), fs2.fingerprint())
    # And a non-trivial fingerprint (the empty / stub state would
    # have returned UInt64(0) — FNV-1a over a non-empty path returns
    # a non-zero hash).
    assert_true(fs1.fingerprint() != UInt64(0))


def test_jsonl_supports_filter_pushdown_returns_false() raises:
    """`FileSource[Jsonl].supports_filter_pushdown(...)` returns False
    for every predicate: JSON has no decode-time pruning."""
    var fs = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    var pred = _trivial_predicate()
    assert_false(fs.supports_filter_pushdown(pred))


def test_jsonl_source_view_returns_some() raises:
    """`json_source_view()` returns Some(JsonSource) on the Jsonl arm
    (parallel to `parquet_source_view()` for Parquet arms). The
    underlying JsonSource carries the path + cached schema."""
    var fs = FileSource[Jsonl](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")),
        _test_jsonl_schema(),
    )
    var view = fs.json_source_view()
    assert_true(Bool(view), "Jsonl arm must expose JsonSource view")
    ref js = view.value()
    assert_equal(String(js.path), (_scratch_dir() + String("/test_file_source_jsonl_arm.jsonl")))


def test_parquet_arm_still_works() raises:
    """Regression guard: the Parquet[Uncompressed] arm still
    constructs and reports its schema correctly; the Jsonl arm must not
    displace the Parquet arms."""
    var fs = FileSource[Parquet[Uncompressed]](
        (_scratch_dir() + String("/test_file_source_jsonl_arm.parquet")),
        _test_jsonl_schema(),
    )
    var s = fs.schema()
    assert_equal(s.num_columns(), 2)
    var view = fs.parquet_source_view()
    assert_true(Bool(view), "Parquet arm must still expose its view")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
