# =============================================================================
# komira_fs_registry/azure_arm.mojo -- the Azure arm: URLs, endpoint and
# connector
# =============================================================================
#
# The Azure arm is komira_azure_blob's `AzureFs` over one container, the
# role S3 gives a bucket. Like the S3 arm it is built from values: an
# `AzureArmConfig` (the account, the endpoint, path-style or not) and an
# `AzureCredential` (a Shared Key, a SAS token, or anonymous), both handed
# in by the caller from its own flags; nothing here reads the environment.
#
# THE ENDPOINT. "" is Azure's own, `https://<account>.blob.core.windows.net`
# with the account as the host's first label. Any other endpoint is
# `http://host[:port]` or `https://host[:port]` with no path, and the scheme
# picks the connector the way the S3 arm's does: plaintext only when the
# endpoint says `http` (an emulator such as Azurite), TLS otherwise; any
# other scheme is refused. `path_style` puts the account in the first path
# segment instead of the host, as Azurite addresses it.
#
# THE URLS `parse_azure_url` accepts (each scheme compared ASCII
# case-insensitively, RFC 3986 section 3.1):
#
#   az://<container>/<path>                       account and endpoint from
#   abfs://<container>/<path>                     the configuration (the
#   abfss://<container>/<path>                    fsspec / adlfs form)
#   az://<container>@<account>.<svc>.core.windows.net/<path>
#   abfs[s]://<container>@<account>.<svc>.core.windows.net/<path>
#                                                 (Hadoop ABFS's form; <svc>
#                                                 is dfs or blob)
#   az://<account>.<svc>.core.windows.net/<container>/<path>
#   abfs[s]://<account>.<svc>.core.windows.net/<container>/<path>
#                                                 (DuckDB's fully qualified
#                                                 form)
#   https://<account>.blob.core.windows.net/<container>/<path>
#                                                 (the Blob service's
#                                                 resource URI)
#   http://<host>[:<port>]/<account>/<container>/<path>
#                                                 (an emulator, path-style)
#
# abfs and abfss are read through the flat Blob API, as AzureFs serves them:
# the ABFS file system is the container and the file path the blob name; a
# `.dfs.` host names the same account, whose blob endpoint is dialed. An
# http:// URL naming Azure's own host is refused (plaintext goes only to an
# emulator), and so is any query or fragment: a SAS token is a credential,
# not part of the URL, and the refusal does not echo it.
#
# No UnsafePointer, no wildcard origin.
# =============================================================================

from komira_azure_blob import (
    AzureClientSpec,
    AzureConfig,
    AzureCredential,
    AzureFs,
)
from komira_http_core.transport.io_stream import Connector

from .s3_connector import (
    S3ProdConnector,
    s3_prod_plain_connector,
    s3_prod_tls_connector,
)


comptime _AZURE_SUFFIX = ".core.windows.net"


@fieldwise_init
struct AzureArmConfig(Copyable, Movable, Deinitable):
    """The Azure arm's endpoint (module header): the storage account,
    `endpoint` ("" for Azure's own) and whether the account is the first
    path segment (`path_style`, an emulator) rather than the host's first
    label."""

    var account: String
    var endpoint: String
    var path_style: Bool

    @staticmethod
    def azure(account: String) -> AzureArmConfig:
        """Azure's own endpoint for `account`."""
        return AzureArmConfig(account=account, endpoint=String(""), path_style=False)


@fieldwise_init
struct AzureUrl(Copyable, Movable, Deinitable):
    """A parsed Azure URL (`parse_azure_url`): the account ("" when the URL
    names none), the container, the blob path ("" for the container's
    root), and the endpoint the URL names: `names_endpoint` False when it
    names none, else `endpoint` ("" for Azure's own) and `path_style`."""

    var account: String
    var container: String
    var path: String
    var names_endpoint: Bool
    var endpoint: String
    var path_style: Bool


def _ascii_lower(s: String) -> String:
    var out = String("")
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = Int(bs[i])
        if c >= ord("A") and c <= ord("Z"):
            c += 32
        out += chr(c)
    return out^


