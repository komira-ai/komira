# The requests komira_aws_route53 builds, each compared exactly with the
# wire form the Amazon Route 53 API Reference states for it: method,
# request target, headers and body.
#
#   ListHostedZonesByName    GET  /2013-04-01/hostedzonesbyname
#                                 ?dnsname=&hostedzoneid=&maxitems=
#   ListResourceRecordSets   GET  /2013-04-01/hostedzone/{Id}/rrset
#                                 ?name=&type=&identifier=&maxitems=
#   ChangeResourceRecordSets POST /2013-04-01/hostedzone/{Id}/rrset/
#                                 <ChangeResourceRecordSetsRequest
#                                  xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
#
# The trailing '/' of the ChangeResourceRecordSets path is the model's
# requestUri and is kept. An Id is sent as the part after its last `/`, as
# botocore's `fix_route53_ids` sends it (the generator's `route53`
# customization), so `/hostedzone/Z1D633PJN98FT9`, as Route 53 answers a
# zone's Id, and the bare `Z1D633PJN98FT9` build the same request; an Id
# that is empty once cut is refused before a request exists.
from komira_aws_route53.komira_aws_route53 import (
    ROUTE53_CHANGE_ACTION_DELETE,
    ROUTE53_CHANGE_ACTION_UPSERT,
    ROUTE53_RRTYPE_A,
    ROUTE53_RRTYPE_TXT,
    Route53AliasTarget,
    Route53Change,
    Route53ChangeBatch,
    Route53ChangeResourceRecordSetsRequest,
    Route53ListHostedZonesByNameRequest,
    Route53ListResourceRecordSetsRequest,
    Route53ResourceRecord,
    Route53ResourceRecordSet,
    build_change_resource_record_sets_request,
    build_list_hosted_zones_by_name_request,
    build_list_resource_record_sets_request,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _NS = 'xmlns="https://route53.amazonaws.com/doc/2013-04-01/"'
comptime _ZONE = "Z1D633PJN98FT9"


# ---- ListHostedZonesByName ---------------------------------------------------


def test_list_hosted_zones_by_name() raises:
    var input = Route53ListHostedZonesByNameRequest()
    input.set_dns_name(String("example.com."))
    input.set_max_items(String("1"))
    var req = build_list_hosted_zones_by_name_request(input)
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/2013-04-01/hostedzonesbyname?dnsname=example.com.&maxitems=1")
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_list_hosted_zones_by_name_next_page() raises:
    # A page after the first names the previous answer's NextDNSName and
    # NextHostedZoneId.
    var input = Route53ListHostedZonesByNameRequest()
    input.set_dns_name(String("example.org."))
    input.set_hosted_zone_id(String(_ZONE))
    var req = build_list_hosted_zones_by_name_request(input)
    assert_equal(
        req.uri,
        "/2013-04-01/hostedzonesbyname?dnsname=example.org.&hostedzoneid=Z1D633PJN98FT9",
    )


def test_list_hosted_zones_by_name_no_parameters() raises:
    # Every parameter is optional: no query at all lists from the start.
    var req = build_list_hosted_zones_by_name_request(Route53ListHostedZonesByNameRequest())
    assert_equal(req.uri, "/2013-04-01/hostedzonesbyname")


# ---- ListResourceRecordSets --------------------------------------------------


def test_list_resource_record_sets() raises:
    var input = Route53ListResourceRecordSetsRequest(String(_ZONE))
    input.set_start_record_name(String("tok._domainkey.example.com."))
    input.set_start_record_type(String(ROUTE53_RRTYPE_TXT))
    input.set_max_items(String("1"))
    var req = build_list_resource_record_sets_request(input)
    assert_equal(req.method, "GET")
    assert_equal(
        req.uri,
        "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset?name=tok._domainkey.example.com.&type=TXT&maxitems=1",
    )
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_list_resource_record_sets_wildcard_name() raises:
    # A query value is percent-encoded: '*' is not unreserved.
    var input = Route53ListResourceRecordSetsRequest(String(_ZONE))
    input.set_start_record_name(String("*.example.com."))
    input.set_start_record_identifier(String("blue green"))
    var req = build_list_resource_record_sets_request(input)
    assert_equal(
        req.uri,
        "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset?name=%2A.example.com.&identifier=blue%20green",
    )


def test_list_resource_record_sets_refuses_what_the_model_bounds() raises:
    # The model bounds StartRecordIdentifier (SetIdentifier) at min length 1.
    var input = Route53ListResourceRecordSetsRequest(String(_ZONE))
    input.set_start_record_identifier(String(""))
    with assert_raises(contains="min length 1"):
        _ = build_list_resource_record_sets_request(input)


# ---- ChangeResourceRecordSets ------------------------------------------------


def _txt_upsert() -> Route53ChangeResourceRecordSetsRequest:
    var rrset = Route53ResourceRecordSet(
        String("tok._domainkey.example.com."), String(ROUTE53_RRTYPE_TXT)
    )
    rrset.set_ttl(Int64(300))
    var records = List[Route53ResourceRecord]()
    records.append(Route53ResourceRecord(String('"v=DKIM1; k=rsa" "p=MIGf"')))
    rrset.set_resource_records(records^)
    var changes = List[Route53Change]()
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), rrset^))
    var batch = Route53ChangeBatch(changes^)
    batch.set_comment(String("dkim & spf"))
    return Route53ChangeResourceRecordSetsRequest(String(_ZONE), batch^)


