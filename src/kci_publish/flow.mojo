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
#      (KCI-E-REVISION), --expect-set-hash is 64 lowercase hex, the
#      concurrency is 1..16, no claim is given twice and the stage is named
#      (KCI-E-USAGE);
#   2. STEP 0, every check before any request (REFUSED): the declarations
#      (KCI-E-DECLARATION); `<release-dir>/<platform>/release.json` names
#      this run's revision (KCI-E-REVISION-MISMATCH) and platform
#      (KCI-E-PLATFORM-MISMATCH); the release directory member by member
#      (`inputs.mojo`), CONDA only, lockstep against `--release-version`,
#      the requirement closure (KCI-E-MEMBER); the set hash
#      (KCI-E-SET-HASH); the channel and each member's coordinate
#      (KCI-E-CHANNEL); for a channel that publishes with OIDC trusted
#      publishing, the stage must be the environment the channel's push
#      identity names (KCI-E-STAGE-ENVIRONMENT: prefix.dev's trusted
#      publisher binds one environment, and the stage IS that environment);
#      the credential is declared, and a PRIVATE OIDC-only channel is not
#      dry-run (KCI-E-CREDENTIAL);
#   3. `recorder.begin` gets the RUNNING record BEFORE the first effect (the
#      first secret, token or channel request). A recorder that cannot
#      record stops the step FAILED with nothing sent;
#   4. THE CREDENTIAL comes from the channel's CONDA repository, never from a
#      flag: an API_TOKEN by secret name (resolved through the `SecretStore`)
#      or OIDC trusted publishing, whose token's `environment` claim must be
#      the stage. Reads on a PUBLIC channel are anonymous; on a PRIVATE one
#      they carry the credential, so it is resolved before step 1 (an OIDC
#      exchange included: that is the one value the run uses). On a PUBLIC
#      channel the write value is resolved at step 2, once. A credential
#      that cannot be had is FAILED (KCI-E-CREDENTIAL), nothing sent;
#   5. --plan: steps 0 and 1 only. No write request and no OIDC exchange.
#      A PUBLIC channel resolves nothing; a PRIVATE channel with an API_TOKEN
#      resolves it for the reads;
#   6. `run_publish` (`run.mojo`), then this step's part of the result
#      document (`report.mojo`, `record_publish_result`). Writing the
#      FINISHED record is the caller's: a stage may hold more steps.
#
# THE ONE ENVIRONMENT READ is the GitHub Actions OIDC handshake, inside
# `GithubOidcCredential.from_actions_env`, and only for an OIDC channel
# outside a dry run.
#
# `publish_release_with_store` is the same over the real HTTPS transport. A
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

from kci_artifact_declaration import read_artifact_declarations
from kci_artifact_declaration_proto.artifact_declaration import ArtifactDeclarations
from kci_contract import (
    ERROR_CHANNEL,
    ERROR_CREDENTIAL,
    ERROR_DECLARATION,
    ERROR_FORMAT,
    ERROR_MEMBER,
    ERROR_PLATFORM,
    ERROR_PLATFORM_MISMATCH,
    ERROR_RESULT_FILE,
    ERROR_REVISION,
    ERROR_REVISION_MISMATCH,
    ERROR_SET_HASH,
    ERROR_STAGE_ENVIRONMENT,
    ERROR_USAGE,
    RELEASE_MANIFEST_NAME,
    RunRecorder,
    require_full_commit_id,
    require_release_platform,
)
from kci_contract import RunResult as KciRunResult
from kci_pkg_upload import (
    SURFACE_PREFIX_DEV,
    AnonymousCredential,
    GithubOidcCredential,
    PkgTransport,
    RegistrySet,
    StaticTokenCredential,
)
from kci_pkg_upload.coordinate import repo_host
from kci_release_channel import (
    ARTIFACT_TYPE_CONDA,
    ChannelCredential,
    ChannelDeclaration,
    find_channel,
    parse_channels_file,
    push_identity_environment,
)
from kci_release_set.release_manifest import ReleaseManifest, read_release_manifest

from .inputs import LoadedRelease, load_release
from .pause import UsleepSleeper
from .plan import PublishTarget, resolve_targets
from .release_version import ReleaseVersion, read_release_version
from .report import REASON_FAILED, PublishReport, record_publish_result
from .request import PublishRequest
from .run import run_publish
from .upload import PublishCredential, RunOptions
from .verify import (
    is_lower_hex_64,
    require_closure,
    require_conda_only,
    require_lockstep,
    require_set_hash,
)
from .workers import MAX_CONCURRENCY, MIN_CONCURRENCY, ChannelTransport, HttpChannelTransport, WorkerSleeper


