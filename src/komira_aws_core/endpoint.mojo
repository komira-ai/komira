# =============================================================================
# komira_aws_core/endpoint.mojo -- where an AWS request goes
# =============================================================================
#
# `AwsEndpoint` is a VALUE: scheme, host, port and an optional base path. A
# generated client holds an `Optional[AwsEndpoint]` override and asks
# `resolve_endpoint` for the endpoint of each send; nothing in a client reads
# the environment.
#
# Three ways to get one, and the order they win in:
#
# 1. An explicit endpoint the caller passes (a parameter of the client).
# 2. A CONFIGURED endpoint, read by `aws_endpoint_config` from the STANDARD
#    AWS SDK settings only, in the AWS SDKs' order
#    (https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html):
#      AWS_IGNORE_CONFIGURED_ENDPOINT_URLS / profile
#        `ignore_configured_endpoint_urls` = true: skip every step below;
#      AWS_ENDPOINT_URL_<SERVICE>  (the service id, upper case, spaces as `_`);
#      AWS_ENDPOINT_URL;
#      the profile's `services` section -- NOT read yet, so a profile naming
#        one is REFUSED rather than silently sent to AWS;
#      the profile's `endpoint_url`.
# 3. The standard AWS endpoint for the service and region,
#    `aws_service_endpoint`: `<prefix>[-fips].<region>.<dns suffix>`, with the
#    partition's dual-stack suffix when dual-stack is on. The FIPS and
#    dual-stack switches are AWS_USE_FIPS_ENDPOINT / AWS_USE_DUALSTACK_ENDPOINT
#    and the profile's `use_fips_endpoint` / `use_dualstack_endpoint`
#    (https://docs.aws.amazon.com/sdkref/latest/guide/feature-endpoints.html).
#
# The partitions are the AWS SDKs' partition table: each partition's region
# shape, DNS suffix, dual-stack suffix and FIPS / dual-stack support. A region
# of no known partition is in `aws`, which is what the SDKs do. Per-service
# exceptions (global endpoints such as iam.amazonaws.com) are not here: a
# `*-global` pseudo region and a legacy `fips-*` / `*-fips` region are
# REFUSED, naming the switch to use instead.
#
# komira adds no environment variable of its own. Every read goes through the
# `EnvSource` / `FileSource` seams of sources.mojo.
# =============================================================================

from ._text import ascii_lower, has_control, is_true_flag, sub, trim
from .credential_chain import AwsCredentialParams
from .credential_transport import host_header
from .shared_config import load_profiles, select_profile
from .sources import EnvSource, FileSource
from .sts_credentials import check_region


# The profile settings this module reads. Names from
# https://docs.aws.amazon.com/sdkref/latest/guide/settings-reference.html
comptime PROFILE_ENDPOINT_URL: StaticString = "endpoint_url"
comptime PROFILE_SERVICES: StaticString = "services"
comptime PROFILE_IGNORE_CONFIGURED_ENDPOINT_URLS: StaticString = (
    "ignore_configured_endpoint_urls"
)
comptime PROFILE_USE_FIPS_ENDPOINT: StaticString = "use_fips_endpoint"
comptime PROFILE_USE_DUALSTACK_ENDPOINT: StaticString = "use_dualstack_endpoint"


# -----------------------------------------------------------------------------
# AwsEndpoint
# -----------------------------------------------------------------------------


def _is_host_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(0x61) and c <= UInt8(0x7A))
        or (c >= UInt8(0x30) and c <= UInt8(0x39))
        or c == UInt8(0x2D)
        or c == UInt8(0x2E)
    )


def _check_host(host: String, what: String) raises:
    """A lower-case DNS name or IPv4 literal, or a bracketed IPv6 literal."""
    var b = host.as_bytes()
    if len(b) == 0:
        raise Error(what + " has an empty host")
    if b[0] == UInt8(0x5B):
        if b[len(b) - 1] != UInt8(0x5D) or len(b) < 3:
            raise Error(what + " has an unterminated IPv6 literal")
        for i in range(1, len(b) - 1):
            var c = b[i]
            var hex = (
                (c >= UInt8(0x30) and c <= UInt8(0x39))
                or (c >= UInt8(0x61) and c <= UInt8(0x66))
                or c == UInt8(0x3A)
                or c == UInt8(0x2E)
            )
            if not hex:
                raise Error(what + " has a malformed IPv6 literal")
        return
    for i in range(len(b)):
        if not _is_host_byte(b[i]):
            raise Error(
                what + " has a host with a byte outside [a-z0-9.-]"
            )
    if b[0] == UInt8(0x2D) or b[0] == UInt8(0x2E):
        raise Error(what + " has a host starting with '-' or '.'")
    if b[len(b) - 1] == UInt8(0x2D):
        raise Error(what + " has a host ending with '-'")


