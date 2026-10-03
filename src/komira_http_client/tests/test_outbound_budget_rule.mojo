# =============================================================================
# test_outbound_budget_rule.mojo — the falsifier for "a budget may not exceed
#   the deadline of the context it runs inside".
# =============================================================================
#
# BOTH DIRECTIONS ARE ASSERTED HERE, and the second is the one that makes this
# NOT a blanket reduction:
#
#   (1) a REQUEST-SCOPED client that would outlive its request is clamped, and
#       the excess is reported;
#   (2) a NON-REQUEST client — a Cloud Run job, a pod, a CLI, a bench, a test —
#       KEEPS the generous 600s default, byte-identically.
#
# Every case here is PURE: the platform values are arguments, supplied by the
# process from its own configuration.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.outbound_budget import (
    CLOUD_RUN_REQUEST_CEILING_US,
    OUTBOUND_BUDGET_DEFAULT_US,
    OUTBOUND_CEILING_NONE,
    OUTBOUND_CEILING_RESERVE_US,
    largest_permissible_budget_us,
    outbound_budget_exceeds_ceiling,
    outbound_budget_refusal_detail,
    outbound_budget_us,
    serving_request_ceiling_us,
)
from komira_http_client.client import HttpClientConfig
from komira_http_client.state_machine import OutboundDriver


def _none() -> String:
    """An UNSET platform value. `""` stands for both "not configured" and
    "configured empty", and the rule is written to treat them identically."""
    return String("")


def _set() -> String:
    """A marker the platform injected. Its VALUE never matters to the rule (a
    service is a service whatever its name is); only its presence does."""
    return String("a-platform-injected-value")

# A per-outbound unit budget a higher-layer caller might author (20s), restated
# as a literal. It is asserted to survive the rule VERBATIM — a caller that knows its
# own share must keep it.
comptime _UNIT_BUDGET_US: Int = 20_000_000


# =============================================================================
# §1 — the DISCRIMINATOR: which container am I inside?
# =============================================================================


def test_a_cloud_run_service_is_inside_a_300s_request() raises:
    """`K_SERVICE` (or `K_REVISION` / `K_CONFIGURATION`) => a 300s ceiling.

    The platform default, not a choice: Cloud Run's `timeoutSeconds` defaults
    to 300."""
    assert_equal(
        serving_request_ceiling_us(
            _set(), _none(), _none(), _none(), _none(), _none()
        ),
        CLOUD_RUN_REQUEST_CEILING_US,
        msg="K_SERVICE must resolve to the Cloud Run request ceiling",
    )
    assert_equal(
        serving_request_ceiling_us(
            _none(), _set(), _none(), _none(), _none(), _none()
        ),
        CLOUD_RUN_REQUEST_CEILING_US,
        msg="K_REVISION alone must resolve to the same ceiling",
    )
    assert_equal(
        serving_request_ceiling_us(
            _none(), _none(), _set(), _none(), _none(), _none()
        ),
        CLOUD_RUN_REQUEST_CEILING_US,
        msg="K_CONFIGURATION alone must resolve to the same ceiling",
    )


def test_a_cloud_run_job_is_inside_no_request_at_all() raises:
    """A JOB has a task timeout, not a request deadline. Nothing to outlive."""
    assert_equal(
        serving_request_ceiling_us(
            _none(), _none(), _none(), _set(), _none(), _none()
        ),
        OUTBOUND_CEILING_NONE,
        msg="CLOUD_RUN_JOB must resolve to NO ceiling",
    )
    assert_equal(
        serving_request_ceiling_us(
            _none(), _none(), _none(), _none(), _set(), _none()
        ),
        OUTBOUND_CEILING_NONE,
        msg="CLOUD_RUN_EXECUTION must resolve to NO ceiling",
    )


def test_a_job_that_also_carries_service_identity_is_still_a_job() raises:
    """★ THE ORDER ASSERTION, and it is the one that stops this being a blanket
    reduction of every batch task.

    Some Cloud Run job runtimes hand the container `K_SERVICE`-shaped identity
    as well. Asking "is it a service" first would classify EVERY such job as
    request-scoped and clamp a batch task that legitimately runs for minutes —
    the exact false positive the 600s default exists to avoid. Asking "is it a
    job" first cannot make the opposite mistake: `CLOUD_RUN_JOB` is never
    injected into a service."""
    assert_equal(
        serving_request_ceiling_us(_set(), _set(), _set(), _set(), _set(), _none()),
        OUTBOUND_CEILING_NONE,
        msg=(
            "a JOB marker must win over SERVICE identity — otherwise a batch"
            " task inherits a request ceiling it does not live inside"
        ),
    )


