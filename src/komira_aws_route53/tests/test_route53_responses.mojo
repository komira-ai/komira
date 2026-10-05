# The responses komira_aws_route53 parses, in the form the Amazon Route 53
# API Reference shows for each operation (the documents in Route 53's
# namespace, `https://route53.amazonaws.com/doc/2013-04-01/`), and its
# error form, read through komira_aws_core's `aws_rest_xml_error`.
#
# What Route 53 answers is passed through as it is: an Id carries its
# `/hostedzone/` or `/change/` prefix, a name its trailing dot, and a
# wildcard name its octal escape (`\052` for '*'), each as the API
# Reference documents them.
from komira_aws_route53.komira_aws_route53 import (
    ROUTE53_CHANGE_STATUS_PENDING,
    parse_change_resource_record_sets_response,
    parse_list_hosted_zones_by_name_response,
    parse_list_resource_record_sets_response,
)
from komira_aws_core import AwsResponse, aws_rest_xml_error
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = 'xmlns="https://route53.amazonaws.com/doc/2013-04-01/"'


def _ok(body: String) -> AwsResponse:
    var r = AwsResponse.of_text(200, String('<?xml version="1.0" encoding="UTF-8"?>\n') + body)
    r.add_header("x-amzn-RequestId", "7e4bd2a5-0000-4000-8000-0123456789ab")
    r.add_header("Content-Type", "text/xml")
    return r^


# ---- ListHostedZonesByName ---------------------------------------------------


def test_list_hosted_zones_by_name() raises:
    var out = parse_list_hosted_zones_by_name_response(
        _ok(
            "<ListHostedZonesByNameResponse "
            + _NS
            + ">\n  <HostedZones>\n    <HostedZone>\n"
            + "      <Id>/hostedzone/Z111111QQQQQQQ</Id>\n"
            + "      <Name>example2.com.</Name>\n"
            + "      <CallerReference>MyUniqueIdentifier2</CallerReference>\n"
            + "      <Config><Comment>This is my second hosted zone.</Comment>"
            + "<PrivateZone>false</PrivateZone></Config>\n"
            + "      <ResourceRecordSetCount>42</ResourceRecordSetCount>\n"
            + "    </HostedZone>\n    <HostedZone>\n"
            + "      <Id>/hostedzone/Z222222VVVVVVV</Id>\n"
            + "      <Name>example3.com.</Name>\n"
            + "      <CallerReference>MyUniqueIdentifier3</CallerReference>\n"
            + "      <Config><PrivateZone>true</PrivateZone></Config>\n"
            + "      <ResourceRecordSetCount>7</ResourceRecordSetCount>\n"
            + "    </HostedZone>\n  </HostedZones>\n"
            + "  <DNSName>example2.com</DNSName>\n"
            + "  <IsTruncated>true</IsTruncated>\n"
            + "  <NextDNSName>example4.com.</NextDNSName>\n"
            + "  <NextHostedZoneId>Z333333YYYYYYY</NextHostedZoneId>\n"
            + "  <MaxItems>2</MaxItems>\n"
            + "</ListHostedZonesByNameResponse>"
        )
    )
    assert_equal(len(out.hosted_zones), 2)
    ref z = out.hosted_zones[0]
    assert_equal(z.id, "/hostedzone/Z111111QQQQQQQ")
    assert_equal(z.name, "example2.com.")
    assert_equal(z.caller_reference, "MyUniqueIdentifier2")
    assert_equal(z.config.value().comment.value(), "This is my second hosted zone.")
    assert_false(z.config.value().private_zone.value())
    assert_equal(z.resource_record_set_count.value(), Int64(42))
    # A private zone says so, which a caller resolving a public name skips.
    assert_true(out.hosted_zones[1].config.value().private_zone.value())
    assert_false(out.hosted_zones[1].config.value().comment)
    assert_equal(out.dns_name.value(), "example2.com")
    assert_true(out.is_truncated)
    assert_equal(out.next_dns_name.value(), "example4.com.")
    assert_equal(out.next_hosted_zone_id.value(), "Z333333YYYYYYY")
    assert_equal(out.max_items, "2")
    assert_false(out.hosted_zone_id)


