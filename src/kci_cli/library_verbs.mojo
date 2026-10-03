# =============================================================================
# src/kci_cli/library_verbs.mojo -- the real verbs: compose the stores, call
#   the library.
# =============================================================================
#
#   build    -> kci_build.build_main (its SupervisorRunner for the builds and
#               for git). No secret is resolved.
#   publish  -> kci_publish.publish_main_with_store over the store the shell
#               composed from --secret-store:
#                 none  RefusingSecretStore: resolves nothing; a channel whose
#                       credential is an API token is refused naming the
#                       secret and the option that would resolve it;
#                 env   EnvSecretStore[ProcessEnv] (komira_secret_env): the
#                       secret NAME is the environment variable's name.
#               An OIDC channel resolves no secret at all, whichever store.
#
# Nothing here parses a verb flag, reads a file or opens a socket: that is
# the libraries' work.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_secret_env import EnvSecretStore, ProcessEnv
from komira_secret_store import SecretStore, SecretValue

from kci_build import build_main
from kci_publish import publish_main_with_store

from .args import SecretStoreChoice
from .dispatch import KciVerbs, kci_main_with


struct RefusingSecretStore(SecretStore, Movable):
    """`--secret-store=none`: holds nothing and says which option would
    resolve the name. Layout: no fields."""

    def __init__(out self):
        pass

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        raise Error(
            String("kci was run with --secret-store=none, so the secret '")
            + secret_ref
            + String("' cannot be resolved; pass --secret-store=env (before the verb) to read")
            + String(" the environment variable of that name")
        )


struct LibraryVerbs(KciVerbs, Movable):
    """The verbs as the kci binary runs them. Layout: no fields."""

    def __init__(out self):
        pass

    def build(mut self, args: List[String]) -> Int:
        return build_main(args)

    def publish(mut self, args: List[String], store: SecretStoreChoice) -> Int:
        if store == SecretStoreChoice.ENV:
            var env = EnvSecretStore[ProcessEnv](ProcessEnv())
            return publish_main_with_store(args, env)
        var none = RefusingSecretStore()
        return publish_main_with_store(args, none)


def kci_main(args: List[String]) -> Int:
    """The kci binary: `args` is argv without the program name."""
    var verbs = LibraryVerbs()
    return kci_main_with(args, verbs)