def _slice(s: String, start: Int, end: Int) -> String:
    return String(s[byte=start:end])


def _is_lower_alnum(c: UInt8) -> Bool:
    return (c >= UInt8(ord("a")) and c <= UInt8(ord("z"))) or (
        c >= UInt8(ord("0")) and c <= UInt8(ord("9"))
    )


def _check_account(account: String) raises:
    """Azure storage account names: 3 to 24 lowercase letters and digits."""
    var bs = account.as_bytes()
    var ok = len(bs) >= 3 and len(bs) <= 24
    for i in range(len(bs)):
        if not _is_lower_alnum(bs[i]):
            ok = False
    if not ok:
        raise Error(
            "fs_registry: '"
            + account
            + "' is not an Azure storage account name (3 to 24 lowercase"
            " letters and digits)"
        )


def _check_container(container: String) raises:
    """Azure container names: 3 to 63 lowercase letters, digits and single
    hyphens, starting and ending with a letter or digit; or one of the
    service's own containers, $root, $web and $logs."""
    if container == "$root" or container == "$web" or container == "$logs":
        return
    var bs = container.as_bytes()
    var n = len(bs)
    var ok = n >= 3 and n <= 63
    for i in range(n):
        var c = bs[i]
        if c == UInt8(ord("-")):
            if i == 0 or i == n - 1 or bs[i - 1] == UInt8(ord("-")):
                ok = False
        elif not _is_lower_alnum(c):
            ok = False
    if not ok:
        raise Error(
            "fs_registry: '"
            + container
            + "' is not an Azure container name (3 to 63 lowercase letters,"
            " digits and single hyphens, starting and ending with a letter or"
            " digit, or $root, $web, $logs)"
        )


def _account_of_host(host: String, allow_dfs: Bool) raises -> String:
    """The account of `<account>.blob.core.windows.net` (or, when
    `allow_dfs`, `<account>.dfs.core.windows.net`), compared
    case-insensitively."""
    var h = _ascii_lower(host)
    var dot = h.find(".")
    var svc = String("")
    if dot > 0 and h.endswith(_AZURE_SUFFIX):
        svc = _slice(h, dot + 1, h.byte_length() - _AZURE_SUFFIX.byte_length())
    if svc == "blob" or (allow_dfs and svc == "dfs"):
        var account = _slice(h, 0, dot)
        _check_account(account)
        return account^
    if allow_dfs:
        raise Error(
            "fs_registry: an Azure URL's host must be"
            " <account>.blob.core.windows.net or"
            " <account>.dfs.core.windows.net, got '"
            + host
            + "'"
        )
    raise Error(
        "fs_registry: an https:// Azure URL's host must be"
        " <account>.blob.core.windows.net, got '"
        + host
        + "'"
    )


def _split_first(s: String) -> Tuple[String, String]:
    """`s` split at its first `/`: (before, after), after "" when none."""
    var at = s.find("/")
    if at < 0:
        return (s, String(""))
    return (_slice(s, 0, at), _slice(s, at + 1, s.byte_length()))


