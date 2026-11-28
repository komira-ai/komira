# =============================================================================
# The CSV `skip` option, carried by the `komira.csv` binding.
# =============================================================================
#
# `skip` is the number of raw lines dropped before the header. It decides which
# bytes are the header and the rows, so it is a param of the binding and a term
# of `CsvSource`'s fingerprint, written and folded only when it is not 0: a
# default scan keeps the params and the fingerprint it had without the option.
#
# The skip=1 and skip=2 fingerprints are literals from a standalone FNV-1a
# implementation of the documented fold (the existing fold, then `skip`), which
# first reproduced `GOLDEN_FP_MTIME_1234567890_Q0` of the CSV arm test.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
)

from arrow.schema import Schema
from scan_source.csv_source import CsvSource, CSV_DEFAULT_SKIP
from scan_source.source_variant import SourceVariant, csv_scan_identity_corpus

comptime SKIP_PATH: String = "/tmp/golden_csv_fp.csv"
comptime FP_SKIP_0: UInt64 = 15403575544779683767
comptime FP_SKIP_1: UInt64 = 13374114915152570946
comptime FP_SKIP_2: UInt64 = 13374113815640942735


def _src(skip: Int) -> CsvSource:
    return CsvSource(
        String(SKIP_PATH), Schema(), mtime_ns=UInt64(1234567890), skip=skip
    )


def test_a_scan_that_skips_no_line_writes_no_skip_param() raises:
    var sv = SourceVariant(_src(0))
    assert_false(sv.binding_ref().params.has(String("skip")))
    assert_equal(sv.fingerprint(), FP_SKIP_0)


def test_a_scan_that_skips_lines_writes_the_count_as_a_param() raises:
    var sv = SourceVariant(_src(2))
    assert_true(sv.binding_ref().params.has(String("skip")))
    assert_equal(sv.binding_ref().params.get_i64(String("skip"), Int64(-1)), Int64(2))


def test_the_default_skip_is_zero() raises:
    assert_equal(CSV_DEFAULT_SKIP, 0)
    var c = CsvSource(String(SKIP_PATH), Schema(), mtime_ns=UInt64(1234567890))
    assert_equal(c.skip, 0)
    assert_equal(c.fingerprint(), FP_SKIP_0)


def test_skip_counts_enter_the_fingerprint() raises:
    assert_equal(_src(1).fingerprint(), FP_SKIP_1)
    assert_equal(_src(2).fingerprint(), FP_SKIP_2)


def test_scans_that_skip_different_counts_have_different_binding_identities() raises:
    var s0 = SourceVariant(_src(0))
    var s1 = SourceVariant(_src(1))
    var s2 = SourceVariant(_src(2))
    var h0 = s0.binding_ref().identity_hash()
    var h1 = s1.binding_ref().identity_hash()
    var h2 = s2.binding_ref().identity_hash()
    assert_not_equal(h0, h1)
    assert_not_equal(h0, h2)
    assert_not_equal(h1, h2)


def test_copy_keeps_the_skip_and_the_fingerprint() raises:
    var c = _src(2).copy()
    assert_equal(c.skip, 2)
    assert_equal(c.fingerprint(), FP_SKIP_2)
    var sv = SourceVariant(_src(2)).copy()
    assert_equal(sv.fingerprint(), FP_SKIP_2)
    assert_equal(sv.binding_ref().params.get_i64(String("skip"), Int64(-1)), Int64(2))


def test_the_identity_corpus_has_a_skip_entry() raises:
    var corpus = csv_scan_identity_corpus()
    var found = False
    for i in range(len(corpus.labels)):
        if corpus.labels[i] == String("skip"):
            found = True
    assert_true(found)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_scan_that_skips_no_line_writes_no_skip_param]()
    suite.test[test_a_scan_that_skips_lines_writes_the_count_as_a_param]()
    suite.test[test_the_default_skip_is_zero]()
    suite.test[test_skip_counts_enter_the_fingerprint]()
    suite.test[test_scans_that_skip_different_counts_have_different_binding_identities]()
    suite.test[test_copy_keeps_the_skip_and_the_fingerprint]()
    suite.test[test_the_identity_corpus_has_a_skip_entry]()
    suite^.run()
