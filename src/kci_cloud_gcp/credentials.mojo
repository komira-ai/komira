# =============================================================================
# kci_cloud_gcp/credentials.mojo: which reader a deploy's credentials go to.
# =============================================================================
#
# A deploy reads GOOGLE_APPLICATION_CREDENTIALS only, and it is REQUIRED:
# kci never falls back to the gcloud well-known file or the metadata server,
# so an operator's own login is never used without being named. The file's
# `type` chooses the reader:
#   * `service_account`  komira_gcp_core's Application Default Credentials
#                        chain, which, with the variable set, reads only
#                        that file and never falls back
#                        (`service_account_token_source`);
#   * `external_account` komira_gcp_wif's reader (a CI's OIDC token
#                        exchanged at STS, optionally impersonating the
#                        deploy identity): its text goes to
#                        `parse_external_account`, and the token source is
#                        wif's `ExternalAccountFetcher` in komira_gcp_core's
#                        cache (`external_account_token_source`);
#   * anything else, `authorized_user` included: REFUSED. Only bootstrap runs
#     with a person's own credentials.
# The variable is read through komira_gcp_core's `EnvSource` seam and the
# file through its `FileSource`, so a test runs every branch with no
# process environment and no file system. No error names the file's path
# or repeats its bytes: only the variable, and the type when it is a plain
# word. An external_account file is read once, and the text whose type was
# checked is the text wif parses. A service_account file is read twice:
# once here to choose, and again by komira_gcp_core's chain, whose reader
# takes the variable and a `FileSource`, not text (its text reader is
# private to adc.mojo).
# =============================================================================

from komira_gcp_core import (
    ENV_GOOGLE_APPLICATION_CREDENTIALS,
    AdcFetcher,
    AdcOptions,
    CachingTokenSource,
    EnvSource,
    FileSource,
    GcpConnectorTransport,
    WallClock,
    application_default_token_source_from,
    credentials_type,
    parse_credentials_json,
)
from komira_gcp_wif import ExternalAccountFetcher, parse_external_account
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_retry import MonotonicClock


comptime CREDENTIALS_SERVICE_ACCOUNT = "service_account"
comptime CREDENTIALS_EXTERNAL_ACCOUNT = "external_account"
comptime CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform"
comptime _WHERE = "named by GOOGLE_APPLICATION_CREDENTIALS"


def _is_word(s: String) -> Bool:
    """`[a-z_]{1,64}`: a credentials type word, safe to repeat."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or c == ord("_")):
            return False
    return True


def _read_credentials[E: EnvSource, F: FileSource](mut env: E, mut files: F) raises -> Tuple[String, String]:
    """The text of the file GOOGLE_APPLICATION_CREDENTIALS names, read once,
    and its type (`deploy_credentials_type`'s rules)."""
    var path = env.get(ENV_GOOGLE_APPLICATION_CREDENTIALS)
    if path.byte_length() == 0:
        raise Error(
            "kci: REFUSED: a GCP deploy needs GOOGLE_APPLICATION_CREDENTIALS to name a service_account or"
            " external_account file; kci does not fall back to gcloud's file or the metadata server"
        )
    var text: String
    try:
        text = files.read(path)
    except:
        raise Error("kci: REFUSED: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS cannot be read")
    var t = credentials_type(parse_credentials_json(text, String(_WHERE)), String(_WHERE))
    if t == CREDENTIALS_SERVICE_ACCOUNT or t == CREDENTIALS_EXTERNAL_ACCOUNT:
        return (text^, t^)
    if t == "authorized_user":
        raise Error(
            "kci: REFUSED: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS is an authorized_user"
            " file (a person's own login); a deploy runs as a service_account or an external_account identity"
        )
    # The type is repeated only when it is a plain word: the file's bytes
    # are never echoed otherwise.
    if not _is_word(t):
        raise Error(
            "kci: REFUSED: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS has a type that is not"
            " a credentials type word; a deploy reads service_account or external_account only"
        )
    raise Error(
        String("kci: REFUSED: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS is of type \"") + t
        + String("\"; a deploy reads service_account or external_account only")
    )


def deploy_credentials_type[E: EnvSource, F: FileSource](mut env: E, mut files: F) raises -> String:
    """`service_account` or `external_account`: the type of the file
    GOOGLE_APPLICATION_CREDENTIALS names (the file header). Refused: the
    variable unset or empty, the file unreadable or not a credentials file,
    and every other type (named only when it is a plain word)."""
    var got = _read_credentials(env, files)
    return got[1].copy()


def service_account_token_source[
    E: EnvSource, F: FileSource, P: Connector, T: Connector, W: WallClock, K: MonotonicClock
](
    mut env: E,
    mut files: F,
    http_config: HttpClientConfig,
    mk_plain: def () raises thin -> P,
    mk_tls: def () raises thin -> T,
    var clock: W,
    var monotonic: K,
) raises -> CachingTokenSource[AdcFetcher[GcpConnectorTransport[P], GcpConnectorTransport[T], W], K]:
    """The token source of a `service_account` file: komira_gcp_core's
    chain, asked for the cloud-platform scope. Refuses any file
    `deploy_credentials_type` does not call a service_account file before
    the chain runs (an external_account file goes to komira_gcp_wif's
    reader instead)."""
    var t = deploy_credentials_type(env, files)
    if t != CREDENTIALS_SERVICE_ACCOUNT:
        raise Error(
            String("kci: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS is an ") + t
            + String(" file, which komira_gcp_wif reads, not komira_gcp_core")
        )
    var scopes = List[String]()
    scopes.append(String(CLOUD_PLATFORM_SCOPE))
    return application_default_token_source_from(
        env, files, http_config, mk_plain, mk_tls, clock^, monotonic^, AdcOptions(scopes^)
    )


def external_account_token_source[
    E: EnvSource, F: FileSource & Movable & Deinitable, CS: Connector, C: Connector, W: WallClock, K: MonotonicClock
](
    mut env: E,
    var files: F,
    var subject_client: HttpClient[CS],
    var sts: HttpClient[C],
    var iam: HttpClient[C],
    var wall: W,
    var monotonic: K,
) raises -> CachingTokenSource[ExternalAccountFetcher[CS, C, F, W], K]:
    """The token source of an `external_account` file: its text read
    through `files` and handed to komira_gcp_wif (`parse_external_account`,
    which refuses a file missing a field it needs, naming the field), and
    wif's fetcher in komira_gcp_core's cache. `subject_client` fetches a
    URL-sourced subject token, `sts` the exchange, `iam` the impersonation;
    `files` also serves a file-sourced subject token, read on each fetch.
    Refuses any file `deploy_credentials_type` does not call an
    external_account file before wif reads it (a service_account file goes
    to komira_gcp_core instead)."""
    # Read once: the text chosen by its type is the text wif parses.
    var got = _read_credentials(env, files)
    if got[1] != CREDENTIALS_EXTERNAL_ACCOUNT:
        raise Error(
            String("kci: the credentials file named by GOOGLE_APPLICATION_CREDENTIALS is a ") + got[1]
            + String(" file, which komira_gcp_core reads, not komira_gcp_wif")
        )
    var config = parse_external_account(got[0])
    return CachingTokenSource[ExternalAccountFetcher[CS, C, F, W], K](
        ExternalAccountFetcher[CS, C, F, W](config^, subject_client^, sts^, iam^, files^, wall^), monotonic^
    )