def _parse_port(s: String, what: String) raises -> Int:
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 5:
        raise Error(what + " has a malformed port")
    var v = 0
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error(what + " has a malformed port")
        v = v * 10 + Int(b[i] - UInt8(0x30))
    if v < 1 or v > 65535:
        raise Error(what + " has a port outside 1..65535")
    return v


struct AwsEndpoint(Copyable, Movable):
    """Where requests go: `scheme` ("https" or "http"), a lower-case `host`,
    a TCP `port`, and a `base_path` ("" or "/a/b", never a trailing '/')
    that prefixes every request target. `root_slash` records whether the
    endpoint URL's path ended in '/', which only the root target ("/")
    shows: botocore's `_urljoin` (botocore/awsrequest.py) sends `/proxy`
    for an endpoint path `/proxy` and `/proxy/` for `/proxy/`, and so does
    `target_for`."""

    var scheme: String
    var host: String
    var port: Int
    var base_path: String
    var root_slash: Bool

    def __init__(
        out self,
        scheme: String,
        host: String,
        port: Int,
        base_path: String,
        root_slash: Bool,
    ):
        self.scheme = scheme
        self.host = host
        self.port = port
        self.base_path = base_path
        self.root_slash = root_slash

    @staticmethod
    def https(host: String) raises -> AwsEndpoint:
        """`https://<host>` on port 443."""
        var h = ascii_lower(host)
        _check_host(h, "the endpoint")
        return AwsEndpoint(String("https"), h, 443, String(""), True)

    @staticmethod
    def parse(url: String, setting: String) raises -> AwsEndpoint:
        """An endpoint URL: `http(s)://host[:port][/path]`.

        Refuses user info, a query, a fragment, any scheme but http and
        https, and control bytes. Errors name `setting`, never the URL,
        which a caller may have copied from a secret-bearing place.
        """
        var what = String("the endpoint URL from ") + setting
        if has_control(url) or url.find(" ") >= 0:
            raise Error(what + " holds a space or a control byte")
        var at = url.find("://")
        if at <= 0:
            raise Error(what + " has no scheme (want http:// or https://)")
        var scheme = ascii_lower(sub(url, 0, at))
        if scheme != "http" and scheme != "https":
            raise Error(what + " has a scheme other than http or https")
        var rest = sub(url, at + 3, url.byte_length())
        if rest.find("@") >= 0:
            raise Error(what + " has user info; put credentials elsewhere")
        if rest.find("?") >= 0 or rest.find("#") >= 0:
            raise Error(what + " has a query or a fragment")
        var slash = rest.find("/")
        var authority = rest if slash < 0 else sub(rest, 0, slash)
        var path = String("") if slash < 0 else sub(
            rest, slash, rest.byte_length()
        )
        var port = 443 if scheme == "https" else 80
        var host: String
        if authority.startswith("["):
            var close = authority.find("]")
            if close < 0:
                raise Error(what + " has an unterminated IPv6 literal")
            host = sub(authority, 0, close + 1)
            var tail = sub(authority, close + 1, authority.byte_length())
            if tail.byte_length() > 0:
                if not tail.startswith(":"):
                    raise Error(what + " has text after the IPv6 literal")
                port = _parse_port(sub(tail, 1, tail.byte_length()), what)
        else:
            var colon = authority.find(":")
            if colon >= 0:
                host = sub(authority, 0, colon)
                port = _parse_port(
                    sub(authority, colon + 1, authority.byte_length()), what
                )
            else:
                host = authority
        host = ascii_lower(host)
        _check_host(host, what)
        var root_slash = path.endswith("/")
        while path.endswith("/"):
            path = sub(path, 0, path.byte_length() - 1)
        return AwsEndpoint(scheme, host, port, path, root_slash)

    def is_https(self) -> Bool:
        return self.scheme == "https"

    def host_header(self) -> String:
        """The Host header: the port only when it is not the scheme's
        default."""
        return host_header(self.host, self.port, self.scheme)

    def target_for(self, uri: String) -> String:
        """The request target for `uri` ("/" or "/path?query"), joined as
        botocore's `_urljoin` joins them: the root keeps the endpoint
        path exactly ("/proxy" stays "/proxy", "/proxy/" stays "/proxy/").
        The path is joined before the query is appended, as botocore's
        `prepare_request_dict` does, so a root with a query keeps it too
        ("/?a" on "/proxy" is "/proxy?a")."""
        if self.base_path.byte_length() == 0:
            return uri
        var q = uri.find("?")
        var path = uri if q < 0 else sub(uri, 0, q)
        var query = String("") if q < 0 else sub(uri, q, uri.byte_length())
        if path == "/":
            if self.root_slash:
                return self.base_path + "/" + query
            return self.base_path + query
        return self.base_path + uri

    def url_for(self, uri: String) -> String:
        """The absolute URL for `uri`, for a transport that takes one."""
        return self.scheme + "://" + self.host_header() + self.target_for(uri)

    def with_host_prefix(self, prefix: String) raises -> AwsEndpoint:
        """This endpoint with an operation's `endpoint.hostPrefix` (already
        substituted) prepended to the host. "" returns it unchanged. Refused
        on an IP-literal host, where a prefix makes no name."""
        if prefix.byte_length() == 0:
            return self.copy()
        if self.host.startswith("[") or _is_ipv4(self.host):
            raise Error(
                "an operation host prefix cannot apply to an IP-literal"
                " endpoint host"
            )
        var h = ascii_lower(prefix) + self.host
        _check_host(h, "the host prefix")
        var e = self.copy()
        e.host = h
        return e^


