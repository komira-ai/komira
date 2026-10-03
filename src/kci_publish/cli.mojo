# =============================================================================
# src/kci_publish/cli.mojo -- `publish_main`: the `kci publish` verb from
#   argv to exit code.
# =============================================================================
#
# `publish_flow` is generic over the channel transport, the OIDC transport,
# the secret store and the sleeper, so the welded tests drive the whole verb
# over an in-memory channel. The order:
#
#   1. flags (`flags.mojo`): a refusal is exit 2, before any file is read;
#   2. STEP 0, every check before any request (exit 3): the declarations;
#      the release directory member by member (`inputs.mojo`); CONDA only;
#      `--release-version`; lockstep, requirement closure and the set hash
#      (`verify.mojo`); the channel and each member's coordinate
#      (`plan.mojo`);
#   3. THE CREDENTIAL comes from the channel's CONDA repository, never from a
#      flag: an API_TOKEN by secret name (resolved through the `SecretStore`)
#      or OIDC trusted publishing. Reads on a PUBLIC channel are anonymous;
#      on a PRIVATE one they carry the credential, so it is resolved before
#      step 1 (an OIDC exchange included: that is the one value the run
#      uses). On a PUBLIC channel the write value is resolved at step 2,
#      once;
#   4. --dry-run: steps 0 and 1 only. No write request and no OIDC exchange.
#      A PUBLIC channel resolves nothing; a PRIVATE channel with an API_TOKEN
#      resolves it for the reads; a PRIVATE channel with OIDC only cannot be
#      dry-run (reading it would mint), so that is refused (exit 3);
#   5. `run_publish` (`run.mojo`), then the report is written to --report.
#      A report that cannot be written turns a 0 or 6 into 4: the release job
#      reads it.
#
# THE ONE ENVIRONMENT READ is the GitHub Actions OIDC handshake, inside
# `GithubOidcCredential.from_actions_env`, and only for an OIDC channel
# outside a dry run.
#
# The standalone binary carries no secret store (`NoSecretStore` refuses by
# name); a host binary that has one calls `publish_main_with_store`.
#
# Encapsulation: owned values and generic seams. No pointer, no wildcard
# origin.
# =============================================================================

from std.ffi import abort
from std.pathlib import Path

from komira_http_client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector
from komira_secret_store import SecretStore, SecretValue

from kci_artifact_declaration import read_artifact_declarations
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
)

from .flags import PUBLISH_USAGE, PublishFlags, parse_publish_flags
from .inputs import LoadedRelease, load_release
from .pause import UsleepSleeper
from .plan import PublishTarget, resolve_targets
from .release_version import ReleaseVersion, read_release_version
from .report import (
    EXIT_ALREADY_PUBLISHED,
    EXIT_FAILED,
    EXIT_PUBLISHED,
    EXIT_REFUSED,
    EXIT_USAGE,
    PublishReport,
    write_report,
)
from .run import run_publish
from .upload import PublishCredential, RunOptions
from .workers import ChannelTransport, HttpChannelTransport, WorkerSleeper
from .verify import (
    require_closure,
    require_conda_only,
    require_lockstep,
    require_set_hash,
)


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


def prepare_release(flags: PublishFlags) raises -> PreparedRelease:
    """Step 0 (see the file header). RAISES with the refusal; no request."""
    var decls = read_artifact_declarations(flags.declarations_file)
    var loaded = load_release(decls, flags.artifacts_dir)
    require_conda_only(loaded.members)
    var rv = read_release_version(flags.release_version_file)
    require_lockstep(loaded.members, rv)
    require_closure(loaded.members)
    require_set_hash(loaded, flags.expect_set_hash)
    var text: String
    try:
        text = Path(flags.channels_file).read_text()
    except e:
        raise Error(
            String("channels file '") + flags.channels_file + String("' cannot be read: ") + String(e)
        )
    var decls_c = parse_channels_file(text)
    var channel = find_channel(decls_c, flags.channel)
    var repository = channel.repository_for(String(ARTIFACT_TYPE_CONDA))
    var targets = resolve_targets(channel, loaded.members)
    return PreparedRelease(loaded^, rv^, channel^, repository.credential.copy(), targets^)


struct NoSecretStore(SecretStore, Movable):
    """The standalone binary's store: it holds nothing, and says so. Layout:
    no fields."""

    def __init__(out self):
        pass

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        raise Error(
            String("this kci publish binary has no secret store to resolve '")
            + secret_ref
            + String("'; run kci publish from a binary that carries one, or use a channel")
            + String(" whose credential is OIDC trusted publishing")
        )


def _base_report(p: PreparedRelease, flags: PublishFlags) -> PublishReport:
    var r = PublishReport()
    r.channel = p.channel.name.copy()
    r.set_hash = p.loaded.set_hash()
    r.release_commit = p.release_version.commit.copy()
    r.dry_run = flags.dry_run
    return r^


def _refused(var p_report: PublishReport, code: Int, why: String) -> PublishReport:
    var r = p_report^
    r.exit_code = code
    var parts = why.split(String("\n"))
    for i in range(len(parts)):
        r.lines.append(String(parts[i]))
    r.finish_line()
    return r^


