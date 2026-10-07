# The requests komira_aws_ecs builds, exactly: method, path, the awsJson
# 1.1 headers (X-Amz-Target `AmazonEC2ContainerServiceV20141113.<Operation>`
# and Content-Type `application/x-amz-json-1.1`) and the body, members in
# the model's order and an unset member absent. One or more rows per
# operation, in the shapes the Amazon ECS API reference documents: a
# Fargate cluster created and given its capacity providers, clusters
# described and listed, a task definition registered, described and
# deregistered, the families and revisions listed, a task run on Fargate
# in a VPC with an override, its tasks listed, described and stopped, and
# a cluster's services listed. Then the model's bounds, which
# `build_<op>_request` checks before any byte is written.
from komira_aws_ecs.komira_aws_ecs import (
    ECSASSIGN_PUBLIC_IP_ENABLED,
    ECSCLUSTER_FIELD_SETTINGS,
    ECSCOMPATIBILITY_FARGATE,
    ECSDESIRED_STATUS_RUNNING,
    ECSLAUNCH_TYPE_FARGATE,
    ECSLOG_DRIVER_AWSLOGS,
    ECSNETWORK_MODE_AWSVPC,
    ECSSORT_ORDER_DESC,
    ECSTASK_DEFINITION_FIELD_TAGS,
    ECSTASK_DEFINITION_STATUS_ACTIVE,
    ECSTRANSPORT_PROTOCOL_TCP,
    ECS_CONTENT_TYPE,
    ECS_SERVICE,
    ECS_TARGET_PREFIX,
    ECSAwsVpcConfiguration,
    ECSCapacityProviderStrategyItem,
    ECSContainerDefinition,
    ECSContainerOverride,
    ECSCreateClusterRequest,
    ECSDeregisterTaskDefinitionRequest,
    ECSDescribeClustersRequest,
    ECSDescribeTaskDefinitionRequest,
    ECSDescribeTasksRequest,
    ECSKeyValuePair,
    ECSListClustersRequest,
    ECSListServicesRequest,
    ECSListTaskDefinitionFamiliesRequest,
    ECSListTaskDefinitionsRequest,
    ECSListTasksRequest,
    ECSLogConfiguration,
    ECSNetworkConfiguration,
    ECSPortMapping,
    ECSPutClusterCapacityProvidersRequest,
    ECSRegisterTaskDefinitionRequest,
    ECSRunTaskRequest,
    ECSStopTaskRequest,
    ECSTag,
    ECSTaskOverride,
    build_create_cluster_request,
    build_deregister_task_definition_request,
    build_describe_clusters_request,
    build_describe_task_definition_request,
    build_describe_tasks_request,
    build_list_clusters_request,
    build_list_services_request,
    build_list_task_definition_families_request,
    build_list_task_definitions_request,
    build_list_tasks_request,
    build_put_cluster_capacity_providers_request,
    build_register_task_definition_request,
    build_run_task_request,
    build_stop_task_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _TASK = "arn:aws:ecs:us-east-1:123456789012:task/jobs/0123456789abcdef0123456789abcdef"


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "AmazonEC2ContainerServiceV20141113." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
    assert_equal(len(req.header_names), 2)


def _tag(key: String, value: String) -> ECSTag:
    var t = ECSTag()
    t.set_key(key)
    t.set_value(value)
    return t^


def _env(name: String, value: String) -> ECSKeyValuePair:
    var p = ECSKeyValuePair()
    p.set_name(name)
    p.set_value(value)
    return p^


def _fargate(weight: Int32) -> ECSCapacityProviderStrategyItem:
    var s = ECSCapacityProviderStrategyItem(String("FARGATE"))
    s.set_weight(weight)
    return s^


def test_wire_constants() raises:
    assert_equal(ECS_TARGET_PREFIX, "AmazonEC2ContainerServiceV20141113")
    assert_equal(ECS_CONTENT_TYPE, "application/x-amz-json-1.1")
    assert_equal(ECS_SERVICE, "ecs")


def test_create_cluster() raises:
    var input = ECSCreateClusterRequest()
    input.set_cluster_name(String("jobs"))
    var tags: List[ECSTag] = [_tag(String("owner"), String("ci"))]
    input.set_tags(tags^)
    var req = build_create_cluster_request(input)
    _check_envelope(req, String("CreateCluster"))
    assert_equal(req.body_text(), '{"clusterName":"jobs","tags":[{"key":"owner","value":"ci"}]}')
    # No member is required: the account's `default` cluster.
    assert_equal(build_create_cluster_request(ECSCreateClusterRequest()).body_text(), "{}")


def test_put_cluster_capacity_providers() raises:
    var providers: List[String] = [String("FARGATE"), String("FARGATE_SPOT")]
    var strategy: List[ECSCapacityProviderStrategyItem] = [_fargate(Int32(1))]
    var req = build_put_cluster_capacity_providers_request(
        ECSPutClusterCapacityProvidersRequest(String("jobs"), providers^, strategy^)
    )
    _check_envelope(req, String("PutClusterCapacityProviders"))
    assert_equal(
        req.body_text(),
        '{"cluster":"jobs","capacityProviders":["FARGATE","FARGATE_SPOT"],'
        + '"defaultCapacityProviderStrategy":[{"capacityProvider":"FARGATE","weight":1}]}',
    )


def test_describe_clusters() raises:
    var input = ECSDescribeClustersRequest()
    var names: List[String] = [String("jobs")]
    input.set_clusters(names^)
    var include: List[String] = [String(ECSCLUSTER_FIELD_SETTINGS)]
    input.set_include(include^)
    var req = build_describe_clusters_request(input)
    _check_envelope(req, String("DescribeClusters"))
    assert_equal(req.body_text(), '{"clusters":["jobs"],"include":["SETTINGS"]}')


def test_list_clusters() raises:
    var req = build_list_clusters_request(ECSListClustersRequest())
    _check_envelope(req, String("ListClusters"))
    assert_equal(req.body_text(), "{}")
    var page = ECSListClustersRequest()
    page.set_next_token(String("tok-2"))
    page.set_max_results(Int32(100))
    assert_equal(build_list_clusters_request(page).body_text(), '{"nextToken":"tok-2","maxResults":100}')


def test_register_task_definition() raises:
    var c = ECSContainerDefinition()
    c.set_name(String("worker"))
    c.set_image(String("123456789012.dkr.ecr.us-east-1.amazonaws.com/team/jobs@sha256:abc"))
    var port = ECSPortMapping()
    port.set_container_port(Int32(8080))
    port.set_protocol(String(ECSTRANSPORT_PROTOCOL_TCP))
    var ports: List[ECSPortMapping] = [port^]
    c.set_port_mappings(ports^)
    c.set_essential(True)
    var cmd: List[String] = [String("--serve")]
    c.set_command(cmd^)
    var env: List[ECSKeyValuePair] = [_env(String("MODE"), String("batch"))]
    c.set_environment(env^)
    var log = ECSLogConfiguration(String(ECSLOG_DRIVER_AWSLOGS))
    var opts = Dict[String, String]()
    opts["awslogs-group"] = String("/ecs/jobs")
    opts["awslogs-region"] = String("us-east-1")
    log.set_options(opts^)
    c.set_log_configuration(log^)
    var defs: List[ECSContainerDefinition] = [c^]
    var input = ECSRegisterTaskDefinitionRequest(String("jobs"), defs^)
    input.set_execution_role_arn(String("arn:aws:iam::123456789012:role/ecsTaskExecutionRole"))
    input.set_network_mode(String(ECSNETWORK_MODE_AWSVPC))
    var compat: List[String] = [String(ECSCOMPATIBILITY_FARGATE)]
    input.set_requires_compatibilities(compat^)
    input.set_cpu(String("256"))
    input.set_memory(String("512"))
    var req = build_register_task_definition_request(input)
    _check_envelope(req, String("RegisterTaskDefinition"))
    assert_equal(
        req.body_text(),
        '{"family":"jobs","executionRoleArn":"arn:aws:iam::123456789012:role/ecsTaskExecutionRole",'
        + '"networkMode":"awsvpc","containerDefinitions":[{"name":"worker",'
        + '"image":"123456789012.dkr.ecr.us-east-1.amazonaws.com/team/jobs@sha256:abc",'
        + '"portMappings":[{"containerPort":8080,"protocol":"tcp"}],"essential":true,'
        + '"command":["--serve"],"environment":[{"name":"MODE","value":"batch"}],'
        + '"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/jobs",'
        + '"awslogs-region":"us-east-1"}}}],"requiresCompatibilities":["FARGATE"],'
        + '"cpu":"256","memory":"512"}',
    )


def test_describe_and_deregister_task_definition() raises:
    var input = ECSDescribeTaskDefinitionRequest(String("jobs:3"))
    var include: List[String] = [String(ECSTASK_DEFINITION_FIELD_TAGS)]
    input.set_include(include^)
    var req = build_describe_task_definition_request(input)
    _check_envelope(req, String("DescribeTaskDefinition"))
    assert_equal(req.body_text(), '{"taskDefinition":"jobs:3","include":["TAGS"]}')
    var dereg = build_deregister_task_definition_request(ECSDeregisterTaskDefinitionRequest(String("jobs:3")))
    _check_envelope(dereg, String("DeregisterTaskDefinition"))
    assert_equal(dereg.body_text(), '{"taskDefinition":"jobs:3"}')


def test_list_task_definition_families_and_revisions() raises:
    var fam = ECSListTaskDefinitionFamiliesRequest()
    fam.set_family_prefix(String("jobs"))
    fam.set_status(String(ECSTASK_DEFINITION_STATUS_ACTIVE))
    var req = build_list_task_definition_families_request(fam)
    _check_envelope(req, String("ListTaskDefinitionFamilies"))
    assert_equal(req.body_text(), '{"familyPrefix":"jobs","status":"ACTIVE"}')
    var revs = ECSListTaskDefinitionsRequest()
    revs.set_family_prefix(String("jobs"))
    revs.set_sort(String(ECSSORT_ORDER_DESC))
    revs.set_next_token(String("tok-2"))
    var rreq = build_list_task_definitions_request(revs)
    _check_envelope(rreq, String("ListTaskDefinitions"))
    assert_equal(rreq.body_text(), '{"familyPrefix":"jobs","sort":"DESC","nextToken":"tok-2"}')


def test_run_task() raises:
    var input = ECSRunTaskRequest(String("jobs:3"))
    input.set_cluster(String("jobs"))
    input.set_count(Int32(1))
    input.set_enable_ecs_managed_tags(True)
    input.set_launch_type(String(ECSLAUNCH_TYPE_FARGATE))
    var subnets: List[String] = [String("subnet-12345678")]
    var vpc = ECSAwsVpcConfiguration(subnets^)
    var groups: List[String] = [String("sg-12345678")]
    vpc.set_security_groups(groups^)
    vpc.set_assign_public_ip(String(ECSASSIGN_PUBLIC_IP_ENABLED))
    var net = ECSNetworkConfiguration()
    net.set_awsvpc_configuration(vpc^)
    input.set_network_configuration(net^)
    var co = ECSContainerOverride()
    co.set_name(String("worker"))
    var env: List[ECSKeyValuePair] = [_env(String("JOB_ID"), String("42"))]
    co.set_environment(env^)
    var cos: List[ECSContainerOverride] = [co^]
    var over = ECSTaskOverride()
    over.set_container_overrides(cos^)
    input.set_overrides(over^)
    input.set_started_by(String("deployer"))
    var req = build_run_task_request(input)
    _check_envelope(req, String("RunTask"))
    # `taskDefinition`, the one required member, comes late: the model's order.
    assert_equal(
        req.body_text(),
        '{"cluster":"jobs","count":1,"enableECSManagedTags":true,"launchType":"FARGATE",'
        + '"networkConfiguration":{"awsvpcConfiguration":{"subnets":["subnet-12345678"],'
        + '"securityGroups":["sg-12345678"],"assignPublicIp":"ENABLED"}},'
        + '"overrides":{"containerOverrides":[{"name":"worker",'
        + '"environment":[{"name":"JOB_ID","value":"42"}]}]},'
        + '"startedBy":"deployer","taskDefinition":"jobs:3"}',
    )
    var strategy = ECSRunTaskRequest(String("jobs:3"))
    var items: List[ECSCapacityProviderStrategyItem] = [_fargate(Int32(1))]
    strategy.set_capacity_provider_strategy(items^)
    assert_equal(
        build_run_task_request(strategy).body_text(),
        '{"capacityProviderStrategy":[{"capacityProvider":"FARGATE","weight":1}],'
        + '"taskDefinition":"jobs:3"}',
    )


def test_list_tasks() raises:
    var input = ECSListTasksRequest()
    input.set_cluster(String("jobs"))
    input.set_family(String("jobs"))
    input.set_desired_status(String(ECSDESIRED_STATUS_RUNNING))
    var req = build_list_tasks_request(input)
    _check_envelope(req, String("ListTasks"))
    assert_equal(req.body_text(), '{"cluster":"jobs","family":"jobs","desiredStatus":"RUNNING"}')
    var by = ECSListTasksRequest()
    by.set_cluster(String("jobs"))
    by.set_started_by(String("deployer"))
    assert_equal(build_list_tasks_request(by).body_text(), '{"cluster":"jobs","startedBy":"deployer"}')


def test_describe_tasks() raises:
    var tasks: List[String] = [String(_TASK)]
    var input = ECSDescribeTasksRequest(tasks^)
    input.set_cluster(String("jobs"))
    var req = build_describe_tasks_request(input)
    _check_envelope(req, String("DescribeTasks"))
    assert_equal(req.body_text(), '{"cluster":"jobs","tasks":["' + String(_TASK) + '"]}')


def test_stop_task() raises:
    var input = ECSStopTaskRequest(String(_TASK))
    input.set_cluster(String("jobs"))
    input.set_reason(String("superseded"))
    var req = build_stop_task_request(input)
    _check_envelope(req, String("StopTask"))
    assert_equal(
        req.body_text(),
        '{"cluster":"jobs","task":"' + String(_TASK) + '","reason":"superseded"}',
    )


def test_list_services() raises:
    var input = ECSListServicesRequest()
    input.set_cluster(String("jobs"))
    input.set_launch_type(String(ECSLAUNCH_TYPE_FARGATE))
    var req = build_list_services_request(input)
    _check_envelope(req, String("ListServices"))
    assert_equal(req.body_text(), '{"cluster":"jobs","launchType":"FARGATE"}')


def test_model_bounds() raises:
    # A resource takes at most 50 tags.
    var many = List[ECSTag]()
    for i in range(51):
        many.append(_tag(String("k") + String(i), String("v")))
    var input = ECSCreateClusterRequest()
    input.set_tags(many^)
    with assert_raises(contains="tags: the model states max size 50"):
        _ = build_create_cluster_request(input)


def main() raises:
    test_wire_constants()
    test_create_cluster()
    test_put_cluster_capacity_providers()
    test_describe_clusters()
    test_list_clusters()
    test_register_task_definition()
    test_describe_and_deregister_task_definition()
    test_list_task_definition_families_and_revisions()
    test_run_task()
    test_list_tasks()
    test_describe_tasks()
    test_stop_task()
    test_list_services()
    test_model_bounds()
    print("OK")
