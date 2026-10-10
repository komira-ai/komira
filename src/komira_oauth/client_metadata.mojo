# =============================================================================
# komira_oauth/client_metadata.mojo: the registration record of a client of
#   the `client_credentials` grant authenticating with `private_key_jwt`,
#   shaped as RFC 7591 client metadata, and its JSON codec.
# =============================================================================
#
# One record is one JSON object with the metadata as top-level members (RFC
# 7591 section 3.1). `render()` writes them in this order:
#
#   {"client_id":..,                                   required, non-empty
#    "client_name":..,                                 left out when ""
#    "token_endpoint_auth_method":"private_key_jwt",   always
#    "token_endpoint_auth_signing_alg":"ES256",        ES256 or EdDSA
#    "grant_types":["client_credentials"],             always
#    "scope":..,                                       left out when ""
#    "jwks":{"keys":[..]}  or  "jwks_uri":"https://..",  exactly one
#    "resource_types":[..]}                            left out when empty
#
# `client_id` is in the record because the record is the registry's copy (RFC
# 7591 returns it in the section 3.2.1 answer). `token_endpoint_auth_signing_alg`
# is the OpenID Connect registration member: it pins the one algorithm the
# token endpoint verifies this client's assertions with. `resource_types` is
# this profile's one extension member: the resource kinds the client declares,
# distinct non-empty strings. `scope` is an RFC 6749 scope. `jwks` holds the
# client's public keys (komira_jwks), several during a key rotation, and never
# a private member; `jwks_uri` is an https URL with a host and no fragment.
# RFC 7591 section 2 forbids both.
#
# `parse_client_metadata(doc)` reads a record, refusing with a fixed
# `OAuthError: ...` text (no byte of the document): a document longer than
# `OAUTH_CLIENT_METADATA_MAX_BYTES`, not a JSON object, or naming a member twice
# at any depth; a member above that is present and fails its rule (an empty
# string included, so a record renders back to the same bytes); a
# `token_endpoint_auth_method` other than `private_key_jwt` (the RFC default,
# `client_secret_basic`, when it is absent); `grant_types` other than exactly
# `["client_credentials"]` (the RFC default, `authorization_code`, when it is
# absent); both or neither of `jwks` and `jwks_uri`; a `jwks` that komira_jwks
# refuses, holds no key, or holds a key it skips. Members it does not know are
# ignored (RFC 7591 section 2), so the RFC's own section 3.1 examples read up
# to their `client_secret_basic`.
#
# ENCAPSULATION: owned values in and out. No pointer crosses this file's API.
# =============================================================================

from komira_json import JSON_OBJECT, write_json_string
from komira_jwks import JwkSet, parse_jwk_set

from komira_oauth._text import (
    _distinct_nonempty_refusal,
    _https_url_refusal,
    _lit,
    _member,
    _optional_string,
    _parse_object,
    _refuse,
    _required_string,
    _scope_refusal,
    _string_list,
    _write_string_list,
)
from komira_oauth.metadata import OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT
from komira_oauth.token_wire import OAUTH_GRANT_CLIENT_CREDENTIALS


# The longest registration record the parser reads, in bytes.
comptime OAUTH_CLIENT_METADATA_MAX_BYTES: Int = 262144


def _check(
    client_id: String,
    signing_alg: String,
    scope: String,
    resource_types: List[String],
) raises:
    if client_id.byte_length() == 0:
        _refuse("the client_id is empty")
    if signing_alg != "ES256" and signing_alg != "EdDSA":
        _refuse("the signing alg must be ES256 or EdDSA")
    if scope.byte_length() > 0 and _scope_refusal(scope) != "":
        _refuse("the scope is not a scope")
    var why = _distinct_nonempty_refusal(resource_types)
    if why != "":
        _refuse("resource_types " + why)


def _check_keys(jwks: JwkSet) raises:
    if len(jwks.keys) == 0:
        _refuse("the jwks holds no key")
    if len(jwks.skipped) > 0:
        _refuse("the jwks holds a key komira_jwks skips")


