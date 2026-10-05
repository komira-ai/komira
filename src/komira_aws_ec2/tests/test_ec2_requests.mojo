# The requests komira_aws_ec2 builds, exactly: a POST to `/` whose form
# body (Content-Type `application/x-www-form-urlencoded; charset=utf-8`)
# starts `Action=<Operation>&Version=2016-11-15` and then names the input's
# members in the model's order, as botocore's EC2Serializer names them: a
# member's queryName, else its locationName capitalized, else its name; a
# list is `<Name>.<i>` from 1 and never wrapped (`SecurityGroupId.1`,
# `Filter.1.Value.2`), a structure's members follow its name
# (`InstanceMarketOptions.SpotOptions.SpotInstanceType`), an unset member is
# absent, and each value is percent-encoded (every byte outside A-Z a-z 0-9
# `-` `.` `_` `~`). One or more rows per operation, in the shapes the EC2
# API reference documents: an instance launched (on demand and spot),
# found by tag, terminated; a spot request read and cancelled; the VPCs,
# subnets and security groups of an account read; a security group
# created, opened, closed and deleted.
from komira_aws_ec2.komira_aws_ec2 import (
    EC2_API_VERSION,
    EC2AuthorizeSecurityGroupIngressRequest,
    EC2CancelSpotInstanceRequestsRequest,
    EC2CreateSecurityGroupRequest,
    EC2DeleteSecurityGroupRequest,
    EC2DescribeInstancesRequest,
    EC2DescribeSecurityGroupsRequest,
    EC2DescribeSpotInstanceRequestsRequest,
    EC2DescribeSubnetsRequest,
    EC2DescribeVpcsRequest,
    EC2Filter,
    EC2IamInstanceProfileSpecification,
    EC2InstanceMarketOptionsRequest,
    EC2IpPermission,
    EC2IpRange,
    EC2RevokeSecurityGroupIngressRequest,
    EC2RunInstancesRequest,
    EC2SpotMarketOptions,
    EC2Tag,
    EC2TagSpecification,
    EC2TerminateInstancesRequest,
    EC2UserIdGroupPair,
    build_authorize_security_group_ingress_request,
    build_cancel_spot_instance_requests_request,
    build_create_security_group_request,
    build_delete_security_group_request,
    build_describe_instances_request,
    build_describe_security_groups_request,
    build_describe_spot_instance_requests_request,
    build_describe_subnets_request,
    build_describe_vpcs_request,
    build_revoke_security_group_ingress_request,
    build_run_instances_request,
    build_terminate_instances_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal


def _body(req: AwsRequest, op: String) raises -> String:
    """The form body after `Action=<op>&Version=...`, once the envelope is
    checked: a POST to `/` with the form Content-Type as its only header."""
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )
    assert_equal(len(req.header_names), 1)
    var text = req.body_text()
    var head = String("Action=") + op + "&Version=2016-11-15"
    assert_equal(String(text[byte = 0 : min(head.byte_length(), text.byte_length())]), head)
    return String(text[byte = head.byte_length() : text.byte_length()])


def _filter(name: String, var values: List[String]) -> EC2Filter:
    var f = EC2Filter()
    f.set_name(name)
    f.set_values(values^)
    return f^


def test_api_version() raises:
    assert_equal(EC2_API_VERSION, "2016-11-15")


def _launch() -> EC2RunInstancesRequest:
    # MaxCount and MinCount are the required members, in the model's order.
    var input = EC2RunInstancesRequest(Int32(1), Int32(1))
    input.set_image_id(String("ami-0abcdef1234567890"))
    input.set_instance_type(String("t3.micro"))
    var groups: List[String] = ["sg-0aaa", "sg-0bbb"]
    input.set_security_group_ids(groups^)
    input.set_subnet_id(String("subnet-0123"))
    input.set_user_data(String("IyEvYmluL3NoCg=="))
    var tag = EC2Tag()
    tag.set_key(String("komira-placement"))
    tag.set_value(String("p-1"))
    var tags = List[EC2Tag]()
    tags.append(tag^)
    var spec = EC2TagSpecification()
    spec.set_resource_type(String("instance"))
    spec.set_tags(tags^)
    var specs = List[EC2TagSpecification]()
    specs.append(spec^)
    input.set_tag_specifications(specs^)
    input.set_instance_initiated_shutdown_behavior(String("terminate"))
    input.set_client_token(String("place-1"))
    var profile = EC2IamInstanceProfileSpecification()
    profile.set_name(String("runner"))
    input.set_iam_instance_profile(profile^)
    return input^


