# =============================================================================
# src/kci_cli/library_verbs.mojo -- the real steps: kci_build and kci_publish
#   behind dispatch.mojo's `StageSteps` seam, and the kci binary's `main`.
# =============================================================================
#
#   BUILD    -> kci_build.run_build, with a `SupervisorRunner` for the builds
#               and another for git. No secret is resolved.
#   PUBLISH  -> kci_publish.publish_release_with_store over
#               `ComposedSecretStore`, the store --secret-store chose:
#                 none  RefusingSecretStore: resolves nothing; a channel whose
#                       credential is an API token is refused naming the
#                       secret and the flag that would resolve it;
#                 env   EnvSecretStore[ProcessEnv] (komira_secret_env): the
#                       secret NAME is the environment variable's name.
#               An OIDC channel resolves no secret at all, whichever store.
#
# Nothing here parses a flag or reads a file: that is args.mojo and
# dispatch.mojo, and the libraries.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_secret_env import EnvSecretStore, ProcessEnv
from komira_secret_store import SecretStore, SecretValue

from kci_build import BuildRequest, SupervisorRunner, run_build
from kci_api import RunResult as KciRunResult
from kci_publish import PublishRequest, publish_release_with_store

from .args import SecretStoreChoice
from .dispatch import StageSteps, StepEnd, kci_main_with, recorder_for
from .recorder import CliRecorder


struct RefusingSecretStore(SecretStore, Movable):
    """`--secret-store=none`: holds nothing and says which flag would
    resolve the name. Layout: no fields."""

    def __init__(out self):
        pass

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        raise Error(
            String("kci was run with --secret-store=none, so the secret '")
            + secret_ref
            + String("' cannot be resolved; pass --secret-store=env to read")
            + String(" the environment variable of that name")
        )


struct ComposedSecretStore(SecretStore, Movable):
    """The one store type a PUBLISH step is given: `--secret-store=env`
    resolves through `EnvSecretStore[ProcessEnv]`, `none` refuses through
    `RefusingSecretStore`. Constructing either reads nothing (ProcessEnv
    holds no state). Layout: a Bool and the env store; no pointer."""

    var _use_env: Bool
    var _env: EnvSecretStore[ProcessEnv]

    def __init__(out self, choice: SecretStoreChoice):
        self._use_env = choice == SecretStoreChoice.ENV
        self._env = EnvSecretStore[ProcessEnv](ProcessEnv())

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        if self._use_env:
            return self._env.resolve(secret_ref)
        var none = RefusingSecretStore()
        return none.resolve(secret_ref)


struct LibrarySteps(StageSteps, Movable):
    """The steps as the kci binary runs them. Layout: no fields."""

    def __init__(out self):
        pass

    def build(mut self, req: BuildRequest, mut result: KciRunResult, mut recorder: CliRecorder) -> StepEnd:
        var runner = SupervisorRunner()
        var git = SupervisorRunner()
        var o = run_build(req, result, recorder, runner, git)
        var end = StepEnd(o.outcome.copy(), o.error_id.copy(), o.message.copy())
        end.lines = o.lines.copy()
        return end^

    def publish(
        mut self, req: PublishRequest, mut result: KciRunResult, mut recorder: CliRecorder, store: SecretStoreChoice
    ) -> StepEnd:
        var composed = ComposedSecretStore(store)
        var r = publish_release_with_store(req, result, recorder, composed)
        var end = StepEnd(r.outcome(), r.error_id.copy(), String(""))
        end.lines = r.lines.copy()
        end.retry = r.retry()
        end.changed_outside = r.landed()
        return end^


def kci_main(args: List[String]) -> Int:
    """The kci binary: `args` is argv without the program name."""
    var steps = LibrarySteps()
    var recorder = recorder_for(args)
    return kci_main_with(args, steps, recorder)
