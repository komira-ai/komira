# komira_aws_route53

An Amazon Route 53 client for DNS records, generated at build time from
botocore's pinned `route53` model (restXml). The module
`komira_aws_route53.komira_aws_route53` holds, for ListHostedZonesByName,
ListResourceRecordSets and ChangeResourceRecordSets:

- a request struct (`Route53<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`
  (method, path and query, and for a change the XML document);
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs Route 53's
  published endpoint ruleset (`komira_aws_route53_endpoint_rules()`) over a
  `Route53EndpointConfig`;
- `Route53Client`, which resolves each call's endpoint, signs it with SigV4
  (signing name `route53`) and sends it over the komira_http_core `Connector`
  it is given, retried as botocore's standard mode retries
  (`PriorRequestNotComplete` counts as a throttle).

Route 53 is a global service: every call goes to one endpoint per partition
(`https://route53.amazonaws.com` in `aws`) and is signed in the region the
ruleset names (us-east-1 in `aws`), whatever region the caller configured.
A zone Id is sent as the part after its last `/`, as botocore sends it, so
`/hostedzone/Z…` as Route 53 answers it can be passed back unchanged. Other
Route 53 operations (GetChange among them) are not generated. The package
reads no environment.

## Examples

Build an UPSERT of a TXT record. Nothing is sent; the request is plain data:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_route53.komira_aws_route53 import ROUTE53_CHANGE_ACTION_UPSERT, ROUTE53_RRTYPE_TXT
from komira_aws_route53.komira_aws_route53 import Route53Change, Route53ChangeBatch
from komira_aws_route53.komira_aws_route53 import Route53ChangeResourceRecordSetsRequest
from komira_aws_route53.komira_aws_route53 import Route53ResourceRecord, Route53ResourceRecordSet
from komira_aws_route53.komira_aws_route53 import build_change_resource_record_sets_request

var rrset = Route53ResourceRecordSet(String("_check.example.com."), String(ROUTE53_RRTYPE_TXT))
rrset.set_ttl(Int64(300))
var records = List[Route53ResourceRecord]()
records.append(Route53ResourceRecord(String('"ok"')))
rrset.set_resource_records(records^)
var changes = List[Route53Change]()
changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), rrset^))
var req = build_change_resource_record_sets_request(
    Route53ChangeResourceRecordSetsRequest(
        String("/hostedzone/Z1D633PJN98FT9"), Route53ChangeBatch(changes^)
    )
)
assert_equal(req.method, "POST")
# The zone Id is sent bare.
assert_equal(req.uri, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
assert_equal(req.header(String("Content-Type")), "application/xml")
assert_equal(
    req.body_text(),
    '<ChangeResourceRecordSetsRequest xmlns="https://route53.amazonaws.com/doc/2013-04-01/">'
    + "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    + "<Name>_check.example.com.</Name><Type>TXT</Type><TTL>300</TTL>"
    + '<ResourceRecords><ResourceRecord><Value>"ok"</Value></ResourceRecord>'
    + "</ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch>"
    + "</ChangeResourceRecordSetsRequest>",
)
```

A lookup is a GET with its parameters in the query:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_route53.komira_aws_route53 import Route53ListHostedZonesByNameRequest
from komira_aws_route53.komira_aws_route53 import build_list_hosted_zones_by_name_request

var input = Route53ListHostedZonesByNameRequest()
input.set_dns_name(String("example.com."))
input.set_max_items(String("1"))
var req = build_list_hosted_zones_by_name_request(input)
assert_equal(req.method, "GET")
assert_equal(req.uri, "/2013-04-01/hostedzonesbyname?dnsname=example.com.&maxitems=1")
assert_equal(len(req.body), 0)
```

Decode a change's answer, and read an `<ErrorResponse>` with komira_aws_core's
`aws_rest_xml_error`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_rest_xml_error
from komira_aws_route53.komira_aws_route53 import ROUTE53_CHANGE_STATUS_PENDING
from komira_aws_route53.komira_aws_route53 import parse_change_resource_record_sets_response

var out = parse_change_resource_record_sets_response(
    AwsResponse.of_text(
        200,
        String(
            '<ChangeResourceRecordSetsResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">'
            + "<ChangeInfo><Id>/change/C2682N5HXP0BZ4</Id><Status>PENDING</Status>"
            + "<SubmittedAt>2026-09-21T14:13:20.751Z</SubmittedAt></ChangeInfo>"
            + "</ChangeResourceRecordSetsResponse>"
        ),
    )
)
assert_equal(out.change_info.id, "/change/C2682N5HXP0BZ4")
assert_equal(out.change_info.status, ROUTE53_CHANGE_STATUS_PENDING)

var gone = AwsResponse.of_text(
    404,
    String(
        '<ErrorResponse xmlns="https://route53.amazonaws.com/doc/2013-04-01/">'
        + "<Error><Type>Sender</Type><Code>NoSuchHostedZone</Code>"
        + "<Message>No hosted zone found with ID: Z1D633PJN98FT9</Message></Error>"
        + "<RequestId>c9a5a1c0-0000-4000-8000-0123456789ab</RequestId></ErrorResponse>"
    ),
)
var e = aws_rest_xml_error(gone)
assert_equal(e.status, 404)
assert_equal(e.code, "NoSuchHostedZone")
assert_equal(e.request_id, "c9a5a1c0-0000-4000-8000-0123456789ab")
```

Resolve the endpoint: a client configured in eu-west-1 reaches the global
endpoint and signs in us-east-1:

<!-- mojo-hidden
from std.testing import assert_equal
from komira_aws_route53.komira_aws_route53 import Route53ListHostedZonesByNameRequest
-->
```mojo
from komira_aws_core import aws_signing_target
from komira_aws_route53.komira_aws_route53 import Route53EndpointConfig
from komira_aws_route53.komira_aws_route53 import komira_aws_route53_endpoint_rules
from komira_aws_route53.komira_aws_route53 import resolve_list_hosted_zones_by_name_endpoint

var resolved = resolve_list_hosted_zones_by_name_endpoint(
    komira_aws_route53_endpoint_rules(),
    Route53EndpointConfig(String("eu-west-1")),
    Route53ListHostedZonesByNameRequest(),
)
assert_equal(resolved.url, "https://route53.amazonaws.com")
var target = aws_signing_target(resolved, String("eu-west-1"), String("route53"))
assert_equal(target.signing_name, "route53")
assert_equal(target.signing_region, "us-east-1")
```
