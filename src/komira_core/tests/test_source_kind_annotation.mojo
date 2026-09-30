# =============================================================================
# source_kind annotation on ScanData
# =============================================================================
#
# Validates the `source_kind: UInt8` field on `ScanData` and the
# `SOURCE_KIND_COLUMNAR` / `SOURCE_KIND_ROW` constants on `logical_plan`.
#
# Coverage:
#   (a) Parquet scan          -> source_kind == COLUMNAR
#   (b) InMemory scan         -> source_kind == COLUMNAR
#   (c) CSV scan              -> source_kind == ROW (declared by the kind)
#   (d) NDJSON scan           -> source_kind == ROW (declared by the kind)
#   (e) ScanData.copy()       -> preserves source_kind across both states
#   (f) Explicit override     -> non-default `source_kind` argument honored
#   (g) EXPLAIN output        -> contains "source_kind=COLUMNAR" / "source_kind=ROW"
#
# The optimizer's routing consumes the field for columnar (Hierarchy A) vs
# row-mode (Hierarchy B) dispatch.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.memory import OwnedPointer

from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.logical_plan_variants import ScanData
from komira_core.plan.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_NDJSON,
    SOURCE_IN_MEMORY,
    SOURCE_KIND_COLUMNAR,
    SOURCE_KIND_ROW,
)
from komira_core.plan.expr import Expr
from komira_core.source.source_variant import SourceVariant
from komira_core.source.parquet_source import ParquetSource
from komira_core_ffi.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A test may be executed by more than one build action at a time, on one
# worker, without a sandbox. A fixed `/tmp` path is shared by every one of
# those executions. `TEST_TMPDIR` is unique per test action, which is what
# makes them disjoint.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_core_ffi.posix` is
# the canonical one.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        return String("/tmp")
    return d


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _test_schema() -> Schema:
    """Build a minimal schema: x (INT64), y (FLOAT64)."""
    var builder = SchemaBuilder()
    builder.add_field(Field("x", ArrowType.INT64, False))
    builder.add_field(Field("y", ArrowType.FLOAT64, True))
    return builder.build()


def _build_parquet_plan() -> LogicalPlan:
    """Parquet scan via the canonical `LogicalPlan.scan(...)` factory."""
    return LogicalPlan.scan(
        (_scratch_dir() + String("/test_source_kind.parquet")),
        SOURCE_PARQUET,
        _test_schema(),
    )


def _build_in_memory_plan() -> LogicalPlan:
    """IN_MEMORY scan via the legacy factory (synthesises an empty batch slab)."""
    return LogicalPlan.scan(
        String("__inmem_test__"),
        SOURCE_IN_MEMORY,
        _test_schema(),
    )


def _build_csv_plan() -> LogicalPlan:
    """CSV scan via the legacy factory."""
    return LogicalPlan.scan(
        (_scratch_dir() + String("/test_source_kind.csv")),
        SOURCE_CSV,
        _test_schema(),
    )


def _build_ndjson_plan() -> LogicalPlan:
    """NDJSON scan via the legacy factory."""
    return LogicalPlan.scan(
        (_scratch_dir() + String("/test_source_kind.jsonl")),
        SOURCE_NDJSON,
        _test_schema(),
    )


# ---------------------------------------------------------------------------
# (a) Parquet → COLUMNAR
# ---------------------------------------------------------------------------

def test_parquet_scan_is_columnar() raises:
    """A Parquet scan must annotate source_kind = COLUMNAR."""
    var plan = _build_parquet_plan()
    assert_equal(Int(plan.tag), Int(PLAN_SCAN))
    assert_equal(
        Int(plan._scan.value()[].source_kind), Int(SOURCE_KIND_COLUMNAR)
    )
    # Sanity: source_type still records the legacy type tag.
    assert_equal(
        Int(plan._scan.value()[].source_type), Int(SOURCE_PARQUET)
    )


# ---------------------------------------------------------------------------
# (b) InMemory → COLUMNAR
# ---------------------------------------------------------------------------

def test_in_memory_scan_is_columnar() raises:
    """An InMemory scan must annotate source_kind = COLUMNAR (record-batch
    payload is columnar by construction)."""
    var plan = _build_in_memory_plan()
    assert_equal(Int(plan.tag), Int(PLAN_SCAN))
    assert_equal(
        Int(plan._scan.value()[].source_kind), Int(SOURCE_KIND_COLUMNAR)
    )
    assert_equal(
        Int(plan._scan.value()[].source_type), Int(SOURCE_IN_MEMORY)
    )


