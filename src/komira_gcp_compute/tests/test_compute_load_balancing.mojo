# The load-balancing half of the generated Compute Engine client: one test
# per method a load-balancer conformer makes, in the order it builds an
# external HTTPS load balancer in front of a serverless backend:
# GlobalAddresses (Get, Insert), SslCertificates (Get, Insert),
# RegionNetworkEndpointGroups (Get, Insert), BackendBuckets (Get, Insert),
# BackendServices (Get, Insert, Patch), UrlMaps (Get, Insert, Patch,
# InvalidateCache), TargetHttpProxies (Get, Insert), TargetHttpsProxies
# (Get, Insert) and GlobalForwardingRules (Get, Insert). Their operations are
# followed through GlobalOperations.Wait and RegionOperations.Wait
# (test_compute_instances).
#
# Each test sends one request through the generated client over
# komira_http_core's ScriptedConnector with a shared write capture (no
# socket) and checks the request line and body the client wrote and the
# response it decoded. The client is pointed at `localhost`, so the send
# resolves no name.
#
# The expected forms are written from the Compute Engine v1 REST reference
# for each resource. Three keys are not the lowerCamel of their proto field
# and are the reference's own spelling, which protoc's JSON name gives:
# `IPAddress` and `IPProtocol` on a forwarding rule (`I_p_address`,
# `I_p_protocol`) and `enableCDN` on a backend service (`enable_c_d_n`).
#
# BackendServices.Patch and UrlMaps.Patch are JSON merge patches on the
# server, and the encoder writes every repeated field (an empty one as
# `[]`): a caller patches with the whole resource as it read it
# (test_compute_network states the same for firewalls).
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import (
    Address,
    BackendBucket,
    BackendBucketsClient,
    BackendService,
    BackendServicesClient,
    CacheInvalidationRule,
    ForwardingRule,
    GetBackendBucketRequest,
    GetBackendServiceRequest,
    GetGlobalAddressRequest,
    GetGlobalForwardingRuleRequest,
    GetRegionNetworkEndpointGroupRequest,
    GetSslCertificateRequest,
    GetTargetHttpProxyRequest,
    GetTargetHttpsProxyRequest,
    GetUrlMapRequest,
    GlobalAddressesClient,
    GlobalForwardingRulesClient,
    InsertBackendBucketRequest,
    InsertBackendServiceRequest,
    InsertGlobalAddressRequest,
    InsertGlobalForwardingRuleRequest,
    InsertRegionNetworkEndpointGroupRequest,
    InsertSslCertificateRequest,
    InsertTargetHttpProxyRequest,
    InsertTargetHttpsProxyRequest,
    InsertUrlMapRequest,
    InvalidateCacheUrlMapRequest,
    NetworkEndpointGroup,
    PatchBackendServiceRequest,
    PatchUrlMapRequest,
    RegionNetworkEndpointGroupsClient,
    SslCertificate,
    SslCertificatesClient,
    TargetHttpProxiesClient,
    TargetHttpProxy,
    TargetHttpsProxiesClient,
    TargetHttpsProxy,
    UrlMap,
    UrlMapsClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource

# A global operation, as every global load-balancing write answers it.
comptime _GLOBAL_OP = (
    '{"kind":"compute#operation","name":"operation-lb-1","status":"RUNNING",'
    + '"targetLink":"https://www.googleapis.com/compute/v1/projects/demo-project/global/urlMaps/web"}'
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _http(capture: ArcPointer[List[UInt8]], answer: String) raises -> HttpClient[SC]:
    return HttpClient[SC].with_defaults(
        SC.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
        )
    )


def _token() raises -> TS:
    return TS(String("test-access-token"))


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _head(capture: ArcPointer[List[UInt8]]) -> String:
    """The request line."""
    return String(_wire(capture).split("\r\n")[0])


def _body(capture: ArcPointer[List[UInt8]]) -> String:
    """What follows the header block."""
    var parts = _wire(capture).split("\r\n\r\n")
    return String(parts[1]) if len(parts) > 1 else String("")


def test_global_addresses_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#address","name":"web-ip","address":"34.120.1.2",'
        + '"addressType":"EXTERNAL","ipVersion":"IPV4","status":"IN_USE"}'
    )
    var c = GlobalAddressesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetGlobalAddressRequest(String("web-ip"), String("demo-project")), reactor
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/addresses/web-ip HTTP/1.1",
    )
    assert_equal(got.address.value(), "34.120.1.2")
    assert_equal(got.status.value(), "IN_USE")


