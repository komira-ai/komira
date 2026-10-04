# =============================================================================
# komira_gcp_core/adc.mojo -- Application Default Credentials
# =============================================================================
#
# Where a process's Google credentials come from when the caller names none,
# in the order Google's auth libraries search
# (https://cloud.google.com/docs/authentication/application-default-credentials;
# google-auth for Python, `google/auth/_default.py`; Go's
# `cloud.google.com/go/auth`, `credentials/detect.go`):
#
#   1. GOOGLE_APPLICATION_CREDENTIALS names a credentials file. When it is
#      set, that file is used or the search FAILS: a missing or unreadable
#      file is an error, not a reason to look further.
#   2. The gcloud well-known file, `application_default_credentials.json`,
#      that `gcloud auth application-default login` writes: in
#      $CLOUDSDK_CONFIG when that is set (google-auth's
#      `_cloud_sdk.get_config_path`), else $HOME/.config/gcloud on Linux and
#      macOS and %APPDATA%\gcloud on Windows. A missing file moves on.
#   3. The metadata server (GCE, Cloud Run, GKE, App Engine flexible): when
#      GCE_METADATA_HOST is set, its host:port (Go's `compute/metadata`
#      `OnGCE` takes that as being on Google Cloud); else when the DMI
#      product name /sys/class/dmi/id/product_name starts with "Google"
#      (google-auth's `detect_gce_residency_linux`); else when a GET of
#      http://169.254.169.254/ answers `Metadata-Flavor: Google`
#      (google-auth's `ping`, Go's `testOnGCE`). google-auth pings before it
#      reads DMI; either signal gives the same answer, and reading the file
#      first spares a GCE VM the network probe. Tokens then come from
#      metadata.google.internal, or GCE_METADATA_HOST when set.
#   4. Otherwise no credentials: Google's own refusal text.
#
# THE PROBE'S WORST CASE. komira_http_client has no connect timeout yet: the
# probe's `PROBE_TIMEOUT_US` (3 s) bounds the request from send to parsed
# head, not the TCP dial. Where 169.254.169.254 is unroutable the dial fails
# at once; where a network DROPS the SYN, the dial waits out the kernel's SYN
# retries (Linux's default `tcp_syn_retries` of 6 is about 127 s) before
# the search ends in "not found". google-auth and Go bound the dial at about
# 3 s. On GCE the DMI check answers first and no probe is sent.
#
# A credentials file (steps 1 and 2) is read by its `type`:
#   * `service_account`: the JWT bearer grant with the caller's scopes, or a
#     self-signed JWT for the caller's audience, as google-auth chooses
#     (`AdcOptions`);
#   * `authorized_user`: the refresh-token grant;
#   * `external_account` (workload identity federation): REFUSED by name.
#     No reader of that file type exists here;
#   * any other type: refused, naming it when it is one of Google's.
#
# THE ENVIRONMENT. The chain reads exactly these variables, each one that
# Google's own libraries read for the same purpose, through the `EnvSource`
# seam (sources.mojo), and nothing else (`adc_env_names()`):
#
#   variable                        google-auth (Python)   Go cloud.google.com/go/auth
#   GOOGLE_APPLICATION_CREDENTIALS  read                   read
#   CLOUDSDK_CONFIG                 read                   not read
#   HOME                            read (expanduser)      read
#   APPDATA                         read (Windows)         read (Windows)
#   GCE_METADATA_HOST               read                   read
#
# CLOUDSDK_CONFIG is google-auth's: gcloud itself honours it, so a developer
# who moved gcloud's directory is found. An EMPTY value reads as unset, as
# Go reads it (google-auth would try to open the empty path). Where HOME is
# unset or empty the gcloud file is not looked for: Go and Python fall back
# to the passwd entry, which this does not read. A welded test runs every
# branch over a `MapEnv` and checks every name read is one of them, and
# scans the sources for any other. komira settings (scopes, the audience,
# the HTTP config) are parameters.
#
# Not done here, and said so: no retry of the probe or of a token fetch
# (google-auth retries the probe three times); App Engine standard's legacy
# `app_identity` API; impersonated_service_account and
# external_account_authorized_user files; the GOOGLE_CLOUD_QUOTA_PROJECT
# override. A file's `quota_project_id` IS read, and exposed
# (`AdcFetcher.quota_project_id()`) for the client to send as
# `x-goog-user-project`; sending it is the client's.
# =============================================================================

