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
#   * dispatch.mojo       `StageSteps` (the steps and the reads around them),
#                         `run_stage_with`, `kci_main_with`,
#                         `run_summary_markdown`, `workflow_path_of`
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
    require_stage_flags,
    selectors_of,
)
from kci_cli.recorder import TMP_SUFFIX, CliRecorder, write_whole_file
from kci_cli.dispatch import (
    GITHUB_ACTIONS,
    GITHUB_REPOSITORY,
    GITHUB_WORKFLOW_REF,
    GITHUB_WORKFLOW_SHA,
    NOT_UNDER_GITHUB_ACTIONS,
    StageSteps,
    StepEnd,
    append_summary,
    kci_main_with,
    recorder_for,
    refused_validations,
    run_stage_with,
    run_summary_markdown,
    workflow_path_of,
)
from kci_cli.library_verbs import ComposedSecretStore, LibrarySteps, RefusingSecretStore, kci_main