comptime _LAUNCH = (
    "&ImageId=ami-0abcdef1234567890&InstanceType=t3.micro&MaxCount=1&MinCount=1"
    "&SecurityGroupId.1=sg-0aaa&SecurityGroupId.2=sg-0bbb&SubnetId=subnet-0123"
    "&UserData=IyEvYmluL3NoCg%3D%3D"
    "&TagSpecification.1.ResourceType=instance"
    "&TagSpecification.1.Tag.1.Key=komira-placement&TagSpecification.1.Tag.1.Value=p-1"
)
comptime _LAUNCH_TAIL = (
    "&InstanceInitiatedShutdownBehavior=terminate&ClientToken=place-1"
    "&IamInstanceProfile.Name=runner"
)


def test_run_instances_on_demand() raises:
    # `SecurityGroupIds` (locationName SecurityGroupId) and `TagSpecifications`
    # (locationName TagSpecification, its `Tags` locationName Tag): ec2 lists
    # under their singular names, from 1.
    assert_equal(
        _body(build_run_instances_request(_launch()), String("RunInstances")),
        String(_LAUNCH) + _LAUNCH_TAIL,
    )


def test_run_instances_spot() raises:
    var input = _launch()
    var spot = EC2SpotMarketOptions()
    spot.set_spot_instance_type(String("one-time"))
    spot.set_instance_interruption_behavior(String("terminate"))
    var market = EC2InstanceMarketOptionsRequest()
    market.set_market_type(String("spot"))
    market.set_spot_options(spot^)
    input.set_instance_market_options(market^)
    # The market options sit where the model declares them, between the tag
    # specifications and the shutdown behaviour.
    assert_equal(
        _body(build_run_instances_request(input), String("RunInstances")),
        String(_LAUNCH)
        + "&InstanceMarketOptions.MarketType=spot"
        + "&InstanceMarketOptions.SpotOptions.SpotInstanceType=one-time"
        + "&InstanceMarketOptions.SpotOptions.InstanceInterruptionBehavior=terminate"
        + _LAUNCH_TAIL,
    )


def test_run_instances_counts_only() raises:
    assert_equal(
        _body(build_run_instances_request(EC2RunInstancesRequest(Int32(2), Int32(1))), String("RunInstances")),
        "&MaxCount=2&MinCount=1",
    )


def test_describe_instances_by_tag() raises:
    var input = EC2DescribeInstancesRequest()
    var filters = List[EC2Filter]()
    var values: List[String] = ["p-1"]
    filters.append(_filter(String("tag:komira-placement"), values^))
    input.set_filters(filters^)
    assert_equal(
        _body(build_describe_instances_request(input), String("DescribeInstances")),
        "&Filter.1.Name=tag%3Akomira-placement&Filter.1.Value.1=p-1",
    )


def test_describe_instances_by_id() raises:
    var input = EC2DescribeInstancesRequest()
    var ids: List[String] = ["i-0123456789abcdef0", "i-0fedcba9876543210"]
    input.set_instance_ids(ids^)
    input.set_next_token(String("eyJ2IjoyfQ=="))
    input.set_max_results(Int32(5))
    assert_equal(
        _body(build_describe_instances_request(input), String("DescribeInstances")),
        "&InstanceId.1=i-0123456789abcdef0&InstanceId.2=i-0fedcba9876543210"
        + "&NextToken=eyJ2IjoyfQ%3D%3D&MaxResults=5",
    )


