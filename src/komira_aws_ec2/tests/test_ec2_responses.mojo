# The responses komira_aws_ec2 reads, exactly. An ec2Query answer has no
# result wrapper: the output's members are the children of the root
# `<OpResponse>`, under their locationNames, each list wrapped in a `...Set`
# (or `...Info`) element whose items are `<item>`, and an element the model
# does not declare is skipped. Then the error document every EC2 operation
# answers with, `<Response><Errors><Error>` with the root's `<RequestID>`,
# read through komira_aws_core's aws_query_error, a 503 throttle the retry
# classifier reads by its code, and an operation answered with no body.
#
# The bodies are in the form the EC2 API reference documents for each
# operation, with documentation ids.
from komira_aws_ec2.komira_aws_ec2 import (
    parse_authorize_security_group_ingress_response,
    parse_cancel_spot_instance_requests_response,
    parse_create_security_group_response,
    parse_delete_security_group_response,
    parse_describe_instances_response,
    parse_describe_security_groups_response,
    parse_describe_spot_instance_requests_response,
    parse_describe_subnets_response,
    parse_describe_vpcs_response,
    parse_revoke_security_group_ingress_response,
    parse_run_instances_response,
    parse_terminate_instances_response,
)
from komira_aws_core import (
    AwsResponse,
    HttpResult,
    aws_is_throttling_code,
    aws_query_error,
    aws_response_error_code,
)
from std.testing import assert_equal, assert_false, assert_true


comptime _NS = ' xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"'
comptime _REQ = "<requestId>59dbff89-35bd-4eac-99ed-be587EXAMPLE</requestId>"


def _ok(op: String, members: String) -> AwsResponse:
    """`<op>Response` whose children are `members`, after the request id."""
    return AwsResponse.of_text(
        200,
        String("<") + op + "Response" + _NS + ">" + _REQ + members + "</" + op + "Response>",
    )


comptime _INSTANCE = (
    "<item><instanceId>i-0123456789abcdef0</instanceId>"
    "<imageId>ami-0abcdef1234567890</imageId>"
    "<instanceState><code>0</code><name>pending</name></instanceState>"
    "<privateIpAddress>10.0.1.5</privateIpAddress>"
    "<instanceType>t3.micro</instanceType>"
    "<launchTime>2026-10-01T00:00:00.000Z</launchTime>"
    "<subnetId>subnet-0123</subnetId><vpcId>vpc-0a1b</vpcId>"
    "<spotInstanceRequestId>sir-abcd1234</spotInstanceRequestId>"
    "<instanceLifecycle>spot</instanceLifecycle>"
    "<groupSet><item><groupId>sg-0aaa</groupId><groupName>komira-runner</groupName></item></groupSet>"
    "<tagSet><item><key>komira-placement</key><value>p-1</value></item></tagSet>"
    "<notInTheModel><item>skipped</item></notInTheModel>"
    "</item>"
)


def test_run_instances() raises:
    # RunInstances answers a Reservation: its members are the root's.
    var out = parse_run_instances_response(
        _ok(
            String("RunInstances"),
            String("<reservationId>r-0a1b2c3d4e5f60718</reservationId><ownerId>123456789012</ownerId>")
            + "<groupSet/><instancesSet>"
            + _INSTANCE
            + "</instancesSet>",
        )
    )
    assert_equal(out.reservation_id.value(), "r-0a1b2c3d4e5f60718")
    assert_equal(out.owner_id.value(), "123456789012")
    assert_equal(len(out.groups.value()), 0)
    var instances = out.instances.value().copy()
    assert_equal(len(instances), 1)
    ref i = instances[0]
    assert_equal(i.instance_id.value(), "i-0123456789abcdef0")
    assert_equal(i.image_id.value(), "ami-0abcdef1234567890")
    assert_equal(i.state.value().code.value(), Int32(0))
    assert_equal(i.state.value().name.value(), "pending")
    assert_equal(i.private_ip_address.value(), "10.0.1.5")
    assert_equal(i.instance_type.value(), "t3.micro")
    # 2026-10-01T00:00:00Z.
    assert_equal(i.launch_time.value(), Float64(1790812800))
    assert_equal(i.spot_instance_request_id.value(), "sir-abcd1234")
    assert_equal(i.instance_lifecycle.value(), "spot")
    assert_equal(i.security_groups.value()[0].group_id.value(), "sg-0aaa")
    var tags = i.tags.value().copy()
    assert_equal(len(tags), 1)
    assert_equal(tags[0].key.value(), "komira-placement")
    assert_equal(tags[0].value.value(), "p-1")
    assert_false(Bool(i.public_ip_address))


