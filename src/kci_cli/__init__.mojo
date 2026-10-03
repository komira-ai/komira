# =============================================================================
# kci_cli: the `kci` command line, one binary (bin/kci is its `main`).
# =============================================================================
#
#   `kci run --stage S`  THE verb for stages: every step of stage S of the
#                        machine file, in order (there is no per-kind verb
#                        and no alias)
#   `kci ci check`       a CI workflow held to the machine file's stages
#
#   * args.mojo           the one parser: `parse_kci_args`, `KciCommand`,
#                         `require_stage_flags`, `DEFAULT_MACHINE_FILE`,
#                         `KCI_USAGE`
#   * recorder.mojo       `CliRecorder`: the result document, written
#                         temp-and-rename to `--result-file`
#   * dispatch.mojo       `StageSteps` (one method per step kind),
#                         `run_stage_with`, `ci_check_with`, `kci_main_with`
#   * library_verbs.mojo  `LibrarySteps` (kci_build, kci_publish), the
#                         composed secret store, `kci_main`
#
# A thin shell: flags and the machine file -> one request per step -> the
# library. All step logic lives in kci_build and kci_publish; every exit
# number and outcome word is kci_contract's.
# =============================================================================

from kci_cli.args import (
    CLI_VERB_CI_CHECK,
    CLI_VERB_HELP,
    CLI_VERB_RUN,
    DEFAULT_MACHINE_FILE,
    KCI_USAGE,
    KciCommand,
    SecretStoreChoice,
    build_flags,
    find_result_file,
    parse_kci_args,
    publish_flags,
    require_stage_flags,
)
from kci_cli.recorder import TMP_SUFFIX, CliRecorder, write_whole_file
from kci_cli.dispatch import StageSteps, StepEnd, ci_check_with, kci_main_with, recorder_for, run_stage_with
from kci_cli.library_verbs import ComposedSecretStore, LibrarySteps, RefusingSecretStore, kci_main
