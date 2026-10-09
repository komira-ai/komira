# =============================================================================
# src/kci_build/request.mojo -- what one BUILD step of a stage is asked to
#   do, and how it ends.
# =============================================================================
#
# Every input arrives in `BuildRequest`; nothing under kci_build reads the
# environment or parses a command line (the kci binary's one parser builds
# the request from its flags and the machine file's BUILD step).
#
# How a build ends is an OUTCOME word and an error id from kci_api;
# the exit number follows from those two (kci_api's exit table), so
# this package spells no exit number:
#
#   SUCCEEDED      every declared artifact was built and verified, and
#                  `release.json` was written; under `plan`, every
#                  artifact rendered for the resolved revision and
#                  nothing was built
#   REFUSED        an input, the checkout, or a build's output breaks the
#                  contract; later artifacts not built. Error ids:
#                  KCI-E-ARTIFACT, KCI-E-PLATFORM, KCI-E-REVISION,
#                  KCI-E-MEMBER, KCI-E-PLATFORM-MISMATCH; and KCI-E-USAGE
#                  for a path flag that names a wrong place (a work dir
#                  that is not one, a used release directory, a log dir
#                  inside the release directory), which the exit table
#                  makes exit 2 like any other command-line error: nothing
#                  was run
#   FAILED         a build exited non-zero, was killed by a signal or timed
#                  out (KCI-E-BUILD-FAILED; in the per-change check, a
#                  batch that timed out and a unit the budget left no time
#                  for are INDETERMINATE instead, below), or the run's result could not
#                  be recorded before the first effect (KCI-E-RESULT-FILE);
#                  later artifacts not built. A build leaves no external
#                  effect (member directories are local and `release.json`
#                  is never written), so a FAILED build is safe to re-run
#   INDETERMINATE  a build or a git command could not be started, timed out
#                  reading the checkout, or its output could not be read:
#                  no verdict (KCI-E-CANNOT-TELL)
#
# The per-change check (`affected_by` set, affected.mojo) adds two ids and no
# exit number: REFUSED with KCI-E-AFFECTED-VACUOUS (an empty change, or one
# that reaches no declared unit) and INDETERMINATE with KCI-E-AFFECTED (an
# affected command that could not be started, failed, timed out or answered
# outside its grammar: never a widening). A unit whose build fails is FAILED
# (KCI-E-BUILD-FAILED); time running out with no unit failed (a batch that
# timed out, units the build budget left no time for) is INDETERMINATE
# (KCI-E-CANNOT-TELL, affected_batch.mojo step 4); a file without what the check needs is REFUSED
# (KCI-E-ARTIFACT).
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_api import (
    OUTCOME_SUCCEEDED,
    RunIdentity,
    exit_code_of,
    release_platform_dir,
    require_error_id,
    require_outcome,
)

comptime DEFAULT_BUILD_TIMEOUT_S: Int = 3600
"""Seconds each build run may take, when the command line gives no
`--build-timeout-s`: one artifact on the release path; one unit or one
whole batch of units in the per-change check."""

comptime NO_BUILD_BUDGET: Int = 0
"""`BuildRequest.build_budget_s` when the command line gives no
`--build-budget-s`: the per-change check's runs are bounded by
`--build-timeout-s` each, and by nothing in total."""

comptime DEFAULT_MAX_BATCH_UNITS: Int = 32
"""The most units one batch of the per-change check builds
(`BuildRequest.max_batch_units`): a group of more is split into
ceil(n / 32) batches of near-equal size, in unit order
(affected_batch.mojo `batch_chunks`). One batch of every unit (299 on a
widened change) did not finish within --build-timeout-s (3600 s)."""

comptime MAX_BUILD_BUDGET_S: Int = 7 * 24 * 3600
"""The largest `--build-budget-s` kci takes (a week, longer than any CI
job runs): a larger one is refused, so `budget * 10^9` added to a
monotonic reading never comes near overflowing an Int."""


struct BuildRequest(Copyable, Movable):
    """The inputs of one BUILD step. `step_name` is the step's name in the
    machine file (the result's `steps[].name`). `release_dir` is the top
    release directory (`--release-dir`); this step writes only under
    `<release_dir>/<platform>` (kci_api's layout). `plan` is `kci run
    --plan`: resolve and render, build nothing (build.mojo).
    `affected_by` is `kci run --affected-by` (the change's base, a full
    commit id) or "": when set, the step is the per-change check
    (affected.mojo) and `release_dir` is not used. `build_budget_s` is
    `kci run --build-budget-s` or NO_BUILD_BUDGET; with a budget,
    `build_deadline_ns` is when it ends on the runner's monotonic clock
    (`ProcessRunner.now_ns`): kci's start plus the budget, so everything
    kci did before the step is charged to it (affected_batch.mojo, THE
    BUDGET). `max_batch_units` is the most units one batch of the
    per-change check builds (DEFAULT_MAX_BATCH_UNITS).

    Layout: owned values only. No pointer field."""

    var step_name: String
    var artifacts_file: String
    var work_dir: String
    var release_dir: String
    var log_dir: String
    var revision_id: String
    var platform: String
    var run: RunIdentity
    var build_timeout_s: Int
    var build_budget_s: Int
    var build_deadline_ns: Int
    var max_batch_units: Int
    var plan: Bool
    var affected_by: String

    def __init__(out self, var run: RunIdentity):
        self.step_name = String("")
        self.artifacts_file = String("")
        self.work_dir = String("")
        self.release_dir = String("")
        self.log_dir = String("")
        self.revision_id = String("")
        self.platform = String("")
        self.run = run^
        self.build_timeout_s = DEFAULT_BUILD_TIMEOUT_S
        self.build_budget_s = NO_BUILD_BUDGET
        self.build_deadline_ns = 0
        self.max_batch_units = DEFAULT_MAX_BATCH_UNITS
        self.plan = False
        self.affected_by = String("")

    def platform_dir(self) raises -> String:
        """`<release_dir>/<platform>`: the directory this step builds into,
        and what `{release_dir}` stands for in the artifacts."""
        return release_platform_dir(self.release_dir, self.platform)


struct BuildOutcome(Copyable, Movable):
    """How a BUILD step ended: its outcome, the error id (empty on
    success), one message, and on success the lines to print (one per
    member, then `SET_HASH <hex>`) and the set hash.

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var lines: List[String]
    var set_hash: String

    def __init__(out self, var outcome: String, var error_id: String, var message: String):
        self.outcome = outcome^
        self.error_id = error_id^
        self.message = message^
        self.lines = List[String]()
        self.set_hash = String("")

    @staticmethod
    def succeeded(var message: String) -> BuildOutcome:
        return BuildOutcome(String(OUTCOME_SUCCEEDED), String(""), message^)

    def ok(self) -> Bool:
        return self.outcome == OUTCOME_SUCCEEDED

    def exit_code(self) raises -> Int:
        """The exit number of this outcome (kci_api's exit table)."""
        require_outcome(self.outcome)
        if self.error_id.byte_length() > 0:
            require_error_id(self.error_id)
        return exit_code_of(self.outcome, self.error_id)
