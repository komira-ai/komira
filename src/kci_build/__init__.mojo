# =============================================================================
# kci_build -- `kci build`: build the publishable Buck2 targets on the farm,
#   check every package against its manifest, and lay them out for
#   `kci publish`.
# =============================================================================
#
#   request.mojo            BuildRequest, BuildOutcome, the exit codes
#   allowlist.mojo          the publishable list
#   runner.mojo             the ProcessRunner seam: RunSpec, RunResult
#   supervisor_runner.mojo  SupervisorRunner: real processes (komira_supervisor)
#   scripted_runner.mojo    ScriptedRunner: the test double
#   preflight.mojo          the farm checks that run before any build
#   report.mojo             reading buck2's build report
#   build.mojo              the one buck2 build, and farm-fault rebuilds
#   emit.mojo               verify against the manifests, then copy out
#   flags.mojo, cli.mojo    the verb: build_publishable, build_main_with
# =============================================================================

from kci_build.allowlist import (
    PublishableEntry,
    label_problem,
    parse_publishable,
    read_publishable,
    select_publishable,
)
from kci_build.build import build_targets, is_farm_fault
from kci_build.cli import build_main, build_main_with, build_publishable, probe_nonce
from kci_build.emit import (
    VerifiedArtifact,
    check_out_dir,
    emit_artifacts,
    file_sha256_hex,
    verify_artifacts,
)
from kci_build.flags import BUILD_USAGE, BuildFlags, parse_build_flags
from kci_build.preflight import FARM_PROPERTIES_KEY, preflight
from kci_build.report import DEFAULT_OUTPUTS, TargetResult, parse_build_report, read_build_report
from kci_build.request import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    FARM_FAULT_ATTEMPTS,
    MANIFEST_SUB_TARGET,
    BuildOutcome,
    BuildRequest,
)
from kci_build.runner import STDERR_TAIL_BYTES, ProcessRunner, RunResult, RunSpec, tail_text
from kci_build.scripted_runner import ANY_ARG, ScriptedRunner, ScriptedStep, write_text_file
from kci_build.supervisor_runner import SupervisorRunner