def test_describe_instances() raises:
    var out = parse_describe_instances_response(
        _ok(
            String("DescribeInstances"),
            String("<reservationSet><item><reservationId>r-0a1b2c3d4e5f60718</reservationId>")
            + "<ownerId>123456789012</ownerId><instancesSet>"
            + _INSTANCE
            + "</instancesSet></item></reservationSet><nextToken>eyJ2IjoyfQ==</nextToken>",
        )
    )
    var reservations = out.reservations.value().copy()
    assert_equal(len(reservations), 1)
    var instances = reservations[0].instances.value().copy()
    assert_equal(instances[0].instance_id.value(), "i-0123456789abcdef0")
    assert_equal(out.next_token.value(), "eyJ2IjoyfQ==")


def test_describe_instances_none() raises:
    var out = parse_describe_instances_response(_ok(String("DescribeInstances"), String("<reservationSet/>")))
    assert_equal(len(out.reservations.value()), 0)
    assert_false(Bool(out.next_token))


def test_terminate_instances() raises:
    var out = parse_terminate_instances_response(
        _ok(
            String("TerminateInstances"),
            String(
                "<instancesSet><item><instanceId>i-0123456789abcdef0</instanceId>"
                "<currentState><code>32</code><name>shutting-down</name></currentState>"
                "<previousState><code>16</code><name>running</name></previousState>"
                "</item></instancesSet>"
            ),
        )
    )
    var changes = out.terminating_instances.value().copy()
    assert_equal(len(changes), 1)
    assert_equal(changes[0].instance_id.value(), "i-0123456789abcdef0")
    assert_equal(changes[0].current_state.value().code.value(), Int32(32))
    assert_equal(changes[0].current_state.value().name.value(), "shutting-down")
    assert_equal(changes[0].previous_state.value().name.value(), "running")


def test_describe_spot_instance_requests() raises:
    var out = parse_describe_spot_instance_requests_response(
        _ok(
            String("DescribeSpotInstanceRequests"),
            String(
                "<spotInstanceRequestSet><item>"
                "<spotInstanceRequestId>sir-abcd1234</spotInstanceRequestId>"
                "<state>closed</state>"
                "<status><code>instance-terminated-no-capacity</code>"
                "<updateTime>2026-10-01T00:00:00.000Z</updateTime>"
                "<message>Spot Instance terminated due to no available Spot capacity.</message></status>"
                "<instanceId>i-0123456789abcdef0</instanceId>"
                "</item></spotInstanceRequestSet>"
            ),
        )
    )
    var reqs = out.spot_instance_requests.value().copy()
    assert_equal(len(reqs), 1)
    assert_equal(reqs[0].spot_instance_request_id.value(), "sir-abcd1234")
    assert_equal(reqs[0].state.value(), "closed")
    var status = reqs[0].status.value().copy()
    assert_equal(status.code.value(), "instance-terminated-no-capacity")
    assert_equal(status.update_time.value(), Float64(1790812800))
    assert_equal(status.message.value(), "Spot Instance terminated due to no available Spot capacity.")
    assert_equal(reqs[0].instance_id.value(), "i-0123456789abcdef0")


def test_cancel_spot_instance_requests() raises:
    var out = parse_cancel_spot_instance_requests_response(
        _ok(
            String("CancelSpotInstanceRequests"),
            String(
                "<spotInstanceRequestSet><item><spotInstanceRequestId>sir-abcd1234</spotInstanceRequestId>"
                "<state>cancelled</state></item></spotInstanceRequestSet>"
            ),
        )
    )
    var cancelled = out.cancelled_spot_instance_requests.value().copy()
    assert_equal(cancelled[0].spot_instance_request_id.value(), "sir-abcd1234")
    assert_equal(cancelled[0].state.value(), "cancelled")


