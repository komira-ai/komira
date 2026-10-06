# The generated Route 53 client (`Route53Client`) end to end, with
# no socket.
#
# Over komira_http_client and komira_http_core's ScriptedConnector, to a
# custom endpoint: a ListHostedZonesByName answered, and a
# ListResourceRecordSets of a zone that does not exist, raised under its
# code (a 404 NoSuchHostedZone, which nothing retries).
#
# Each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is a restXml error
# naming the request head, so each row asserts the request line, the Host
# the endpoint ruleset resolved, and the SigV4 scope. A custom endpoint
# states no auth scheme, so these are signed in the client's own region.
# A zone's Id as ListHostedZonesByName answers it (`/hostedzone/Z…`) is
# passed back into ListResourceRecordSets and ChangeResourceRecordSets as
# it came, and reaches the wire bare.
#
# The global endpoint, through the verbs over injected seams (`<op>_with`)
# and a recording transport that answers without a connector: a client
# configured in eu-west-1 with no endpoint override sends to
# https://route53.amazonaws.com, signed in us-east-1, as Route 53's
# endpoint ruleset states; and a ChangeResourceRecordSets answered
# PriorRequestNotComplete (Route 53's throttle while an earlier change to
# the zone is still being applied) is resent after a backoff, as botocore's
# standard mode resends it, and its answer parsed.
from komira_aws_route53.komira_aws_route53 import (
    ROUTE53_CHANGE_ACTION_UPSERT,
    ROUTE53_RRTYPE_CNAME,
    Route53Change,
    Route53ChangeBatch,
    Route53ChangeResourceRecordSetsRequest,
    Route53EndpointConfig,
    Route53ListHostedZonesByNameRequest,
    Route53ListResourceRecordSetsRequest,
    Route53ResourceRecord,
    Route53ResourceRecordSet,
    Route53Client,
    parse_change_resource_record_sets_response,
    parse_list_hosted_zones_by_name_response,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    AwsHttpTransport,
    AwsRetryQuota,
    CredentialHttpRequest,
    FixedClock,
    HttpResult,
    StaticCredsSource,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import (
    Backoff,
    Jitter,
    ManualClock,
    RecordingSleeper,
    RetryLoop,
    RetryPolicy,
    SplitMix64Rng,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _NS = 'xmlns="https://route53.amazonaws.com/doc/2013-04-01/"'
comptime _ZONE = "Z1D633PJN98FT9"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: text/xml\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: 7e4bd2a5-0000-4000-8000-0123456789ab\r\n\r\n"
            + body
        )
    )


def _zones_body() -> String:
    return (
        "<ListHostedZonesByNameResponse "
        + _NS
        + "><HostedZones><HostedZone><Id>/hostedzone/Z1D633PJN98FT9</Id>"
        + "<Name>example.com.</Name><CallerReference>ref-1</CallerReference>"
        + "<Config><PrivateZone>false</PrivateZone></Config>"
        + "<ResourceRecordSetCount>3</ResourceRecordSetCount></HostedZone>"
        + "</HostedZones><DNSName>example.com.</DNSName>"
        + "<IsTruncated>false</IsTruncated><MaxItems>1</MaxItems>"
        + "</ListHostedZonesByNameResponse>"
    )


def _mk_zones() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(_answer(200, "OK", _zones_body()))


def _mk_no_zone() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            "<ErrorResponse "
            + _NS
            + "><Error><Type>Sender</Type><Code>NoSuchHostedZone</Code>"
            + "<Message>No hosted zone found with ID: ZNOTTHERE</Message></Error>"
            + "<RequestId>7e4bd2a5</RequestId></ErrorResponse>",
        )
    )


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _local[C: Connector](
    mk: def () raises thin -> C,
) raises -> Route53Client[C, StaticCredsSource]:
    var config = Route53EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return Route53Client[C, StaticCredsSource](
        mk, HttpClientConfig.defaults(), _creds(), String("eu-west-1"), config^
    )


def _zones_request() -> Route53ListHostedZonesByNameRequest:
    var input = Route53ListHostedZonesByNameRequest()
    input.set_dns_name(String("example.com."))
    input.set_max_items(String("1"))
    return input^


def _change() -> Route53ChangeResourceRecordSetsRequest:
    var rrset = Route53ResourceRecordSet(
        String("sel1._domainkey.example.com."), String(ROUTE53_RRTYPE_CNAME)
    )
    rrset.set_ttl(Int64(1800))
    var records = List[Route53ResourceRecord]()
    records.append(Route53ResourceRecord(String("sel1.dkim.example.net.")))
    rrset.set_resource_records(records^)
    var changes = List[Route53Change]()
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), rrset^))
    return Route53ChangeResourceRecordSetsRequest(String(_ZONE), Route53ChangeBatch(changes^))