def test_describe_instances_no_input() raises:
    assert_equal(
        _body(build_describe_instances_request(EC2DescribeInstancesRequest()), String("DescribeInstances")),
        "",
    )


def test_terminate_instances() raises:
    var ids: List[String] = ["i-0123456789abcdef0", "i-0fedcba9876543210"]
    var input = EC2TerminateInstancesRequest(ids^)
    assert_equal(
        _body(build_terminate_instances_request(input), String("TerminateInstances")),
        "&InstanceId.1=i-0123456789abcdef0&InstanceId.2=i-0fedcba9876543210",
    )
    # `dryRun` (locationName) capitalized.
    input.set_dry_run(True)
    assert_equal(
        _body(build_terminate_instances_request(input), String("TerminateInstances")),
        "&InstanceId.1=i-0123456789abcdef0&InstanceId.2=i-0fedcba9876543210&DryRun=true",
    )


def test_describe_spot_instance_requests() raises:
    var input = EC2DescribeSpotInstanceRequestsRequest()
    var ids: List[String] = ["sir-abcd1234"]
    input.set_spot_instance_request_ids(ids^)
    assert_equal(
        _body(build_describe_spot_instance_requests_request(input), String("DescribeSpotInstanceRequests")),
        "&SpotInstanceRequestId.1=sir-abcd1234",
    )


def test_cancel_spot_instance_requests() raises:
    var ids: List[String] = ["sir-abcd1234"]
    var req = build_cancel_spot_instance_requests_request(EC2CancelSpotInstanceRequestsRequest(ids^))
    assert_equal(_body(req, String("CancelSpotInstanceRequests")), "&SpotInstanceRequestId.1=sir-abcd1234")


def test_describe_vpcs() raises:
    var input = EC2DescribeVpcsRequest()
    var filters = List[EC2Filter]()
    var values: List[String] = ["true"]
    filters.append(_filter(String("isDefault"), values^))
    input.set_filters(filters^)
    assert_equal(
        _body(build_describe_vpcs_request(input), String("DescribeVpcs")),
        "&Filter.1.Name=isDefault&Filter.1.Value.1=true",
    )
    var by_id = EC2DescribeVpcsRequest()
    var ids: List[String] = ["vpc-0a1b"]
    by_id.set_vpc_ids(ids^)
    assert_equal(_body(build_describe_vpcs_request(by_id), String("DescribeVpcs")), "&VpcId.1=vpc-0a1b")


def test_describe_subnets() raises:
    var input = EC2DescribeSubnetsRequest()
    var filters = List[EC2Filter]()
    var vpc: List[String] = ["vpc-0a1b"]
    filters.append(_filter(String("vpc-id"), vpc^))
    var zones: List[String] = ["us-east-1a", "us-east-1b"]
    filters.append(_filter(String("availability-zone"), zones^))
    input.set_filters(filters^)
    assert_equal(
        _body(build_describe_subnets_request(input), String("DescribeSubnets")),
        "&Filter.1.Name=vpc-id&Filter.1.Value.1=vpc-0a1b"
        + "&Filter.2.Name=availability-zone&Filter.2.Value.1=us-east-1a&Filter.2.Value.2=us-east-1b",
    )


def test_describe_security_groups() raises:
    var input = EC2DescribeSecurityGroupsRequest()
    var filters = List[EC2Filter]()
    var vpc: List[String] = ["vpc-0a1b"]
    filters.append(_filter(String("vpc-id"), vpc^))
    var name: List[String] = ["komira-runner"]
    filters.append(_filter(String("group-name"), name^))
    input.set_filters(filters^)
    # Filter is the last member of DescribeSecurityGroupsRequest.
    var ids: List[String] = ["sg-0aaa"]
    input.set_group_ids(ids^)
    assert_equal(
        _body(build_describe_security_groups_request(input), String("DescribeSecurityGroups")),
        "&GroupId.1=sg-0aaa&Filter.1.Name=vpc-id&Filter.1.Value.1=vpc-0a1b"
        + "&Filter.2.Name=group-name&Filter.2.Value.1=komira-runner",
    )