# ---------------------------------------------------------------------------
# (c) CSV → ROW
# ---------------------------------------------------------------------------

def test_csv_scan_is_row() raises:
    """A CSV scan must annotate source_kind = ROW. The `LogicalPlan.scan`
    factory builds the CSV binding arm, and the `komira.csv` kind DECLARES
    `orientation = ROW`."""
    var plan = _build_csv_plan()
    assert_equal(Int(plan.tag), Int(PLAN_SCAN))
    assert_equal(
        Int(plan._scan.value()[].source_kind), Int(SOURCE_KIND_ROW)
    )


# ---------------------------------------------------------------------------
# (d) NDJSON → ROW
# ---------------------------------------------------------------------------

def test_ndjson_scan_is_row() raises:
    """A NDJSON scan must annotate source_kind = ROW.

    JSONL is a ROW-major on-wire format, and `row_streaming_dispatch` routes
    this arm's tag to the JSONL direct ROW reader. The `komira.json` kind
    DECLARES `orientation = ROW` and `ScanData.__init__` reads the
    declaration."""
    var plan = _build_ndjson_plan()
    assert_equal(Int(plan.tag), Int(PLAN_SCAN))
    assert_equal(
        Int(plan._scan.value()[].source_kind), Int(SOURCE_KIND_ROW)
    )


# ---------------------------------------------------------------------------
# (e) ScanData.copy() preserves source_kind for both states
# ---------------------------------------------------------------------------

def test_scandata_copy_preserves_columnar() raises:
    """ScanData.copy() preserves source_kind = COLUMNAR for a Parquet scan."""
    var plan = _build_parquet_plan()
    var orig_data = plan._scan.value()[].copy()  # Defensive: deep-clone first.
    var copied = orig_data.copy()
    assert_equal(Int(copied.source_kind), Int(SOURCE_KIND_COLUMNAR))
    assert_equal(Int(copied.source_type), Int(SOURCE_PARQUET))


def test_scandata_copy_preserves_row() raises:
    """ScanData.copy() preserves source_kind = ROW for a CSV scan."""
    var plan = _build_csv_plan()
    var orig_data = plan._scan.value()[].copy()
    var copied = orig_data.copy()
    assert_equal(Int(copied.source_kind), Int(SOURCE_KIND_ROW))


# ---------------------------------------------------------------------------
# (f) Explicit override is honored verbatim
# ---------------------------------------------------------------------------

def test_explicit_source_kind_override_honored() raises:
    """An explicit `source_kind=SOURCE_KIND_ROW` overrides the COLUMNAR
    default even for a Parquet source_type. Forward-compat for sources
    whose physical decoding differs from their nominal type tag."""
    var ps = ParquetSource(
        (_scratch_dir() + String("/test_override.parquet")),
        _test_schema(),
        Optional[String](None),
    )
    var src = SourceVariant(ps^)
    var sd = ScanData(
        src^,
        Optional[Schema](_test_schema()),
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
        None,
        SOURCE_KIND_ROW,
    )
    assert_equal(Int(sd.source_kind), Int(SOURCE_KIND_ROW))
    assert_equal(Int(sd.source_type), Int(SOURCE_PARQUET))


# ---------------------------------------------------------------------------
# (g) EXPLAIN output annotates source_kind
# ---------------------------------------------------------------------------

def test_explain_contains_source_kind_columnar() raises:
    """`write_to(plan)` (EXPLAIN) must include `source_kind=COLUMNAR` for a
    Parquet scan node."""
    var plan = _build_parquet_plan()
    var s = String("")
    s.write(plan)
    assert_true(s.find("source_kind=COLUMNAR") >= 0)


def test_explain_contains_source_kind_row() raises:
    """EXPLAIN must include `source_kind=ROW` for a CSV scan node."""
    var plan = _build_csv_plan()
    var s = String("")
    s.write(plan)
    assert_true(s.find("source_kind=ROW") >= 0)


# ---------------------------------------------------------------------------
# main entry point
# ---------------------------------------------------------------------------

def main() raises:
    test_parquet_scan_is_columnar()
    test_in_memory_scan_is_columnar()
    test_csv_scan_is_row()
    test_ndjson_scan_is_row()
    test_scandata_copy_preserves_columnar()
    test_scandata_copy_preserves_row()
    test_explicit_source_kind_override_honored()
    test_explain_contains_source_kind_columnar()
    test_explain_contains_source_kind_row()
    print("all source_kind annotation tests passed")