def test_list_hosted_zones_by_name_empty() raises:
    # An account with no zone at or after the name: an empty list, not an
    # error, and no next page.
    var out = parse_list_hosted_zones_by_name_response(
        _ok(
            "<ListHostedZonesByNameResponse "
            + _NS
            + "><HostedZones/><DNSName>nowhere.example.</DNSName>"
            + "<IsTruncated>false</IsTruncated><MaxItems>1</MaxItems>"
            + "</ListHostedZonesByNameResponse>"
        )
    )
    assert_equal(len(out.hosted_zones), 0)
    assert_false(out.is_truncated)
    assert_false(out.next_dns_name)


# ---- ListResourceRecordSets --------------------------------------------------


def test_list_resource_record_sets() raises:
    var out = parse_list_resource_record_sets_response(
        _ok(
            "<ListResourceRecordSetsResponse "
            + _NS
            + "><ResourceRecordSets>"
            + "<ResourceRecordSet><Name>tok._domainkey.example.com.</Name><Type>TXT</Type>"
            + "<TTL>300</TTL><ResourceRecords>"
            + '<ResourceRecord><Value>"v=DKIM1; k=rsa" "p=MIGf"</Value></ResourceRecord>'
            + "</ResourceRecords></ResourceRecordSet>"
            + "<ResourceRecordSet><Name>\\052.example.com.</Name><Type>A</Type>"
            + "<SetIdentifier>blue</SetIdentifier><Weight>10</Weight>"
            + "<TTL>60</TTL><ResourceRecords>"
            + "<ResourceRecord><Value>192.0.2.1</Value></ResourceRecord>"
            + "<ResourceRecord><Value>192.0.2.2</Value></ResourceRecord>"
            + "</ResourceRecords></ResourceRecordSet>"
            + "<ResourceRecordSet><Name>www.example.com.</Name><Type>A</Type>"
            + "<AliasTarget><HostedZoneId>Z2FDTNDATAQYW2</HostedZoneId>"
            + "<DNSName>d111111abcdef8.cloudfront.net.</DNSName>"
            + "<EvaluateTargetHealth>false</EvaluateTargetHealth></AliasTarget>"
            + "</ResourceRecordSet>"
            + "</ResourceRecordSets><IsTruncated>true</IsTruncated>"
            + "<NextRecordName>www.example.com.</NextRecordName>"
            + "<NextRecordType>AAAA</NextRecordType>"
            + "<MaxItems>3</MaxItems></ListResourceRecordSetsResponse>"
        )
    )
    assert_equal(len(out.resource_record_sets), 3)
    ref txt = out.resource_record_sets[0]
    assert_equal(txt.name, "tok._domainkey.example.com.")
    assert_equal(txt.type, "TXT")
    assert_equal(txt.ttl.value(), Int64(300))
    assert_equal(len(txt.resource_records.value()), 1)
    # A TXT value is Route 53's quoted, chunked form, unchanged.
    assert_equal(txt.resource_records.value()[0].value, '"v=DKIM1; k=rsa" "p=MIGf"')
    ref weighted = out.resource_record_sets[1]
    assert_equal(weighted.name, "\\052.example.com.")
    assert_equal(weighted.set_identifier.value(), "blue")
    assert_equal(weighted.weight.value(), Int64(10))
    assert_equal(len(weighted.resource_records.value()), 2)
    assert_equal(weighted.resource_records.value()[1].value, "192.0.2.2")
    ref aliased = out.resource_record_sets[2]
    assert_false(aliased.ttl)
    assert_false(aliased.resource_records)
    assert_equal(aliased.alias_target.value().hosted_zone_id, "Z2FDTNDATAQYW2")
    assert_equal(aliased.alias_target.value().dns_name, "d111111abcdef8.cloudfront.net.")
    assert_false(aliased.alias_target.value().evaluate_target_health)
    assert_true(out.is_truncated)
    assert_equal(out.next_record_name.value(), "www.example.com.")
    assert_equal(out.next_record_type.value(), "AAAA")
    assert_false(out.next_record_identifier)
    assert_equal(out.max_items, "3")


