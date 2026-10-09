# =============================================================================
# kci_build -- one BUILD step of a stage: one build per declared artifact,
#   each into its own empty directory, every result verified, then
#   `release.json`.
# =============================================================================
#
#   request.mojo            BuildRequest, BuildOutcome (an outcome word and
#                           an error id from kci_api; no exit number)
#   runner.mojo             the ProcessRunner seam: RunSpec (with an optional
#                           explicit child environment), RunResult
#   revision.mojo           derive_release_stamp: --revision-id checked
#                           against the checkout, the stamp derived from git
#   supervisor_runner.mojo  SupervisorRunner: real processes (komira_supervisor)
#   scripted_runner.mojo    ScriptedRunner: the test double
#   build.mojo              run_build: the flow (and the --plan path), and
#                           the step's part of the run's result document
#   affected.mojo           run_affected: the per-change check
#                           (`--affected-by`): the change, each build
#                           system's affected command, exactly the units it
#                           reaches built (every unit when WIDENED)
#   affected_batch.mojo     build_affected_units: those units built in one
#                           run per shared build_targets command, a failed
#                           batch retried unit by unit to name its failures,
#                           every run within the --build-budget-s budget
#
# What to build, and with which program, is the artifacts file's
# (kci_artifact); what a build must leave is checked by
# kci_release_set.verify_member, the same function a PUBLISH step runs. The
# command line is the kci binary's (`kci run`, its one command); this package
# parses none.
# =============================================================================

from kci_build.affected import run_affected
from kci_build.affected_batch import MAX_FAILED_UNITS, build_affected_units, run_timeout_s
from kci_build.build import check_log_dir, check_platform_dir, resolved_path, run_build
from kci_build.request import (
    DEFAULT_BUILD_TIMEOUT_S,
    MAX_BUILD_BUDGET_S,
    NO_BUILD_BUDGET,
    BuildOutcome,
    BuildRequest,
)
from kci_build.revision import (
    CHANGED_FILES_NAME,
    GIT_PROGRAM,
    GIT_TIMEOUT_S,
    ChangedFiles,
    StampResult,
    changed_files,
    derive_release_stamp,
)
from kci_build.runner import (
    STDERR_TAIL_BYTES,
    ProcessRunner,
    RunResult,
    RunSpec,
    check_child_env,
    env_entry_name,
    tail_text,
)
from kci_build.scripted_runner import ANY_ARG, ScriptedRunner, ScriptedStep, write_text_file
from kci_build.supervisor_runner import SupervisorRunner
