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
#   validate       -> by kind. CONDA_INSTALL_SMOKE:
#                     kci_validate.run_install_smoke, a `SupervisorRunner`
#                     for `docker`, anonymous HTTPS reads of the channel
#                     (`HttpPkgTransport`, no credential), `UsleepSleeper`
#                     for the index wait, each poll a line on stderr
#                     (`StderrIndexPollLog`). The container runs as this
#                     process's uid:gid; the docker CLI gets this process's
#                     PATH (platform-set; a default when unset) and nothing
#                     else it holds. CONDA_INSTALL_ENV:
#                     kci_validate.run_install_env, the same runner,
#                     transport, sleeper and poll log; pixi (--pixi, checked against
#                     --pixi-sha256) gets an environment built from nothing,
#                     and pixi's system config directory is /etc/pixi;
#                     the transport is `FileChannelTransport` over the
#                     HTTPS one, so a --channel file:/// directory is read
#                     from the disk and every host over HTTPS.
#   lookahead      -> kci_publish.lookahead_new_names_https: a later stage's
#                     NEW NAMES, anonymous reads over HTTPS.
#   platform_env   -> this process's environment, for the platform-set
#                     variables of the workflow check only (dispatch.mojo).
#   committed_file -> `git show <commit>:<path>` through a `SupervisorRunner`
#                     in the directory kci runs in; its output goes to
#                     `$RUNNER_TEMP` (platform-set: the check runs only under
#                     GitHub Actions), a missing RUNNER_TEMP is a refusal.
#   is_ancestor    -> `git rev-parse --is-shallow-repository` (anything but
#                     `false` raises: a shallow clone's history cannot
#                     tell), then `git merge-base --is-ancestor`: exit 0
#                     True, 1 False, anything else raises; the same
#                     RUNNER_TEMP rule.
#   publish's history -> for a never-backward publish, `git rev-list
#                     <revision>` (`git_history`, after the same shallow
#                     check as is_ancestor) is handed to kci_publish
#                     (`RevisionHistory`): the channel's newest build must
#                     be on it. Git that cannot answer, or no RUNNER_TEMP,
#                     leaves it unread, and kci_publish then cannot tell
#                     (exit 5) whenever the channel lists a numbered build.
#   publish's carried commits -> for a never-backward publish, `git rev-list
#                     --first-parent --reverse <revision>` (`git_first_parent`)
#                     feeds summary.mojo's `carried_markdown`; git that
#                     cannot answer is said in the summary, never a failure
#                     of the step.
#   release_set_hash -> kci_publish.load_release over the artifacts file
#                     (kci_artifact): the set the members recompute to.
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

from kci_api import (
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_VALIDATED,
    ResultValidation,
    ResultValidationCheck,
    is_full_commit_id,
)
from kci_pkg_upload import HttpPkgTransport
from kci_publish import UsleepSleeper
from kci_validate import (
    PIXI_SYSTEM_CONFIG_DIR,
    ContainerHost,
    EnvHost,
    FileChannelTransport,
    StderrIndexPollLog,
    ValidateRequest,
    run_install_env,
    run_install_smoke,
)

from kci_artifact import read_artifacts
from kci_build import GIT_PROGRAM, BuildRequest, ProcessRunner, RunSpec, SupervisorRunner, run_build
from kci_build import RunResult as ProcessResult
from kci_api import RunResult as KciRunResult
from kci_publish import (
    NewNamesReport,
    PublishRequest,
    RevisionHistory,
    load_release,
    lookahead_new_names_https,
    new_names_markdown,
    new_names_of,
    publish_release_with_store,
)

from .args import SecretStoreChoice
from .deploy_step import NoCloudBuilt
from .dispatch import kci_main_with, recorder_for
from .seam import StageSteps, StepEnd
from .recorder import CliRecorder
from .summary import carried_markdown


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