def _is_ipv4(host: String) -> Bool:
    var b = host.as_bytes()
    var dots = 0
    for i in range(len(b)):
        if b[i] == UInt8(0x2E):
            dots += 1
        elif b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            return False
    return dots == 3


def resolve_endpoint(
    override: Optional[AwsEndpoint], default_host: String
) raises -> AwsEndpoint:
    """The endpoint for one send: `override` when set, else
    `https://<default_host>`. This is the call a generated client makes; the
    override is the value the client was constructed with (an explicit
    endpoint, or `aws_endpoint_config(...).endpoint`)."""
    if override:
        return override.value().copy()
    return AwsEndpoint.https(default_host)


# -----------------------------------------------------------------------------
# Partitions
# -----------------------------------------------------------------------------


@fieldwise_init
struct AwsPartition(Copyable, Movable):
    """One AWS partition: its id, DNS suffixes and what it supports."""

    var id: String
    var dns_suffix: String
    var dual_stack_dns_suffix: String
    var supports_fips: Bool
    var supports_dual_stack: Bool


def _partition(id: StaticString) -> AwsPartition:
    if id == "aws-cn":
        return AwsPartition(
            String(id), "amazonaws.com.cn", "api.amazonwebservices.com.cn",
            True, True,
        )
    if id == "aws-us-gov":
        return AwsPartition(String(id), "amazonaws.com", "api.aws", True, True)
    if id == "aws-iso":
        return AwsPartition(String(id), "c2s.ic.gov", "", True, False)
    if id == "aws-iso-b":
        return AwsPartition(String(id), "sc2s.sgov.gov", "", True, False)
    if id == "aws-iso-e":
        return AwsPartition(String(id), "cloud.adc-e.uk", "", True, False)
    if id == "aws-iso-f":
        return AwsPartition(String(id), "csp.hci.ic.gov", "", True, False)
    if id == "aws-eusc":
        return AwsPartition(String(id), "amazonaws.eu", "", True, False)
    return AwsPartition(String("aws"), "amazonaws.com", "api.aws", True, True)


def _split_dash(s: String) -> List[String]:
    var out = List[String]()
    var start = 0
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x2D):
            out.append(sub(s, start, i))
            start = i + 1
    out.append(sub(s, start, len(b)))
    return out^


def _is_word(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
        )
        if not ok:
            return False
    return True


