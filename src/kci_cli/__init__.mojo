# =============================================================================
# kci_cli: the `kci` command line, one binary with the `build` and `publish`
#   verbs (bin/kci is its `main`).
# =============================================================================
#
#   * args.mojo           kci's own options, the verb, the verb's arguments:
#                         `parse_kci_args`, `KciInvocation`,
#                         `SecretStoreChoice`, `KCI_USAGE`.
#   * dispatch.mojo       `KciVerbs` (one method per verb) and
#                         `kci_main_with`: argv to exactly one verb call.
#   * library_verbs.mojo  `LibraryVerbs`: composes the secret store and calls
#                         kci_build / kci_publish; `kci_main`.
#
# A thin shell: flags -> compose the stores -> call the library. All verb
# logic lives in kci_build and kci_publish.
# =============================================================================

from kci_cli.args import (
    EXIT_KCI_OK,
    EXIT_KCI_USAGE,
    KCI_USAGE,
    VERB_BUILD,
    VERB_PUBLISH,
    KciInvocation,
    SecretStoreChoice,
    parse_kci_args,
)
from kci_cli.dispatch import KciVerbs, kci_main_with
from kci_cli.library_verbs import LibraryVerbs, RefusingSecretStore, kci_main