def test_describe_vpcs() raises:
    var out = parse_describe_vpcs_response(
        _ok(
            String("DescribeVpcs"),
            String(
                "<vpcSet><item><vpcId>vpc-0a1b</vpcId><state>available</state>"
                "<cidrBlock>172.31.0.0/16</cidrBlock><ownerId>123456789012</ownerId>"
                "<isDefault>true</isDefault></item></vpcSet>"
            ),
        )
    )
    var vpcs = out.vpcs.value().copy()
    assert_equal(len(vpcs), 1)
    assert_equal(vpcs[0].vpc_id.value(), "vpc-0a1b")
    assert_equal(vpcs[0].state.value(), "available")
    assert_equal(vpcs[0].cidr_block.value(), "172.31.0.0/16")
    assert_true(vpcs[0].is_default.value())


def test_describe_subnets() raises:
    var out = parse_describe_subnets_response(
        _ok(
            String("DescribeSubnets"),
            String(
                "<subnetSet><item><subnetId>subnet-0123</subnetId><state>available</state>"
                "<vpcId>vpc-0a1b</vpcId><cidrBlock>172.31.16.0/20</cidrBlock>"
                "<availableIpAddressCount>4091</availableIpAddressCount>"
                "<availabilityZone>us-east-1a</availabilityZone>"
                "<defaultForAz>true</defaultForAz><mapPublicIpOnLaunch>false</mapPublicIpOnLaunch>"
                "</item></subnetSet>"
            ),
        )
    )
    var subnets = out.subnets.value().copy()
    assert_equal(len(subnets), 1)
    assert_equal(subnets[0].subnet_id.value(), "subnet-0123")
    assert_equal(subnets[0].vpc_id.value(), "vpc-0a1b")
    assert_equal(subnets[0].available_ip_address_count.value(), Int32(4091))
    assert_equal(subnets[0].availability_zone.value(), "us-east-1a")
    assert_true(subnets[0].default_for_az.value())
    assert_false(subnets[0].map_public_ip_on_launch.value())


def test_describe_security_groups() raises:
    var out = parse_describe_security_groups_response(
        _ok(
            String("DescribeSecurityGroups"),
            String(
                "<securityGroupInfo><item><ownerId>123456789012</ownerId>"
                "<groupId>sg-0aaa</groupId><groupName>komira-runner</groupName>"
                "<groupDescription>runner ingress</groupDescription><vpcId>vpc-0a1b</vpcId>"
                "<ipPermissions><item><ipProtocol>tcp</ipProtocol><fromPort>443</fromPort>"
                "<toPort>443</toPort><groups/><ipRanges><item><cidrIp>0.0.0.0/0</cidrIp>"
                "<description>https</description></item></ipRanges></item></ipPermissions>"
                "<ipPermissionsEgress/>"
                "</item></securityGroupInfo>"
            ),
        )
    )
    var groups = out.security_groups.value().copy()
    assert_equal(len(groups), 1)
    ref g = groups[0]
    assert_equal(g.group_id.value(), "sg-0aaa")
    assert_equal(g.group_name.value(), "komira-runner")
    assert_equal(g.description.value(), "runner ingress")
    assert_equal(g.vpc_id.value(), "vpc-0a1b")
    var perms = g.ip_permissions.value().copy()
    assert_equal(len(perms), 1)
    assert_equal(perms[0].ip_protocol.value(), "tcp")
    assert_equal(perms[0].from_port.value(), Int32(443))
    assert_equal(perms[0].to_port.value(), Int32(443))
    assert_equal(len(perms[0].user_id_group_pairs.value()), 0)
    assert_equal(perms[0].ip_ranges.value()[0].cidr_ip.value(), "0.0.0.0/0")
    assert_equal(perms[0].ip_ranges.value()[0].description.value(), "https")
    assert_equal(len(g.ip_permissions_egress.value()), 0)


def test_create_security_group() raises:
    var out = parse_create_security_group_response(
        _ok(
            String("CreateSecurityGroup"),
            String(
                "<return>true</return><groupId>sg-0aaa</groupId>"
                "<securityGroupArn>arn:aws:ec2:us-east-1:123456789012:security-group/sg-0aaa</securityGroupArn>"
            ),
        )
    )
    assert_equal(out.group_id.value(), "sg-0aaa")
    assert_equal(out.security_group_arn.value(), "arn:aws:ec2:us-east-1:123456789012:security-group/sg-0aaa")


