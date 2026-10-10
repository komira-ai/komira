# =============================================================================
# src/kci_publish/flow.mojo -- `publish_flow`: one PUBLISH step of a stage,
#   from its request to its report and its part of the run's result.
# =============================================================================
#
# `publish_flow` is generic over the channel transport, the OIDC transport,
# the secret store, the sleeper and the result recorder, so the welded tests
# drive the whole step over an in-memory channel. The order:
#
#   1. the request's own values (REFUSED, nothing read): the platform is one
#      kci releases (KCI-E-PLATFORM), --revision-id is a full commit id
#      (KCI-E-REVISION), the concurrency is 1..16 and the stage is named
#      (KCI-E-USAGE);
#   2. STEP 0, every check before any request (REFUSED): the artifacts
#      (KCI-E-ARTIFACT); `<release-dir>/<platform>/release.json` names
#      this run's revision (KCI-E-REVISION-MISMATCH) and platform
#      (KCI-E-PLATFORM-MISMATCH); the release directory member by member
#      (`inputs.mojo`; `release.json`'s set hash must be what the members
#      recompute to), CONDA only, lockstep against `--release-version`, the
#      requirement closure (KCI-E-MEMBER); the channel and each member's
#      coordinate (KCI-E-CHANNEL); for a channel that publishes with OIDC
#      trusted publishing, the stage's GitHub environment must be the one the
#      channel's push identity names (KCI-E-STAGE-ENVIRONMENT: prefix.dev's
#      trusted publisher binds one environment); on a BREAK-GLASS run
#      (`req.break_glass`) the one its `break_glass_push_identity` names, and
#      a channel without one refuses the run (KCI-E-STAGE-ENVIRONMENT); the
#      credential is declared,
#      and a PRIVATE OIDC-only channel is not dry-run (KCI-E-CREDENTIAL);
#   3. `recorder.begin` gets the RUNNING record BEFORE the first effect (the
#      first secret, token or channel request). A recorder that cannot
#      record stops the step FAILED with nothing sent;
#   4. THE CREDENTIAL comes from the channel's CONDA repository, never from a
#      flag: an API_TOKEN by secret name (resolved through the `SecretStore`)
#      or OIDC trusted publishing, whose token's `environment` claim must be
#      the stage's environment. Reads on a PUBLIC channel are anonymous; on a
#      PRIVATE one
#      they carry the credential, so it is resolved before step 1 (an OIDC
#      exchange included: that is the one value the run uses). On a PUBLIC
#      channel the write value is resolved at step 2, once. A credential
#      that cannot be had is FAILED (KCI-E-CREDENTIAL), nothing sent;
#   5. --plan: steps 0 and 1 only, and NO WRITE to the channel. The reads
#      stay as above (a PUBLIC channel's anonymous; a PRIVATE API_TOKEN
#      channel's carry the token). THE CREDENTIAL PROBE: for an OIDC channel
#      under GitHub Actions, the plan asks for the ID token (its `environment`
#      claim held to the stage's environment, refused before the exchange
#      otherwise), exchanges it at the channel host's mint endpoint, and
#      discards the minted token unused (`credential_probe` MINTED). A mint
#      refusal is FAILED (KCI-E-CREDENTIAL), so a misconfigured trusted
#      publisher turns the dry run red. Not under CI (neither handshake
#      variable set) the probe is NOT_UNDER_CI, which is never a pass; a
#      channel whose credential is not OIDC is NOT_OIDC. What a MINTED probe
#      does not prove: that the publisher which matched belongs to this
#      channel (the mint request names none) and that it may write;
#   6. `run_publish` (`run.mojo`), then this step's part of the result
#      document (`report.mojo`, `record_publish_result`). Writing the
#      FINISHED record is the caller's: a stage may hold more steps.
#
# THE ONE ENVIRONMENT READ is the GitHub Actions OIDC handshake
# (`ActionsOidcEnv`), passed in so the welded tests can give it; only an OIDC
# channel uses it.
#
# `publish_release_with_store` is the same over the real HTTPS transport,
# reading the handshake from this process (`ActionsOidcEnv.from_process`). A
# binary without a secret store passes `NoSecretStore` (it refuses by name).
#
# Encapsulation: owned values and generic seams. No pointer, no wildcard
# origin.
# =============================================================================

from std.ffi import abort
from std.os.path import exists
from std.pathlib import Path

from komira_http_client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_secret_store import SecretStore, SecretValue