def test_change_resource_record_sets_upsert() raises:
    var req = build_change_resource_record_sets_request(_txt_upsert())
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
    assert_equal(req.header(String("Content-Type")), "application/xml")
    assert_equal(len(req.header_names), 1)
    # The document is the operation's input element, in Route 53's
    # namespace, holding the ChangeBatch; members in the model's order, the
    # text escaped (`&` is; a quote in text need not be, and is not).
    assert_equal(
        req.body_text(),
        "<ChangeResourceRecordSetsRequest "
        + _NS
        + "><ChangeBatch><Comment>dkim &amp; spf</Comment><Changes><Change>"
        + "<Action>UPSERT</Action><ResourceRecordSet>"
        + "<Name>tok._domainkey.example.com.</Name><Type>TXT</Type><TTL>300</TTL>"
        + "<ResourceRecords><ResourceRecord>"
        + '<Value>"v=DKIM1; k=rsa" "p=MIGf"</Value>'
        + "</ResourceRecord></ResourceRecords>"
        + "</ResourceRecordSet></Change></Changes></ChangeBatch>"
        + "</ChangeResourceRecordSetsRequest>",
    )


def test_change_resource_record_sets_delete_and_alias() raises:
    # Two changes in one batch, applied by Route 53 as one transaction: a
    # DELETE carrying the record's current TTL and values, and an alias
    # record, which has no TTL and no ResourceRecords.
    var old = Route53ResourceRecordSet(String("old.example.com."), String(ROUTE53_RRTYPE_A))
    old.set_ttl(Int64(60))
    var values = List[Route53ResourceRecord]()
    values.append(Route53ResourceRecord(String("192.0.2.1")))
    values.append(Route53ResourceRecord(String("192.0.2.2")))
    old.set_resource_records(values^)
    var aliased = Route53ResourceRecordSet(String("www.example.com."), String(ROUTE53_RRTYPE_A))
    aliased.set_alias_target(
        Route53AliasTarget(String("Z2FDTNDATAQYW2"), String("d111111abcdef8.cloudfront.net."), False)
    )
    var changes = List[Route53Change]()
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_DELETE), old^))
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), aliased^))
    var req = build_change_resource_record_sets_request(
        Route53ChangeResourceRecordSetsRequest(String(_ZONE), Route53ChangeBatch(changes^))
    )
    assert_equal(
        req.body_text(),
        "<ChangeResourceRecordSetsRequest "
        + _NS
        + "><ChangeBatch><Changes>"
        + "<Change><Action>DELETE</Action><ResourceRecordSet>"
        + "<Name>old.example.com.</Name><Type>A</Type><TTL>60</TTL><ResourceRecords>"
        + "<ResourceRecord><Value>192.0.2.1</Value></ResourceRecord>"
        + "<ResourceRecord><Value>192.0.2.2</Value></ResourceRecord>"
        + "</ResourceRecords></ResourceRecordSet></Change>"
        + "<Change><Action>UPSERT</Action><ResourceRecordSet>"
        + "<Name>www.example.com.</Name><Type>A</Type><AliasTarget>"
        + "<HostedZoneId>Z2FDTNDATAQYW2</HostedZoneId>"
        + "<DNSName>d111111abcdef8.cloudfront.net.</DNSName>"
        + "<EvaluateTargetHealth>false</EvaluateTargetHealth>"
        + "</AliasTarget></ResourceRecordSet></Change>"
        + "</Changes></ChangeBatch></ChangeResourceRecordSetsRequest>",
    )