def parse_azure_url(url: String) raises -> AzureUrl:
    """The account, container, path and endpoint `url` names (module
    header for the accepted forms). Raises `fs_registry: ...` naming the
    form expected for anything else; see the header for each refusal."""
    if url.find("?") >= 0 or url.find("#") >= 0:
        raise Error(
            "fs_registry: an Azure URL must not carry a query or fragment"
            " (a SAS token is a credential, not part of the URL)"
        )
    var sep = url.find("://")
    var scheme = String("")
    if sep > 0:
        scheme = _ascii_lower(_slice(url, 0, sep))
    var rest = String("")
    if sep > 0:
        rest = _slice(url, sep + 3, url.byte_length())
    var parts = _split_first(rest)
    var authority = parts[0]
    var tail = parts[1]
    var account = String("")
    var container = String("")
    var path = String("")
    var names_endpoint = False
    var endpoint = String("")
    var path_style = False
    if scheme == "az" or scheme == "abfs" or scheme == "abfss":
        var at = authority.find("@")
        if at >= 0:
            container = _slice(authority, 0, at)
            account = _account_of_host(
                _slice(authority, at + 1, authority.byte_length()), True
            )
            path = tail
            names_endpoint = True
        elif authority.find(".") >= 0:
            account = _account_of_host(authority, True)
            var p = _split_first(tail)
            container = p[0]
            path = p[1]
            names_endpoint = True
        else:
            container = authority
            path = tail
    elif scheme == "https":
        account = _account_of_host(authority, False)
        var p = _split_first(tail)
        container = p[0]
        path = p[1]
        names_endpoint = True
    elif scheme == "http":
        var host = authority
        var colon = authority.find(":")
        if colon >= 0:
            host = _slice(authority, 0, colon)
        if _ascii_lower(host).endswith(_AZURE_SUFFIX):
            raise Error(
                "fs_registry: an http:// Azure URL names Azure's own endpoint '"
                + host
                + "'; plaintext is only for an emulator endpoint, use https://"
            )
        var p = _split_first(tail)
        if host.byte_length() == 0 or p[0].byte_length() == 0 or p[1].byte_length() == 0:
            raise Error(
                "fs_registry: an http:// Azure URL is path-style,"
                " http://<host>[:<port>]/<account>/<container>/<path>, got '"
                + url
                + "'"
            )
        account = p[0]
        _check_account(account)
        var q = _split_first(p[1])
        container = q[0]
        path = q[1]
        names_endpoint = True
        endpoint = String("http://") + authority
        path_style = True
    else:
        raise Error(
            "fs_registry: an Azure URL must start with az://, abfs://,"
            " abfss://, https:// or http://, got '"
            + url
            + "'"
        )
    if container.byte_length() == 0:
        raise Error(
            "fs_registry: an Azure URL must name a container, got '" + url + "'"
        )
    _check_container(container)
    return AzureUrl(
        account=account^,
        container=container^,
        path=path^,
        names_endpoint=names_endpoint,
        endpoint=endpoint^,
        path_style=path_style,
    )


def azure_arm_config_for_url(url: AzureUrl, base: AzureArmConfig) raises -> AzureArmConfig:
    """The arm configuration that serves `url`: its account, else `base`'s;
    the endpoint it names, else `base`'s. Raises when the URL and `base`
    name different accounts or endpoints, or neither names an account."""
    var account = url.account
    if account.byte_length() == 0:
        account = base.account
    elif base.account.byte_length() > 0 and base.account != url.account:
        raise Error(
            "fs_registry: the Azure URL names account '"
            + url.account
            + "' and the configured account is '"
            + base.account
            + "'"
        )
    if account.byte_length() == 0:
        raise Error(
            "fs_registry: the Azure URL names no account and none is configured"
        )
    if not url.names_endpoint:
        return AzureArmConfig(
            account=account^, endpoint=base.endpoint, path_style=base.path_style
        )
    if base.endpoint.byte_length() > 0 and base.endpoint != url.endpoint:
        var named = url.endpoint
        if named.byte_length() == 0:
            named = String("Azure's own")
        raise Error(
            "fs_registry: the Azure URL names endpoint '"
            + named
            + "' and the configured endpoint is '"
            + base.endpoint
            + "'"
        )
    return AzureArmConfig(
        account=account^, endpoint=url.endpoint, path_style=url.path_style
    )


def azure_endpoint_is_plaintext(endpoint: String) raises -> Bool:
    """True for an `http://` endpoint, False for an `https://` one or ""
    (Azure's own, https). The scheme is compared ASCII case-insensitively.
    Raises `fs_registry: an Azure endpoint must start with http:// or
    https://, got '<endpoint>'` for anything else."""
    if endpoint.byte_length() == 0:
        return False
    var lower = _ascii_lower(endpoint)
    if lower.startswith("https://"):
        return False
    if lower.startswith("http://"):
        return True
    raise Error(
        "fs_registry: an Azure endpoint must start with http:// or https://, got '"
        + endpoint
        + "'"
    )


