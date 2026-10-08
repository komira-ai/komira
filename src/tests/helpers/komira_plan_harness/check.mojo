# =============================================================================
# komira_plan_harness/check.mojo -- one call from an expected file to a verdict.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.table import Table

from .compare import CompareReport, compare_canon
from .parse import parse_canon
from .render import render_batch, render_table


def check_batch(expected_text: String, actual: RecordBatch) raises -> CompareReport:
    """Parse the expected text, render `actual` under its policy, compare."""
    var expected = parse_canon(expected_text)
    var got = render_batch(actual, expected.policy.copy())
    return compare_canon(expected, got)


def check_table(expected_text: String, actual: Table) raises -> CompareReport:
    var expected = parse_canon(expected_text)
    var got = render_table(actual, expected.policy.copy())
    return compare_canon(expected, got)


def require_batch_matches(expected_text: String, actual: RecordBatch) raises:
    """Raise with EVERY mismatch unless `actual` matches the expected text."""
    var report = check_batch(expected_text, actual)
    if not report.ok():
        raise Error(String("canon: result differs: ") + String(report))


def require_table_matches(expected_text: String, actual: Table) raises:
    var report = check_table(expected_text, actual)
    if not report.ok():
        raise Error(String("canon: result differs: ") + String(report))