from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_retry import MonotonicClock, SystemClock

from ._text import _trim
from .sources import (
    EnvSource,
    FileSource,
    ProcessEnv,
    ProcessFiles,
    SystemWallClock,
    WallClock,
)
from .token import AccessToken, AccessTokenFetcher, CachingTokenSource
from .token_http import GcpConnectorTransport, GcpHttpTransport
from .token_sources import (
    AuthorizedUserFetcher,
    MetadataServerFetcher,
    SelfSignedJwtFetcher,
    ServiceAccountKeyFetcher,
)
from .token_wire import (
    METADATA_DEFAULT_HOST,
    METADATA_IP,
    AuthorizedUser,
    ServiceAccountKey,
    TokenEndpoint,
    authorized_user_from_json,
    credentials_quota_project,
    credentials_type,
    metadata_endpoint,
    metadata_ping_answered,
    metadata_ping_request,
    parse_credentials_json,
    service_account_key_from_json,
)


# -----------------------------------------------------------------------------
# The environment variables the chain reads: Google's, and only these.
# -----------------------------------------------------------------------------

comptime ENV_GOOGLE_APPLICATION_CREDENTIALS: StaticString = "GOOGLE_APPLICATION_CREDENTIALS"
"""The credentials file (google-auth `environment_vars.CREDENTIALS`; Go
`golang.org/x/oauth2/google` and `cloud.google.com/go/auth`)."""

comptime ENV_CLOUDSDK_CONFIG: StaticString = "CLOUDSDK_CONFIG"
"""gcloud's configuration directory (google-auth
`environment_vars.CLOUD_SDK_CONFIG_DIR`)."""

comptime ENV_HOME: StaticString = "HOME"
"""The home directory under which gcloud keeps `.config/gcloud` (google-auth
`_cloud_sdk.get_config_path`; Go `internal/credsfile` `guessUnixHomeDir`)."""

comptime ENV_APPDATA: StaticString = "APPDATA"
"""gcloud's configuration root on Windows (google-auth
`_cloud_sdk._WINDOWS_CONFIG_ROOT_ENV_VAR`; Go `internal/credsfile`)."""

comptime ENV_GCE_METADATA_HOST: StaticString = "GCE_METADATA_HOST"
"""The metadata server's host:port (google-auth
`environment_vars.GCE_METADATA_HOST`; Go `compute/metadata`
`metadataHostEnv`)."""


def adc_env_names() -> List[String]:
    """Every environment variable the chain may read."""
    return [
        String(ENV_GOOGLE_APPLICATION_CREDENTIALS),
        String(ENV_CLOUDSDK_CONFIG),
        String(ENV_HOME),
        String(ENV_APPDATA),
        String(ENV_GCE_METADATA_HOST),
    ]


comptime ADC_WELL_KNOWN_FILE: StaticString = "application_default_credentials.json"
comptime GCE_PRODUCT_NAME_FILE: StaticString = "/sys/class/dmi/id/product_name"

comptime ADC_NOT_FOUND: StaticString = (
    "Your default credentials were not found. To set up Application Default"
    " Credentials, see"
    " https://cloud.google.com/docs/authentication/external/set-up-adc for"
    " more information."
)
"""Google's own text for an empty search (google-auth `_default.py`,
`_CLOUD_SDK_MISSING_CREDENTIALS`)."""

comptime PROBE_TIMEOUT_US: Int = 3_000_000
"""The metadata probe's bound: 3 s, google-auth's `_METADATA_DEFAULT_TIMEOUT`.
A caller's shorter request timeout wins."""


# -----------------------------------------------------------------------------
# What the chain found.
# -----------------------------------------------------------------------------

comptime ADC_SOURCE_ENV_FILE: Int = 1
"""Step 1: the file GOOGLE_APPLICATION_CREDENTIALS names."""
comptime ADC_SOURCE_GCLOUD_FILE: Int = 2
"""Step 2: the gcloud well-known file."""
comptime ADC_SOURCE_METADATA: Int = 3
"""Step 3: the metadata server."""

comptime ADC_KIND_SERVICE_ACCOUNT: Int = 1
"""A service-account key, through the JWT bearer grant."""
comptime ADC_KIND_SELF_SIGNED_JWT: Int = 2
"""A service-account key's self-signed JWT."""
comptime ADC_KIND_AUTHORIZED_USER: Int = 3
"""An authorized_user file's refresh-token grant."""
comptime ADC_KIND_METADATA_SERVER: Int = 4
"""The metadata server's token."""