struct PreparedRelease(Movable):
    """Everything step 0 read and checked.

    Layout: owned values only. No pointer field."""

    var loaded: LoadedRelease
    var release_version: ReleaseVersion
    var channel: ChannelDeclaration
    var credential: Optional[ChannelCredential]
    var targets: List[PublishTarget]

    def __init__(
        out self,
        var loaded: LoadedRelease,
        var release_version: ReleaseVersion,
        var channel: ChannelDeclaration,
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
    if not is_lower_hex_64(req.expect_set_hash):
        return String("--expect-set-hash '") + req.expect_set_hash + String("' is not 64 lowercase hex characters")
    if req.concurrency < MIN_CONCURRENCY or req.concurrency > MAX_CONCURRENCY:
        return (
            String("--concurrency ") + String(req.concurrency) + String(" is not in ")
            + String(MIN_CONCURRENCY) + String("..") + String(MAX_CONCURRENCY)
        )
    for i in range(len(req.claims)):
        for j in range(i):
            if req.claims[j] == req.claims[i]:
                return String("--claim-new-name ") + req.claims[i] + String(" is given twice")
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
    var decls: ArtifactDeclarations
    try:
        decls = read_artifact_declarations(req.declarations_file)
    except e:
        return _Step0(String(ERROR_DECLARATION), String(e))
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
        loaded = load_release(decls, dir)
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
    try:
        require_set_hash(loaded, req.expect_set_hash)
    except e:
        return _Step0(String(ERROR_SET_HASH), String(e))
    var channel: ChannelDeclaration
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
        targets = resolve_targets(channel, loaded.members)
        _ = repo_host(targets[0].coordinate.repo)
    except e:
        return _Step0(String(ERROR_CHANNEL), String(e))
    var is_oidc = Bool(credential) and credential.value().is_oidc_trusted_publishing()
    if is_oidc and environment != req.stage:
        var named = String("names no environment") if environment.byte_length() == 0 else (
            String("names environment '") + environment + String("'")
        )
        return _Step0(
            String(ERROR_STAGE_ENVIRONMENT),
            String("channel '") + channel.name + String("' publishes with OIDC trusted publishing, and its")
            + String(" push identity ") + named + String("; this PUBLISH step runs in stage '")
            + req.stage + String("'. The trusted publisher accepts one environment, so the stage")
            + String(" that publishes is named exactly that environment"),
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


def _base_report(p: PreparedRelease, req: PublishRequest) -> PublishReport:
    var r = PublishReport()
    r.channel = p.channel.name.copy()
    r.set_hash = p.loaded.set_hash()
    r.release_commit = p.release_version.commit.copy()
    r.plan = req.plan
    r.has_produced_by = True
    r.produced_by_run_id = p.loaded.recomputed.produced_by_run_id.copy()
    r.produced_by_attempt = p.loaded.recomputed.produced_by_attempt
    return r^


def _flow[T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper, C: RunRecorder](
    req: PublishRequest,
    mut result: KciRunResult,
    mut recorder: C,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    mut store: S,
    run_opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    var opts = run_opts.copy()
    opts.concurrency = req.concurrency
    var step0 = _step0(req)
    if not step0.prepared:
        return step0.refusal.copy()
    var p = step0.prepared.take()
    var base = _base_report(p, req)
    # ── RUNNING, before the first effect ───────────────────────────────────
    result.revision = req.revision_id.copy()
    result.platform = req.platform.copy()
    result.expect_set_hash = req.expect_set_hash.copy()
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
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            else:
                var token = StaticTokenCredential.token_secret(
                    SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
                )
                var auth = token.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth^)
            var nobody = AnonymousCredential()
            return run_publish(p.targets, req.claims, registry, nobody, True, opts, sleeper, base.copy())
        if is_oidc:
            var oidc = GithubOidcCredential[U].from_actions_env(oidc_t^, host.copy(), String(""))
            oidc.with_required_environment(req.stage.copy())
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            else:
                var auth = oidc.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
                registry.credential().arm(auth^)
            return run_publish(p.targets, req.claims, registry, oidc, False, opts, sleeper, base.copy())
        var token = StaticTokenCredential.token_secret(
            SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
        )
        if public:
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
        else:
            var auth = token.authorization(SURFACE_PREFIX_DEV, host)
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
            registry.credential().arm(auth^)
        return run_publish(p.targets, req.claims, registry, token, False, opts, sleeper, base.copy())
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
    mut store: S,
    opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    """One PUBLISH step over the given seams (file header): `registry`
    talks to the channel (its credential unconfigured; the flow configures
    it), `oidc_t` carries the OIDC exchange. `recorder.begin` is called at
    most once, before the first effect; this step's row, artifacts, set
    hash and first error go into `result`. Never raises."""
    var r = _flow(req, result, recorder, registry, oidc_t^, store, opts, sleeper)
    try:
        record_publish_result(r, req.step_name, req.revision_id, req.platform, result)
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


def publish_release_with_store[S: SecretStore, C: RunRecorder](
    req: PublishRequest, mut result: KciRunResult, mut recorder: C, mut store: S
) -> PublishReport:
    """`publish_flow` over the real HTTPS transport, resolving an API_TOKEN
    channel credential through `store`."""
    var sleeper = UsleepSleeper()
    var registry = RegistrySet[_Http, PublishCredential](_http(), PublishCredential())
    return publish_flow(req, result, recorder, registry, _http(), store, RunOptions(), sleeper)


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
