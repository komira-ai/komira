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
#               The step's NEW NAMES block goes to the job summary.
#   validate       -> kci_validate.run_install_smoke: a `SupervisorRunner`
#                     for `docker`, anonymous HTTPS reads of the channel
#                     (`HttpPkgTransport`, no credential), `UsleepSleeper`
#                     for the index wait. The container runs as this
#                     process's uid:gid; the docker CLI gets this process's
#                     PATH (platform-set; a default when unset) and nothing
#                     else it holds.
#   lookahead      -> kci_publish.lookahead_new_names_https: a later stage's
#                     NEW NAMES, anonymous reads over HTTPS.
#   platform_env   -> this process's environment, for the platform-set
#                     variables of the workflow check only (dispatch.mojo).
#   committed_file -> `git show <commit>:<path>` through a `SupervisorRunner`
#                     in the directory kci runs in; its output goes to
#                     `$RUNNER_TEMP` (platform-set: the check runs only under
#                     GitHub Actions), a missing RUNNER_TEMP is a refusal.
#
# Nothing here parses a flag or reads a file: that is args.mojo and
# dispatch.mojo, and the libraries.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.ffi import abort, external_call
from std.os import remove
from std.os.path import exists
from std.pathlib import Path

from komira_http_client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_secret_env import EnvSecretStore, ProcessEnv
from komira_secret_store import SecretStore, SecretValue

from kci_contract import OUTCOME_VALIDATION_FAILED, VALIDATION_VALIDATED, ResultValidation, ResultValidationCheck
from kci_pkg_upload import HttpPkgTransport
from kci_publish import UsleepSleeper
from kci_validate import ContainerHost, ValidateRequest, run_install_smoke

from kci_build import GIT_PROGRAM, BuildRequest, RunSpec, SupervisorRunner, run_build
from kci_build import RunResult as ProcessResult
from kci_api import RunResult as KciRunResult
from kci_publish import (
    NewNamesReport,
    PublishRequest,
    lookahead_new_names_https,
    new_names_markdown,
    new_names_of,
    publish_release_with_store,
)

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


comptime DOCKER_PROGRAM: String = "docker"
comptime DEFAULT_CHILD_PATH: String = "/usr/local/bin:/usr/bin:/bin"
"""The docker CLI's PATH when this process has none."""

comptime _Conn = TlsConnector[KernelTcpConnector]


def _mk_connector(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("validation: TLS connector for ") + host + String(": ") + String(e))


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
        end.summary = new_names_markdown(new_names_of(r, req.stage, req.step_name))
        return end^

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        var path = self.platform_env(String("PATH"))
        if path.byte_length() == 0:
            path = String(DEFAULT_CHILD_PATH)
        var user = String(Int(external_call["getuid", UInt32]())) + String(":") + String(
            Int(external_call["getgid", UInt32]())
        )
        var host = ContainerHost(String(DOCKER_PROGRAM), path^, user^)
        var runner = SupervisorRunner()
        var transport = HttpPkgTransport[_Conn](_mk_connector)
        var sleeper = UsleepSleeper()
        try:
            return run_install_smoke(runner, transport, sleeper, req, host)
        except e:
            var row = ResultValidation(
                req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
                String(VALIDATION_VALIDATED), String(OUTCOME_VALIDATION_FAILED),
            )
            row.checks.append(ResultValidationCheck(String("validation"), String("a validation kci runs"), String(e), False))
            return row^

    def lookahead(mut self, req: PublishRequest) -> NewNamesReport:
        return lookahead_new_names_https(req)

    def platform_env(mut self, name: String) -> String:
        var env = ProcessEnv()
        try:
            var v = env.lookup(name)
            if not v:
                return String("")
            var b = v.value().revealed_bytes()
            var out = String("")
            for i in range(len(b)):
                out += chr(Int(b[i]))
            return out^
        except:
            return String("")

    def committed_file(mut self, commit: String, path: String) raises -> String:
        var tmp = self.platform_env(String("RUNNER_TEMP"))
        if tmp.byte_length() == 0:
            raise Error(String("RUNNER_TEMP is not set, so there is nowhere to put git's output"))
        var base = tmp + String("/kci-workflow-") + String(Int(external_call["getpid", Int32]()))
        var argv = List[String]()
        argv.append(String("show"))
        argv.append(commit + String(":") + path)
        var spec = RunSpec(String(GIT_PROGRAM), argv^, String("."), 60, base + String(".stdout"), base + String(".stderr"))
        var runner = SupervisorRunner()
        var r: ProcessResult = runner.run(spec)
        if not r.ok():
            var why = String("`") + spec.command_line() + String("` ") + r.describe()
            if r.stderr_tail.byte_length() > 0:
                why += String(": ") + String(r.stderr_tail.strip())
            raise Error(why^)
        var text = Path(spec.stdout_path).read_text()
        for p in [spec.stdout_path.copy(), spec.stderr_path.copy()]:
            if exists(p):
                remove(p)
        return text^


def kci_main(args: List[String]) -> Int:
    """The kci binary: `args` is argv without the program name."""
    var steps = LibrarySteps()
    var recorder = recorder_for(args)
    return kci_main_with(args, steps, recorder)