def test_authorize_security_group_ingress() raises:
    var out = parse_authorize_security_group_ingress_response(
        _ok(
            String("AuthorizeSecurityGroupIngress"),
            String(
                "<return>true</return><securityGroupRuleSet><item>"
                "<securityGroupRuleId>sgr-0123</securityGroupRuleId><groupId>sg-0aaa</groupId>"
                "<isEgress>false</isEgress><ipProtocol>tcp</ipProtocol><fromPort>443</fromPort>"
                "<toPort>443</toPort><cidrIpv4>0.0.0.0/0</cidrIpv4>"
                "</item></securityGroupRuleSet>"
            ),
        )
    )
    assert_true(out.return_.value())
    var rules = out.security_group_rules.value().copy()
    assert_equal(rules[0].security_group_rule_id.value(), "sgr-0123")
    assert_false(rules[0].is_egress.value())
    assert_equal(rules[0].cidr_ipv4.value(), "0.0.0.0/0")


def test_revoke_security_group_ingress() raises:
    var out = parse_revoke_security_group_ingress_response(
        _ok(
            String("RevokeSecurityGroupIngress"),
            String(
                "<return>true</return><revokedSecurityGroupRuleSet><item>"
                "<securityGroupRuleId>sgr-0123</securityGroupRuleId><groupId>sg-0aaa</groupId>"
                "</item></revokedSecurityGroupRuleSet>"
            ),
        )
    )
    assert_true(out.return_.value())
    assert_false(Bool(out.unknown_ip_permissions))
    assert_equal(out.revoked_security_group_rules.value()[0].security_group_rule_id.value(), "sgr-0123")


def test_delete_security_group() raises:
    var out = parse_delete_security_group_response(
        _ok(String("DeleteSecurityGroup"), String("<return>true</return><groupId>sg-0aaa</groupId>"))
    )
    assert_true(out.return_.value())
    assert_equal(out.group_id.value(), "sg-0aaa")


def test_an_empty_body_sets_nothing() raises:
    # A DEPARTURE FROM BOTOCORE, pinned so it cannot change unseen: its
    # EC2QueryParser raises a ResponseParserError on an empty 200 body, and
    # komira_aws_core's shared awsQuery/ec2Query reader reads an empty body
    # as an empty element, so no member is set (the BUCK file says so).
    var out = parse_delete_security_group_response(AwsResponse.of_text(200, String("")))
    assert_false(Bool(out.return_))
    assert_false(Bool(out.group_id))


def test_the_error_document() raises:
    # The ec2Query form: <Errors> holds the <Error>, and the request id is
    # the root's <RequestID>.
    var e = aws_query_error(
        AwsResponse.of_text(
            400,
            "<Response><Errors><Error><Code>InvalidGroup.NotFound</Code>"
            + "<Message>The security group 'sg-0aaa' does not exist</Message></Error></Errors>"
            + "<RequestID>5a2c9a5f-0000-4000-8000-1234567890aa</RequestID></Response>",
        )
    )
    assert_equal(e.status, 400)
    assert_equal(e.code, "InvalidGroup.NotFound")
    assert_equal(e.message, "The security group 'sg-0aaa' does not exist")
    assert_equal(e.request_id, "5a2c9a5f-0000-4000-8000-1234567890aa")


def test_a_throttle_is_read_by_its_code() raises:
    # RequestLimitExceeded is EC2's throttle; the retry classifier reads it
    # from the same document (botocore's standard mode retries it).
    var body = String(
        "<Response><Errors><Error><Code>RequestLimitExceeded</Code>"
        "<Message>Request limit exceeded.</Message></Error></Errors>"
        "<RequestID>r-1</RequestID></Response>"
    )
    var bytes = List[UInt8]()
    bytes.extend(Span(body.as_bytes()))
    assert_equal(aws_response_error_code(HttpResult(503, bytes^)), "RequestLimitExceeded")
    assert_equal(aws_query_error(AwsResponse.of_text(503, body)).code, "RequestLimitExceeded")
    # And the classifier counts it a throttle (test_ec2_client resends one).
    assert_true(aws_is_throttling_code(String("RequestLimitExceeded")))


def main() raises:
    test_run_instances()
    test_describe_instances()
    test_describe_instances_none()
    test_terminate_instances()
    test_describe_spot_instance_requests()
    test_cancel_spot_instance_requests()
    test_describe_vpcs()
    test_describe_subnets()
    test_describe_security_groups()
    test_create_security_group()
    test_authorize_security_group_ingress()
    test_revoke_security_group_ingress()
    test_delete_security_group()
    test_an_empty_body_sets_nothing()
    test_the_error_document()
    test_a_throttle_is_read_by_its_code()
    print("OK")