def _git[R: ProcessRunner](mut runner: R, tmp: String, var argv: List[String]) raises -> Tuple[Int, String]:
    """`git <argv>` in the directory kci runs in, its output under `tmp`:
    its exit code (0 or 1) and stdout. Raises when it did not run to an exit
    (a signal, the timeout) or exited with more than 1."""
    var base = tmp + String("/kci-git-") + String(Int(external_call["getpid", Int32]()))
    var spec = RunSpec(String(GIT_PROGRAM), argv^, String("."), 60, base + String(".stdout"), base + String(".stderr"))
    var r: ProcessResult = runner.run(spec)
    var text = Path(spec.stdout_path).read_text() if exists(spec.stdout_path) else String("")
    for p in [spec.stdout_path.copy(), spec.stderr_path.copy()]:
        if exists(p):
            remove(p)
    if r.signaled or r.timed_out or Int(r.exit_code) > 1:
        var why = String("`") + spec.command_line() + String("` ") + r.describe()
        if r.stderr_tail.byte_length() > 0:
            why += String(": ") + String(r.stderr_tail.strip())
        raise Error(why^)
    return (Int(r.exit_code), text^)


def git_is_ancestor[R: ProcessRunner](mut runner: R, tmp: String, commit: String, of: String) raises -> Bool:
    """`is_ancestor` of the file header over `runner`: a checkout that is
    shallow (or not a repository) raises; then `git merge-base --is-ancestor
    <commit> <of>`: exit 0 True, 1 False, anything else raises."""
    var shallow_argv = List[String]()
    shallow_argv.append(String("rev-parse"))
    shallow_argv.append(String("--is-shallow-repository"))
    var shallow = _git(runner, tmp, shallow_argv^)
    if shallow[0] != 0 or String(shallow[1].strip()) != String("false"):
        raise Error(String("the checkout is shallow (or not a git repository): its history cannot tell"))
    var argv = List[String]()
    argv.append(String("merge-base"))
    argv.append(String("--is-ancestor"))
    argv.append(commit.copy())
    argv.append(of.copy())
    # `_git` already raises on any exit above 1; this states the contract
    # where it is read: 0 True, 1 False, nothing else is an answer.
    var r = _git(runner, tmp, argv^)
    if r[0] == 0:
        return True
    if r[0] == 1:
        return False
    raise Error(String("`git merge-base --is-ancestor` exited ") + String(r[0]) + String(", which is no answer"))


def git_first_parent[R: ProcessRunner](mut runner: R, tmp: String, revision: String) raises -> List[String]:
    """`git rev-list --first-parent --reverse <revision>`: main's first-parent
    commits up to `revision`, oldest first. Raises when git exits non-zero
    or a line is not a full commit id."""
    var argv = List[String]()
    argv.append(String("rev-list"))
    argv.append(String("--first-parent"))
    argv.append(String("--reverse"))
    argv.append(revision.copy())
    var r = _git(runner, tmp, argv^)
    if r[0] != 0:
        raise Error(String("`git rev-list --first-parent --reverse ") + revision + String("` exited ") + String(r[0]))
    var out = List[String]()
    var lines = r[1].split(String("\n"))
    for i in range(len(lines)):
        var line = String(String(lines[i]).strip())
        if line.byte_length() == 0:
            continue
        if not is_full_commit_id(line):
            raise Error(String("`git rev-list` printed '") + line + String("', not a full commit id"))
        out.append(line^)
    return out^


def git_history[R: ProcessRunner](mut runner: R, tmp: String, revision: String) raises -> List[String]:
    """`git rev-list <revision>`: every commit on `revision`'s history,
    newest first. A shallow checkout (or not a repository) raises: it lists
    part of the history, which would read as "not on it". Raises when git
    exits non-zero or a line is not a full commit id."""
    var shallow_argv = List[String]()
    shallow_argv.append(String("rev-parse"))
    shallow_argv.append(String("--is-shallow-repository"))
    var shallow = _git(runner, tmp, shallow_argv^)
    if shallow[0] != 0 or String(shallow[1].strip()) != String("false"):
        raise Error(String("the checkout is shallow (or not a git repository): its history cannot tell"))
    var argv = List[String]()
    argv.append(String("rev-list"))
    argv.append(revision.copy())
    var r = _git(runner, tmp, argv^)
    if r[0] != 0:
        raise Error(String("`git rev-list ") + revision + String("` exited ") + String(r[0]))
    var out = List[String]()
    var lines = r[1].split(String("\n"))
    for i in range(len(lines)):
        var line = String(String(lines[i]).strip())
        if line.byte_length() == 0:
            continue
        if not is_full_commit_id(line):
            raise Error(String("`git rev-list` printed '") + line + String("', not a full commit id"))
        out.append(line^)
    return out^


