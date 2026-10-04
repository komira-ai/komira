# =============================================================================
# test_server_integration.mojo
# =============================================================================
#
# In-process unary round-trip through the
# ConnectService ↔ Router bridge (`server_integration.mojo`).
#
# Coverage (NO network, NO Go, NO streaming):
#   T1   register_connect_wildcard returns the sentinel handler-id and
#        adds exactly one route to the Router.
#   T2   dispatch_connect_request — registered method, Connect-JSON unary
#        echo round-trip: matched wildcard → ConnectService.handle_request,
#        result body round-trips the handler's output, status OK.
#   T3   dispatch_connect_request — UNregistered method path returns the
#        NOT_FOUND DispatchResult (the has_method-miss path inside the
#        bound service).
#   T4   dispatch_connect_request — path that does NOT match the wildcard
#        at all (Router miss) ALSO returns NOT_FOUND (no Connect route).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_server.routing import Router

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CODEC_ID_CONNECT_JSON,
    ConnectService,
    DispatchResult,
    connect_json_decode_unary,
    CONNECT_SERVICE_HANDLER_ID,
    register_connect_wildcard,
    dispatch_connect_request,
)


# A simple echo handler — returns a copy of the request bytes.
def _echo_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    return req_body.copy()


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_t1_register_returns_sentinel_and_adds_route() raises:
    var router = Router()
    assert_equal(router.len(), 0)
    var hid = register_connect_wildcard(router)
    assert_equal(hid, CONNECT_SERVICE_HANDLER_ID)
    assert_equal(router.len(), 1)


def test_t2_registered_unary_echo_round_trip() raises:
    # Build a ConnectService with one registered method.
    var svc = ConnectService("example.search.v1.SearchService")
    svc.register_method(
        "/example.search.v1.SearchService/Search", _echo_handler
    )

    # Wire it through a Router via the bridge.
    var router = Router()
    _ = register_connect_wildcard(router)

    # Feed a request: registered path + Connect-JSON content-type + body.
    var body = _bytes(String('{"q":"hello"}'))
    var result = dispatch_connect_request(
        svc,
        router,
        "/example.search.v1.SearchService/Search",
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(body),
    )

    # OK status, Connect-JSON codec, and the body round-trips the echo.
    assert_true(result.is_ok())
    assert_equal(Int(result.grpc_status), Int(GRPC_STATUS_OK))
    assert_equal(Int(result.codec_id), Int(CODEC_ID_CONNECT_JSON))
    # For Connect-JSON unary, the response body IS the message bytes.
    var decoded = connect_json_decode_unary(Span(result.body))
    assert_equal(len(decoded), len(body))
    for i in range(len(body)):
        assert_equal(decoded[i], body[i])


def test_t3_unregistered_method_returns_not_found() raises:
    var svc = ConnectService("example.search.v1.SearchService")
    svc.register_method(
        "/example.search.v1.SearchService/Search", _echo_handler
    )
    var router = Router()
    _ = register_connect_wildcard(router)

    # Path matches the wildcard route, so the bridge delegates to the
    # service — but the method is NOT registered → NOT_FOUND from
    # handle_request's has_method miss path.
    var body = _bytes(String('{"q":"x"}'))
    var result = dispatch_connect_request(
        svc,
        router,
        "/example.search.v1.SearchService/DoesNotExist",
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(body),
    )
    assert_false(result.is_ok())
    assert_equal(Int(result.grpc_status), Int(GRPC_STATUS_NOT_FOUND))


def test_t4_router_miss_returns_not_found() raises:
    # An empty router (no wildcard registered) cannot match POST /* — the
    # bridge surfaces NOT_FOUND without ever touching the service.
    var svc = ConnectService("example.search.v1.SearchService")
    svc.register_method(
        "/example.search.v1.SearchService/Search", _echo_handler
    )
    var router = Router()  # NO route registered.

    var body = _bytes(String('{"q":"x"}'))
    var result = dispatch_connect_request(
        svc,
        router,
        "/example.search.v1.SearchService/Search",
        CONNECT_JSON_CONTENT_TYPE_UNARY,
        Span(body),
    )
    assert_false(result.is_ok())
    assert_equal(Int(result.grpc_status), Int(GRPC_STATUS_NOT_FOUND))


def main() raises:
    test_t1_register_returns_sentinel_and_adds_route()
    test_t2_registered_unary_echo_round_trip()
    test_t3_unregistered_method_returns_not_found()
    test_t4_router_miss_returns_not_found()
    print("PASS komira_connect server_integration")