def test_global_addresses_insert() raises:
    var capture = _capture()
    var c = GlobalAddressesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var addr = decode_json_lenient[Address](
        String('{"name":"web-ip","ipVersion":"IPV4"}')
    )
    var op = c.insert[_RT](
        InsertGlobalAddressRequest(addr^, String("demo-project"), None), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/addresses HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"ipVersion":"IPV4","labels":{},"name":"web-ip","users":[]}',
    )
    assert_equal(op.name.value(), "operation-lb-1")


def test_ssl_certificates_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#sslCertificate","name":"web-cert","type":"MANAGED",'
        + '"managed":{"domains":["app.example.com"],"status":"PROVISIONING",'
        + '"domainStatus":{"app.example.com":"PROVISIONING"}}}'
    )
    var c = SslCertificatesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetSslCertificateRequest(String("demo-project"), String("web-cert")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/sslCertificates/web-cert HTTP/1.1",
    )
    assert_equal(got.type.value(), "MANAGED")
    ref managed = got.managed.value()
    assert_equal(managed.status.value(), "PROVISIONING")
    assert_equal(managed.domains[0], "app.example.com")
    assert_equal(managed.domain_status["app.example.com"], "PROVISIONING")


def test_ssl_certificates_insert() raises:
    var capture = _capture()
    var c = SslCertificatesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var cert = decode_json_lenient[SslCertificate](
        String(
            '{"name":"web-cert","type":"MANAGED",'
            + '"managed":{"domains":["app.example.com"]}}'
        )
    )
    _ = c.insert[_RT](
        InsertSslCertificateRequest(String("demo-project"), None, cert^), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/sslCertificates HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"domains":["app.example.com"]' in body)
    assert_true('"type":"MANAGED"' in body)


def test_region_network_endpoint_groups_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#networkEndpointGroup","name":"web-neg",'
        + '"networkEndpointType":"SERVERLESS","cloudRun":{"service":"web"},"size":0}'
    )
    var c = RegionNetworkEndpointGroupsClient[SC, TS](
        _http(capture, answer), _token()
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetRegionNetworkEndpointGroupRequest(
            String("web-neg"), String("demo-project"), String("us-central1")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/regions/us-central1/networkEndpointGroups/web-neg HTTP/1.1",
    )
    assert_equal(got.network_endpoint_type.value(), "SERVERLESS")
    assert_equal(got.cloud_run.value().service.value(), "web")


def test_region_network_endpoint_groups_insert() raises:
    var capture = _capture()
    var c = RegionNetworkEndpointGroupsClient[SC, TS](
        _http(capture, _GLOBAL_OP), _token()
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var neg = decode_json_lenient[NetworkEndpointGroup](
        String(
            '{"name":"web-neg","networkEndpointType":"SERVERLESS",'
            + '"cloudRun":{"service":"web"}}'
        )
    )
    _ = c.insert[_RT](
        InsertRegionNetworkEndpointGroupRequest(
            neg^, String("demo-project"), String("us-central1"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/regions/us-central1/networkEndpointGroups HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"annotations":{},"cloudRun":{"service":"web"},"name":"web-neg",'
        + '"networkEndpointType":"SERVERLESS"}',
    )


def test_backend_buckets_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#backendBucket","name":"static","bucketName":"demo-static",'
        + '"enableCdn":true}'
    )
    var c = BackendBucketsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetBackendBucketRequest(String("static"), String("demo-project")), reactor
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/backendBuckets/static HTTP/1.1",
    )
    assert_equal(got.bucket_name.value(), "demo-static")
    assert_true(got.enable_cdn.value())


def test_backend_buckets_insert() raises:
    var capture = _capture()
    var c = BackendBucketsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var bb = decode_json_lenient[BackendBucket](
        String('{"name":"static","bucketName":"demo-static","enableCdn":true}')
    )
    _ = c.insert[_RT](
        InsertBackendBucketRequest(bb^, String("demo-project"), None), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/backendBuckets HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"bucketName":"demo-static","customResponseHeaders":[],"enableCdn":true,'
        + '"name":"static","usedBy":[]}',
    )


def test_backend_services_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#backendService","name":"web-backend",'
        + '"loadBalancingScheme":"EXTERNAL_MANAGED","protocol":"HTTPS",'
        + '"enableCDN":false,"fingerprint":"abc=",'
        + '"backends":[{"group":"https://www.googleapis.com/compute/v1/projects/demo-project/regions/us-central1/networkEndpointGroups/web-neg"}]}'
    )
    var c = BackendServicesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetBackendServiceRequest(String("web-backend"), String("demo-project")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/backendServices/web-backend HTTP/1.1",
    )
    assert_equal(got.load_balancing_scheme.value(), "EXTERNAL_MANAGED")
    assert_false(got.enable_c_d_n.value())
    assert_equal(got.fingerprint.value(), "abc=")
    assert_equal(len(got.backends), 1)
    assert_true(got.backends[0].group.value().endswith("/web-neg"))


def test_backend_services_insert() raises:
    var capture = _capture()
    var c = BackendServicesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var bs = decode_json_lenient[BackendService](
        String(
            '{"name":"web-backend","loadBalancingScheme":"EXTERNAL_MANAGED",'
            + '"protocol":"HTTPS","enableCDN":true,'
            + '"backends":[{"group":"regions/us-central1/networkEndpointGroups/web-neg"}]}'
        )
    )
    _ = c.insert[_RT](
        InsertBackendServiceRequest(bs^, String("demo-project"), None), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/backendServices HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"enableCDN":true' in body)
    assert_true('"loadBalancingScheme":"EXTERNAL_MANAGED"' in body)
    assert_true(
        '"group":"regions/us-central1/networkEndpointGroups/web-neg"' in body
    )


def test_backend_services_patch() raises:
    var capture = _capture()
    var c = BackendServicesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var bs = decode_json_lenient[BackendService](
        String('{"name":"web-backend","fingerprint":"abc=","enableCDN":false}')
    )
    _ = c.patch[_RT](
        PatchBackendServiceRequest(
            String("web-backend"), bs^, String("demo-project"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "PATCH /compute/v1/projects/demo-project/global/backendServices/web-backend HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"enableCDN":false' in body)
    assert_true('"fingerprint":"abc="' in body)
    # Every list is written, empty or not (module header).
    assert_true('"backends":[]' in body)


def test_url_maps_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#urlMap","name":"web","fingerprint":"f1=",'
        + '"defaultService":"https://www.googleapis.com/compute/v1/projects/demo-project/global/backendServices/web-backend",'
        + '"hostRules":[{"hosts":["app.example.com"],"pathMatcher":"app"}],'
        + '"pathMatchers":[{"name":"app","defaultService":"global/backendServices/web-backend",'
        + '"pathRules":[{"paths":["/static/*"],"service":"global/backendBuckets/static"}]}]}'
    )
    var c = UrlMapsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetUrlMapRequest(String("demo-project"), String("web")), reactor
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/urlMaps/web HTTP/1.1",
    )
    assert_equal(got.host_rules[0].path_matcher.value(), "app")
    assert_equal(got.path_matchers[0].path_rules[0].paths[0], "/static/*")
    assert_equal(
        got.path_matchers[0].path_rules[0].service.value(),
        "global/backendBuckets/static",
    )


def test_url_maps_insert() raises:
    var capture = _capture()
    var c = UrlMapsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var um = decode_json_lenient[UrlMap](
        String('{"name":"web","defaultService":"global/backendServices/web-backend"}')
    )
    _ = c.insert[_RT](
        InsertUrlMapRequest(String("demo-project"), None, um^), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/urlMaps HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"defaultService":"global/backendServices/web-backend","hostRules":[],'
        + '"name":"web","pathMatchers":[],"tests":[]}',
    )


def test_url_maps_patch() raises:
    var capture = _capture()
    var c = UrlMapsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var um = decode_json_lenient[UrlMap](
        String(
            '{"name":"web","fingerprint":"f1=",'
            + '"defaultService":"global/backendServices/web-backend-v2"}'
        )
    )
    _ = c.patch[_RT](
        PatchUrlMapRequest(String("demo-project"), None, String("web"), um^),
        reactor,
    )
    assert_equal(
        _head(capture),
        "PATCH /compute/v1/projects/demo-project/global/urlMaps/web HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"fingerprint":"f1="' in body)
    assert_true('"defaultService":"global/backendServices/web-backend-v2"' in body)


def test_url_maps_invalidate_cache() raises:
    var capture = _capture()
    var c = UrlMapsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var rule = decode_json_lenient[CacheInvalidationRule](
        String('{"path":"/static/*","host":"app.example.com"}')
    )
    _ = c.invalidate_cache[_RT](
        InvalidateCacheUrlMapRequest(rule^, String("demo-project"), None, String("web")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/urlMaps/web/invalidateCache HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"cacheTags":[],"host":"app.example.com","path":"/static/*"}',
    )


def test_target_http_proxies_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#targetHttpProxy","name":"web-http",'
        + '"urlMap":"https://www.googleapis.com/compute/v1/projects/demo-project/global/urlMaps/web-redirect"}'
    )
    var c = TargetHttpProxiesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetTargetHttpProxyRequest(String("demo-project"), String("web-http")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/targetHttpProxies/web-http HTTP/1.1",
    )
    assert_true(got.url_map.value().endswith("/urlMaps/web-redirect"))


def test_target_http_proxies_insert() raises:
    var capture = _capture()
    var c = TargetHttpProxiesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var proxy = decode_json_lenient[TargetHttpProxy](
        String('{"name":"web-http","urlMap":"global/urlMaps/web-redirect"}')
    )
    _ = c.insert[_RT](
        InsertTargetHttpProxyRequest(String("demo-project"), None, proxy^),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/targetHttpProxies HTTP/1.1",
    )
    assert_equal(
        _body(capture), '{"name":"web-http","urlMap":"global/urlMaps/web-redirect"}'
    )


def test_target_https_proxies_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#targetHttpsProxy","name":"web-https",'
        + '"urlMap":"global/urlMaps/web",'
        + '"sslCertificates":["global/sslCertificates/web-cert"]}'
    )
    var c = TargetHttpsProxiesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetTargetHttpsProxyRequest(String("demo-project"), String("web-https")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/targetHttpsProxies/web-https HTTP/1.1",
    )
    assert_equal(got.ssl_certificates[0], "global/sslCertificates/web-cert")


def test_target_https_proxies_insert() raises:
    var capture = _capture()
    var c = TargetHttpsProxiesClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var proxy = decode_json_lenient[TargetHttpsProxy](
        String(
            '{"name":"web-https","urlMap":"global/urlMaps/web",'
            + '"sslCertificates":["global/sslCertificates/web-cert"]}'
        )
    )
    _ = c.insert[_RT](
        InsertTargetHttpsProxyRequest(String("demo-project"), None, proxy^),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/targetHttpsProxies HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"name":"web-https","sslCertificates":["global/sslCertificates/web-cert"],'
        + '"urlMap":"global/urlMaps/web"}',
    )


def test_global_forwarding_rules_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#forwardingRule","name":"web-https-fr",'
        + '"IPAddress":"34.120.1.2","IPProtocol":"TCP","portRange":"443-443",'
        + '"loadBalancingScheme":"EXTERNAL_MANAGED",'
        + '"target":"global/targetHttpsProxies/web-https"}'
    )
    var c = GlobalForwardingRulesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = c.get[_RT](
        GetGlobalForwardingRuleRequest(
            String("web-https-fr"), String("demo-project"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/forwardingRules/web-https-fr HTTP/1.1",
    )
    assert_equal(got.I_p_address.value(), "34.120.1.2")
    assert_equal(got.I_p_protocol.value(), "TCP")
    assert_equal(got.port_range.value(), "443-443")


def test_global_forwarding_rules_insert() raises:
    var capture = _capture()
    var c = GlobalForwardingRulesClient[SC, TS](
        _http(capture, _GLOBAL_OP), _token()
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var fr = decode_json_lenient[ForwardingRule](
        String(
            '{"name":"web-https-fr","IPAddress":"global/addresses/web-ip",'
            + '"IPProtocol":"TCP","portRange":"443",'
            + '"loadBalancingScheme":"EXTERNAL_MANAGED",'
            + '"target":"global/targetHttpsProxies/web-https"}'
        )
    )
    _ = c.insert[_RT](
        InsertGlobalForwardingRuleRequest(fr^, String("demo-project"), None),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/forwardingRules HTTP/1.1",
    )
    var body = _body(capture)
    assert_true(body.startswith('{"IPAddress":"global/addresses/web-ip","IPProtocol":"TCP",'))
    assert_true('"portRange":"443"' in body)
    assert_true('"target":"global/targetHttpsProxies/web-https"' in body)


def main() raises:
    test_global_addresses_get()
    test_global_addresses_insert()
    test_ssl_certificates_get()
    test_ssl_certificates_insert()
    test_region_network_endpoint_groups_get()
    test_region_network_endpoint_groups_insert()
    test_backend_buckets_get()
    test_backend_buckets_insert()
    test_backend_services_get()
    test_backend_services_insert()
    test_backend_services_patch()
    test_url_maps_get()
    test_url_maps_insert()
    test_url_maps_patch()
    test_url_maps_invalidate_cache()
    test_target_http_proxies_get()
    test_target_http_proxies_insert()
    test_target_https_proxies_get()
    test_target_https_proxies_insert()
    test_global_forwarding_rules_get()
    test_global_forwarding_rules_insert()
    print("OK")
