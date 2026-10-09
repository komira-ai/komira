# =============================================================================
# kci_cli: the `kci` command line, one binary (bin/kci is its `main`).
# =============================================================================
#
#   `kci run --stage S`  kci's ONE command: every step of stage S of the
#                        machine file, in order (there is no other verb and
#                        no alias); `--only step:|validation:` selects (a
#                        SELECTIVE run), `--plan` is a dry run. Under GitHub
#                        Actions it first holds the workflow it runs under to
#                        the machine file; it reports the NEW NAMES of the
#                        stages after it; `--summary-file` gets a markdown
#                        summary
#
#   * args.mojo           the one parser: `parse_kci_args`, `KciCommand`,
#                         `selectors_of`, `require_stage_flags`, `KCI_USAGE`
#                         (the default machine file is kci_api's
#                         `DEFAULT_MACHINE_FILE`)
#   * recorder.mojo       `CliRecorder`: the result document, written
#                         temp-and-rename to `--result-file`
#   * seam.mojo           `StageSteps` (the steps and the reads around
#                         them), `StepEnd`
#   * dispatch.mojo       `run_stage_with`, `kci_main_with`,
#                         `evidence_line_of`
#   * start_checks.mojo   under GitHub Actions, at start-up: the workflow,
#                         the ref (main only; break-glass with a reason)
#                         and the set hash; `workflow_path_of`
#   * summary.mojo        `run_summary_markdown`, `promotion_line`,
#                         `break_glass_line`, `append_summary`
#   * deploy_step.mojo    a DEPLOY step: `deploy_step[S: CloudAdapter, St:
#                         StateStore]`, the `CellDeploys` seam with
#                         `CloudDeploys[S, St]` (one built-in cloud) and
#                         `NoCloudBuilt` (the kci binary: every DEPLOY step
#                         refused), `check_deploy_set_hash`, `plan_hash_of`
#   * library_verbs.mojo  `LibrarySteps` (kci_build, kci_publish), the
#                         composed secret store, `kci_main`
#
# A thin shell: flags and the machine file -> one request per step -> the
# library. All step logic lives in kci_build and kci_publish; every exit
# number and outcome word is kci_api's.
# =============================================================================

from kci_cli.args import (
    CLI_VERB_HELP,
    CLI_VERB_RUN,
    KCI_USAGE,
    KciCommand,
    SecretStoreChoice,
    build_flags,
    find_result_file,
    find_summary_file,
    parse_kci_args,
    publish_flags,
    validation_flags,
    require_stage_flags,
    selectors_of,
)
from kci_cli.recorder import TMP_SUFFIX, CliRecorder, write_whole_file
from kci_cli.seam import StageSteps, StepEnd
from kci_cli.start_checks import (
    GITHUB_ACTIONS,
    GITHUB_ACTOR,
    GITHUB_EVENT_NAME,
    GITHUB_REF,
    GITHUB_REPOSITORY,
    GITHUB_SHA,
    GITHUB_WORKFLOW_REF,
    GITHUB_WORKFLOW_SHA,
    MAIN_TRACKING_REF,
    NOT_UNDER_GITHUB_ACTIONS,
    workflow_path_of,
)
from kci_cli.dispatch import (
    evidence_line_of,
    kci_main_with,
    recorder_for,
    run_stage_with,
    validation_failure_message,
)
from kci_cli.summary import (
    append_summary,
    break_glass_line,
    carried_markdown,
    deploy_markdown,
    promotion_line,
    run_summary_markdown,
)
from kci_cli.deploy_step import (
    NOT_BUILT_WITH,
    CellDeploys,
    CloudDeploys,
    DeployRequest,
    NoCloudBuilt,
    check_deploy_set_hash,
    deploy_request,
    deploy_step,
    plan_hash_of,
)
from kci_cli.library_verbs import ComposedSecretStore, LibrarySteps, RefusingSecretStore, git_first_parent, git_history, git_is_ancestor, kci_main
