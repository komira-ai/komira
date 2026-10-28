# =============================================================================
# komira_oauth/metadata.mojo: OAuth authorization server metadata (RFC 8414)
#   for an issuer of the `client_credentials` grant: where its metadata is,
#   and the document itself.
# =============================================================================
#
# `authorization_server_metadata_url(issuer)` is RFC 8414 section 3.1: the
# well-known path `/.well-known/oauth-authorization-server` inserted between
# the issuer's host and its path, with any terminating `/` of the path
# removed: `https://issuer.example/a` gives
# `https://issuer.example/.well-known/oauth-authorization-server/a`.
#
# `AuthorizationServerMetadata` holds the members this package reads:
#   * `issuer` (REQUIRED): an https URL with a host, no query and no fragment;
#   * `token_endpoint` and `jwks_uri` (required here: a client needs the
#     first, a service verifying the issuer's tokens the second): https URLs
#     with a host and no fragment;
#   * `grant_types_supported`, `token_endpoint_auth_methods_supported` and
#     `token_endpoint_auth_signing_alg_values_supported`: lists of distinct
#     non-empty strings, empty when the document leaves them out. An empty
#     list is what the document said, not what RFC 8414 defaults it to
#     (`authorization_code` and `implicit`; `client_secret_basic`).
# When the auth methods name `private_key_jwt`, the signing algorithms must be
# listed (RFC 8414 section 2).
#
# `AuthorizationServerMetadata.for_client_credentials(...)` fills the three
# lists for an issuer that serves only this package's flow: `grant_types_supported`
# `["client_credentials"]`, `token_endpoint_auth_methods_supported`
# `["private_key_jwt"]` and the signing algorithms given.
#
# `render()` writes those members in that order and leaves out an empty list
# (section 3.2: a member with zero elements is omitted). This issuer has no
# authorization endpoint and supports no response type, so the REQUIRED
# `response_types_supported` would have zero elements and is omitted too.
#
# `parse_authorization_server_metadata(doc, issuer)` reads a document fetched
# from `authorization_server_metadata_url(issuer)`, refusing with a fixed
# `OAuthError: ...` text (no byte of the document): a document longer than
# `OAUTH_METADATA_MAX_BYTES` or not a JSON object, a member named twice at
# any depth, any member above that fails its rule, and an `issuer` that is not
# `issuer` byte for byte (section 3.3). Other members are ignored.
#
# ENCAPSULATION: `String` and `List[String]` in and out. No pointer crosses
# this file's API.
# =============================================================================

from komira_json import write_json_string

from komira_oauth.token_wire import OAUTH_GRANT_CLIENT_CREDENTIALS
from komira_oauth._text import (
    _distinct_nonempty_refusal,
    _https_url_refusal,
    _lit,
    _parse_object,
    _refuse,
    _required_string,
    _string_list,
    _write_string_list,
)


comptime OAUTH_METADATA_WELL_KNOWN: String = "/.well-known/oauth-authorization-server"
# The longest metadata document the parser reads, in bytes.
comptime OAUTH_METADATA_MAX_BYTES: Int = 65536
comptime OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT: String = "private_key_jwt"


def _check_url(what: String, url: String, allow_query: Bool) raises:
    var why = _https_url_refusal(url, allow_query)
    if why != "":
        _refuse(what + " " + why)


def authorization_server_metadata_url(issuer: String) raises -> String:
    """Where `issuer` publishes its metadata (see the file header). Raises
    `OAuthError: ...` for an issuer that is not an https URL with a host and
    no query or fragment."""
    _check_url("the issuer", issuer, False)
    var b = issuer.as_bytes()
    var host_end = 8  # after "https://"
    while host_end < len(b) and b[host_end] != 0x2F:  # '/'
        host_end += 1
    var path_end = len(b)
    while path_end > host_end and b[path_end - 1] == 0x2F:
        path_end -= 1
    var out = List[UInt8]()
    out.extend(b[0:host_end])
    _lit(out, OAUTH_METADATA_WELL_KNOWN)
    out.extend(b[host_end:path_end])
    return String(unsafe_from_utf8=Span(out))


