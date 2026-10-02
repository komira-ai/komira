# =============================================================================
# komira_aws_core/endpoint_signing.mojo -- a resolved endpoint, as the signer
# takes it
# =============================================================================
#
# An endpoint ruleset (endpoint_rules.mojo) answers with a URL, headers and
# properties; its `authSchemes` property says how a request to that URL is
# signed. `aws_signing_target` turns that answer into what
# `build_sigv4_signed_request` takes: the `AwsEndpoint`, the signing name and
# region, and the headers to send.
#
# The scheme is chosen as botocore chooses one with no scheme requested
# (`EndpointRulesetResolver.auth_schemes_to_signing_ctx`,
# botocore/regions.py, at the release third_party/botocore pins): the first
# scheme of the list this core can sign. That is `sigv4` alone: a list with
# no `sigv4` (`sigv4a` for a Multi-Region Access Point, `sigv4-s3express`
# for an S3 Express directory bucket) is REFUSED, naming every scheme it
# offers. An endpoint with no `authSchemes` is signed with sigv4 under the
# client's own signing name and region.
#
# `disableDoubleEncoding` is not a switch here. The signer decides it from
# the signing name: service `s3` signs the path as sent, any other encodes
# it again (signed_request.mojo). A scheme asking for the other behaviour
# would be signed wrongly, so it is refused rather than signed.
# =============================================================================

from komira_json import JSON_ARRAY, JSON_BOOL, JSON_OBJECT, JSON_STRING, JsonValue

from ._text import sub
from .endpoint import AwsEndpoint
from .endpoint_rules import ResolvedEndpoint


comptime _SIGNABLE_SCHEME: StaticString = "sigv4"


struct AwsSigningTarget(Copyable, Movable):
    """Where a request goes and how it is signed.

    - `endpoint`: the resolved URL as an `AwsEndpoint`; the request's path
      and query are joined to its base path by `target_for`.
    - `signing_name`, `signing_region`: the SigV4 service and region.
    - `header_names` / `header_values`: the headers the endpoint adds, one
      name per value, in the ruleset's order.
    """

    var endpoint: AwsEndpoint
    var signing_name: String
    var signing_region: String
    var header_names: List[String]
    var header_values: List[String]

    def __init__(
        out self,
        var endpoint: AwsEndpoint,
        var signing_name: String,
        var signing_region: String,
    ):
        self.endpoint = endpoint^
        self.signing_name = signing_name^
        self.signing_region = signing_region^
        self.header_names = List[String]()
        self.header_values = List[String]()


def _member(v: JsonValue, key: String) -> Int:
    if v.kind != JSON_OBJECT:
        return -1
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            return i
    return -1


def _scheme_name(scheme: JsonValue) -> String:
    """A scheme's name without a `namespace#` prefix, "" when it has none."""
    var i = _member(scheme, "name")
    if i < 0 or scheme.children[i].kind != JSON_STRING:
        return String("")
    var name = scheme.children[i].text
    var b = name.as_bytes()
    var start = 0
    for j in range(len(b)):
        if b[j] == UInt8(0x23):  # '#'
            start = j + 1
    return sub(name, start, len(b))


def _string_property(
    scheme: JsonValue, key: String, default: String
) raises -> String:
    var i = _member(scheme, key)
    if i < 0:
        return default
    if scheme.children[i].kind != JSON_STRING:
        raise Error(
            "the endpoint's sigv4 auth scheme has a " + key + " that is not a string"
        )
    return scheme.children[i].text


def aws_signing_target(
    resolved: ResolvedEndpoint, region: String, service: String
) raises -> AwsSigningTarget:
    """The signing target for `resolved`: `region` and `service` are the
    client's own, used where the chosen scheme names none.

    Refuses an endpoint whose `authSchemes` offer no `sigv4`, naming the
    schemes it offers; a sigv4 scheme whose `disableDoubleEncoding` differs
    from what the signer does for its signing name; and a URL
    `AwsEndpoint.parse` refuses."""
    var schemes = resolved.auth_schemes()
    var signing_name = service
    var signing_region = region
    var double_encoding_off = service == "s3"
    if len(schemes.children) > 0:
        var chosen = -1
        var offered = String("")
        for i in range(len(schemes.children)):
            var name = _scheme_name(schemes.children[i])
            if offered.byte_length() > 0:
                offered += ", "
            offered += name if name.byte_length() > 0 else String("(unnamed)")
            if chosen < 0 and name == _SIGNABLE_SCHEME:
                chosen = i
        if chosen < 0:
            raise Error(
                "the endpoint must be signed with the auth scheme(s) "
                + offered
                + ", and komira_aws_core signs "
                + String(_SIGNABLE_SCHEME)
                + " only"
            )
        ref scheme = schemes.children[chosen]
        signing_name = _string_property(scheme, "signingName", service)
        signing_region = _string_property(scheme, "signingRegion", region)
        var d = _member(scheme, "disableDoubleEncoding")
        if d >= 0:
            if scheme.children[d].kind != JSON_BOOL:
                raise Error(
                    "the endpoint's sigv4 auth scheme has a disableDoubleEncoding"
                    " that is not a boolean"
                )
            double_encoding_off = scheme.children[d].bool_val
        else:
            double_encoding_off = False
    if double_encoding_off != (signing_name == "s3"):
        raise Error(
            "the endpoint's sigv4 auth scheme sets disableDoubleEncoding to "
            + ("true" if double_encoding_off else "false")
            + " for the signing name "
            + signing_name
            + ", and the signer encodes a path once for s3 alone"
        )
    if signing_region.byte_length() == 0:
        raise Error("the endpoint names no signing region and none is configured")
    var out = AwsSigningTarget(
        AwsEndpoint.parse(resolved.url, String("the endpoint ruleset")),
        signing_name,
        signing_region,
    )
    ref headers = resolved.headers
    if headers.kind == JSON_OBJECT:
        for i in range(len(headers.obj_keys)):
            ref values = headers.children[i]
            if values.kind != JSON_ARRAY:
                raise Error(
                    "the endpoint header " + headers.obj_keys[i] + " is not a list"
                )
            for j in range(len(values.children)):
                if values.children[j].kind != JSON_STRING:
                    raise Error(
                        "the endpoint header "
                        + headers.obj_keys[i]
                        + " has a value that is not a string"
                    )
                out.header_names.append(headers.obj_keys[i])
                out.header_values.append(values.children[j].text)
    return out^