from kci_artifact import read_artifacts
from kci_artifact_proto.artifact import Artifacts
from kci_api import (
    ERROR_CHANNEL,
    ERROR_CREDENTIAL,
    ERROR_ARTIFACT,
    ERROR_FORMAT,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_PLATFORM_MISMATCH,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_REVISION_MISMATCH,
    ERROR_STAGE_ENVIRONMENT,
    ERROR_USAGE,
    CREDENTIAL_PROBE_MINTED,
    CREDENTIAL_PROBE_NOT_OIDC,
    CREDENTIAL_PROBE_NOT_UNDER_CI,
    RELEASE_MANIFEST_NAME,
    RunRecorder,
    require_full_commit_id,
    require_release_platform,
)
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import (
    SURFACE_PREFIX_DEV,
    AnonymousCredential,
    GithubOidcCredential,
    PkgTransport,
    RegistrySet,
    StaticTokenCredential,
)
from kci_pkg_upload.coordinate import repo_host
from kci_pkg_upload.prefix_dev_registry import prefix_dev_channel
from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ChannelCredential,
    Channel,
    break_glass_push_identity_environment,
    find_channel,
    parse_channels_file,
    push_identity_environment,
)
from kci_release_set.release_manifest import ReleaseManifest, read_release_manifest

from .actions_env import ActionsOidcEnv
from .inputs import LoadedRelease, load_release
from .pause import UsleepSleeper
from .plan import PublishTarget, resolve_targets
from .release_version import ReleaseVersion, read_release_version
from .report import REASON_FAILED, PublishReport, record_publish_result
from .request import PublishRequest
from .history import HistoryReader, UnreadHistory
from .run import run_publish_reading
from .upload import PublishCredential, RunOptions
from .verify import require_closure, require_conda_only, require_lockstep
from .workers import MAX_CONCURRENCY, MIN_CONCURRENCY, ChannelTransport, HttpChannelTransport, WorkerSleeper


struct PreparedRelease(Movable):
    """Everything step 0 read and checked.

    Layout: owned values only. No pointer field."""

    var loaded: LoadedRelease
    var release_version: ReleaseVersion
    var channel: Channel
    var credential: Optional[ChannelCredential]
    var targets: List[PublishTarget]

    def __init__(
        out self,
        var loaded: LoadedRelease,
        var release_version: ReleaseVersion,
        var channel: Channel,
        var credential: Optional[ChannelCredential],
        var targets: List[PublishTarget],
    ):
        self.loaded = loaded^
        self.release_version = release_version^
        self.channel = channel^
        self.credential = credential^
        self.targets = targets^


struct _Step0(Movable):
    """Step 0's answer: the prepared release, or the refusal that stopped
    it. Layout: owned values only. No pointer field."""

    var prepared: Optional[PreparedRelease]
    var refusal: PublishReport

    def __init__(out self, var prepared: PreparedRelease):
        self.prepared = prepared^
        self.refusal = PublishReport()

    def __init__(out self, var error_id: String, message: String):
        self.prepared = None
        var text = message.copy()
        if not text.startswith(String("PUBLISH step: ")):
            text = String("PUBLISH step: ") + text
        self.refusal = PublishReport.refused(error_id^, text^)


def _usage(req: PublishRequest) -> String:
    """Why the request's own values are refused, or "" (file header, 1)."""
    if req.stage.byte_length() == 0:
        return String("the stage is EMPTY: a PUBLISH step runs in a named stage")
    if req.concurrency < MIN_CONCURRENCY or req.concurrency > MAX_CONCURRENCY:
        return (
            String("--concurrency ") + String(req.concurrency) + String(" is not in ")
            + String(MIN_CONCURRENCY) + String("..") + String(MAX_CONCURRENCY)
        )
    return String("")