def test_an_undeployed_process_has_no_ceiling() raises:
    """A CLI, a bench, a test, a dev process. This is the arm every existing
    test in the repo takes, which is why they are byte-identical after the
    change."""
    assert_equal(
        serving_request_ceiling_us(
            _none(), _none(), _none(), _none(), _none(), _none()
        ),
        OUTBOUND_CEILING_NONE,
        msg="no marker => no ceiling",
    )


def test_lambda_reports_no_ceiling_and_that_is_a_known_gap() raises:
    """⛔ PINS A GAP, DOES NOT CLAIM A FIX.

    A Lambda invocation has a hard deadline and the runtime API delivers it
    per-invocation in `Lambda-Runtime-Deadline-Ms`. That header is read NOWHERE
    in this tree, so there is no value to clamp against, and GUESSING a function
    timeout would clamp correct calls on a 15-minute function. NONE is the
    honest answer until the header is threaded.

    This test goes RED the day somebody wires it — which is the point: the
    follow-on lands with the assertion that proves it landed."""
    assert_equal(
        serving_request_ceiling_us(
            _none(), _none(), _none(), _none(), _none(), _set()
        ),
        OUTBOUND_CEILING_NONE,
        msg=(
            "Lambda must report NO ceiling until Lambda-Runtime-Deadline-Ms is"
            " threaded; a guessed function timeout would clamp correct calls"
        ),
    )


# =============================================================================
# §2 — DIRECTION (2): a NON-REQUEST client keeps its long budget.
# =============================================================================


def test_no_ceiling_keeps_the_generous_default_byte_identically() raises:
    """The half that makes this not a blanket reduction. Unchanged behaviour for
    every job, pod, CLI, bench and test — i.e. for every existing test in the
    repo, which is why none of them had to change."""
    assert_equal(
        outbound_budget_us(0, OUTBOUND_CEILING_NONE),
        OUTBOUND_BUDGET_DEFAULT_US,
        msg="no ceiling + no authored budget => the 600s default, unchanged",
    )
    assert_equal(
        largest_permissible_budget_us(OUTBOUND_CEILING_NONE),
        OUTBOUND_BUDGET_DEFAULT_US,
        msg="no ceiling => the default is the largest permissible",
    )


def test_the_default_here_is_the_drive_loops_own_default() raises:
    """★ THE ANTI-FORK ASSERTION.

    `OUTBOUND_BUDGET_DEFAULT_US` is restated in `outbound_budget.mojo` rather
    than imported from `state_machine.mojo`, so that the RULE stays pure and
    testable in isolation. That restatement is exactly how two defaults silently
    diverge. This asserts they are one number by DRIVING the real driver: a
    driver with no configured timeout must produce the same deadline the rule
    would."""
    var driver = OutboundDriver.new(List[UInt8]())
    var started_us = 1_000_000
    assert_equal(
        driver._effective_deadline_us(started_us) - started_us,
        OUTBOUND_BUDGET_DEFAULT_US,
        msg=(
            "the rule's default and the drive loop's default have FORKED —"
            " outbound_budget.mojo and state_machine.mojo must state one number"
        ),
    )


def test_an_explicit_budget_inside_the_ceiling_survives_verbatim() raises:
    """A caller that knows its own share KEEPS it. A 20s unit budget and
    a 30s probe budget pass through untouched — the rule is a
    ceiling, not an allowance."""
    assert_equal(
        outbound_budget_us(_UNIT_BUDGET_US, CLOUD_RUN_REQUEST_CEILING_US),
        _UNIT_BUDGET_US,
        msg="a 20s unit budget must survive the rule verbatim",
    )
    assert_equal(
        outbound_budget_us(30_000_000, CLOUD_RUN_REQUEST_CEILING_US),
        30_000_000,
        msg="a 30s probe budget must survive verbatim",
    )
    assert_false(
        outbound_budget_exceeds_ceiling(
            _UNIT_BUDGET_US, CLOUD_RUN_REQUEST_CEILING_US
        ),
        msg="20s inside a 300s ceiling is not an excess",
    )