def _is_digits(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            return False
    return True


def aws_partition_for_region(region: String) -> AwsPartition:
    """The partition of `region`, by the partitions' region shapes:

      aws-us-gov  us-gov-<w>-<n>      aws-iso   us-iso-<w>-<n>
      aws-iso-b   us-isob-<w>-<n>     aws-iso-f us-isof-<w>-<n>
      aws-iso-e   eu-isoe-<w>-<n>     aws-eusc  eusc-de-<w>-<n>
      aws-cn      cn-<w>-<n>          aws       anything else

    The `<prefix>-global` pseudo regions map to their partition."""
    if region == "aws-cn-global":
        return _partition("aws-cn")
    if region == "aws-us-gov-global":
        return _partition("aws-us-gov")
    if region == "aws-iso-global":
        return _partition("aws-iso")
    if region == "aws-iso-b-global":
        return _partition("aws-iso-b")
    if region == "aws-iso-e-global":
        return _partition("aws-iso-e")
    if region == "aws-iso-f-global":
        return _partition("aws-iso-f")
    var p = _split_dash(region)
    if len(p) == 4 and _is_word(p[2]) and _is_digits(p[3]):
        if p[0] == "us" and p[1] == "gov":
            return _partition("aws-us-gov")
        if p[0] == "us" and p[1] == "iso":
            return _partition("aws-iso")
        if p[0] == "us" and p[1] == "isob":
            return _partition("aws-iso-b")
        if p[0] == "us" and p[1] == "isof":
            return _partition("aws-iso-f")
        if p[0] == "eu" and p[1] == "isoe":
            return _partition("aws-iso-e")
        if p[0] == "eusc" and p[1] == "de":
            return _partition("aws-eusc")
    if len(p) == 3 and p[0] == "cn" and _is_word(p[1]) and _is_digits(p[2]):
        return _partition("aws-cn")
    return _partition("aws")


def aws_service_endpoint(
    endpoint_prefix: String, region: String, use_fips: Bool, use_dual_stack: Bool
) raises -> AwsEndpoint:
    """The standard regional endpoint:
    `https://<prefix>[-fips].<region>.<dns suffix or dual-stack suffix>`.

    Refuses an empty or malformed region, a `*-global` pseudo region (global
    endpoints are per service), a legacy FIPS region name, and FIPS or
    dual-stack in a partition that does not offer it."""
    if region.byte_length() == 0:
        raise Error(
            "no AWS region is configured for the "
            + endpoint_prefix
            + " endpoint (set the region parameter, AWS_REGION, or the"
            " profile's region)"
        )
    check_region(region, String("the region parameter"))
    if region.endswith("-global") or region == "aws-global":
        raise Error(
            "the region "
            + region
            + " is a global pseudo region; komira_aws_core builds regional"
            " endpoints only"
        )
    if region.startswith("fips-") or region.endswith("-fips"):
        raise Error(
            "the region "
            + region
            + " is a legacy FIPS region name; use the plain region with"
            " AWS_USE_FIPS_ENDPOINT or use_fips_endpoint"
        )
    var p = aws_partition_for_region(region)
    if use_fips and not p.supports_fips:
        raise Error("the " + p.id + " partition has no FIPS endpoints")  # cov: unreachable every partition _partition returns supports FIPS
    if use_dual_stack and not p.supports_dual_stack:
        raise Error("the " + p.id + " partition has no dual-stack endpoints")
    var host = endpoint_prefix
    if use_fips:
        host += "-fips"
    host += "." + region + "."
    host += p.dual_stack_dns_suffix if use_dual_stack else p.dns_suffix
    return AwsEndpoint.https(host)


# -----------------------------------------------------------------------------
# Configured endpoints (environment and shared config)
# -----------------------------------------------------------------------------


def service_endpoint_env_var(service_id: String) -> String:
    """`AWS_ENDPOINT_URL_<SERVICE>`: the service id upper-cased, spaces as
    underscores ("Secrets Manager" -> AWS_ENDPOINT_URL_SECRETS_MANAGER)."""
    var out = String("AWS_ENDPOINT_URL_")
    var b = service_id.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(0x20):
            out += "_"
        elif c >= UInt8(0x61) and c <= UInt8(0x7A):
            out += chr(Int(c - UInt8(0x20)))
        else:
            out += chr(Int(c))
    return out^


def _flag(v: String, setting: String) raises -> Bool:
    """A true/false setting; "" is false. Anything else is refused."""
    var t = ascii_lower(trim(v))
    if t.byte_length() == 0 or t == "false":
        return False
    if is_true_flag(t):
        return True
    raise Error(setting + " is neither true nor false")


struct AwsEndpointConfig(Copyable, Movable):
    """What the standard settings say about one service's endpoint.

    - `endpoint`: the configured endpoint URL, `None` for real AWS. Pass it
      as the client's endpoint override.
    - `endpoint_setting`: which setting `endpoint` came from (a name, never
      the URL), "" when none.
    - `use_fips`, `use_dual_stack`: the switches for
      `aws_service_endpoint`.
    """

    var endpoint: Optional[AwsEndpoint]
    var endpoint_setting: String
    var use_fips: Bool
    var use_dual_stack: Bool

    def __init__(out self):
        self.endpoint = None
        self.endpoint_setting = String("")
        self.use_fips = False
        self.use_dual_stack = False


def _setting(name: StaticString, profile: String) -> String:
    return "the " + String(name) + " of profile '" + profile + "'"


def aws_endpoint_config[
    E: EnvSource, F: FileSource
](
    params: AwsCredentialParams,
    mut env: E,
    mut files: F,
    service_id: String,
    service_env_var: StaticString,
) raises -> AwsEndpointConfig:
    """The configured endpoint and switches for service `service_id`.

    `service_env_var` must be `service_endpoint_env_var(service_id)`; it is a
    `StaticString` because every environment read names its variable
    literally, so a generated client passes it as a literal. A mismatch is
    refused. `params.profile` selects the profile as in the credential
    chain."""
    if String(service_env_var) != service_endpoint_env_var(service_id):
        raise Error(
            "the service endpoint variable "
            + String(service_env_var)
            + " is not the one for service id '"
            + service_id
            + "'"
        )
    var out = AwsEndpointConfig()
    var choice = select_profile(params.profile, env)
    var profiles = load_profiles(env, files)
    var have_profile = profiles.has_profile(choice.name)
    if choice.named and not have_profile:
        raise Error(
            "the AWS profile '" + choice.name + "' is in neither shared file"
        )

    # FIPS and dual-stack: environment first, then the profile.
    var fips = trim(env.get("AWS_USE_FIPS_ENDPOINT"))
    if fips.byte_length() > 0:
        out.use_fips = _flag(fips, String("AWS_USE_FIPS_ENDPOINT"))
    elif have_profile:
        var p = profiles.profile(choice.name)
        out.use_fips = _flag(
            p.get(String(PROFILE_USE_FIPS_ENDPOINT)),
            _setting(PROFILE_USE_FIPS_ENDPOINT, choice.name),
        )
    var ds = trim(env.get("AWS_USE_DUALSTACK_ENDPOINT"))
    if ds.byte_length() > 0:
        out.use_dual_stack = _flag(ds, String("AWS_USE_DUALSTACK_ENDPOINT"))
    elif have_profile:
        var p = profiles.profile(choice.name)
        out.use_dual_stack = _flag(
            p.get(String(PROFILE_USE_DUALSTACK_ENDPOINT)),
            _setting(PROFILE_USE_DUALSTACK_ENDPOINT, choice.name),
        )

    # Configured endpoint URLs, unless they are switched off.
    var ignore = trim(env.get("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"))
    var ignored: Bool
    if ignore.byte_length() > 0:
        ignored = _flag(ignore, String("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"))
    elif have_profile:
        var p = profiles.profile(choice.name)
        ignored = _flag(
            p.get(String(PROFILE_IGNORE_CONFIGURED_ENDPOINT_URLS)),
            _setting(PROFILE_IGNORE_CONFIGURED_ENDPOINT_URLS, choice.name),
        )
    else:
        ignored = False
    if ignored:
        return out^

    var svc = trim(env.get(service_env_var))
    if svc.byte_length() > 0:
        out.endpoint = AwsEndpoint.parse(svc, String(service_env_var))
        out.endpoint_setting = String(service_env_var)
        return out^
    var glob = trim(env.get("AWS_ENDPOINT_URL"))
    if glob.byte_length() > 0:
        out.endpoint = AwsEndpoint.parse(glob, String("AWS_ENDPOINT_URL"))
        out.endpoint_setting = String("AWS_ENDPOINT_URL")
        return out^
    if have_profile:
        var p = profiles.profile(choice.name)
        if p.has(String(PROFILE_SERVICES)):
            raise Error(
                "profile '"
                + choice.name
                + "' names a services section; komira_aws_core does not read"
                " per-service endpoint sections yet, so it refuses rather"
                " than send to the default AWS endpoint"
            )
        var url = trim(p.get(String(PROFILE_ENDPOINT_URL)))
        if url.byte_length() > 0:
            var setting = _setting(PROFILE_ENDPOINT_URL, choice.name)
            out.endpoint = AwsEndpoint.parse(url, setting)
            out.endpoint_setting = setting
    return out^
