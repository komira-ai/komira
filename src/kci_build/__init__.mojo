# =============================================================================
# kci_build -- `kci build`: one build per declared artifact, each into its
#   own empty directory, every result verified, then `release.json`.
# =============================================================================
#
#   request.mojo            BuildRequest, BuildOutcome, the exit codes
#   runner.mojo             the ProcessRunner seam: RunSpec, RunResult
#   supervisor_runner.mojo  SupervisorRunner: real processes (komira_supervisor)
#   scripted_runner.mojo    ScriptedRunner: the test double
#   build.mojo              build_release: the flow
#   flags.mojo, cli.mojo    the verb: build_main, build_main_with
#
# What to build, and with which program, is the declarations file's
# (kci_artifact_declaration); what a build must leave is checked by
# kci_release_set.verify_member, the same function `kci publish` runs.
# =============================================================================

from kci_build.build import build_release, check_out_dir
from kci_build.cli import build_main, build_main_with
from kci_build.flags import BUILD_USAGE, BuildFlags, parse_build_flags
from kci_build.request import (
    DEFAULT_BUILD_TIMEOUT_S,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    BuildOutcome,
    BuildRequest,
)
from kci_build.runner import STDERR_TAIL_BYTES, ProcessRunner, RunResult, RunSpec, tail_text
from kci_build.scripted_runner import ANY_ARG, ScriptedRunner, ScriptedStep, write_text_file
from kci_build.supervisor_runner import SupervisorRunner