struct ClientMetadata(Copyable, Movable):
    """A client registration record (see the file header). Build one with
    `with_jwks` or `with_jwks_uri`."""

    var client_id: String
    var client_name: String
    var token_endpoint_auth_signing_alg: String
    var scope: String
    var jwks: Optional[JwkSet]
    var jwks_uri: String
    var resource_types: List[String]

    def __init__(
        out self,
        *,
        var _client_id: String,
        var _client_name: String,
        var _alg: String,
        var _scope: String,
        var _jwks: Optional[JwkSet],
        var _jwks_uri: String,
        var _resource_types: List[String],
    ):
        """Unchecked; use `with_jwks` or `with_jwks_uri`."""
        self.client_id = _client_id^
        self.client_name = _client_name^
        self.token_endpoint_auth_signing_alg = _alg^
        self.scope = _scope^
        self.jwks = _jwks^
        self.jwks_uri = _jwks_uri^
        self.resource_types = _resource_types^

    @staticmethod
    def with_jwks(
        *,
        client_id: String,
        client_name: String,
        signing_alg: String,
        scope: String,
        jwks: JwkSet,
        resource_types: List[String],
    ) raises -> ClientMetadata:
        """A record holding the client's public keys. Raises `OAuthError:
        ...` for an empty `client_id`, an algorithm other than ES256 and
        EdDSA, a scope that is not one, a set with no key or a skipped key,
        or `resource_types` with an empty or repeated value."""
        _check(client_id, signing_alg, scope, resource_types)
        _check_keys(jwks)
        return ClientMetadata(
            _client_id=client_id.copy(),
            _client_name=client_name.copy(),
            _alg=signing_alg.copy(),
            _scope=scope.copy(),
            _jwks=Optional[JwkSet](jwks.copy()),
            _jwks_uri=String(""),
            _resource_types=resource_types.copy(),
        )

    @staticmethod
    def with_jwks_uri(
        *,
        client_id: String,
        client_name: String,
        signing_alg: String,
        scope: String,
        jwks_uri: String,
        resource_types: List[String],
    ) raises -> ClientMetadata:
        """A record naming where the client's keys are. Raises as
        `with_jwks`, and for a `jwks_uri` that is not an https URL with a
        host and no fragment."""
        _check(client_id, signing_alg, scope, resource_types)
        var why = _https_url_refusal(jwks_uri, True)
        if why != "":
            _refuse("the jwks_uri " + why)
        return ClientMetadata(
            _client_id=client_id.copy(),
            _client_name=client_name.copy(),
            _alg=signing_alg.copy(),
            _scope=scope.copy(),
            _jwks=Optional[JwkSet](),
            _jwks_uri=jwks_uri.copy(),
            _resource_types=resource_types.copy(),
        )

    def render(self) -> String:
        """The record's JSON (see the file header)."""
        var buf = List[UInt8]()
        _lit(buf, '{"client_id":')
        write_json_string(buf, self.client_id)
        if self.client_name.byte_length() > 0:
            _lit(buf, ',"client_name":')
            write_json_string(buf, self.client_name)
        _lit(buf, ',"token_endpoint_auth_method":')
        write_json_string(buf, OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT)
        _lit(buf, ',"token_endpoint_auth_signing_alg":')
        write_json_string(buf, self.token_endpoint_auth_signing_alg)
        _lit(buf, ',"grant_types":["client_credentials"]')
        if self.scope.byte_length() > 0:
            _lit(buf, ',"scope":')
            write_json_string(buf, self.scope)
        if self.jwks:
            _lit(buf, ',"jwks":')
            _lit(buf, self.jwks.value().render())
        else:
            _lit(buf, ',"jwks_uri":')
            write_json_string(buf, self.jwks_uri)
        if len(self.resource_types) > 0:
            _lit(buf, ',"resource_types":')
            _write_string_list(buf, self.resource_types)
        buf.append(0x7D)  # '}'
        return String(unsafe_from_utf8=Span(buf))


def _optional_or_empty(v: Optional[String]) -> String:
    if v:
        return v.value()
    return String("")


def parse_client_metadata(doc: String) raises -> ClientMetadata:
    """Read a registration record (see the file header). Raises
    `OAuthError: ...`."""
    var obj = _parse_object(
        doc, OAUTH_CLIENT_METADATA_MAX_BYTES, "the client metadata"
    )
    var client_id = _required_string(obj, "client_id")
    var client_name = _optional_or_empty(_optional_string(obj, "client_name"))
    var method = _optional_string(obj, "token_endpoint_auth_method")
    if not method or method.value() != OAUTH_AUTH_METHOD_PRIVATE_KEY_JWT:
        _refuse("token_endpoint_auth_method is not private_key_jwt")
    var alg = _required_string(obj, "token_endpoint_auth_signing_alg")
    var grants = _string_list(obj, "grant_types")
    if (
        not grants
        or len(grants.value()) != 1
        or grants.value()[0] != OAUTH_GRANT_CLIENT_CREDENTIALS
    ):
        _refuse("grant_types is not exactly client_credentials")
    var scope = _optional_or_empty(_optional_string(obj, "scope"))
    var resource_types = List[String]()
    var rt = _string_list(obj, "resource_types")
    if rt:
        resource_types = rt.value().copy()
    var jwks_at = _member(obj, "jwks")
    var uri = _optional_string(obj, "jwks_uri")
    if jwks_at >= 0 and uri:
        _refuse("the record holds both jwks and jwks_uri")
    if jwks_at >= 0:
        if obj.children[jwks_at].kind != JSON_OBJECT:
            _refuse("member jwks is not a JWK Set")
        var keys: JwkSet
        try:
            keys = parse_jwk_set(obj.children[jwks_at].serialize())
        except:
            raise Error("OAuthError: member jwks is not a JWK Set")
        return ClientMetadata.with_jwks(
            client_id=client_id,
            client_name=client_name,
            signing_alg=alg,
            scope=scope,
            jwks=keys,
            resource_types=resource_types,
        )
    if not uri:
        _refuse("the record holds neither jwks nor jwks_uri")
    return ClientMetadata.with_jwks_uri(
        client_id=client_id,
        client_name=client_name,
        signing_alg=alg,
        scope=scope,
        jwks_uri=uri.value(),
        resource_types=resource_types,
    )
