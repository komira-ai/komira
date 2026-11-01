# =============================================================================
# kci_validator_rows — ★ THE ONE POSITIONAL ROW-ACCOUNTING MODEL every managed-
#   app validator shares.
# =============================================================================
#
# ── WHAT IT REPLACES, AND WHY ────────────────────────────────────────────────
# A validator that decides its verdict with
#
#     return self.passed_count() == self.total() and self.total() > 0
#
# where `total()` is `len(self.rows)` prints PASS for a truncated run. The
# denominator is whatever the run emitted, so a matrix that emitted a PREFIX of
# its rows and returned prints PASS.
#
# The fix is positional name accounting against an authored list, shared by
# every validator.
#
# ── THREE FILES, THREE QUESTIONS ─────────────────────────────────────────────
#   live.mojo        ★ WHEN IS A ROW OBSERVABLE? `emit_live_row` — the row goes
#                    to stdout, FLUSHED, the moment it completes, so a run that
#                    is cancelled/SIGKILLed/OOMed still yields everything that
#                    had finished. The end-of-run report is UNCHANGED; this is
#                    additional, differently-marked output. See its header for
#                    why.
#   spec.mojo        WHAT DOES THIS MATRIX PROMISE? `ExpectedRow(name, asserts)`
#                    in emission order, plus the spec's OWN falsifier
#                    (`spec_fault`) — empty spec, blank name, blank obligation,
#                    duplicate name.
#   accounting.mojo  DID IT DELIVER? `row_accounting_fault` — positional, first
#                    divergence named with BOTH names. Plus
#                    `validator_exit_code`, so a test can assert the code the
#                    binary exits with rather than a boolean it must trust.
#
# ── NO DEPS, ON PURPOSE ──────────────────────────────────────────────────────
# Pure `String` / `List` work. No runtime library, no FFI, no transport, no
# clock. Every validator can take this dep for one line without dragging a
# closure in, and every function here is falsifiable with no process.
# =============================================================================

from kci_validator_rows.spec import (
    ExpectedRow,
    expected_row,
    expected_names,
    expected_count,
    spec_fault,
    plan_lines,
)

from kci_validator_rows.accounting import (
    first_name_divergence,
    row_accounting_fault,
    validator_exit_code,
)

from kci_validator_rows.live import (
    LIVE_ROW_MARKER,
    emit_live_row,
    live_row_line,
)
