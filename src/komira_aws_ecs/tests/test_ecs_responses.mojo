# The responses komira_aws_ecs decodes, one or more rows per operation, and
# the error forms Amazon ECS answers with. The wire texts are written here
# from the Amazon ECS API reference's examples, with made-up clusters,
# tasks and task definitions.
#
# Two answers are not errors and must not read as success either: a
# DescribeClusters or RunTask whose `failures` names what it could not do
# (a cluster that is MISSING, no capacity) is HTTP 200, so a caller reads
# `failures` beside the result, as the rows below do.
#
# Errors. ECS is awsJson 1.1: the body's `__type` names the error shape,
# which komira_aws_core's `aws_json_error_info` reads as the code; the
# modeled error shapes carry the message.
from komira_aws_ecs.komira_aws_ecs import (
    ECSClientException,
    ECSClusterNotFoundException,
    parse_create_cluster_response,
    parse_deregister_task_definition_response,
    parse_describe_clusters_response,
    parse_describe_task_definition_response,
    parse_describe_tasks_response,
    parse_list_clusters_response,
    parse_list_services_response,
    parse_list_task_definition_families_response,
    parse_list_task_definitions_response,
    parse_list_tasks_response,
    parse_put_cluster_capacity_providers_response,
    parse_register_task_definition_response,
    parse_run_task_response,
    parse_stop_task_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _CLUSTER_ARN = "arn:aws:ecs:us-east-1:123456789012:cluster/jobs"
comptime _TASK_ARN = "arn:aws:ecs:us-east-1:123456789012:task/jobs/0123456789abcdef0123456789abcdef"
comptime _TD_ARN = "arn:aws:ecs:us-east-1:123456789012:task-definition/jobs:3"


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def _cluster() -> String:
    return (
        String('{"clusterArn":"') + _CLUSTER_ARN + '","clusterName":"jobs","status":"ACTIVE",'
        + '"registeredContainerInstancesCount":0,"runningTasksCount":2,"pendingTasksCount":1,'
        + '"activeServicesCount":0,"capacityProviders":["FARGATE","FARGATE_SPOT"],'
        + '"defaultCapacityProviderStrategy":[{"capacityProvider":"FARGATE","weight":1,"base":0}]}'
    )


def _task(last: String) -> String:
    return (
        String('{"taskArn":"') + _TASK_ARN + '","clusterArn":"' + _CLUSTER_ARN + '",'
        + '"taskDefinitionArn":"' + _TD_ARN + '","lastStatus":"' + last + '",'
        + '"desiredStatus":"STOPPED","launchType":"FARGATE","cpu":"256","memory":"512",'
        + '"createdAt":1790812800.5,"startedBy":"deployer","stopCode":"EssentialContainerExited",'
        + '"stoppedReason":"Essential container in task exited","version":4,'
        + '"containers":[{"name":"worker","lastStatus":"' + last + '","exitCode":3,'
        + '"reason":"OutOfMemoryError: Container killed due to memory usage"}]}'
    )


def test_create_cluster_and_capacity_providers() raises:
    var c = parse_create_cluster_response(_ok(String('{"cluster":') + _cluster() + "}")).cluster.value().copy()
    assert_equal(c.cluster_arn.value(), _CLUSTER_ARN)
    assert_equal(c.status.value(), "ACTIVE")
    assert_equal(c.running_tasks_count.value(), Int32(2))
    var p = parse_put_cluster_capacity_providers_response(_ok(String('{"cluster":') + _cluster() + "}"))
    var cl = p.cluster.value().copy()
    assert_equal(len(cl.capacity_providers.value()), 2)
    var strategy = cl.default_capacity_provider_strategy.value().copy()
    assert_equal(strategy[0].capacity_provider, "FARGATE")
    assert_equal(strategy[0].weight.value(), Int32(1))


def test_describe_clusters_with_a_failure() raises:
    var r = parse_describe_clusters_response(
        _ok(
            String('{"clusters":[') + _cluster() + '],"failures":[{"arn":'
            + '"arn:aws:ecs:us-east-1:123456789012:cluster/gone","reason":"MISSING"}]}'
        )
    )
    assert_equal(len(r.clusters.value()), 1)
    var f = r.failures.value().copy()
    assert_equal(len(f), 1)
    assert_equal(f[0].reason.value(), "MISSING")
    assert_false(Bool(f[0].detail))


def test_list_operations() raises:
    var clusters = parse_list_clusters_response(
        _ok(String('{"clusterArns":["') + _CLUSTER_ARN + '"],"nextToken":"tok-2"}')
    )
    assert_equal(clusters.cluster_arns.value()[0], _CLUSTER_ARN)
    assert_equal(clusters.next_token.value(), "tok-2")
    var services = parse_list_services_response(
        _ok(String('{"serviceArns":["arn:aws:ecs:us-east-1:123456789012:service/jobs/web"]}'))
    )
    assert_equal(len(services.service_arns.value()), 1)
    assert_false(Bool(services.next_token))
    var fams = parse_list_task_definition_families_response(_ok(String('{"families":["jobs","web"]}')))
    assert_equal(fams.families.value()[1], "web")
    var defs = parse_list_task_definitions_response(
        _ok(String('{"taskDefinitionArns":["') + _TD_ARN + '"],"nextToken":"tok-3"}')
    )
    assert_equal(defs.task_definition_arns.value()[0], _TD_ARN)
    assert_equal(defs.next_token.value(), "tok-3")
    var tasks = parse_list_tasks_response(_ok(String('{"taskArns":[]}')))
    assert_equal(len(tasks.task_arns.value()), 0)


def _task_definition(status: String) -> String:
    return (
        String('{"taskDefinitionArn":"') + _TD_ARN + '","family":"jobs","revision":3,'
        + '"status":"' + status + '","networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],'
        + '"compatibilities":["EC2","FARGATE"],"cpu":"256","memory":"512",'
        + '"registeredAt":1790812800,'
        + '"containerDefinitions":[{"name":"worker","image":"team/jobs:3","essential":true,'
        + '"portMappings":[{"containerPort":8080,"hostPort":8080,"protocol":"tcp"}],'
        + '"environment":[{"name":"MODE","value":"batch"}],'
        + '"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/jobs"}}}]}'
    )


def test_register_describe_and_deregister_task_definition() raises:
    var reg = parse_register_task_definition_response(
        _ok(String('{"taskDefinition":') + _task_definition(String("ACTIVE")) + "}")
    )
    var td = reg.task_definition.value().copy()
    assert_equal(td.revision.value(), Int32(3))
    assert_equal(td.status.value(), "ACTIVE")
    assert_equal(td.registered_at.value(), 1790812800.0)
    var c = td.container_definitions.value()[0].copy()
    assert_equal(c.name.value(), "worker")
    assert_equal(c.port_mappings.value()[0].container_port.value(), Int32(8080))
    assert_equal(c.environment.value()[0].value.value(), "batch")
    assert_equal(c.log_configuration.value().options.value()["awslogs-group"], "/ecs/jobs")
    var desc = parse_describe_task_definition_response(
        _ok(
            String('{"taskDefinition":') + _task_definition(String("ACTIVE"))
            + ',"tags":[{"key":"owner","value":"ci"}]}'
        )
    )
    assert_equal(desc.tags.value()[0].key.value(), "owner")
    assert_equal(desc.task_definition.value().family.value(), "jobs")
    var dereg = parse_deregister_task_definition_response(
        _ok(String('{"taskDefinition":') + _task_definition(String("INACTIVE")) + "}")
    )
    assert_equal(dereg.task_definition.value().status.value(), "INACTIVE")


def test_run_task() raises:
    var r = parse_run_task_response(_ok(String('{"tasks":[') + _task(String("PROVISIONING")) + '],"failures":[]}'))
    var t = r.tasks.value()[0].copy()
    assert_equal(t.task_arn.value(), _TASK_ARN)
    assert_equal(t.last_status.value(), "PROVISIONING")
    assert_equal(t.created_at.value(), 1790812800.5)
    assert_equal(len(r.failures.value()), 0)
    # No capacity: HTTP 200, no task, and the failure names why.
    var none = parse_run_task_response(
        _ok(String('{"tasks":[],"failures":[{"reason":"RESOURCE:CPU","detail":"no capacity"}]}'))
    )
    assert_equal(len(none.tasks.value()), 0)
    assert_equal(none.failures.value()[0].reason.value(), "RESOURCE:CPU")


def test_describe_and_stop_tasks() raises:
    var d = parse_describe_tasks_response(_ok(String('{"tasks":[') + _task(String("STOPPED")) + '],"failures":[]}'))
    var t = d.tasks.value()[0].copy()
    assert_equal(t.stop_code.value(), "EssentialContainerExited")
    assert_equal(t.stopped_reason.value(), "Essential container in task exited")
    assert_equal(t.version.value(), Int64(4))
    var c = t.containers.value()[0].copy()
    assert_equal(c.exit_code.value(), Int32(3))
    assert_true(c.reason.value().find("OutOfMemoryError") >= 0)
    var s = parse_stop_task_response(_ok(String('{"task":') + _task(String("STOPPED")) + "}"))
    assert_equal(s.task.value().desired_status.value(), "STOPPED")


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_list_clusters_response(_ok(String("<html/>")))
    with assert_raises():
        _ = parse_describe_tasks_response(_ok(String('{"tasks":[{"containers":[{"exitCode":"three"}]}]}')))


def test_cluster_not_found() raises:
    var resp = AwsResponse.of_text(
        400, String('{"__type":"ClusterNotFoundException","message":"Cluster not found."}')
    )
    resp.add_header(String("x-amzn-RequestId"), String("3c4d5e6f-0000-4000-8000-1234567890ab"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ClusterNotFoundException")
    assert_equal(info.message, "Cluster not found.")
    assert_equal(info.request_id, "3c4d5e6f-0000-4000-8000-1234567890ab")
    var e = ECSClusterNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "Cluster not found.")


def test_client_exception() raises:
    # A task definition that does not exist is a ClientException, namespaced.
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.ecs#ClientException",'
            + '"message":"Unable to describe task definition."}'
        ),
    )
    assert_equal(aws_json_error_info(resp).code, "ClientException")
    var e = ECSClientException.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "Unable to describe task definition.")


def main() raises:
    test_create_cluster_and_capacity_providers()
    test_describe_clusters_with_a_failure()
    test_list_operations()
    test_register_describe_and_deregister_task_definition()
    test_run_task()
    test_describe_and_stop_tasks()
    test_a_body_that_is_not_json_is_refused()
    test_cluster_not_found()
    test_client_exception()
    print("OK")
