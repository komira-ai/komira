# komira_aws_iam

An AWS Identity and Access Management (IAM) client generated at build time
from botocore's `iam` service model (awsQuery), for users, roles and OpenID
Connect providers: `CreateUser`, `CreateAccessKey`, `PutUserPolicy`,
`CreateRole`, `GetRole`, `UpdateAssumeRolePolicy`, `PutRolePolicy`,
`GetRolePolicy`, `ListRolePolicies`, `DeleteRolePolicy`, `TagRole`,
`DeleteRole`, `GetOpenIDConnectProvider`,
`AddClientIDToOpenIDConnectProvider` and
`RemoveClientIDFromOpenIDConnectProvider`.

The module `komira_aws_iam.komira_aws_iam` has, for each operation, a
request struct (`IAMCreateRoleRequest`, ...), `build_<op>_request` (a POST
to `/` with a form body `Action=<Operation>&Version=2010-05-08&...`, each
value percent-encoded), `parse_<op>_response` (reads the `<OpResult>`
element of the XML answer) and `resolve_<op>_endpoint` (IAM's published
endpoint ruleset, embedded in the module, over an `IAMEndpointConfig`).
`IAMClient[C, S]` puts them together: each call resolves its endpoint, signs
with SigV4 for the region the ruleset states (IAM is global: in the `aws`
partition every region reaches `https://iam.amazonaws.com`, signed for
`us-east-1`), sends over the `komira_http_core` `Connector` `C` it is given,
retries as botocore's standard mode does, and returns the decoded result or
raises `IAM.<Operation> failed: HTTP <status> <code> <message>`.

A policy document in a response is returned as IAM sends it,
percent-encoded; this package does not decode it. It reads no environment
variable and no credential file.

## Examples

A `CreateRole` request: the form body with the trust policy
percent-encoded:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_iam.komira_aws_iam import IAMCreateRoleRequest, build_create_role_request

var trust = String('{"Statement":[]}')
var input = IAMCreateRoleRequest(String("deploy"), trust)
input.set_max_session_duration(Int32(3600))
var req = build_create_role_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("Content-Type")), "application/x-www-form-urlencoded; charset=utf-8")
assert_equal(
    req.body_text(),
    "Action=CreateRole&Version=2010-05-08&RoleName=deploy"
    + "&AssumeRolePolicyDocument=%7B%22Statement%22%3A%5B%5D%7D&MaxSessionDuration=3600",
)
```

IAM is global: a caller in any `aws` region reaches one endpoint, signed for
`us-east-1`; in China the endpoint is in `cn-north-1`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import aws_signing_target
from komira_aws_iam.komira_aws_iam import IAMEndpointConfig, IAMGetRoleRequest, komira_aws_iam_endpoint_rules, resolve_get_role_endpoint

var rules = komira_aws_iam_endpoint_rules()
var input = IAMGetRoleRequest(String("deploy"))
var got = resolve_get_role_endpoint(rules, IAMEndpointConfig(String("eu-west-1")), input)
assert_equal(got.url, "https://iam.amazonaws.com")
var target = aws_signing_target(got, String("eu-west-1"), String("iam"))
assert_equal(target.signing_region, "us-east-1")
assert_equal(
    resolve_get_role_endpoint(rules, IAMEndpointConfig(String("cn-north-1")), input).url,
    "https://iam.cn-north-1.amazonaws.com.cn",
)
```

Reading answers: a `GetRole` result decoded (its policy document left
percent-encoded, as IAM sent it), and an error document read through
`komira_aws_core.aws_query_error`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_query_error
from komira_aws_iam.komira_aws_iam import parse_get_role_response

var out = parse_get_role_response(
    AwsResponse.of_text(
        200,
        String(
            '<GetRoleResponse xmlns="https://iam.amazonaws.com/doc/2010-05-08/"><GetRoleResult>'
            + "<Role><Path>/</Path><RoleName>deploy</RoleName><RoleId>AROADBQP57FF2AEXAMPLE</RoleId>"
            + "<Arn>arn:aws:iam::123456789012:role/deploy</Arn>"
            + "<CreateDate>2026-10-01T00:00:00Z</CreateDate>"
            + "<AssumeRolePolicyDocument>%7B%22Statement%22%3A%5B%5D%7D</AssumeRolePolicyDocument>"
            + "</Role></GetRoleResult>"
            + "<ResponseMetadata><RequestId>r-1</RequestId></ResponseMetadata></GetRoleResponse>"
        ),
    )
)
assert_equal(out.role.role_name, "deploy")
assert_equal(out.role.arn, "arn:aws:iam::123456789012:role/deploy")
assert_equal(out.role.create_date, Float64(1790812800))  # epoch seconds
assert_equal(out.role.assume_role_policy_document.value(), "%7B%22Statement%22%3A%5B%5D%7D")

var e = aws_query_error(
    AwsResponse.of_text(
        409,
        String(
            "<ErrorResponse><Error><Type>Sender</Type><Code>EntityAlreadyExists</Code>"
            + "<Message>Role with name deploy already exists.</Message></Error>"
            + "<RequestId>r-2</RequestId></ErrorResponse>"
        ),
    )
)
assert_equal(e.code, "EntityAlreadyExists")
assert_equal(e.message, "Role with name deploy already exists.")
assert_equal(e.request_id, "r-2")
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_iam.komira_aws_iam import IAMClient, IAMEndpointConfig, IAMGetRoleRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    var text = (
        String("HTTP/1.1 ") + String(status) + " " + reason
        + "\r\nContent-Type: text/xml\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(text.as_bytes()))
    return ScriptedStream.from_read_script(raw^)

def _role_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            "<GetRoleResponse><GetRoleResult><Role><Path>/</Path>"
            + "<RoleName>deploy</RoleName><RoleId>AROADBQP57FF2AEXAMPLE</RoleId>"
            + "<Arn>arn:aws:iam::123456789012:role/deploy</Arn>"
            + "<CreateDate>2026-10-01T00:00:00Z</CreateDate></Role></GetRoleResult>"
            + "</GetRoleResponse>",
        )
    )

def _missing_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            "<ErrorResponse><Error><Type>Sender</Type><Code>NoSuchEntity</Code>"
            + "<Message>The role with name gone cannot be found.</Message></Error>"
            + "<RequestId>r-3</RequestId></ErrorResponse>",
        )
    )

def _iam(mk: def () raises thin -> ScriptedConnector) raises -> IAMClient[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = IAMEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return IAMClient[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIAIOSFODNN7EXAMPLE"), String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _iam(_role_answer)
var out = client.get_role(IAMGetRoleRequest(String("deploy")))
assert_equal(out.role.arn, "arn:aws:iam::123456789012:role/deploy")

var missing = _iam(_missing_answer)
with assert_raises(contains="IAM.GetRole failed: HTTP 404 NoSuchEntity The role with name gone cannot be found."):
    _ = missing.get_role(IAMGetRoleRequest(String("gone")))
```
