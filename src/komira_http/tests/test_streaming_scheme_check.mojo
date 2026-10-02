# =============================================================================
# test_streaming_scheme_check.mojo — THE STREAMING ENTRY POINTS REFUSE A
# SCHEME/CONNECTOR MISMATCH BEFORE ANY BYTE LEAVES.
# =============================================================================
#
# Every dial path of `HttpClient` calls `_scheme_check_or_raise`: an `https://`
# URL needs a TLS connector, an `http://` URL needs a plaintext one. Three
# streaming entry points read the scheme and never checked it:
#
#     send_streaming_pooled_get
#     issue_streaming_get_nonblocking
#     issue_streaming_put_nonblocking
#
# so `HttpClient[KernelTcpConnector]` handed an `https://` URL dialled the
# plaintext connector and wrote the signed request, `Authorization` header and
# all, in cleartext.
#
# The observable is the connector's `connect_call_count()`: a refusal happens
# BEFORE the dial, so the count stays 0 and the pre-armed stream is never
# taken (nothing is written). Each case also asserts the typed error, so a
# change that merely dialled and then failed would not pass.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.body import BytesBody, EmptyBody
from komira_http.client.client import (
    HttpClient,
    build_get_request,
    build_request_with_body,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.service import ClientRequest
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = PerCoreAsyncRuntime[NoopSink]


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _payload() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(65))
    out.append(UInt8(66))
    return out^


def _get_req(url: String) raises -> ClientRequest[EmptyBody]:
    var hdrs = HeaderMap()
    return build_get_request(Url.parse(url), hdrs^)


def _put_req(url: String) raises -> ClientRequest[BytesBody]:
    var hdrs = HeaderMap()
    return build_request_with_body[BytesBody](
        HttpMethod.put(), Url.parse(url), hdrs^,
        BytesBody.from_bytes(_payload()),
    )


def _plain() -> ScriptedConnector:
    return ScriptedConnector.with_stream(ScriptedStream.empty())


def _tls() -> ScriptedConnector:
    return ScriptedConnector.with_stream_tls(ScriptedStream.empty())


def _assert_refused(raised: Bool, detail: String, connects: Int) raises:
    assert_true(raised, msg="a scheme/connector mismatch must raise")
    assert_true(
        detail.find("URL_INVALID") >= 0,
        msg="must be the typed scheme error; got: " + detail,
    )
    assert_equal(connects, 0, "nothing may be dialled on a mismatch")


# --- https:// URL on a PLAINTEXT connector: the cleartext-leak direction -----


def test_send_streaming_pooled_get_refuses_https_on_plaintext() raises:
    var connector = _plain()
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client.send_streaming_pooled_get[_RT](
            _get_req(String("https://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_issue_streaming_get_refuses_https_on_plaintext() raises:
    var connector = _plain()
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _p = client.issue_streaming_get_nonblocking[_RT](
            _get_req(String("https://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_issue_streaming_put_refuses_https_on_plaintext() raises:
    var connector = _plain()
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _p = client.issue_streaming_put_nonblocking[_RT](
            _put_req(String("https://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


# --- http:// URL on a TLS connector: the converse ---------------------------


def test_send_streaming_pooled_get_refuses_http_on_tls() raises:
    var connector = _tls()
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client.send_streaming_pooled_get[_RT](
            _get_req(String("http://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_issue_streaming_get_refuses_http_on_tls() raises:
    var connector = _tls()
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _p = client.issue_streaming_get_nonblocking[_RT](
            _get_req(String("http://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_issue_streaming_put_refuses_http_on_tls() raises:
    var connector = _tls()
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _p = client.issue_streaming_put_nonblocking[_RT](
            _put_req(String("http://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


# --- the gRPC / pooled / batch entry points ---------------------------------
# A refusal is observed on BOTH connectors the call could have dialled: the
# client's own (`own`) and, where one is passed, the per-call connector.


def test_send_grpc_pooled_refuses_https_on_plaintext() raises:
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client.send_grpc_pooled[_RT](
            _get_req(String("https://127.0.0.1:9000/o"))^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, client._connector.connect_call_count())


def test_send_grpc_pooled_h2c_refuses_https_on_plaintext() raises:
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client.send_grpc_pooled_h2c[_RT](
            _get_req(String("https://127.0.0.1:9000/o"))^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, client._connector.connect_call_count())


def test_send_grpc_pooled_h2c_refuses_http_on_tls() raises:
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client.send_grpc_pooled_h2c[_RT](
            _get_req(String("http://127.0.0.1:9000/o"))^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, client._connector.connect_call_count())


def test_call_pooled_self_c_refuses_http_on_tls() raises:
    var connector = _tls()
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client._call_pooled_self_c[_RT](
            _get_req(String("http://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_call_pooled_self_c_refuses_https_on_plaintext() raises:
    var connector = _plain()
    var own = _plain()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var raised = False
    var detail = String()
    try:
        var _r = client._call_pooled_self_c[_RT](
            _get_req(String("https://127.0.0.1:9000/o"))^, connector, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, connector.connect_call_count())


def test_send_buffered_batch_refuses_mixed_schemes() raises:
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var reqs = List[ClientRequest[EmptyBody]]()
    reqs.append(_get_req(String("https://127.0.0.1:9000/a")))
    reqs.append(_get_req(String("http://127.0.0.1:9000/b")))
    var raised = False
    var detail = String()
    try:
        var _r = client.send_buffered_batch[_RT](reqs^, reactor)
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, client._connector.connect_call_count())


def test_send_buffered_batch_refuses_mixed_authorities() raises:
    var own = _tls()
    var client = HttpClient[ScriptedConnector].with_defaults(own^)
    var reactor = _make_reactor()
    var reqs = List[ClientRequest[EmptyBody]]()
    reqs.append(_get_req(String("https://a.example.com/a")))
    reqs.append(_get_req(String("https://b.example.com/b")))
    var raised = False
    var detail = String()
    try:
        var _r = client.send_buffered_batch[_RT](reqs^, reactor)
    except e:
        raised = True
        detail = String(e)
    _assert_refused(raised, detail, client._connector.connect_call_count())


def main() raises:
    test_send_streaming_pooled_get_refuses_https_on_plaintext()
    test_issue_streaming_get_refuses_https_on_plaintext()
    test_issue_streaming_put_refuses_https_on_plaintext()
    test_send_streaming_pooled_get_refuses_http_on_tls()
    test_issue_streaming_get_refuses_http_on_tls()
    test_issue_streaming_put_refuses_http_on_tls()
    test_send_grpc_pooled_refuses_https_on_plaintext()
    test_send_grpc_pooled_h2c_refuses_https_on_plaintext()
    test_send_grpc_pooled_h2c_refuses_http_on_tls()
    test_call_pooled_self_c_refuses_http_on_tls()
    test_call_pooled_self_c_refuses_https_on_plaintext()
    test_send_buffered_batch_refuses_mixed_schemes()
    test_send_buffered_batch_refuses_mixed_authorities()
    print("OK: test_streaming_scheme_check")