struct AdcOptions(Copyable, Movable, Deinitable):
    """What the caller asks of the credentials, as google-auth's
    `default(scopes=...)` and a client's self-signed-JWT audience:

    * `scopes`: OAuth scopes. A service-account key exchanges a JWT for a
      token with them and the metadata server is asked for them. An
      authorized_user refresh is NOT: the user's grant fixed its scopes
      (google-auth's ADC never scopes those credentials).
    * `self_signed_jwt_audience`: `https://<service>.googleapis.com/`. A
      service-account key with no scopes signs a JWT for this audience and
      uses it as the token (google-auth `service_account.Credentials`,
      `_create_self_signed_jwt`).
    * `always_use_jwt_access`: a service-account key ALWAYS self-signs: with
      a `scope` claim when there are scopes, else for the audience
      (google-auth's `always_use_jwt_access`)."""

    var scopes: List[String]
    var self_signed_jwt_audience: String
    var always_use_jwt_access: Bool

    def __init__(
        out self,
        var scopes: List[String] = List[String](),
        var self_signed_jwt_audience: String = String(""),
        always_use_jwt_access: Bool = False,
    ):
        self.scopes = scopes^
        self.self_signed_jwt_audience = self_signed_jwt_audience^
        self.always_use_jwt_access = always_use_jwt_access


struct AdcCredentials(Movable, Deinitable):
    """The credentials the chain chose: which step (`source`), how a token
    is minted (`kind`), where (`origin`: the file's path or the metadata
    server's URL), the parsed credential, and the file's
    `quota_project_id` ("" when it names none, and for the metadata
    server). Not `Writable`."""

    var source: Int
    var kind: Int
    var origin: String
    var key: Optional[ServiceAccountKey]
    var user: Optional[AuthorizedUser]
    var metadata: Optional[TokenEndpoint]
    var quota_project_id: String

    def __init__(out self, source: Int, kind: Int, var origin: String):
        self.source = source
        self.kind = kind
        self.origin = origin^
        self.key = None
        self.user = None
        self.metadata = None
        self.quota_project_id = String("")


def gcloud_adc_path[E: EnvSource](mut env: E, windows: Bool) -> String:
    """The gcloud well-known file's path, "" when the environment gives no
    directory for it."""
    var config = env.get(ENV_CLOUDSDK_CONFIG)
    if config.byte_length() > 0:
        return config + ("\\" if windows else "/") + String(ADC_WELL_KNOWN_FILE)
    if windows:
        var appdata = env.get(ENV_APPDATA)
        if appdata.byte_length() == 0:
            return String("")
        return appdata + "\\gcloud\\" + String(ADC_WELL_KNOWN_FILE)
    var home = env.get(ENV_HOME)
    if home.byte_length() == 0:
        return String("")
    return home + "/.config/gcloud/" + String(ADC_WELL_KNOWN_FILE)


def _require_https(endpoint: TokenEndpoint, where: String) raises:
    """A credentials file's grant carries a credential (a signed assertion,
    or a refresh token and client secret), and goes over the TLS transport:
    its `token_uri` must be https."""
    if endpoint.scheme != "https":
        raise Error(
            "ADC: the credentials file " + where + "'s token_uri is not an"
            " https URL; its grant carries a credential"
        )


