"""`kci_validator_report` — the one report library every validator shares.

⛔ THIS LIBRARY PRODUCES EVIDENCE, NOT AUTHORIZATION. NOTHING MAY GATE ON IT.
The record it renders is written by the party being gated, into a bucket that
party can write, and a stricter reader of a file the gated party writes is a
formality, not evidence. The gate stays the EXIT CODE (`report_exit_code`, here)
and the BUILD GRAPH (a test marker is an input to the artifact). See `state.mojo`
and `document.mojo` for the full statement; it is repeated in three places on
purpose, including inside the rendered JSON, because the reader who reaches for
this record as a green light will be reading the bytes, not the header.

── WHY THIS PACKAGE EXISTS ──────────────────────────────────────────────────
A validator that folds dozens of rows across several matrices into ONE exit bit,
with the rows surviving only in a job's stdout (which the validate DAG cannot
read), leaves no durable statement of WHICH row failed or WHY.

A verdict is non-vacuous only if the report model carries three things: an
`asserted_count()` DENOMINATOR, a three-conjunct `all_passed()` that includes the
positional accounting fault, and a TYPED abstention. This package is that model
as a leaf, wide enough to fit validators that have no HTTP shape at all.

── ⚠ WHY IT IS A LEAF ───────────────────────────────────────────────────────
A report model that lives inside a validator which drives a service over TLS
drags an HTTP client and an async runtime into every adopter, and then copying
forty lines is cheaper than taking the dep — so everyone copies. Shared validator
libraries get adopted only when they have no deps, no pointers and no FFI, which
is what `kci_validator_rows` and `validator_target_lib` both state in their
headers.

⇒ ★ THE ONE DEP OF THIS PACKAGE IS `kci_validator_rows`, which is itself
dep-free. One zero-closure leaf on another. No HTTP, no async, no clock, no store,
no FFI, no cloud. THAT is the property that makes adoption cheaper than a copy,
and it is the property to defend.

⚠ A `.mojoc` package does not inline transitive code, so a consumer compiles
against BOTH `kci_validator_report` AND `kci_validator_rows`. The build's `deps`
carries that closure; the re-exports below buy a consumer ONE IMPORT LINE.

── WHAT LIVES HERE ──────────────────────────────────────────────────────────
  state.mojo     the CLOSED row-state vocabulary (PASSED / FAILED / NOT_RUN /
                 NOT_REACHED / UNREADABLE), the CLOSED version-source vocabulary,
                 and the three-valued exit codes.
  row.mojo       `RowResult` + the constructors that keep the simple case four
                 lines (`row_passed`, `row_failed`, `row_not_run`,
                 `row_not_reached`, `row_unreadable`, `http_row`).
  target.mojo    `ReportTarget` — a (NAME, VERSION/HASH) pair with the label
                 that makes the version citable — and `ReportGuard`.
  outcome.mojo   `MatrixOutcome` (rows + authored spec + targets), the counting,
                 and `report_exit_code` — THE GATE.
  document.mojo  `render_step_document` — the `VALIDATION_SCHEMA` record, and
                 the ONE key derivation writer and reader share.

Mojo 1.0.0b2 (def-only).
"""

# ── the state vocabularies ───────────────────────────────────────────────────
from kci_validator_report.state import (
    ROW_PASSED,
    ROW_FAILED,
    ROW_NOT_RUN,
    ROW_NOT_REACHED,
    ROW_UNREADABLE,
    row_state_token,
    row_state_is_known,
    VERSION_SOURCE_LIVE_SERVING,
    VERSION_SOURCE_AUTHORED_MANIFEST,
    VERSION_SOURCE_STAGED_LEDGER,
    VERSION_SOURCE_NONE,
    version_source_is_known,
    TARGET_KIND_SERVICE,
    TARGET_KIND_WEB_CONTENT,
    TARGET_KIND_PROBE,
    TARGET_KIND_SHARED_INFRASTRUCTURE,
    REPORT_EXIT_OK,
    REPORT_EXIT_FAILED,
    REPORT_EXIT_CENSUS_FAULT,
)

# ── the row ──────────────────────────────────────────────────────────────────
from kci_validator_report.row import (
    RowResult,
    NO_TARGET,
    NO_STATUS,
    row_passed,
    row_failed,
    row_not_run,
    row_not_reached,
    row_unreadable,
    http_row,
    http_row_predicate,
    with_target,
)

# ── the target + the guard ───────────────────────────────────────────────────
from kci_validator_report.target import (
    ReportTarget,
    ReportGuard,
    served_target,
    # ★ THE SAFE `LIVE_SERVING` CONSTRUCTOR over a RAW live image reference, and
    # the digest split it refuses a tag with. `served_target` stamps LIVE_SERVING
    # on whatever the caller hands it; this one decides.
    digest_pinned_by,
    live_serving_target,
    unversioned_target,
    shared_infrastructure_target,
    guard_held,
    guard_broken,
    targets_fault,
    guards_fault,
)

# ── the leg + the verdict ────────────────────────────────────────────────────
from kci_validator_report.outcome import (
    MatrixOutcome,
    DEFAULT_VALIDATOR_NAME,
    DEFAULT_LEG_NAME,
    copy_row_spec,
    single_row_outcome,
    combine_outcomes,
    run_census_fault,
    report_exit_code,
)

# ── the record ───────────────────────────────────────────────────────────────
from kci_validator_report.document import (
    VALIDATION_SCHEMA,
    DOC_KIND_STEP,
    DOC_KIND_RUN,
    NOT_A_GATE_NOTICE,
    VALIDATION_RAW_PREFIX,
    RECORD_LINE_WRITTEN,
    RECORD_LINE_NOT_WRITTEN,
    validation_step_key,
    run_date_from_micros,
    json_quote,
    render_step_document,
    # ── §5, the RUN half: the selectivity a validator cannot see ─────────────
    DOC_KIND_LATEST,
    EVIDENCE_NOT_EMITTED,
    AUDIENCE_OPERATOR_INTERNAL,
    STEP_RECORD_WRITTEN,
    STEP_RECORD_NOT_WRITTEN,
    RESERVED_RUN_STEP_NAME,
    VALIDATION_LATEST_PREFIX,
    refuse_reserved_step_name,
    validation_run_key,
    validation_latest_key,
    render_latest_pointer,
    render_run_document,
)

# ★ THE POSITIONAL ACCOUNTING, RE-EXPORTED so a new adopter writes ONE import
# line for the spec AND the report. `kci_validator_rows` stays the DEFINING
# package — existing consumers are untouched — but a validator adopting this leaf
# should not have to know that the spec type lives one package over.
from kci_validator_rows import (
    ExpectedRow,
    expected_row,
    expected_names,
    expected_count,
    spec_fault,
    plan_lines,
    first_name_divergence,
    row_accounting_fault,
)
