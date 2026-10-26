# =============================================================================
# tests/test_tick_pump_edges.mojo: the classifying loop's dispatcher-raise arm,
#   `announce_init_failure` when its own channel fails, and the tick
#   converter's path edges.
# =============================================================================
# `test_pump_flush_ordering.mojo` asserts the dispatcher-raise-is-a-500 rule
# for `run_api_gateway_pump` only; the classifying loop
# (`run_api_gateway_and_tick_pump`) has its own copy of that arm, asserted
# here on both of its arms (a tick and an API Gateway event). The instruments
# are re-declared, as in the sibling test files, so this file compiles against
# this library and its deps only.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.aws_lambda_runtime import AwsLambdaRuntime

from komira_http_core.codec.types import HTTP_METHOD_GET, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_json import parse_json_value

from komira_aws_lambda_http.apigw_v2 import AuthorizerHeaderPrefix
from komira_aws_lambda_http.eventbridge_tick import (
    _starts_with_slash,
    eventbridge_tick_event_to_request,
)
from komira_aws_lambda_http.pump import (
    LambdaInvocationTransport,
    LambdaInvokeEvent,
    LambdaPostResponseFlush,
    announce_init_failure,
    run_api_gateway_and_tick_pump,
)


comptime _Rt = AwsLambdaRuntime[NoopSink]


def _prefix() raises -> AuthorizerHeaderPrefix:
    return AuthorizerHeaderPrefix(String("x-example-authz-"))


struct _Transport(LambdaInvocationTransport, Movable, Deinitable):
    """No socket: events to hand out, one counter per channel, and a switch
    that makes the init-error channel itself fail."""

    var _events: List[String]
    var _next: Int
    var post_count: Int
    var error_count: Int
    var init_error_attempts: Int
    var last_payload: String
    var last_request_id: String
    var fail_init_channel: Bool

    def __init__(out self, var events: List[String]):
        self._events = events^
        self._next = 0
        self.post_count = 0
        self.error_count = 0
        self.init_error_attempts = 0
        self.last_payload = String("")
        self.last_request_id = String("")
        self.fail_init_channel = False

    def next_invocation(mut self) raises -> LambdaInvokeEvent:
        if self._next >= len(self._events):
            raise Error("transport: no invocation left")
        var event = self._events[self._next].copy()
        var rid = String("req-") + String(self._next)
        self._next += 1
        return LambdaInvokeEvent(rid^, event^)

    def respond_ok(mut self, request_id: String, payload: String) raises:
        self.post_count += 1
        self.last_payload = payload
        self.last_request_id = request_id

    def report_error(mut self, request_id: String, message: String) raises:
        self.error_count += 1
        self.last_request_id = request_id

    def report_init_error(mut self, message: String) raises:
        self.init_error_attempts += 1
        if self.fail_init_channel:
            raise Error("transport: init-error channel unreachable")


struct _Flush(LambdaPostResponseFlush, Movable, Deinitable):
    var count: Int

    def __init__(out self):
        self.count = 0

    def flush_after_response(mut self) raises -> Int:
        self.count += 1
        return 0


struct _RaisingDispatcher(RequestDispatcher, Movable, Deinitable):
    """Raises on every dispatch, with a detail string that must NOT reach the
    response body."""

    var dispatch_count: Int

    def __init__(out self):
        self.dispatch_count = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.dispatch_count += 1
        raise Error("upstream table orders-internal unavailable")


def _run_one_raising(event: String) raises -> _Transport:
    var events = List[String]()
    events.append(event)
    var transport = _Transport(events^)
    var dispatcher = _RaisingDispatcher()
    var flush = _Flush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var handled = run_api_gateway_and_tick_pump[
        _RaisingDispatcher, _Rt, _Transport, _Flush
    ](transport, dispatcher, reactor, flush, _prefix(), 1)
    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(flush.count, 1)
    return transport^


def _assert_a_500_result(transport: _Transport) raises:
    """A RESULT, not an error report, carrying the generic 500 and none of the
    raise's detail."""
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)
    assert_equal(transport.last_request_id, String("req-0"))
    var v = parse_json_value(transport.last_payload)
    assert_equal(v.get(String("statusCode")).text, String("500"))
    var body = v.get(String("body")).as_string()
    assert_equal(body, String('{"error": "internal"}'))
    assert_true(body.find(String("orders-internal")) < 0)
    var hdrs = v.get(String("headers"))
    assert_equal(
        hdrs.get(String("content-type")).as_string(),
        String("application/json"),
    )
    assert_equal(hdrs.get(String("content-length")).as_string(), String("21"))