def _step0(req: PublishRequest) -> _Step0:
    """Steps 1 and 2 of the file header: every check before any request."""
    var why = _usage(req)
    if why.byte_length() > 0:
        return _Step0(String(ERROR_USAGE), why)
    try:
        require_release_platform(req.platform)
    except e:
        return _Step0(String(ERROR_PLATFORM), String(e))
    try:
        require_full_commit_id(String("--revision-id"), req.revision_id)
    except e:
        return _Step0(String(ERROR_REVISION), String(e))
    var dir: String
    try:
        dir = req.platform_dir()
    except e:
        return _Step0(String(ERROR_USAGE), String("--release-dir: ") + String(e))
    var arts: Artifacts
    try:
        arts = read_artifacts(req.artifacts_file)
    except e:
        return _Step0(String(ERROR_ARTIFACT), String(e))
    var manifest_path = dir + String("/") + String(RELEASE_MANIFEST_NAME)
    if exists(manifest_path):
        var recorded: ReleaseManifest
        try:
            recorded = read_release_manifest(manifest_path)
        except e:
            return _Step0(String(ERROR_FORMAT), String(e))
        if recorded.revision != req.revision_id:
            return _Step0(
                String(ERROR_REVISION_MISMATCH),
                String("the release in '") + dir + String("' was built from revision ")
                + recorded.revision + String(", not --revision-id ") + req.revision_id
                + String(": a release is published from the commit it was built from"),
            )
        if recorded.platform != req.platform:
            return _Step0(
                String(ERROR_PLATFORM_MISMATCH),
                String("the release in '") + dir + String("' is for platform ") + recorded.platform
                + String(", not this step's ") + req.platform,
            )
    var loaded: LoadedRelease
    try:
        loaded = load_release(arts, dir)
        require_conda_only(loaded.members)
    except e:
        return _Step0(String(ERROR_MEMBER), String(e))
    var rv: ReleaseVersion
    try:
        rv = read_release_version(req.release_version_file)
    except e:
        return _Step0(String(ERROR_FORMAT), String(e))
    try:
        require_lockstep(loaded.members, rv)
        require_closure(loaded.members)
    except e:
        return _Step0(String(ERROR_MEMBER), String(e))
    var channel: Channel
    var targets: List[PublishTarget]
    var credential: Optional[ChannelCredential]
    var environment: String
    try:
        var text: String
        try:
            text = Path(req.channels_file).read_text()
        except e:
            raise Error(
                String("channels file '") + req.channels_file + String("' cannot be read: ") + String(e)
            )
        channel = find_channel(parse_channels_file(text), req.channel)
        var repository = channel.repository_for(String(ARTIFACT_TYPE_CONDA))
        credential = repository.credential.copy()
        environment = push_identity_environment(repository)
        if req.break_glass:
            environment = break_glass_push_identity_environment(repository)
        targets = resolve_targets(channel, loaded.members)
        _ = repo_host(targets[0].coordinate.repo)
    except e:
        return _Step0(String(ERROR_CHANNEL), String(e))
    var is_oidc = Bool(credential) and credential.value().is_oidc_trusted_publishing()
    var stage_env = req.github_environment()
    if is_oidc and req.break_glass and environment.byte_length() == 0:
        return _Step0(
            String(ERROR_STAGE_ENVIRONMENT),
            String("this is a BREAK-GLASS run of stage '") + req.stage + String("', and channel '") + channel.name
            + String("' publishes with OIDC trusted publishing but names no break_glass_push_identity: a")
            + String(" break-glass run publishes only from an environment of its own (the stage's")
            + String(" break_glass_environment), which the channel trusts as a second publisher"),
        )
    if is_oidc and environment != stage_env:
        var named = String("names no environment") if environment.byte_length() == 0 else (
            String("names environment '") + environment + String("'")
        )
        return _Step0(
            String(ERROR_STAGE_ENVIRONMENT),
            String("channel '") + channel.name + String("' publishes with OIDC trusted publishing, and its")
            + String(" push identity ") + named + String("; this PUBLISH step runs in stage '")
            + req.stage + String("', in GitHub environment '") + stage_env
            + String("'. The trusted publisher accepts one environment, so the stage that publishes")
            + String(" runs in exactly that environment"),
        )
    if not credential and not (req.plan and channel.is_public()):
        return _Step0(
            String(ERROR_CREDENTIAL),
            String("channel '") + channel.name
            + String("' declares no credential for its CONDA repository, so it cannot be published to"),
        )
    if req.plan and is_oidc and not channel.is_public():
        return _Step0(
            String(ERROR_CREDENTIAL),
            String("channel '") + channel.name
            + String("' is PRIVATE and publishes with OIDC only; a dry run would have to mint a token")
            + String(" to read it, so it cannot be dry-run"),
        )
    return _Step0(PreparedRelease(loaded^, rv^, channel^, credential^, targets^))


