"""CSV source end-to-end integration test (LIGHT).

Pins the contract that `CsvSource` + `SourceVariant` CSV arm + the
plan-compile dispatch all wire correctly.

This is the LIGHT variant — it does NOT pull in `EngineContext` /
`ctx.materialize`, which would drag the full SDK + engine transitive
closure into the test binary (a very long compile). The full
`ctx.read_csv -> materialize` integration is covered by the CSV reader
end-to-end tests, and the remaining wire-up (ctx.read_csv -> SourceVariant
-> _compile_csv_scan -> read_csv_bytes_to_batch -> RecordBatch) is checked
by compiling the packages that carry the SOURCE_VARIANT_CSV arm.

Coverage:
  T1: CsvSource ctor + schema + fingerprint stability.
  T2: SourceVariant CSV arm tag + dispatch round-trip.
"""

from std.testing import assert_equal, assert_true

from komira_arrow.schema import Schema
from komira_scan_source.csv_source import CsvSource
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_CSV,
)
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. A test may be executed by more
# than one action at a time on one worker, and a fixed `/tmp` path is shared by
# all of them; `TEST_TMPDIR` is unique per execution.
#
# ⚠ `_read_env`, NOT `std.os.getenv` — Mojo's MLIR FFI legalization allows at
# most ONE `getenv` declaration per link unit and `komira_libc.posix` is
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


def test_csv_source_ctor_and_schema() raises:
    print("T1: CsvSource ctor + schema + fingerprint stability")
    var sch = Schema()
    var src = CsvSource((_scratch_dir() + String("/foo.csv")), sch^)
    var fp1 = src.fingerprint()

    # Clone preserves identity (cache-discrimination contract).
    var c = src.copy()
    var fp2 = c.fingerprint()
    assert_equal(fp1, fp2)

    # Two different paths -> different fingerprints.
    var sch2 = Schema()
    var src2 = CsvSource((_scratch_dir() + String("/bar.csv")), sch2^)
    var fp3 = src2.fingerprint()
    assert_true(fp1 != fp3)

    # estimate_rows() == -1 (unknown).
    assert_equal(src.estimate_rows(), -1)
    print("  PASS")


def test_source_variant_csv_arm() raises:
    print("T2: SourceVariant CSV arm tag + dispatch round-trip")
    var sch = Schema()
    var src = CsvSource((_scratch_dir() + String("/foo.csv")), sch^)
    var sv = SourceVariant(src^)
    assert_equal(Int(sv.tag), Int(SOURCE_VARIANT_CSV))
    assert_equal(String(sv.kind_name()), String("csv"))
    # Round-trip via copy preserves tag.
    var fp = sv.fingerprint()
    var sv2 = sv.copy()
    assert_equal(Int(sv2.tag), Int(SOURCE_VARIANT_CSV))
    assert_equal(sv2.fingerprint(), fp)
    print("  PASS")


def main() raises:
    test_csv_source_ctor_and_schema()
    test_source_variant_csv_arm()
    print("test_csv_read_csv_e2e: 2/2 PASS")