def test_create_security_group() raises:
    var input = EC2CreateSecurityGroupRequest(String("runner ingress"), String("komira-runner"))
    input.set_vpc_id(String("vpc-0a1b"))
    # `Description` is sent as its locationName, GroupDescription.
    assert_equal(
        _body(build_create_security_group_request(input), String("CreateSecurityGroup")),
        "&GroupDescription=runner%20ingress&GroupName=komira-runner&VpcId=vpc-0a1b",
    )


def _permissions() -> List[EC2IpPermission]:
    var https = EC2IpPermission()
    https.set_ip_protocol(String("tcp"))
    https.set_from_port(Int32(443))
    https.set_to_port(Int32(443))
    var cidr = EC2IpRange()
    cidr.set_cidr_ip(String("0.0.0.0/0"))
    cidr.set_description(String("https"))
    var ranges = List[EC2IpRange]()
    ranges.append(cidr^)
    https.set_ip_ranges(ranges^)
    var peers = EC2IpPermission()
    peers.set_ip_protocol(String("-1"))
    var pair = EC2UserIdGroupPair()
    pair.set_group_id(String("sg-0bbb"))
    var pairs = List[EC2UserIdGroupPair]()
    pairs.append(pair^)
    peers.set_user_id_group_pairs(pairs^)
    var out = List[EC2IpPermission]()
    out.append(https^)
    out.append(peers^)
    return out^


# `IpPermissions.<i>` from 1, each permission's ranges and peer groups under
# their own names (`IpRanges.<j>`, `Groups.<j>`), members in the model's
# order (an IpRange's Description before its CidrIp).
comptime _PERMISSIONS = (
    "&IpPermissions.1.IpProtocol=tcp&IpPermissions.1.FromPort=443&IpPermissions.1.ToPort=443"
    "&IpPermissions.1.IpRanges.1.Description=https&IpPermissions.1.IpRanges.1.CidrIp=0.0.0.0%2F0"
    "&IpPermissions.2.IpProtocol=-1&IpPermissions.2.Groups.1.GroupId=sg-0bbb"
)


def test_authorize_security_group_ingress() raises:
    var input = EC2AuthorizeSecurityGroupIngressRequest()
    input.set_group_id(String("sg-0aaa"))
    input.set_ip_permissions(_permissions())
    assert_equal(
        _body(build_authorize_security_group_ingress_request(input), String("AuthorizeSecurityGroupIngress")),
        String("&GroupId=sg-0aaa") + _PERMISSIONS,
    )


def test_revoke_security_group_ingress() raises:
    var input = EC2RevokeSecurityGroupIngressRequest()
    input.set_group_id(String("sg-0aaa"))
    input.set_ip_permissions(_permissions())
    assert_equal(
        _body(build_revoke_security_group_ingress_request(input), String("RevokeSecurityGroupIngress")),
        String("&GroupId=sg-0aaa") + _PERMISSIONS,
    )
    var by_rule = EC2RevokeSecurityGroupIngressRequest()
    by_rule.set_group_id(String("sg-0aaa"))
    var rules: List[String] = ["sgr-0123"]
    by_rule.set_security_group_rule_ids(rules^)
    assert_equal(
        _body(build_revoke_security_group_ingress_request(by_rule), String("RevokeSecurityGroupIngress")),
        "&GroupId=sg-0aaa&SecurityGroupRuleId.1=sgr-0123",
    )


def test_delete_security_group() raises:
    var input = EC2DeleteSecurityGroupRequest()
    input.set_group_id(String("sg-0aaa"))
    assert_equal(
        _body(build_delete_security_group_request(input), String("DeleteSecurityGroup")),
        "&GroupId=sg-0aaa",
    )


def main() raises:
    test_api_version()
    test_run_instances_on_demand()
    test_run_instances_spot()
    test_run_instances_counts_only()
    test_describe_instances_by_tag()
    test_describe_instances_by_id()
    test_describe_instances_no_input()
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
    print("OK")
