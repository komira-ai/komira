# komira_aws_ecr

An Amazon ECR (Elastic Container Registry) client generated at build time
from botocore's `ecr` service model (awsJson 1.1), for the operations a
deployer calls on a registry: `CreateRepository`, `DescribeRepositories`,
`PutImageTagMutability` and `GetAuthorizationToken`.

The module `komira_aws_ecr.komira_aws_ecr` has, for each operation, a
request struct (`ECRCreateRepositoryRequest`, ...), `build_<op>_request`
(the exact `komira_aws_core.AwsRequest`: method, path, `X-Amz-Target`,
`Content-Type`, JSON body), `parse_<op>_response` and
`resolve_<op>_endpoint` (the service's published endpoint ruleset, embedded
in the module, over an `ECREndpointConfig`). `ECRClient[C, S]` puts them
together: each call resolves its endpoint, signs with SigV4 (signing name
`ecr`) using the credentials source `S`, sends over the `komira_http_core`
`Connector` `C` it is given, retries as botocore's standard mode does, and
returns the decoded result or raises `ECR.<Operation> failed: HTTP <status>
<code> <message>`.

The package reads no environment variable and no credential file: the
region, endpoint configuration and credentials source are parameters. It
does not log in to a registry or push images; `GetAuthorizationToken` returns
the token and the caller uses it.

## Examples

Requests, exactly as they go on the wire:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ecr.komira_aws_ecr import ECRCreateRepositoryRequest, ECRDescribeRepositoriesRequest, ECRImageScanningConfiguration, build_create_repository_request, build_describe_repositories_request

var input = ECRCreateRepositoryRequest(String("team/jobs"))
input.set_image_tag_mutability(String("IMMUTABLE"))
var scan = ECRImageScanningConfiguration()
scan.set_scan_on_push(True)
input.set_image_scanning_configuration(scan^)
var req = build_create_repository_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(
    req.header(String("X-Amz-Target")),
    "AmazonEC2ContainerRegistry_V20150921.CreateRepository",
)
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
assert_equal(
    req.body_text(),
    '{"repositoryName":"team/jobs","imageTagMutability":"IMMUTABLE",'
    + '"imageScanningConfiguration":{"scanOnPush":true}}',
)

# No member is required: every repository, a page at a time.
var page = ECRDescribeRepositoriesRequest()
page.set_next_token(String("tok-2"))
page.set_max_results(Int32(100))
assert_equal(
    build_describe_repositories_request(page).body_text(),
    '{"nextToken":"tok-2","maxResults":100}',
)
```

Where a call goes, from the endpoint ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ecr.komira_aws_ecr import ECRDescribeRepositoriesRequest, ECREndpointConfig, komira_aws_ecr_endpoint_rules, resolve_describe_repositories_endpoint

var rules = komira_aws_ecr_endpoint_rules()
var input = ECRDescribeRepositoriesRequest()
assert_equal(
    resolve_describe_repositories_endpoint(rules, ECREndpointConfig(String("us-west-2")), input).url,
    "https://api.ecr.us-west-2.amazonaws.com",
)
var fips = ECREndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_describe_repositories_endpoint(rules, fips, input).url,
    "https://api.ecr-fips.us-east-1.amazonaws.com",
)
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so the call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_ecr.komira_aws_ecr import ECRClient, ECRDescribeRepositoriesRequest, ECREndpointConfig, ECRGetAuthorizationTokenRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    var text = (
        String("HTTP/1.1 ") + String(status) + " " + reason
        + "\r\nContent-Type: application/x-amz-json-1.1\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(text.as_bytes()))
    return ScriptedStream.from_read_script(raw^)

def _token_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"authorizationData":[{"authorizationToken":"QVdTOnRva2Vu","expiresAt":1790856000.0}]}')
    )

def _missing_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(400, "Bad Request", '{"__type":"RepositoryNotFoundException","message":"no repository named gone"}')
    )

def _ecr(mk: def () raises thin -> ScriptedConnector) raises -> ECRClient[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = ECREndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ECRClient[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _ecr(_token_answer)
var out = client.get_authorization_token(ECRGetAuthorizationTokenRequest())
var data = out.authorization_data.value().copy()
assert_equal(len(data), 1)
assert_equal(data[0].authorization_token.value(), "QVdTOnRva2Vu")
assert_equal(data[0].expires_at.value(), 1790856000.0)

var request = ECRDescribeRepositoriesRequest()
var names: List[String] = [String("gone")]
request.set_repository_names(names^)
var failing = _ecr(_missing_answer)
with assert_raises(contains="ECR.DescribeRepositories failed: HTTP 400 RepositoryNotFoundException no repository named gone"):
    _ = failing.describe_repositories(request)
```