# ---- answered ------------------------------------------------------------------


def test_list_hosted_zones_by_name() raises:
    var client = _local(_mk_zones)
    var out = client.list_hosted_zones_by_name(_zones_request())
    assert_equal(len(out.hosted_zones), 1)
    assert_equal(out.hosted_zones[0].id, "/hostedzone/Z1D633PJN98FT9")
    assert_equal(out.hosted_zones[0].name, "example.com.")


def test_a_missing_zone_is_raised_under_its_code() raises:
    var client = _local(_mk_no_zone)
    with assert_raises(
        contains="ListResourceRecordSets failed: HTTP 404 NoSuchHostedZone No hosted zone found with ID: ZNOTTHERE"
    ):
        _ = client.list_resource_record_sets(Route53ListResourceRecordSetsRequest(String("ZNOTTHERE")))


# ---- on the wire ---------------------------------------------------------------


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _wire(e: Error, op: String) raises -> String:
    var text = String(e)
    var marker = op + " failed: HTTP 400 " + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, request_line: String, extra: String = "") raises:
    assert_true(wire.startswith(request_line.lower() + " | "), wire)
    var want: List[String] = [
        "host: 127.0.0.1:4566",
        "/eu-west-1/route53/aws4_request, signedheaders=",
    ]
    if extra.byte_length() > 0:
        want.append(extra.lower())
    for i in range(len(want)):
        assert_true(wire.find(want[i]) >= 0, want[i] + " is not in " + wire)


def test_each_verb_on_the_wire() raises:
    var client = _local(_mk_echo)
    try:
        _ = client.list_hosted_zones_by_name(_zones_request())
        raise Error("the echo answered ListHostedZonesByName with a success")
    except e:
        _check(
            _wire(e, String("ListHostedZonesByName")),
            String("GET /2013-04-01/hostedzonesbyname?dnsname=example.com.&maxitems=1 HTTP/1.1"),
        )
    var rr = Route53ListResourceRecordSetsRequest(String(_ZONE))
    rr.set_start_record_name(String("sel1._domainkey.example.com."))
    rr.set_start_record_type(String(ROUTE53_RRTYPE_CNAME))
    rr.set_max_items(String("1"))
    try:
        _ = client.list_resource_record_sets(rr)
        raise Error("the echo answered ListResourceRecordSets with a success")
    except e:
        _check(
            _wire(e, String("ListResourceRecordSets")),
            String(
                "GET /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset"
                "?name=sel1._domainkey.example.com.&type=CNAME&maxitems=1 HTTP/1.1"
            ),
        )
    try:
        _ = client.change_resource_record_sets(_change())
        raise Error("the echo answered ChangeResourceRecordSets with a success")
    except e:
        _check(
            _wire(e, String("ChangeResourceRecordSets")),
            String("POST /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/ HTTP/1.1"),
            String("content-type: application/xml"),
        )


def test_a_found_zone_id_is_passed_back_as_it_came() raises:
    # Find a zone, then read and change its records: the Id the answer
    # carries (`/hostedzone/Z…`) goes back into the next calls unchanged,
    # and each reaches the wire with the bare Id.
    var finder = _local(_mk_zones)
    var found = finder.list_hosted_zones_by_name(_zones_request())
    var zone_id = found.hosted_zones[0].id.copy()
    assert_equal(zone_id, "/hostedzone/Z1D633PJN98FT9")
    var client = _local(_mk_echo)
    try:
        _ = client.list_resource_record_sets(Route53ListResourceRecordSetsRequest(zone_id))
        raise Error("the echo answered ListResourceRecordSets with a success")
    except e:
        _check(
            _wire(e, String("ListResourceRecordSets")),
            String("GET /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset HTTP/1.1"),
        )
    var change = _change()
    change.hosted_zone_id = zone_id
    try:
        _ = client.change_resource_record_sets(change)
        raise Error("the echo answered ChangeResourceRecordSets with a success")
    except e:
        _check(
            _wire(e, String("ChangeResourceRecordSets")),
            String("POST /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/ HTTP/1.1"),
            String("content-type: application/xml"),
        )


# ---- the global endpoint, over injected seams ----------------------------------