struct AuthorizationServerMetadata(Copyable, Movable):
    """The metadata members this package reads (see the file header)."""

    var issuer: String
    var token_endpoint: String
    var jwks_uri: String
    var grant_types_supported: List[String]
    var token_endpoint_auth_methods_supported: List[String]
    var token_endpoint_auth_signing_alg_values_supported: List[String]

    def __init__(
        out self,
        *,
        issuer: String,
        token_endpoint: String,
        jwks_uri: String,
        grant_types_supported: List[String],
        token_endpoint_auth_methods_supported: List[String],
        token_endpoint_auth_signing_alg_values_supported: List[String],
    ) raises:
        """Raises `OAuthError: ...` for any member that fails its rule (see
        the file header)."""
        _check_url("the issuer", issuer, False)
        _check_url("the token endpoint", token_endpoint, True)
        _check_url("the jwks_uri", jwks_uri, True)
        var why = _distinct_nonempty_refusal(grant_types_supported)
        if why != "":
            _refuse("grant_types_supported " + why)
        why = _distinct_nonempty_refusal(token_endpoint_auth_methods_supported)
        if why != "":
            _refuse("token_endpoint_auth_methods_supported " + why)
        why = _distinct_nonempty_refusal(
            token_endpoint_auth_signing_alg_values_supported
        )
        if why != "":
            _refuse("token_endpoint_auth_signing_alg_values_supported " + why)
        var jwt_auth = False
        for i in range(len(token_endpoint_auth_methods_supported)):
            if (
                token_endpoint_auth_methods_supported[i]
                == OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT
            ):
                jwt_auth = True
        if jwt_auth and len(token_endpoint_auth_signing_alg_values_supported) == 0:
            _refuse("private_key_jwt is listed without its signing algorithms")
        self.issuer = issuer.copy()
        self.token_endpoint = token_endpoint.copy()
        self.jwks_uri = jwks_uri.copy()
        self.grant_types_supported = grant_types_supported.copy()
        self.token_endpoint_auth_methods_supported = (
            token_endpoint_auth_methods_supported.copy()
        )
        self.token_endpoint_auth_signing_alg_values_supported = (
            token_endpoint_auth_signing_alg_values_supported.copy()
        )

    @staticmethod
    def for_client_credentials(
        *,
        issuer: String,
        token_endpoint: String,
        jwks_uri: String,
        signing_algs: List[String],
    ) raises -> AuthorizationServerMetadata:
        """The metadata of an issuer whose token endpoint serves the
        `client_credentials` grant with `private_key_jwt` only, verifying
        assertions signed with `signing_algs`. Raises as the constructor
        does; an empty `signing_algs` is refused."""
        var grants = List[String]()
        grants.append(OAUTH_GRANT_CLIENT_CREDENTIALS)
        var methods = List[String]()
        methods.append(OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT)
        return AuthorizationServerMetadata(
            issuer=issuer,
            token_endpoint=token_endpoint,
            jwks_uri=jwks_uri,
            grant_types_supported=grants,
            token_endpoint_auth_methods_supported=methods,
            token_endpoint_auth_signing_alg_values_supported=signing_algs,
        )

    def render(self) -> String:
        """The metadata document (see the file header)."""
        var buf = List[UInt8]()
        _lit(buf, '{"issuer":')
        write_json_string(buf, self.issuer)
        _lit(buf, ',"token_endpoint":')
        write_json_string(buf, self.token_endpoint)
        _lit(buf, ',"jwks_uri":')
        write_json_string(buf, self.jwks_uri)
        if len(self.grant_types_supported) > 0:
            _lit(buf, ',"grant_types_supported":')
            _write_string_list(buf, self.grant_types_supported)
        if len(self.token_endpoint_auth_methods_supported) > 0:
            _lit(buf, ',"token_endpoint_auth_methods_supported":')
            _write_string_list(buf, self.token_endpoint_auth_methods_supported)
        if len(self.token_endpoint_auth_signing_alg_values_supported) > 0:
            _lit(buf, ',"token_endpoint_auth_signing_alg_values_supported":')
            _write_string_list(
                buf, self.token_endpoint_auth_signing_alg_values_supported
            )
        buf.append(0x7D)  # '}'
        return String(unsafe_from_utf8=Span(buf))


def _list_or_empty(v: Optional[List[String]]) -> List[String]:
    if v:
        return v.value().copy()
    return List[String]()


def parse_authorization_server_metadata(
    doc: String, issuer: String
) raises -> AuthorizationServerMetadata:
    """Read the metadata document of `issuer` (see the file header). Raises
    `OAuthError: ...`."""
    var obj = _parse_object(doc, OAUTH_METADATA_MAX_BYTES, "the metadata")
    var iss = _required_string(obj, "issuer")
    if iss != issuer:
        _refuse("member issuer is not the issuer")
    return AuthorizationServerMetadata(
        issuer=iss,
        token_endpoint=_required_string(obj, "token_endpoint"),
        jwks_uri=_required_string(obj, "jwks_uri"),
        grant_types_supported=_list_or_empty(
            _string_list(obj, "grant_types_supported")
        ),
        token_endpoint_auth_methods_supported=_list_or_empty(
            _string_list(obj, "token_endpoint_auth_methods_supported")
        ),
        token_endpoint_auth_signing_alg_values_supported=_list_or_empty(
            _string_list(obj, "token_endpoint_auth_signing_alg_values_supported")
        ),
    )