# =============================================================================
# §3 — DIRECTION (1): a REQUEST-SCOPED client cannot outlive its request.
# =============================================================================


def test_the_unauthored_budget_is_derived_not_inherited() raises:
    """★ THE HEADLINE. `with_defaults` authors NO budget, so pre-fix it
    inherited 600s — inside a 300s request. The rule derives one instead."""
    var budget = outbound_budget_us(0, CLOUD_RUN_REQUEST_CEILING_US)
    assert_true(
        budget < CLOUD_RUN_REQUEST_CEILING_US,
        msg=(
            "an unauthored budget inside a 300s request must be STRICTLY"
            " inside it; got " + String(budget)
        ),
    )
    assert_true(
        budget < OUTBOUND_BUDGET_DEFAULT_US,
        msg="it must no longer inherit the 600s default",
    )
    assert_equal(
        budget,
        CLOUD_RUN_REQUEST_CEILING_US - OUTBOUND_CEILING_RESERVE_US,
        msg="the derived budget is ceiling - reserve",
    )


def test_an_authored_budget_over_the_ceiling_is_reported_and_clamped() raises:
    """An AUTHORED excess is a statement about the world that is false, so it is
    reported as well as clamped. `outbound_budget_exceeds_ceiling` is what a
    caller already in a `raises` context turns into a refusal in one line.

    MEASURED: today ZERO call sites author a budget over 300s — the largest in
    the tree is 60s, and the ONLY 600s literal is the drive loop's own default.
    So this predicate changes nothing today and is a ratchet against the next
    one."""
    assert_true(
        outbound_budget_exceeds_ceiling(
            OUTBOUND_BUDGET_DEFAULT_US, CLOUD_RUN_REQUEST_CEILING_US
        ),
        msg="600s authored inside a 300s request must be reported as an excess",
    )
    assert_equal(
        outbound_budget_us(
            OUTBOUND_BUDGET_DEFAULT_US, CLOUD_RUN_REQUEST_CEILING_US
        ),
        CLOUD_RUN_REQUEST_CEILING_US - OUTBOUND_CEILING_RESERVE_US,
        msg="an authored excess clamps to the largest permissible budget",
    )
    var detail = outbound_budget_refusal_detail(
        OUTBOUND_BUDGET_DEFAULT_US, CLOUD_RUN_REQUEST_CEILING_US
    )
    assert_true(
        "600s" in detail and "300s" in detail and "295s" in detail,
        msg=(
            "the refusal must name the authored budget, the ceiling AND the"
            " largest permissible budget; got: " + detail
        ),
    )


def test_an_unauthored_budget_is_not_an_excess() raises:
    """`requested <= 0` means "nobody authored a number", which is a DERIVATION
    case, not a violation. Reporting it as an excess would fire on all 118 sites
    and say nothing."""
    assert_false(
        outbound_budget_exceeds_ceiling(0, CLOUD_RUN_REQUEST_CEILING_US),
        msg="an unauthored budget is derived, not refused",
    )
    assert_false(
        outbound_budget_exceeds_ceiling(-1, CLOUD_RUN_REQUEST_CEILING_US),
        msg="a negative budget is the same 'unauthored' case",
    )


def test_a_ceiling_smaller_than_the_reserve_still_yields_a_positive_budget(
) raises:
    """A pathological container (a sub-5s request timeout) must not produce a
    non-positive budget: downstream, `<= 0` is read as "use the default" — i.e.
    exactly the bug this file closes, reintroduced by an arithmetic edge."""
    assert_equal(
        largest_permissible_budget_us(1_000_000),
        1_000_000,
        msg="a 1s ceiling yields a 1s budget, never 0 or negative",
    )
    assert_true(
        outbound_budget_us(0, 1_000_000) > 0,
        msg="a derived budget must always be positive",
    )
    assert_true(
        outbound_budget_us(0, OUTBOUND_CEILING_RESERVE_US) > 0,
        msg="a ceiling exactly equal to the reserve must not yield 0",
    )


# =============================================================================
# §4 — THE WIRING. The rule is only worth anything if `with_defaults` uses it.
# =============================================================================
#
# §1-§3 test the rule. This section tests that the rule REACHES the client
# config, which is a different claim and the one that regresses silently: the
# rule could be perfect and `HttpClientConfig.for_serving_ceiling` could keep
# returning `request_timeout_us = 0`, and every assertion above would still be
# green. `defaults()` is `for_serving_ceiling(OUTBOUND_CEILING_NONE)`.


