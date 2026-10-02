# =============================================================================
# src/kci_publish/cli.mojo -- `publish_main`: the `kci publish` verb from
#   argv to exit code.
# =============================================================================
#
# `publish_main(args)` parses the flags, then hands the real HTTPS transport
# to `publish_flow`; `publish_flow` is generic over the transport so the
# welded tests drive the whole verb over scripted ones. The order:
#
#   1. flags (`flags.mojo`) -- a refusal is exit 2, before any file is read;
#   2. inputs: the channels file, every manifest, the approved names, the
#      targets, each file's sha256, the approved-names gate (`plan.mojo`) --
#      a refusal is exit 3, before any request;
#   3. --dry-run: the presence reads go through an ANONYMOUS credential, the
#      plan is printed, and the verb returns. No credential is constructed,
#      resolved or minted, and no upload is composed. A PRIVATE channel cannot
#      be read anonymously, so a dry run of one is refused (exit 3);
#   4. otherwise the credential named by --credential is built, the plan is
#      read (anonymously for a PUBLIC channel, with the credential for a
#      PRIVATE one) and `run_publish` carries it out.
#
# THE ONE ENVIRONMENT READ is the GitHub Actions OIDC handshake, inside
# `GithubOidcCredential.from_actions_env`, and only for `--credential oidc`
# outside a dry run. Everything else comes from the flags and the files
# they name.
#
# `token-secret:<name>` resolves the name through the `SecretStore` the
# caller passes to `publish_main_with_store`. The standalone binary carries
# no secret store, so it refuses that form by name; a host binary that has
# one calls `publish_main_with_store`.
#
# Encapsulation: owned values and generic seams. No pointer, no wildcard
# origin.
# =============================================================================

from std.ffi import abort
from std.pathlib import Path

from komira_http.client.tls_connector import TlsConnector, build_public_ca_tls_connector
from komira_http.transport.kernel_tcp import KernelTcpConnector
from komira_retry import Sleeper
from komira_secret_store import SecretStore, SecretValue

from kci_pkg_upload import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    AnonymousCredential,
    ApprovedNames,
    GithubOidcCredential,
    HttpPkgTransport,
    PkgTransport,
    RegistryCredential,
    RegistrySet,
    StaticTokenCredential,
)
from kci_pkg_upload.coordinate import repo_host
from kci_release_channel import ChannelDeclaration, find_channel, parse_channels_file

from .flags import (
    CREDENTIAL_OIDC,
    CREDENTIAL_TOKEN_FILE,
    PUBLISH_USAGE,
    PublishFlags,
    parse_publish_flags,
)
from .manifest import ArtifactManifest, read_approved_names, read_artifact_manifest
from .pause import UsleepSleeper
from .plan import (
    PublishPlan,
    PublishTarget,
    refuse_unapproved_names,
    resolve_targets,
    verify_target_files,
)
from .run import (
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    PublishReport,
    RunOptions,
    plan_publish,
    run_publish,
)


struct PublishInputs(Movable, Deinitable):
    """Everything step 2 read and checked.

    Layout: owned values only. No pointer field."""

    var channel: ChannelDeclaration
    var targets: List[PublishTarget]
    var names: ApprovedNames

    def __init__(
        out self,
        var channel: ChannelDeclaration,
        var targets: List[PublishTarget],
        var names: ApprovedNames,
    ):
        self.channel = channel^
        self.targets = targets^
        self.names = names^


def load_inputs(flags: PublishFlags) raises -> PublishInputs:
    """Step 2 of the header. RAISES with every refusal it found."""
    var text: String
    try:
        text = Path(flags.channels_file).read_text()
    except e:
        raise Error(
            String("channels file '")
            + flags.channels_file
            + String("' cannot be read: ")
            + String(e)
        )
    var decls = parse_channels_file(text)
    var channel = find_channel(decls, flags.channel)
    var manifests = List[ArtifactManifest]()
    var refusals = List[String]()
    for i in range(len(flags.artifacts)):
        try:
            manifests.append(read_artifact_manifest(flags.artifacts[i]))
        except e:
            refusals.append(String(e))
    if len(refusals) > 0:
        raise Error(
            String("kci publish: refused before any upload:\n  ")
            + String("\n  ").join(refusals)
        )
    var names = read_approved_names(flags.approved_names_file)
    var targets = resolve_targets(decls, flags.channel, manifests)
    verify_target_files(targets)
    refuse_unapproved_names(targets, names)
    return PublishInputs(channel^, targets^, names^)


struct NoSecretStore(SecretStore, Movable):
    """The standalone binary's store: it holds nothing, and says so naming
    the forms that work. Layout: no fields."""

    def __init__(out self):
        pass

    def resolve(mut self, secret_ref: String) raises -> SecretValue:
        raise Error(
            String("this kci publish binary has no secret store to resolve '")
            + secret_ref
            + String("'; use --credential token-file:<path> or --credential oidc")
        )


def _surfaces_of(targets: List[PublishTarget]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(targets)):
        var s = SURFACE_PYPI_UPLOAD
        if targets[i].coordinate.substrate == SUBSTRATE_PREFIX_DEV_CONDA:
            s = SURFACE_PREFIX_DEV
        var seen = False
        for j in range(len(out)):
            if out[j] == s:
                seen = True
        if not seen:
            out.append(s)
    return out^