def _from_file(
    text: String, where: String, source: Int, options: AdcOptions
) raises -> AdcCredentials:
    var doc = parse_credentials_json(text, where)
    var t = credentials_type(doc, where)
    if t == "service_account":
        var key = service_account_key_from_json(doc, where)
        var kind: Int
        if options.always_use_jwt_access:
            if (
                len(options.scopes) == 0
                and options.self_signed_jwt_audience.byte_length() == 0
            ):
                raise Error(
                    "ADC: the service-account key " + where + " is set to"
                    " always self-sign, and that needs scopes or an audience"
                )
            kind = ADC_KIND_SELF_SIGNED_JWT
        elif len(options.scopes) > 0:
            kind = ADC_KIND_SERVICE_ACCOUNT
        elif options.self_signed_jwt_audience.byte_length() > 0:
            kind = ADC_KIND_SELF_SIGNED_JWT
        else:
            raise Error(
                "ADC: the service-account key " + where + " needs scopes (for"
                " the JWT bearer grant) or a self-signed JWT audience"
            )
        if kind == ADC_KIND_SERVICE_ACCOUNT:
            _require_https(key.token_endpoint, where)
        var out = AdcCredentials(source, kind, where.copy())
        out.key = key^
        out.quota_project_id = credentials_quota_project(doc, where)
        return out^
    if t == "authorized_user":
        var user = authorized_user_from_json(doc, where)
        _require_https(user.token_endpoint, where)
        var out = AdcCredentials(source, ADC_KIND_AUTHORIZED_USER, where.copy())
        out.user = user^
        out.quota_project_id = credentials_quota_project(doc, where)
        return out^
    if t == "external_account":
        raise Error(
            "ADC: the credentials file " + where + " is an external_account"
            " (workload identity federation) file, which komira_gcp_core does"
            " not read"
        )
    if (
        t == "impersonated_service_account"
        or t == "external_account_authorized_user"
        or t == "gdch_service_account"
    ):
        raise Error(
            "ADC: the credentials file " + where + " is of type " + t
            + ", which komira_gcp_core does not support"
        )
    raise Error(
        "ADC: the credentials file " + where + " is of an unknown type;"
        " expected service_account or authorized_user"
    )


def _metadata_credentials(var endpoint: TokenEndpoint) -> AdcCredentials:
    var out = AdcCredentials(
        ADC_SOURCE_METADATA, ADC_KIND_METADATA_SERVER, endpoint.url()
    )
    out.metadata = endpoint^
    return out^


def _probe_metadata[X: GcpHttpTransport](mut probe: X) -> Bool:
    """Whether 169.254.169.254 answers as a metadata server. A transport
    failure is "no"."""
    try:
        var ep = TokenEndpoint(String("http"), String(METADATA_IP), 80, String("/"))
        var res = probe.send(metadata_ping_request(ep))
        return metadata_ping_answered(res)
    except:
        return False


def _resolve_before_probe[E: EnvSource, F: FileSource](
    mut env: E, mut files: F, options: AdcOptions, windows: Bool
) raises -> Optional[AdcCredentials]:
    """Every step of the search but the network probe: the two files,
    GCE_METADATA_HOST and the DMI product name. None when the probe is all
    that is left."""
    var explicit = env.get(ENV_GOOGLE_APPLICATION_CREDENTIALS)
    if explicit.byte_length() > 0:
        if not files.exists(explicit):
            if files.present(explicit):
                raise Error(
                    "ADC: GOOGLE_APPLICATION_CREDENTIALS names "
                    + explicit + ", which is not a regular file"
                )
            raise Error(
                "ADC: GOOGLE_APPLICATION_CREDENTIALS names the file "
                + explicit + ", which does not exist"
            )
        var text = files.read(explicit)
        return _from_file(text, explicit, ADC_SOURCE_ENV_FILE, options)
    var well_known = gcloud_adc_path(env, windows)
    if well_known.byte_length() > 0 and files.exists(well_known):
        var text = files.read(well_known)
        return _from_file(text, well_known, ADC_SOURCE_GCLOUD_FILE, options)
    var host = env.get(ENV_GCE_METADATA_HOST)
    if host.byte_length() > 0:
        return _metadata_credentials(metadata_endpoint(host))
    if not windows:
        var product = String(GCE_PRODUCT_NAME_FILE)
        if files.exists(product):
            var name = String("")
            try:
                name = _trim(files.read(product))
            except:
                pass
            if name.startswith("Google"):
                return _metadata_credentials(
                    metadata_endpoint(String(METADATA_DEFAULT_HOST))
                )
    return None


def _resolve_after_probe(answered: Bool) raises -> AdcCredentials:
    """The last step: the metadata server when the probe answered, else
    Google's own text."""
    if answered:
        return _metadata_credentials(metadata_endpoint(String(METADATA_DEFAULT_HOST)))
    raise Error(String(ADC_NOT_FOUND))