def _failed_row(req: ValidateRequest, why: String) -> ResultValidation:
    """A validation that raised: VALIDATION_FAILED with the reason."""
    var row = ResultValidation(
        req.validation.name.copy(), req.step_name.copy(), req.validation.kind.copy(),
        String(VALIDATION_VALIDATED), String(OUTCOME_VALIDATION_FAILED),
    )
    row.checks.append(ResultValidationCheck(String("validation"), String("a validation kci runs"), why.copy(), False))
    return row^


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
        var held = req.copy()
        if req.never_backward:
            held.revision_history = self._history(req.revision_id)
        var r = publish_release_with_store(held, result, recorder, composed)
        var end = StepEnd(r.outcome(), r.error_id.copy(), String(""))
        end.lines = r.lines.copy()
        end.retry = r.retry()
        end.changed_outside = r.landed()
        end.summary = new_names_markdown(new_names_of(r, req.stage, req.step_name))
        if req.never_backward and r.build_number >= 0:
            end.summary += self._carried(req, r.previous_build, r.build_number)
        return end^

    def _history(mut self, revision: String) -> RevisionHistory:
        """What a never-backward publish holds the channel's newest build
        against: `git_history` of the revision, or why it was not read
        (kci_publish then cannot tell, exit 5, when the channel lists a
        numbered build)."""
        var h = RevisionHistory()
        var tmp = self.platform_env(String("RUNNER_TEMP"))
        if tmp.byte_length() == 0:
            h.unread = String("RUNNER_TEMP is not set, so there is nowhere to put git's output")
            return h^
        var runner = SupervisorRunner()
        try:
            h.commits = git_history(runner, tmp, revision)
        except e:
            h.unread = String(e)
        return h^

    def _carried(mut self, req: PublishRequest, previous: Int, ours: Int) -> String:
        if previous < 0:
            return carried_markdown(req.stage, previous, ours, List[String]())
        var tmp = self.platform_env(String("RUNNER_TEMP"))
        if tmp.byte_length() == 0:
            return String("#### carried to ") + req.stage + String("\n\nnot listed: RUNNER_TEMP is not set\n\n")
        var runner = SupervisorRunner()
        try:
            return carried_markdown(req.stage, previous, ours, git_first_parent(runner, tmp, req.revision_id))
        except e:
            return String("#### carried to ") + req.stage + String("\n\nnot listed: ") + String(e) + String("\n\n")

    def validate(mut self, req: ValidateRequest) -> ResultValidation:
        if req.validation.kind == VALIDATION_KIND_CONDA_INSTALL_ENV:
            var env_runner = SupervisorRunner()
            # a host-less read is a local channel's file (--channel), the rest HTTPS
            var env_transport = FileChannelTransport(HttpPkgTransport[_Conn](_mk_connector))
            var env_sleeper = UsleepSleeper()
            var env_log = StderrIndexPollLog()
            try:
                return run_install_env(
                    env_runner, env_transport, env_sleeper, env_log, req, EnvHost(String(PIXI_SYSTEM_CONFIG_DIR))
                )
            except e:
                return _failed_row(req, String(e))
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
        var log = StderrIndexPollLog()
        try:
            return run_install_smoke(runner, transport, sleeper, log, req, host)
        except e:
            return _failed_row(req, String(e))

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

    def is_ancestor(mut self, commit: String, of: String) raises -> Bool:
        var tmp = self.platform_env(String("RUNNER_TEMP"))
        if tmp.byte_length() == 0:
            raise Error(String("RUNNER_TEMP is not set, so there is nowhere to put git's output"))
        var runner = SupervisorRunner()
        return git_is_ancestor(runner, tmp, commit, of)

    def release_set_hash(mut self, artifacts_file: String, platform_dir: String) raises -> String:
        var arts = read_artifacts(artifacts_file)
        return load_release(arts, platform_dir).set_hash()

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
    """The kci binary: `args` is argv without the program name. It is built
    with no cloud adapter, so every DEPLOY step it runs is REFUSED, "this
    kci was not built with that cloud" (deploy_step.mojo `NoCloudBuilt`)."""
    var steps = LibrarySteps()
    var deploys = NoCloudBuilt()
    var recorder = recorder_for(args)
    return kci_main_with(args, steps, deploys, recorder)