struct Answering(AwsHttpTransport, Movable, Deinitable):
    """Answers each send with the next scripted (status, body), and keeps
    every signed request it was handed. No connector, no socket."""

    var statuses: List[Int]
    var bodies: List[String]
    var sent: List[CredentialHttpRequest]

    def __init__(out self):
        self.statuses = List[Int]()
        self.bodies = List[String]()
        self.sent = List[CredentialHttpRequest]()

    def then(mut self, status: Int, body: String):
        self.statuses.append(status)
        self.bodies.append(body)

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        var n = len(self.sent)
        self.sent.append(req.copy())
        if n >= len(self.statuses):
            raise Error("the transport was sent more requests than it was scripted for")
        var r = HttpResult(self.statuses[n], _bytes(self.bodies[n]))
        r.add_header("Content-Type", "text/xml")
        r.add_header("x-amzn-RequestId", String("rid-") + String(n))
        return r^


def _never() raises -> ScriptedConnector:
    raise Error("a verb over injected seams dialed through the factory")


def _global() raises -> Route53Client[ScriptedConnector, StaticCredsSource]:
    # No endpoint override: where the call goes is the ruleset's answer
    # for the client's region.
    return Route53Client[ScriptedConnector, StaticCredsSource](
        _never, HttpClientConfig.defaults(), _creds(), String("eu-west-1")
    )


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        RetryPolicy(
            Backoff(initial_ms=1000, multiplier=2.0, max_ms=20_000, jitter=Jitter.full()),
            max_attempts=3,
            deadline_ms=Int64(600_000),
        ),
        ManualClock(),
        RecordingSleeper(),
        SplitMix64Rng(7),
    )


def _check_global(req: CredentialHttpRequest) raises:
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "route53.amazonaws.com")
    assert_equal(req.header("Host"), "route53.amazonaws.com")
    var auth = req.header("Authorization")
    assert_true(
        auth.find("Credential=AKIDEXAMPLE/20260921/us-east-1/route53/aws4_request,") >= 0,
        auth,
    )


def test_a_regional_client_signs_for_the_global_endpoint() raises:
    var t = Answering()
    t.then(200, _zones_body())
    var clock = FixedClock(1790000000)
    var budget = AwsRetryQuota()
    var loop = _loop()
    var client = _global()
    assert_equal(client.region(), "eu-west-1")
    var res = client.list_hosted_zones_by_name_with(_zones_request(), t, clock, loop, budget)
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 1)
    _check_global(t.sent[0])
    assert_equal(t.sent[0].method, "GET")
    assert_equal(t.sent[0].target, "/2013-04-01/hostedzonesbyname?dnsname=example.com.&maxitems=1")
    var out = parse_list_hosted_zones_by_name_response(res^.into_response())
    assert_equal(out.hosted_zones[0].name, "example.com.")


def test_prior_request_not_complete_is_resent() raises:
    var t = Answering()
    t.then(
        400,
        "<ErrorResponse "
        + _NS
        + "><Error><Type>Sender</Type><Code>PriorRequestNotComplete</Code>"
        + "<Message>The request was rejected because Route 53 was still "
        + "processing a prior request.</Message></Error>"
        + "<RequestId>r1</RequestId></ErrorResponse>",
    )
    t.then(
        200,
        "<ChangeResourceRecordSetsResponse "
        + _NS
        + "><ChangeInfo><Id>/change/C2682N5HXP0BZ4</Id><Status>PENDING</Status>"
        + "<SubmittedAt>2026-09-21T14:13:20Z</SubmittedAt></ChangeInfo>"
        + "</ChangeResourceRecordSetsResponse>",
    )
    var clock = FixedClock(1790000000)
    var budget = AwsRetryQuota()
    var loop = _loop()
    var client = _global()
    var res = client.change_resource_record_sets_with(_change(), t, clock, loop, budget)
    assert_equal(res.status, 200)
    assert_equal(len(t.sent), 2)
    assert_equal(len(loop.sleeper().slept), 1)
    for i in range(2):
        _check_global(t.sent[i])
        assert_equal(t.sent[i].method, "POST")
        assert_equal(t.sent[i].target, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
    # The resend carries the same document.
    assert_true(t.sent[0].body == t.sent[1].body, "the resent body differs")
    var out = parse_change_resource_record_sets_response(res^.into_response())
    assert_equal(out.change_info.id, "/change/C2682N5HXP0BZ4")
    assert_equal(out.change_info.status, "PENDING")


def main() raises:
    test_list_hosted_zones_by_name()
    test_a_missing_zone_is_raised_under_its_code()
    test_each_verb_on_the_wire()
    test_a_found_zone_id_is_passed_back_as_it_came()
    test_a_regional_client_signs_for_the_global_endpoint()
    test_prior_request_not_complete_is_resent()
    print("OK")