# ---- ChangeResourceRecordSets ------------------------------------------------


def test_change_resource_record_sets() raises:
    var out = parse_change_resource_record_sets_response(
        _ok(
            "<ChangeResourceRecordSetsResponse "
            + _NS
            + "><ChangeInfo><Id>/change/C2682N5HXP0BZ4</Id>"
            + "<Status>PENDING</Status>"
            + "<SubmittedAt>2026-09-21T14:13:20.751Z</SubmittedAt>"
            + "<Comment>dkim</Comment></ChangeInfo>"
            + "</ChangeResourceRecordSetsResponse>"
        )
    )
    ref info = out.change_info
    assert_equal(info.id, "/change/C2682N5HXP0BZ4")
    assert_equal(info.status, ROUTE53_CHANGE_STATUS_PENDING)
    # 2026-09-21T14:13:20.751Z in epoch seconds.
    assert_true(abs(info.submitted_at - 1790000000.751) < 0.0005, String(info.submitted_at))
    assert_equal(info.comment.value(), "dkim")


def test_change_resource_record_sets_without_change_info() raises:
    # ChangeInfo is required by the model: a document without it is not
    # this operation's answer.
    with assert_raises(contains="required member `ChangeInfo` is absent"):
        _ = parse_change_resource_record_sets_response(
            _ok("<ChangeResourceRecordSetsResponse " + _NS + "/>")
        )


# ---- errors ------------------------------------------------------------------


def test_errors() raises:
    # Route 53 answers an error as <ErrorResponse><Error>, the code and
    # message inside <Error>, the request id in the header and the body.
    var gone = AwsResponse.of_text(
        404,
        "<?xml version=\"1.0\"?>\n<ErrorResponse "
        + _NS
        + "><Error><Type>Sender</Type><Code>NoSuchHostedZone</Code>"
        + "<Message>No hosted zone found with ID: Z1D633PJN98FT9</Message>"
        + "</Error><RequestId>c9a5a1c0-0000-4000-8000-0123456789ab</RequestId>"
        + "</ErrorResponse>",
    )
    var e = aws_rest_xml_error(gone)
    assert_equal(e.status, 404)
    assert_equal(e.code, "NoSuchHostedZone")
    assert_equal(e.message, "No hosted zone found with ID: Z1D633PJN98FT9")
    assert_equal(e.request_id, "c9a5a1c0-0000-4000-8000-0123456789ab")
    var batch = AwsResponse.of_text(
        400,
        "<ErrorResponse "
        + _NS
        + "><Error><Type>Sender</Type><Code>InvalidChangeBatch</Code>"
        + "<Message>[Tried to delete resource record set [name='a.example.com.', "
        + "type='A'] but it was not found]</Message></Error>"
        + "<RequestId>b1c2</RequestId></ErrorResponse>",
    )
    batch.add_header("x-amzn-RequestId", "hdr-1")
    var b = aws_rest_xml_error(batch)
    assert_equal(b.code, "InvalidChangeBatch")
    assert_equal(
        b.message,
        "[Tried to delete resource record set [name='a.example.com.', type='A'] but it was not found]",
    )
    assert_equal(b.request_id, "hdr-1")
    var busy = AwsResponse.of_text(
        400,
        "<ErrorResponse "
        + _NS
        + "><Error><Type>Sender</Type><Code>PriorRequestNotComplete</Code>"
        + "<Message>The request was rejected because Route 53 was still "
        + "processing a prior request.</Message></Error>"
        + "<RequestId>r3</RequestId></ErrorResponse>",
    )
    assert_equal(aws_rest_xml_error(busy).code, "PriorRequestNotComplete")


def main() raises:
    test_list_hosted_zones_by_name()
    test_list_hosted_zones_by_name_empty()
    test_list_resource_record_sets()
    test_change_resource_record_sets()
    test_change_resource_record_sets_without_change_info()
    test_errors()
    print("OK")
