# kci_validator_report

The report model validators share. A validator records each check as a
`RowResult` (passed, failed, not run, not reached, or unreadable) in a
`MatrixOutcome`, which holds the rows, the authored row spec from
`kci_validator_rows`, and the targets the rows validated. A leg passes only if
at least one row made a claim, every asserted row passed, no row was
unreadable, and the rows emitted match the authored spec in order.
`report_exit_code` folds the legs, the targets (a `ReportTarget` names a
version and where that version came from) and any guards into a three-valued
process exit code: 0 (pass), 1 (a check failed) or 3 (the run cannot say what
it ran). That exit code is the gate; the JSON record `render_step_document`
writes is evidence, not authorization. The package is pure `String`/`List`
work and depends only on `kci_validator_rows`.

## Examples

A leg whose authored rows all ran and passed exits 0:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validator_report import MatrixOutcome, ReportTarget, ReportGuard, ExpectedRow, expected_row, http_row, row_passed, served_target, report_exit_code, REPORT_EXIT_OK

var spec: List[ExpectedRow] = [
    expected_row("livez_200", "the app answers liveness"),
    expected_row("send_ok", "a message is accepted"),
]
var leg = MatrixOutcome("example_validator", "surface", spec^)
leg.add(http_row("livez_200", "GET", "/livez", 200, 200, True, ""))
leg.add(row_passed("send_ok", "POST /send", "202", "2xx"))
assert_equal(leg.asserted_count(), 2)
assert_true(leg.all_passed())

var legs = List[MatrixOutcome]()
legs.append(leg^)
var targets: List[ReportTarget] = [served_target("example-app", "sha256:7c11aa", "")]
assert_equal(report_exit_code(legs, targets, List[ReportGuard]()), REPORT_EXIT_OK)
```

An unreadable row leaves the denominator and makes the run a census fault
(exit 3), even though every asserted row passed:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from kci_validator_report import MatrixOutcome, ReportGuard, ReportTarget, ExpectedRow, expected_row, http_row, row_unreadable, served_target, report_exit_code, REPORT_EXIT_CENSUS_FAULT

var spec2: List[ExpectedRow] = [
    expected_row("livez_200", "liveness"),
    expected_row("send_ok", "send"),
]
var leg2 = MatrixOutcome("example_validator", "surface", spec2^)
leg2.add(http_row("livez_200", "GET", "/livez", 200, 200, True, ""))
leg2.add(row_unreadable("send_ok", "POST /send", "no credential", "grant one"))
assert_equal(leg2.asserted_count(), 1)
assert_equal(leg2.asserted_passed_count(), 1)
assert_false(leg2.all_passed())

var legs2 = List[MatrixOutcome]()
legs2.append(leg2^)
var targets2: List[ReportTarget] = [served_target("example-app", "sha256:7c11aa", "")]
assert_equal(
    report_exit_code(legs2, targets2, List[ReportGuard]()),
    REPORT_EXIT_CENSUS_FAULT,
)
```

A live image reference versions a target only when it pins a digest; a tag
does not:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_validator_report import digest_pinned_by, live_serving_target, VERSION_SOURCE_LIVE_SERVING, VERSION_SOURCE_NONE

assert_equal(digest_pinned_by("repo/app@sha256:ab12"), "sha256:ab12")
assert_equal(digest_pinned_by("repo/app:latest"), "")

var pinned = live_serving_target("app", "repo/app@sha256:ab12", "")
assert_equal(pinned.version, "sha256:ab12")
assert_equal(pinned.version_source, VERSION_SOURCE_LIVE_SERVING)

var tagged = live_serving_target("app", "repo/app:latest", "")
assert_equal(tagged.version, "")
assert_equal(tagged.version_source, VERSION_SOURCE_NONE)
```

A run with no legs proves nothing, and neither does an empty target list:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validator_report import MatrixOutcome, ReportGuard, ReportTarget, combine_outcomes, run_census_fault, report_exit_code, REPORT_EXIT_CENSUS_FAULT

var no_legs = List[MatrixOutcome]()
assert_true(not combine_outcomes(no_legs))
assert_true(
    run_census_fault(no_legs, List[ReportTarget](), List[ReportGuard]()).startswith("NO TARGETS")
)
assert_equal(
    report_exit_code(no_legs, List[ReportTarget](), List[ReportGuard]()),
    REPORT_EXIT_CENSUS_FAULT,
)
```