def azure_config_for(config: AzureArmConfig) raises -> AzureConfig:
    """komira_azure_blob's `AzureConfig` for `config`: Azure's own
    virtual-hosted endpoint for "", else the endpoint's scheme, host and
    port. Raises for an empty or invalid account, a scheme other than http
    or https, an endpoint with a path or no host, a port outside 1 to
    65535, or path-style addressing without an endpoint."""
    if config.account.byte_length() == 0:
        raise Error("fs_registry: an Azure arm needs an account name")
    _check_account(config.account)
    if config.endpoint.byte_length() == 0:
        if config.path_style:
            raise Error(
                "fs_registry: Azure's own endpoint is virtual-hosted;"
                " path-style addressing needs an endpoint"
            )
        return AzureConfig.azure(config.account)
    var plain = azure_endpoint_is_plaintext(config.endpoint)
    var scheme = String("http") if plain else String("https")
    var authority = _slice(
        config.endpoint, scheme.byte_length() + 3, config.endpoint.byte_length()
    )
    if authority.endswith("/"):
        authority = _slice(authority, 0, authority.byte_length() - 1)
    if authority.find("/") >= 0:
        raise Error(
            "fs_registry: an Azure endpoint is scheme://host[:port] with no"
            " path, got '"
            + config.endpoint
            + "'"
        )
    var host = authority
    var port = 0
    var colon = authority.find(":")
    if colon >= 0:
        host = _slice(authority, 0, colon)
        var digits = _slice(authority, colon + 1, authority.byte_length())
        var ds = digits.as_bytes()
        var ok = len(ds) > 0 and len(ds) <= 5
        for i in range(len(ds)):
            if ds[i] < UInt8(ord("0")) or ds[i] > UInt8(ord("9")):
                ok = False
            else:
                port = port * 10 + Int(ds[i]) - ord("0")
        if not ok or port < 1 or port > 65535:
            raise Error(
                "fs_registry: an Azure endpoint's port must be 1 to 65535, got '"
                + config.endpoint
                + "'"
            )
    if host.byte_length() == 0:
        raise Error(
            "fs_registry: an Azure endpoint names no host, got '"
            + config.endpoint
            + "'"
        )
    return AzureConfig.custom(
        config.account, scheme, host, UInt16(port), config.path_style
    )


def azure_connector_factory[
    C: Connector
](
    endpoint: String,
    mk_plain: def () raises thin -> C,
    mk_tls: def () raises thin -> C,
) raises -> def () raises thin -> C:
    """`mk_plain` for an `http://` endpoint, else `mk_tls`; refuses any other
    scheme (`azure_endpoint_is_plaintext`)."""
    if azure_endpoint_is_plaintext(endpoint):
        return mk_plain
    return mk_tls


def azure_arm[
    C: Connector
](
    var container: String,
    config: AzureArmConfig,
    credential: AzureCredential,
    mk_plain: def () raises thin -> C,
    mk_tls: def () raises thin -> C,
) raises -> AzureFs[C]:
    """The Azure arm on `container` over connector `C`: `mk_plain` makes its
    connectors when `config.endpoint` is `http://`, `mk_tls` otherwise.
    Builds no client and dials nothing here (AzureFs builds its client on
    the first verb)."""
    _check_container(container)
    var spec = AzureClientSpec[C](
        azure_config_for(config),
        credential,
        azure_connector_factory[C](config.endpoint, mk_plain, mk_tls),
    )
    return AzureFs[C](container^, spec^)


def azure_prod_arm(
    var container: String,
    config: AzureArmConfig,
    credential: AzureCredential,
) raises -> AzureFs[S3ProdConnector]:
    """The production Azure arm on `container`, over the registry's
    production connector: plaintext for an `http://` endpoint, TLS with
    public CA roots otherwise. Dials nothing here."""
    return azure_arm[S3ProdConnector](
        container^, config, credential, s3_prod_plain_connector, s3_prod_tls_connector
    )