def _publish_with[T: PkgTransport, C: RegistryCredential, W: Sleeper](
    inputs: PublishInputs,
    var read_t: T,
    var write_t: T,
    var cred: C,
    opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    var writer = RegistrySet[T, C](write_t^, cred^)
    var plan: PublishPlan
    try:
        if inputs.channel.is_public():
            var reader = RegistrySet[T, AnonymousCredential](
                read_t^, AnonymousCredential()
            )
            plan = plan_publish(reader, inputs.channel, inputs.targets)
        else:
            plan = plan_publish(writer, inputs.channel, inputs.targets)
    except e:
        return PublishReport.refused(EXIT_REFUSED, String(e))
    return run_publish(plan, writer, inputs.names, False, opts, sleeper)


def publish_flow[T: PkgTransport, S: SecretStore, W: Sleeper](
    flags: PublishFlags,
    var read_t: T,
    var write_t: T,
    var cred_t: T,
    mut store: S,
    opts: RunOptions,
    mut sleeper: W,
) -> PublishReport:
    """Steps 2-4 of the header over the given transports: `read_t` for the
    anonymous presence reads, `write_t` for uploads and read-backs, `cred_t`
    for the OIDC exchange; `sleeper` waits between read-back polls. Never
    raises."""
    var inputs: PublishInputs
    try:
        inputs = load_inputs(flags)
    except e:
        return PublishReport.refused(EXIT_REFUSED, String(e))
    if flags.dry_run:
        if not inputs.channel.is_public():
            return PublishReport.refused(
                EXIT_REFUSED,
                String("kci publish: channel '")
                + inputs.channel.name
                + String("' is PRIVATE; a dry run reads anonymously and")
                + String(" resolves no credential, so it cannot read it"),
            )
        var reader = RegistrySet[T, AnonymousCredential](read_t^, AnonymousCredential())
        var plan: PublishPlan
        try:
            plan = plan_publish(reader, inputs.channel, inputs.targets)
        except e:
            return PublishReport.refused(EXIT_REFUSED, String(e))
        return run_publish(plan, reader, inputs.names, True, opts, sleeper)
    var surfaces = _surfaces_of(inputs.targets)
    try:
        if flags.credential_kind == CREDENTIAL_OIDC:
            var prefix_host = String("")
            var pypi_index = String("")
            for i in range(len(inputs.targets)):
                ref c = inputs.targets[i].coordinate
                if c.substrate == SUBSTRATE_PREFIX_DEV_CONDA:
                    prefix_host = repo_host(c.repo)
                else:
                    pypi_index = c.repo.copy()
            var oidc = GithubOidcCredential[T].from_actions_env(
                cred_t^, prefix_host^, pypi_index^
            )
            if flags.require_environment.byte_length() > 0:
                oidc.with_required_environment(flags.require_environment.copy())
            return _publish_with(inputs, read_t^, write_t^, oidc^, opts, sleeper)
        if len(surfaces) != 1:
            return PublishReport.refused(
                EXIT_REFUSED,
                String("kci publish: a token credential serves one registry,")
                + String(" and these artifacts publish to both a conda channel")
                + String(" and a python index; publish them in two runs"),
            )
        # The token is bound to the channel's host: `run_publish` asks for it
        # per (surface, host) before the first upload, so a target on any
        # other host is refused with nothing sent.
        var host = repo_host(inputs.targets[0].coordinate.repo)
        var token: StaticTokenCredential
        if flags.credential_kind == CREDENTIAL_TOKEN_FILE:
            token = StaticTokenCredential.token_file(
                surfaces[0], host^, flags.credential_arg
            )
        else:
            token = StaticTokenCredential.token_secret(
                surfaces[0], host^, store, flags.credential_arg
            )
        return _publish_with(inputs, read_t^, write_t^, token^, opts, sleeper)
    except e:
        return PublishReport.refused(EXIT_REFUSED, String("kci publish: ") + String(e))


comptime _Conn = TlsConnector[KernelTcpConnector]
comptime _Http = HttpPkgTransport[_Conn]


def _mk_connector(host: String) -> _Conn:
    try:
        return build_public_ca_tls_connector(host)
    except e:
        abort(String("kci publish: TLS connector for ") + host + String(": ") + String(e))


def _http() -> _Http:
    return _Http(_mk_connector)


def publish_main_with_store[S: SecretStore](args: List[String], mut store: S) -> Int:
    """`kci publish` with `args` (the arguments after the verb), resolving
    `token-secret:<name>` through `store`. Prints the report; returns the
    exit code."""
    var flags: PublishFlags
    try:
        flags = parse_publish_flags(args)
    except e:
        print(String(e))
        return EXIT_USAGE
    if flags.help:
        print(String(PUBLISH_USAGE))
        return EXIT_OK
    var sleeper = UsleepSleeper()
    var report = publish_flow(
        flags, _http(), _http(), _http(), store, RunOptions(), sleeper
    )
    for i in range(len(report.lines)):
        print(report.lines[i])
    return report.exit_code


def publish_main(args: List[String]) -> Int:
    """`kci publish` as the standalone binary runs it (no secret store)."""
    var store = NoSecretStore()
    return publish_main_with_store(args, store)