def test_a_request_scoped_config_cannot_outlive_its_request() raises:
    """★ THE WIRING ASSERTION. Pre-fix this went RED: `defaults()` returned
    `request_timeout_us = 0`, which the drive loop reads as 600s — inside a 300s
    request."""
    var cfg = HttpClientConfig.for_serving_ceiling(CLOUD_RUN_REQUEST_CEILING_US)
    assert_true(
        cfg.request_timeout_us > 0,
        msg=(
            "a request-scoped config must carry a POSITIVE budget: 0 is read"
            " downstream as 'use the 600s default', i.e. the defect itself"
        ),
    )
    assert_true(
        cfg.request_timeout_us < CLOUD_RUN_REQUEST_CEILING_US,
        msg=(
            "the budget must be STRICTLY inside the request that contains it;"
            " got " + String(cfg.request_timeout_us)
        ),
    )
    assert_true(
        cfg.budget_was_clamped(),
        msg="a request-scoped config must REPORT that its budget was derived",
    )
    assert_equal(
        cfg.context_ceiling_us,
        CLOUD_RUN_REQUEST_CEILING_US,
        msg="the config must carry the ceiling it was derived from",
    )


def test_a_non_request_config_is_byte_identical_to_pre_fix() raises:
    """★ THE OTHER DIRECTION, and the one that keeps this from being a blanket
    reduction. A Cloud Run job / pod / CLI / bench / test keeps
    `request_timeout_us = 0` — the exact pre-fix value, which the drive loop
    resolves to the generous 600s default."""
    var cfg = HttpClientConfig.for_serving_ceiling(OUTBOUND_CEILING_NONE)
    assert_equal(
        cfg.request_timeout_us,
        OUTBOUND_BUDGET_DEFAULT_US,
        msg=(
            "a config with no containing deadline must resolve to the generous"
            " default — a local-LLM generation legitimately runs for minutes"
        ),
    )
    assert_false(
        cfg.budget_was_clamped(),
        msg="nothing was clamped where there is no ceiling to clamp against",
    )
    assert_equal(
        cfg.context_ceiling_us,
        OUTBOUND_CEILING_NONE,
        msg="no ceiling recorded where there is none",
    )


def test_an_authored_budget_survives_the_client_constructor() raises:
    """`with_request_timeout_us` resolves through the same rule, and for every
    caller in the tree today that is a NO-OP: the largest authored budget
    anywhere is 60s, well inside a 300s ceiling. This pins that the resolution
    did not start eating authored budgets."""
    assert_equal(
        outbound_budget_us(
            _UNIT_BUDGET_US,
            HttpClientConfig.for_serving_ceiling(
                CLOUD_RUN_REQUEST_CEILING_US
            ).context_ceiling_us,
        ),
        _UNIT_BUDGET_US,
        msg="an authored 20s budget must reach the wire as 20s",
    )
    assert_equal(
        outbound_budget_us(
            60_000_000,
            HttpClientConfig.for_serving_ceiling(
                OUTBOUND_CEILING_NONE
            ).context_ceiling_us,
        ),
        60_000_000,
        msg="an authored 60s budget off-platform must reach the wire as 60s",
    )


def main() raises:
    test_a_cloud_run_service_is_inside_a_300s_request()
    test_a_cloud_run_job_is_inside_no_request_at_all()
    test_a_job_that_also_carries_service_identity_is_still_a_job()
    test_an_undeployed_process_has_no_ceiling()
    test_lambda_reports_no_ceiling_and_that_is_a_known_gap()
    test_no_ceiling_keeps_the_generous_default_byte_identically()
    test_the_default_here_is_the_drive_loops_own_default()
    test_an_explicit_budget_inside_the_ceiling_survives_verbatim()
    test_the_unauthored_budget_is_derived_not_inherited()
    test_an_authored_budget_over_the_ceiling_is_reported_and_clamped()
    test_an_unauthored_budget_is_not_an_excess()
    test_a_ceiling_smaller_than_the_reserve_still_yields_a_positive_budget()
    test_a_request_scoped_config_cannot_outlive_its_request()
    test_a_non_request_config_is_byte_identical_to_pre_fix()
    test_an_authored_budget_survives_the_client_constructor()
    print("test_outbound_budget_rule: OK")