def test_a_tick_whose_dispatcher_raises_is_a_500_result() raises:
    """The tick arm of the classifying loop: a dispatcher raise becomes the
    generic 500 on the RESULT channel (as in `run_api_gateway_pump`), not an
    invocation error, and the drain still runs once."""
    var t = _run_one_raising(
        String('{"httpMethod":"POST","path":"/internal/tick/reconcile"}')
    )
    _assert_a_500_result(t)


def test_an_apigw_event_whose_dispatcher_raises_is_a_500_result() raises:
    """The API Gateway arm of the same loop, same answer."""
    var t = _run_one_raising(
        String(
            '{"version": "2.0", "rawPath": "/api/v1/items",'
            ' "requestContext": {"http": {"method": "GET"}}}'
        )
    )
    _assert_a_500_result(t)


def test_init_failure_with_an_unreachable_channel_still_returns_the_line() raises:
    """`announce_init_failure` never raises: when the init-error POST itself
    fails, it still returns the original line (stage and cause), having tried
    the channel exactly once."""
    var transport = _Transport(List[String]())
    transport.fail_init_channel = True
    var msg = announce_init_failure[_Transport](
        transport, String("read-config"), String("flag --table missing")
    )
    assert_equal(
        msg, String("lambda-init-failed: read-config: flag --table missing")
    )
    assert_equal(transport.init_error_attempts, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.error_count, 0)


def test_a_trailing_question_mark_leaves_an_empty_query() raises:
    """`/x?`: the path stops before the `?` and the query is empty (the slice
    after the last byte), not `?` and not the whole path."""
    var req = eventbridge_tick_event_to_request(
        String('{"httpMethod":"GET","path":"/x?"}')
    )
    assert_equal(req.path, String("/x"))
    assert_equal(req.query_string, String(""))
    assert_equal(req.method.code, HTTP_METHOD_GET)
    var root = eventbridge_tick_event_to_request(
        String('{"httpMethod":"GET","path":"/?"}')
    )
    assert_equal(root.path, String("/"))
    assert_equal(root.query_string, String(""))


def test_the_slash_check_on_its_own() raises:
    """`_starts_with_slash` directly: through the converter an empty path is
    refused first by the empty-member check, so its empty arm is reached only
    here. Empty is not a slash; a slash anywhere but first is not either."""
    assert_false(_starts_with_slash(String("")))
    assert_true(_starts_with_slash(String("/")))
    assert_true(_starts_with_slash(String("/a")))
    assert_false(_starts_with_slash(String("a/")))
    assert_false(_starts_with_slash(String("\\a")))


def test_an_unknown_verb_and_a_slashless_path_report_the_verb() raises:
    """Two faults at once: `httpMethod` outside the table AND a path without a
    leading `/`. The verb is checked first and its refusal is the one
    reported."""
    var msg = String("")
    try:
        _ = eventbridge_tick_event_to_request(
            String('{"httpMethod":"FROB","path":"x"}')
        )
    except e:
        msg = String(e)
    assert_true(msg.find(String("`httpMethod` = 'FROB'")) >= 0)
    assert_true(msg.find(String("does not start with '/'")) < 0)
    # The baseline: the slashless path alone, with a known verb, IS refused,
    # and by the path check, so the assertion above is about order.
    var alone = String("")
    try:
        _ = eventbridge_tick_event_to_request(
            String('{"httpMethod":"GET","path":"x?/"}')
        )
    except e:
        alone = String(e)
    assert_true(alone.find(String("`path` = 'x?/' does not start with '/'")) >= 0)


def main() raises:
    test_a_tick_whose_dispatcher_raises_is_a_500_result()
    test_an_apigw_event_whose_dispatcher_raises_is_a_500_result()
    test_init_failure_with_an_unreachable_channel_still_returns_the_line()
    test_a_trailing_question_mark_leaves_an_empty_query()
    test_the_slash_check_on_its_own()
    test_an_unknown_verb_and_a_slashless_path_report_the_verb()
    print("test_tick_pump_edges: ALL PASS")