def prepare_release(req: PublishRequest) raises -> PreparedRelease:
    """Step 0 alone (file header, 1 and 2): every check before any request.
    RAISES with the refusal's message. A later stage's NEW NAMES lookahead
    reads through this, so it sees exactly what that stage's own run would
    publish."""
    var step0 = _step0(req)
    if not step0.prepared:
        var text = String("")
        for i in range(len(step0.refusal.lines)):
            if step0.refusal.lines[i].startswith(String("RESULT ")):
                continue
            if text.byte_length() > 0:
                text += String("\n")
            text += step0.refusal.lines[i]
        raise Error(text^)
    return step0.prepared.take()


def _base_report(p: PreparedRelease, req: PublishRequest) -> PublishReport:
    var r = PublishReport()
    r.channel = p.channel.name.copy()
    try:
        r.channel_path = prefix_dev_channel(p.targets[0].coordinate.repo)
    except:
        r.channel_path = p.channel.name.copy()
    r.set_hash = p.loaded.set_hash()
    r.release_commit = p.release_version.commit.copy()
    r.plan = req.plan
    r.has_produced_by = True
    r.produced_by_run_id = p.loaded.recomputed.produced_by_run_id.copy()
    r.produced_by_attempt = p.loaded.recomputed.produced_by_attempt
    return r^


def _oidc_credential[U: PkgTransport, W: WorkerSleeper](
    var oidc_t: U, var sleeper: W, var actions: ActionsOidcEnv, host: String, environment: String
) raises -> GithubOidcCredential[U, W]:
    """The trusted-publishing credential over `oidc_t`, from the handshake in
    `actions`, holding the ID token's `environment` claim to `environment`;
    its ID-token request retries through `sleeper`.
    RAISES naming each handshake variable that is not set."""
    var missing = actions.missing()
    if missing.byte_length() > 0:
        raise Error(
            String("GithubOidcCredential: ") + missing
            + String(" not set. Trusted publishing needs a GitHub Actions job with `permissions: id-token: write`")
        )
    var url = actions.request_url.copy()
    var token = actions.take_request_token()
    var oidc = GithubOidcCredential[U, W](oidc_t^, sleeper^, url, token^, host.copy(), String(""))
    oidc.with_required_environment(environment.copy())
    return oidc^


def _probe[U: PkgTransport, W: WorkerSleeper](
    var oidc_t: U, var sleeper: W, var actions: ActionsOidcEnv, host: String, environment: String
) raises -> String:
    """A dry run's probe of an OIDC channel's credential (file header, 5):
    NOT_UNDER_CI when neither handshake variable is set; otherwise one ID
    token and one exchange, the minted token dropped unused (its
    `SecretValue` is zeroized), MINTED. RAISES when the handshake is
    incomplete, the token's environment is not `environment`, or the
    exchange is refused: the caller reports FAILED (KCI-E-CREDENTIAL)."""
    if actions.is_absent():
        return String(CREDENTIAL_PROBE_NOT_UNDER_CI)
    var oidc = _oidc_credential(oidc_t^, sleeper^, actions^, host, environment)
    _ = oidc.authorization(SURFACE_PREFIX_DEV, host)
    return String(CREDENTIAL_PROBE_MINTED)


def _flow[T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper, C: RunRecorder, H: HistoryReader](
    req: PublishRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    var actions: ActionsOidcEnv,
    mut store: S,
    run_opts: RunOptions,
    mut sleeper: W,
    mut reader: H,
) -> PublishReport:
    var opts = run_opts.copy()
    opts.concurrency = req.concurrency
    opts.never_backward = req.never_backward
    opts.main_line_only = req.main_line_only
    var step0 = _step0(req)
    if not step0.prepared:
        return step0.refusal.copy()
    var p = step0.prepared.take()
    var base = _base_report(p, req)
    # ── RUNNING, before the first effect ───────────────────────────────────
    result.revision = req.revision_id.copy()
    result.platform = req.platform.copy()
    result.set_run(req.run)
    try:
        recorder.begin(result.begin_record())
    except e:
        base.stop(
            String(REASON_FAILED),
            String(ERROR_RESULT_FILE),
            String("PUBLISH step: the run's RUNNING record could not be written; nothing was sent: ")
            + String(e),
        )
        return base^
    var host: String
    try:
        host = repo_host(p.targets[0].coordinate.repo)
    except e:
        base.stop(String(REASON_FAILED), String(ERROR_CHANNEL), String("PUBLISH step: ") + String(e))
        return base^
    var public = p.channel.is_public()
    var is_oidc = Bool(p.credential) and p.credential.value().is_oidc_trusted_publishing()
    try:
        if req.plan:
            if is_oidc:
                base.credential_probe = _probe(oidc_t^, sleeper.for_worker(), actions^, host, req.github_environment())
            else:
                base.credential_probe = String(CREDENTIAL_PROBE_NOT_OIDC)
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            else:
                var token = StaticTokenCredential.token_secret(
                    SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
                )
                var auth = token.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth^)
            var nobody = AnonymousCredential()
            return run_publish_reading(p.targets, registry, nobody, True, opts, sleeper, base.copy(), req.revision_history, reader)
        if is_oidc:
            var oidc = _oidc_credential(oidc_t^, sleeper.for_worker(), actions^, host, req.github_environment())
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            else:
                var auth = oidc.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
                registry.credential().arm(auth^)
            return run_publish_reading(p.targets, registry, oidc, False, opts, sleeper, base.copy(), req.revision_history, reader)
        var token = StaticTokenCredential.token_secret(
            SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
        )
        if public:
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
        else:
            var auth = token.authorization(SURFACE_PREFIX_DEV, host)
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
            registry.credential().arm(auth^)
        return run_publish_reading(p.targets, registry, token, False, opts, sleeper, base.copy(), req.revision_history, reader)
    except e:
        base.stop(
            String(REASON_FAILED),
            String(ERROR_CREDENTIAL),
            String("PUBLISH step: the channel's credential: ") + String(e),
        )
        return base^


