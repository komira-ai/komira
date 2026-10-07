# komira_aws_ecs

An Amazon ECS client generated at build time from botocore's `ecs` service
model (awsJson 1.1), for what a deployer and a job runner call on Fargate:
`CreateCluster`, `PutClusterCapacityProviders`, `DescribeClusters`,
`ListClusters`, `RegisterTaskDefinition`, `DescribeTaskDefinition`,
`DeregisterTaskDefinition`, `ListTaskDefinitionFamilies`,
`ListTaskDefinitions`, `RunTask`, `ListTasks`, `DescribeTasks`, `StopTask`
and `ListServices`. The service operations that create, update, describe or
delete a service are not included.

The module `komira_aws_ecs.komira_aws_ecs` has, for each operation, a
request struct (`ECSRunTaskRequest`, ...), `build_<op>_request` (the exact
`komira_aws_core.AwsRequest`: method, path, `X-Amz-Target`, `Content-Type`,
JSON body with members in the model's order), `parse_<op>_response` and
`resolve_<op>_endpoint` (the service's published endpoint ruleset, embedded
in the module, over an `ECSEndpointConfig`); each modeled error has a struct
with `from_aws_json`. `ECSClient[C, S]` puts them together: each call
resolves its endpoint, signs with SigV4 (signing name `ecs`) using the
credentials source `S`, sends over the `komira_http_core` `Connector` `C` it
is given, retries as botocore's standard mode does, and returns the decoded
result or raises `ECS.<Operation> failed: HTTP <status> <code> <message>`.
When a `RunTask` caller leaves `clientToken` unset, the client fills it with
a fresh UUID once per call, so a retry does not start a second task.

The package reads no environment variable and no credential file.

## Examples

A `RunTask` request for a Fargate task: the one required member,
`taskDefinition`, is the constructor's argument and is written where the
model puts it, last:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ecs.komira_aws_ecs import ECSAwsVpcConfiguration, ECSNetworkConfiguration, ECSRunTaskRequest, build_run_task_request

var input = ECSRunTaskRequest(String("jobs:3"))
input.set_cluster(String("jobs"))
input.set_launch_type(String("FARGATE"))
var subnets: List[String] = [String("subnet-12345678")]
var vpc = ECSAwsVpcConfiguration(subnets^)
vpc.set_assign_public_ip(String("ENABLED"))
var net = ECSNetworkConfiguration()
net.set_awsvpc_configuration(vpc^)
input.set_network_configuration(net^)
input.set_client_token(String("run-0001"))

var req = build_run_task_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "AmazonEC2ContainerServiceV20141113.RunTask")
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
assert_equal(
    req.body_text(),
    '{"cluster":"jobs","launchType":"FARGATE",'
    + '"networkConfiguration":{"awsvpcConfiguration":{"subnets":["subnet-12345678"],'
    + '"assignPublicIp":"ENABLED"}},"taskDefinition":"jobs:3","clientToken":"run-0001"}',
)
```

Where a call goes, from the endpoint ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ecs.komira_aws_ecs import ECSEndpointConfig, ECSListClustersRequest, komira_aws_ecs_endpoint_rules, resolve_list_clusters_endpoint

var got = resolve_list_clusters_endpoint(
    komira_aws_ecs_endpoint_rules(), ECSEndpointConfig(String("us-west-2")), ECSListClustersRequest()
)
assert_equal(got.url, "https://ecs.us-west-2.amazonaws.com")
```

Reading answers: a `RunTask` that found no capacity is an HTTP 200 with no
task and a failure naming why; an error is read through
`komira_aws_core.aws_json_error_info` and then as its modeled shape:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_json_error_info
from komira_aws_ecs.komira_aws_ecs import ECSClusterNotFoundException, parse_run_task_response
from komira_json import parse_json_value

var none = parse_run_task_response(
    AwsResponse.of_text(200, String('{"tasks":[],"failures":[{"reason":"RESOURCE:CPU","detail":"no capacity"}]}'))
)
assert_equal(len(none.tasks.value()), 0)
assert_equal(none.failures.value()[0].reason.value(), "RESOURCE:CPU")

var resp = AwsResponse.of_text(400, String('{"__type":"ClusterNotFoundException","message":"Cluster not found."}'))
assert_equal(aws_json_error_info(resp).code, "ClusterNotFoundException")
var e = ECSClusterNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
assert_equal(e.message.value(), "Cluster not found.")
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_ecs.komira_aws_ecs import ECSClient, ECSEndpointConfig, ECSListClustersRequest, ECSStopTaskRequest
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

def _clusters_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"clusterArns":["arn:aws:ecs:us-east-1:000000000000:cluster/jobs"],"nextToken":"page-2"}')
    )

def _no_cluster_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(400, "Bad Request", '{"__type":"ClusterNotFoundException","message":"Cluster not found."}')
    )

def _ecs(mk: def () raises thin -> ScriptedConnector) raises -> ECSClient[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = ECSEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ECSClient[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _ecs(_clusters_answer)
var out = client.list_clusters(ECSListClustersRequest())
assert_equal(out.cluster_arns.value()[0], "arn:aws:ecs:us-east-1:000000000000:cluster/jobs")
assert_equal(out.next_token.value(), "page-2")

var stop = ECSStopTaskRequest(String("arn:aws:ecs:us-east-1:000000000000:task/gone/0123456789abcdef"))
stop.set_cluster(String("gone"))
var failing = _ecs(_no_cluster_answer)
with assert_raises(contains="ECS.StopTask failed: HTTP 400 ClusterNotFoundException Cluster not found."):
    _ = failing.stop_task(stop)
```