def resolve_adc[E: EnvSource, F: FileSource, X: GcpHttpTransport](
    mut env: E,
    mut files: F,
    mut probe: X,
    options: AdcOptions,
    windows: Bool = False,
) raises -> AdcCredentials:
    """Search for Application Default Credentials in Google's order (the
    module header). `probe` carries the one metadata-server probe; it is
    used only when every other step finds nothing. `windows` picks the
    well-known file's Windows location and skips the Linux DMI check.
    Raises a named refusal for a file it cannot use, and Google's own text
    when it finds nothing."""
    var found = _resolve_before_probe(env, files, options, windows)
    if found:
        return found.take()
    return _resolve_after_probe(_probe_metadata(probe))


struct AdcFetcher[XP: GcpHttpTransport, XT: GcpHttpTransport, W: WallClock](
    AccessTokenFetcher, Movable, Deinitable
):
    """The fetcher for the credentials `resolve_adc` chose: one of the four
    of token_sources.mojo. `XP` is the plain-HTTP transport (the metadata
    server), `XT` the TLS one (Google's token endpoint). Only the one the
    credentials use need be given; the other may be None."""

    var kind: Int
    var _quota_project_id: String
    var _metadata: Optional[MetadataServerFetcher[Self.XP]]
    var _key: Optional[ServiceAccountKeyFetcher[Self.XT, Self.W]]
    var _jwt: Optional[SelfSignedJwtFetcher[Self.W]]
    var _user: Optional[AuthorizedUserFetcher[Self.XT]]

    def __init__(
        out self,
        var creds: AdcCredentials,
        var plain: Optional[Self.XP],
        var tls: Optional[Self.XT],
        var clock: Self.W,
        options: AdcOptions,
    ) raises:
        self.kind = creds.kind
        self._quota_project_id = creds.quota_project_id.copy()
        self._metadata = None
        self._key = None
        self._jwt = None
        self._user = None
        if creds.kind == ADC_KIND_METADATA_SERVER:
            if not plain:
                raise Error("AdcFetcher: the metadata server needs the plain transport")
            self._metadata = MetadataServerFetcher[Self.XP](
                plain.take(), creds.metadata.take(), options.scopes.copy()
            )
        elif creds.kind == ADC_KIND_SERVICE_ACCOUNT:
            if not tls:
                raise Error("AdcFetcher: a key's grant needs the TLS transport")
            self._key = ServiceAccountKeyFetcher[Self.XT, Self.W](
                tls.take(), clock^, creds.key.take(), options.scopes.copy()
            )
        elif creds.kind == ADC_KIND_SELF_SIGNED_JWT:
            # google-auth: always_use_jwt_access with scopes signs a `scope`
            # claim and no audience; otherwise the audience.
            var audience = options.self_signed_jwt_audience.copy()
            var scopes = List[String]()
            if options.always_use_jwt_access and len(options.scopes) > 0:
                audience = String("")
                scopes = options.scopes.copy()
            self._jwt = SelfSignedJwtFetcher[Self.W](
                clock^, creds.key.take(), audience^, scopes^
            )
        elif creds.kind == ADC_KIND_AUTHORIZED_USER:
            # No scopes on the refresh: a user's grant carries the scopes it
            # was consented with, and asking for others (a client's
            # datastore scope, say) can get `invalid_scope` for a scope the
            # user never granted. google-auth's ADC loads the file without
            # scopes and never applies them (`oauth2.credentials.Credentials`
            # is `ReadOnlyScoped`, so `with_scopes_if_required` leaves it),
            # and Go's refresh sends no `scope` either.
            if not tls:
                raise Error(
                    "AdcFetcher: an authorized_user refresh needs the TLS transport"
                )
            self._user = AuthorizedUserFetcher[Self.XT](
                tls.take(), creds.user.take(), List[String]()
            )
        else:
            raise Error("AdcFetcher: unknown credential kind " + String(creds.kind))

    def quota_project_id(self) -> String:
        """The credentials file's `quota_project_id`, "" when none. A client
        sends it as `x-goog-user-project`; Firestore, among others, refuses
        user credentials that carry none."""
        return self._quota_project_id.copy()

    def fetch(mut self, now_ms: Int64) raises -> AccessToken:
        if self._metadata:
            return self._metadata.value().fetch(now_ms)
        if self._key:
            return self._key.value().fetch(now_ms)
        if self._jwt:
            return self._jwt.value().fetch(now_ms)
        return self._user.value().fetch(now_ms)