def test_change_resource_record_sets_refuses_what_the_model_bounds() raises:
    # An empty batch (Changes: min 1), a TTL below 0, an empty
    # ResourceRecords (min 1): each is refused before a request exists.
    with assert_raises(contains="Changes: the model states min size 1"):
        _ = build_change_resource_record_sets_request(
            Route53ChangeResourceRecordSetsRequest(
                String(_ZONE), Route53ChangeBatch(List[Route53Change]())
            )
        )
    var neg = Route53ResourceRecordSet(String("a.example.com."), String(ROUTE53_RRTYPE_A))
    neg.set_ttl(Int64(-1))
    var c1 = List[Route53Change]()
    c1.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), neg^))
    with assert_raises(contains="TTL: the model states min value 0"):
        _ = build_change_resource_record_sets_request(
            Route53ChangeResourceRecordSetsRequest(String(_ZONE), Route53ChangeBatch(c1^))
        )
    var empty = Route53ResourceRecordSet(String("a.example.com."), String(ROUTE53_RRTYPE_A))
    empty.set_resource_records(List[Route53ResourceRecord]())
    var c2 = List[Route53Change]()
    c2.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), empty^))
    with assert_raises(contains="ResourceRecords: the model states min size 1"):
        _ = build_change_resource_record_sets_request(
            Route53ChangeResourceRecordSetsRequest(String(_ZONE), Route53ChangeBatch(c2^))
        )


def test_a_prefixed_id_builds_the_bare_request() raises:
    # Each verb, given the Id as Route 53 answers it, builds exactly the
    # request the bare Id builds, and leaves the caller's input as it was.
    var prefixed = String("/hostedzone/") + _ZONE
    var rr = Route53ListResourceRecordSetsRequest(prefixed)
    assert_equal(
        build_list_resource_record_sets_request(rr).uri,
        build_list_resource_record_sets_request(
            Route53ListResourceRecordSetsRequest(String(_ZONE))
        ).uri,
    )
    assert_equal(rr.hosted_zone_id, prefixed)
    var change = _txt_upsert()
    change.hosted_zone_id = prefixed
    var sent = build_change_resource_record_sets_request(change)
    var bare = build_change_resource_record_sets_request(_txt_upsert())
    assert_equal(sent.uri, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
    assert_equal(sent.uri, bare.uri)
    assert_equal(sent.body_text(), bare.body_text())
    var zones = Route53ListHostedZonesByNameRequest()
    zones.set_dns_name(String("example.org."))
    zones.set_hosted_zone_id(prefixed)
    assert_equal(
        build_list_hosted_zones_by_name_request(zones).uri,
        "/2013-04-01/hostedzonesbyname?dnsname=example.org.&hostedzoneid=Z1D633PJN98FT9",
    )
    # An Id with more than one '/' keeps only its last segment, as
    # botocore's `split('/')[-1]` keeps it.
    assert_equal(
        build_list_resource_record_sets_request(
            Route53ListResourceRecordSetsRequest(String("a/b/") + _ZONE)
        ).uri,
        "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset",
    )


def test_only_top_level_ids_are_cut() raises:
    # botocore cuts the input's own members only: an alias target's
    # HostedZoneId, inside the change batch, is sent as given.
    var aliased = Route53ResourceRecordSet(String("www.example.com."), String(ROUTE53_RRTYPE_A))
    aliased.set_alias_target(
        Route53AliasTarget(
            String("/hostedzone/Z2FDTNDATAQYW2"), String("d111111abcdef8.cloudfront.net."), False
        )
    )
    var changes = List[Route53Change]()
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), aliased^))
    var req = build_change_resource_record_sets_request(
        Route53ChangeResourceRecordSetsRequest(
            String("/hostedzone/") + _ZONE, Route53ChangeBatch(changes^)
        )
    )
    assert_equal(req.uri, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
    assert_true(
        req.body_text().find("<HostedZoneId>/hostedzone/Z2FDTNDATAQYW2</HostedZoneId>") >= 0,
        req.body_text(),
    )


def test_an_empty_zone_id_is_refused() raises:
    # The model bounds ResourceId at max 32 and states no min, so an empty
    # Id passes validation; the empty path label is refused, and
    # `/hostedzone//rrset` is never built. An Id that is only a prefix is
    # empty once cut.
    with assert_raises(contains="is empty"):
        _ = build_list_resource_record_sets_request(
            Route53ListResourceRecordSetsRequest(String(""))
        )
    with assert_raises(contains="is empty"):
        _ = build_list_resource_record_sets_request(
            Route53ListResourceRecordSetsRequest(String("/hostedzone/"))
        )
    var change = _txt_upsert()
    change.hosted_zone_id = String("")
    with assert_raises(contains="is empty"):
        _ = build_change_resource_record_sets_request(change)



def main() raises:
    test_list_hosted_zones_by_name()
    test_list_hosted_zones_by_name_next_page()
    test_list_hosted_zones_by_name_no_parameters()
    test_list_resource_record_sets()
    test_list_resource_record_sets_wildcard_name()
    test_list_resource_record_sets_refuses_what_the_model_bounds()
    test_change_resource_record_sets_upsert()
    test_change_resource_record_sets_delete_and_alias()
    test_change_resource_record_sets_refuses_what_the_model_bounds()
    test_a_prefixed_id_builds_the_bare_request()
    test_only_top_level_ids_are_cut()
    test_an_empty_zone_id_is_refused()
    print("OK")