def publish_flow[T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper, C: RunRecorder](
    req: PublishRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    var actions: ActionsOidcEnv,
    mut store: S,
    opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    """One PUBLISH step over the given seams (file header): `registry`
    talks to the channel (its credential unconfigured; the flow configures
    it), `oidc_t` carries the OIDC exchange, `actions` is the runner's OIDC
    handshake. `recorder.begin` is called at most once, before the first
    effect; this step's row, artifacts, set hash, new names and first error
    go into `result`. Never raises. A never-backward run the rules would
    refuse cannot tell (no history reader; `publish_flow_reading` gives
    one)."""
    var reader = UnreadHistory()
    return publish_flow_reading(req, result, recorder, registry, oidc_t^, actions^, store, opts, sleeper, reader)


def publish_flow_reading[
    T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper, C: RunRecorder, H: HistoryReader
](
    req: PublishRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    var actions: ActionsOidcEnv,
    mut store: S,
    opts: RunOptions,
    mut sleeper: W,
    mut reader: H,
) -> PublishReport:
    """`publish_flow` whose never-backward split asks `reader` (run.mojo,
    THE SPLIT)."""
    var r = _flow(req, result, recorder, registry, oidc_t^, actions^, store, opts, sleeper, reader)
    try:
        record_publish_result(r, req.step_name, req.stage, req.revision_id, req.platform, result)
    except e:
        r.lines.append(String("RESULT not recorded in the result document: ") + String(e))
    return r^


comptime _Conn = TlsConnector[KernelTcpConnector]
comptime _Http = HttpChannelTransport[_Conn]


def _mk_connector(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("PUBLISH step: TLS connector for ") + host + String(": ") + String(e))


def _http() -> _Http:
    return _Http(_mk_connector)


def publish_release_with_store[S: SecretStore, C: RunRecorder, H: HistoryReader](
    req: PublishRequest, mut result: KciRunResult, mut recorder: C, mut store: S, mut reader: H
) -> PublishReport:
    """`publish_flow_reading` over the real HTTPS transport, resolving an
    API_TOKEN channel credential through `store`; never-backward's split
    asks `reader`."""
    var sleeper = UsleepSleeper()
    var registry = RegistrySet[_Http, PublishCredential](_http(), PublishCredential())
    var actions: ActionsOidcEnv
    try:
        actions = ActionsOidcEnv.from_process()
    except e:
        var r = PublishReport.refused(
            String(ERROR_CREDENTIAL), String("PUBLISH step: the GitHub Actions OIDC handshake: ") + String(e)
        )
        try:
            record_publish_result(r, req.step_name, req.stage, req.revision_id, req.platform, result)
        except:
            pass
        return r^
    return publish_flow_reading(req, result, recorder, registry, _http(), actions^, store, RunOptions(), sleeper, reader)


struct NoSecretStore(SecretStore, Movable):
    """A store that holds nothing, and says so. Layout: no fields."""

    def __init__(out self):
        pass

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        raise Error(
            String("this kci binary has no secret store to resolve '")
            + secret_ref
            + String("'; run kci from a binary that carries one, or use a channel")
            + String(" whose credential is OIDC trusted publishing")
        )