def _flow[T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper](
    flags: PublishFlags,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    mut store: S,
    run_opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    # --concurrency is the flag's, always (validated to 1..16 by the parser).
    var opts = run_opts.copy()
    opts.concurrency = flags.concurrency
    var p: PreparedRelease
    try:
        p = prepare_release(flags)
    except e:
        return PublishReport.refused(EXIT_REFUSED, String(e))
    var base = _base_report(p, flags)
    var host: String
    try:
        host = repo_host(p.targets[0].coordinate.repo)
    except e:
        return _refused(base^, EXIT_REFUSED, String("kci publish: ") + String(e))
    var public = p.channel.is_public()
    var has_cred = Bool(p.credential)
    var is_oidc = has_cred and p.credential.value().is_oidc_trusted_publishing()
    if flags.require_environment.byte_length() > 0 and not is_oidc:
        return _refused(
            base^,
            EXIT_REFUSED,
            String("kci publish: --require-environment checks the OIDC token's `environment`")
            + String(" claim, and channel '")
            + p.channel.name
            + String("' does not publish with OIDC trusted publishing"),
        )
    if not has_cred and not (flags.dry_run and public):
        return _refused(
            base^,
            EXIT_REFUSED,
            String("kci publish: channel '")
            + p.channel.name
            + String("' declares no credential for its CONDA repository, so it cannot be")
            + String(" published to"),
        )
    try:
        if flags.dry_run:
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            elif is_oidc:
                return _refused(
                    base.copy(),
                    EXIT_REFUSED,
                    String("kci publish: channel '")
                    + p.channel.name
                    + String("' is PRIVATE and publishes with OIDC only; a dry run would have")
                    + String(" to mint a token to read it, so it cannot be dry-run"),
                )
            else:
                var token = StaticTokenCredential.token_secret(
                    SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
                )
                var auth = token.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth^)
            var nobody = AnonymousCredential()
            return run_publish(p.targets, flags.claims, registry, nobody, True, opts, sleeper, base.copy())
        if is_oidc:
            var oidc = GithubOidcCredential[U].from_actions_env(oidc_t^, host.copy(), String(""))
            if flags.require_environment.byte_length() > 0:
                oidc.with_required_environment(flags.require_environment.copy())
            if public:
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
            else:
                var auth = oidc.authorization(SURFACE_PREFIX_DEV, host)
                registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
                registry.credential().arm(auth^)
            return run_publish(p.targets, flags.claims, registry, oidc, False, opts, sleeper, base.copy())
        var token = StaticTokenCredential.token_secret(
            SURFACE_PREFIX_DEV, host.copy(), store, p.credential.value().secret_name
        )
        if public:
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, String(""))
        else:
            var auth = token.authorization(SURFACE_PREFIX_DEV, host)
            registry.credential().configure(SURFACE_PREFIX_DEV, host^, auth.copy())
            registry.credential().arm(auth^)
        return run_publish(p.targets, flags.claims, registry, token, False, opts, sleeper, base.copy())
    except e:
        return _refused(base^, EXIT_FAILED, String("kci publish: the channel's credential: ") + String(e))


def publish_flow[T: ChannelTransport, U: PkgTransport, S: SecretStore, W: WorkerSleeper](
    flags: PublishFlags,
    mut registry: RegistrySet[T, PublishCredential],
    var oidc_t: U,
    mut store: S,
    opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    """Steps 0 to 6 over the given seams (see the file header): `registry`
    talks to the channel (its credential unconfigured; the flow configures
    it), `oidc_t` carries the OIDC exchange. Writes the report. Never
    raises."""
    var r = _flow(flags, registry, oidc_t^, store, opts, sleeper)
    try:
        write_report(r, flags.report_file)
    except e:
        r.lines.append(
            String("REPORT not written to '") + flags.report_file + String("': ") + String(e)
        )
        if r.exit_code == EXIT_PUBLISHED or r.exit_code == EXIT_ALREADY_PUBLISHED:
            r.exit_code = EXIT_FAILED
    return r^


comptime _Conn = TlsConnector[KernelTcpConnector]
comptime _Http = HttpChannelTransport[_Conn]


def _mk_connector(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("kci publish: TLS connector for ") + host + String(": ") + String(e))


def _http() -> _Http:
    return _Http(_mk_connector)


def publish_main_with_store[S: SecretStore](args: List[String], mut store: S) -> Int:
    """`kci publish` with `args` (the arguments after the verb), resolving an
    API_TOKEN channel credential through `store`. Prints the lines; returns
    the exit code."""
    var flags: PublishFlags
    try:
        flags = parse_publish_flags(args)
    except e:
        print(String(e))
        return EXIT_USAGE
    if flags.help:
        print(String(PUBLISH_USAGE))
        return EXIT_PUBLISHED
    var sleeper = UsleepSleeper()
    var registry = RegistrySet[_Http, PublishCredential](_http(), PublishCredential())
    var report = publish_flow(flags, registry, _http(), store, RunOptions(), sleeper)
    for i in range(len(report.lines)):
        print(report.lines[i])
    return report.exit_code


def publish_main(args: List[String]) -> Int:
    """`kci publish` as the standalone binary runs it (no secret store)."""
    var store = NoSecretStore()
    return publish_main_with_store(args, store)