def adc_probe_config(http_config: HttpClientConfig) -> HttpClientConfig:
    """The caller's config with the request bounded at `PROBE_TIMEOUT_US`,
    for the metadata probe."""
    var c = http_config
    if c.request_timeout_us <= 0 or c.request_timeout_us > PROBE_TIMEOUT_US:
        c.request_timeout_us = PROBE_TIMEOUT_US
    return c


def application_default_token_source_with[
    E: EnvSource,
    F: FileSource,
    XP: GcpHttpTransport,
    XT: GcpHttpTransport,
    W: WallClock,
    K: MonotonicClock,
](
    mut env: E,
    mut files: F,
    var probe: XP,
    var plain: XP,
    var tls: XT,
    var clock: W,
    var monotonic: K,
    options: AdcOptions,
    windows: Bool = False,
) raises -> CachingTokenSource[AdcFetcher[XP, XT, W], K]:
    """`application_default_token_source` over injected seams: the chain
    runs now (`resolve_adc`), and the source fetches its first token on its
    first request."""
    var creds = resolve_adc(env, files, probe, options, windows)
    return CachingTokenSource[AdcFetcher[XP, XT, W], K](
        AdcFetcher[XP, XT, W](
            creds^, Optional[XP](plain^), Optional[XT](tls^), clock^, options
        ),
        monotonic^,
    )


def application_default_token_source_from[
    E: EnvSource,
    F: FileSource,
    P: Connector,
    T: Connector,
    W: WallClock,
    K: MonotonicClock,
](
    mut env: E,
    mut files: F,
    http_config: HttpClientConfig,
    mk_plain: def () raises thin -> P,
    mk_tls: def () raises thin -> T,
    var clock: W,
    var monotonic: K,
    options: AdcOptions,
    windows: Bool = False,
) raises -> CachingTokenSource[
    AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], W], K
]:
    """`application_default_token_source` over injected env, file and clock
    seams, making connectors only as the search needs them: the probe's
    plain connector only when the probe runs (a connector that cannot be
    made counts as no answer, as a failed probe does), then the plain one
    for the metadata server OR the TLS one for a token endpoint, never
    both. So a missing trust store cannot fail ADC on Cloud Run, where only
    the metadata server is used."""
    var found = _resolve_before_probe(env, files, options, windows)
    var creds: AdcCredentials
    if found:
        creds = found.take()
    else:
        var answered = False
        try:
            var probe = GcpConnectorTransport[P](
                adc_probe_config(http_config), mk_plain()
            )
            answered = _probe_metadata(probe)
        except:
            answered = False
        creds = _resolve_after_probe(answered)
    var plain: Optional[GcpConnectorTransport[P]] = None
    var tls: Optional[GcpConnectorTransport[T]] = None
    if creds.kind == ADC_KIND_METADATA_SERVER:
        plain = GcpConnectorTransport[P](http_config, mk_plain())
    elif (
        creds.kind == ADC_KIND_SERVICE_ACCOUNT
        or creds.kind == ADC_KIND_AUTHORIZED_USER
    ):
        tls = GcpConnectorTransport[T](http_config, mk_tls())
    return CachingTokenSource[
        AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], W], K
    ](
        AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], W](
            creds^, plain^, tls^, clock^, options
        ),
        monotonic^,
    )


def application_default_token_source[P: Connector, T: Connector](
    http_config: HttpClientConfig,
    mk_plain: def () raises thin -> P,
    mk_tls: def () raises thin -> T,
    options: AdcOptions,
) raises -> CachingTokenSource[
    AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], SystemWallClock],
    SystemClock,
]:
    """A `GcpTokenSource` from Application Default Credentials: the process
    environment and filesystem, the wall and monotonic clocks, and
    komira_http_client over connectors the caller makes — `mk_plain` a
    plain-TCP one for the metadata server, `mk_tls` a TLS one for Google's
    token endpoint — each with an HTTP client built from `http_config` (the
    caller's; the metadata probe is further bounded by `PROBE_TIMEOUT_US`).
    A connector is made only when the search needs it
    (`application_default_token_source_from`). Raises when the chain finds
    nothing it can use."""
    var env = ProcessEnv()
    var files = ProcessFiles()
    # Mojo builds no Windows target: the Windows arm of the search is tested,
    # and unreachable from here.
    return application_default_token_source_from(
        env,
        files,
        http_config,
        mk_plain,
        mk_tls,
        SystemWallClock(),
        SystemClock(),
        options,
        False,
    )
