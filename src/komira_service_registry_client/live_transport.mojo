# =============================================================================
# komira_service_registry_client/live_transport.mojo — the PRODUCTION conformer:
#   one GET over komira_http_client, no credential of any kind.
# =============================================================================
#
# ★ WHY A CONFORMER SHIPS IN THIS PACKAGE AT ALL. A seam with no production
# implementation is a landed, tested, re-exported API that nothing can use:
# green unit gates over pieces of a chain that is not connected. The trait is what makes the classifier testable with no socket;
# THIS is what makes the package a thing a deployed service can hold.
#
# ⛔ IT SENDS NO CREDENTIAL, AND THAT IS THE POINT OF THE WHOLE SUBSYSTEM. The
# caller of this client is, canonically, an AWS Lambda that CANNOT authenticate
# to anything in the GCP project the registry runs in — cross-cloud IAM
# federation was deleted fleet-wide. Registry reads are unauthenticated by the
# mandate; the API Gateway in front runs `CLIENT_PASSTHROUGH` and mints the
# backend hop's OIDC itself. Adding an `Authorization` header here would be a
# credential this package must not hold and would break the one caller it
# exists for.
#
# ⛔ IT DOES NOT FOLLOW REDIRECTS. A 3xx has no marker, classifies as
# NOT_REACHED, and stops. Following one would let whatever emitted it choose the
# host this client asks for a peer's address — the intermediary would be
# answering the question, which is the exact substitution the marker exists to
# detect.
#
# ⚠ THE SCHEME PICKS THE CLIENT TYPE, WHICH IS WHY THE TWO ARMS ARE WRITTEN OUT.
# `HttpClient[TlsConnector[KernelTcpConnector]]` and `HttpClient[KernelTcpConnector]`
# are different TYPES; there is no runtime value that is either. The plaintext
# arm is reachable only for a loopback host, because `RegistryEndpoint.parse`
# refuses plaintext anywhere else.
#
# ⚠ COVERAGE, STATED HONESTLY: this file is COMPILED by the gate and is NOT
# EXERCISED by it. Driving it needs a live listener, which a hermetic test does not
# have. Everything decidable
# without a socket has been moved OUT of it on purpose — URL composition is
# `RegistryEndpoint` + the contract's path composers, and every classification
# rule is `answer.mojo` — so what is untested here is exactly "call the HTTP client
# and copy three fields out of the response", and nothing else.
#
# ENCAPSULATION: a fieldless-but-for-a-timeout value; no credential is stored,
# no pointer crosses a boundary, no wildcard origin.
# =============================================================================

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import EmptyBody
from komira_http_client.client import HttpClient, build_get_request
from komira_http_client.header_map import HeaderMap
from komira_http_client.tls_connector import (
    TlsConnector,
    build_public_ca_tls_connector,
)
from komira_http_client.url import Url
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_service_registry.http_contract import SERVICE_REGISTRY_MARKER_HEADER

from .transport import RegistryHttpResponse, RegistryTransport


comptime REGISTRY_DIAL_TIMEOUT_US: Int = 5_000_000
"""The default per-request deadline: 5s.

★ A REGISTRY LOOKUP IS ON A REQUEST PATH AND MUST FAIL FAST. The staleness
ladder makes a timeout CHEAP — an expired-but-usable entry is served the moment
the dial gives up — so a long timeout buys nothing and costs the caller's
latency budget. A short one is only correct BECAUSE the cache exists."""


struct LiveRegistryTransport(RegistryTransport, Movable, Deinitable):
    """The production conformer: one unauthenticated GET, three fields out."""

    var _timeout_us: Int

    def __init__(out self, timeout_us: Int = REGISTRY_DIAL_TIMEOUT_US):
        self._timeout_us = timeout_us

    def get(mut self, url: String) raises -> RegistryHttpResponse:
        """GET `url`; return status + marker + body.

        RAISES only for a genuine transport fault — a malformed URL, DNS, TCP,
        TLS, a timeout. A 4xx or 5xx is RETURNED, because the classifier reads
        the status and the marker to decide what happened, and a raise would
        throw both away."""
        if url.startswith(String("https://")):
            var u = Url.parse(url)
            var host = u.host_copy()
            var headers = HeaderMap()
            headers.append(String("Accept"), String("application/json"))
            var req = build_get_request(u^, headers^)
            var connector = build_public_ca_tls_connector(host)
            var client = HttpClient[
                TlsConnector[KernelTcpConnector]
            ].with_request_timeout_us(connector^, self._timeout_us)
            var rt = BlockingRuntime[NoopSink].new(
                NoopSink(_placeholder=UInt8(0))
            )
            ref reactor = rt.reactor()
            var cr = client.send_buffered[
                BlockingRuntime[NoopSink], EmptyBody
            ](req^, reactor)
            return _harvest(
                Int(cr.status),
                cr.headers.get(SERVICE_REGISTRY_MARKER_HEADER),
                cr.body.take_bytes(),
            )

        var u2 = Url.parse(url)
        var headers2 = HeaderMap()
        headers2.append(String("Accept"), String("application/json"))
        var req2 = build_get_request(u2^, headers2^)
        var client2 = HttpClient[KernelTcpConnector].with_request_timeout_us(
            KernelTcpConnector.new(), self._timeout_us
        )
        var rt2 = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
        ref reactor2 = rt2.reactor()
        var cr2 = client2.send_buffered[BlockingRuntime[NoopSink], EmptyBody](
            req2^, reactor2
        )
        return _harvest(
            Int(cr2.status),
            cr2.headers.get(SERVICE_REGISTRY_MARKER_HEADER),
            cr2.body.take_bytes(),
        )


def _harvest(
    status: Int, var marker: Optional[String], var body_bytes: List[UInt8]
) -> RegistryHttpResponse:
    """Copy the three contract facts out of a response.

    ⚠ AN ABSENT MARKER BECOMES `""`, AND NOTHING ELSE MAY. Substituting a
    placeholder would erase the one bit that separates "the registry answered"
    from "something in front of it did"."""
    var m = String("")
    if marker:
        m = marker.value().copy()
    return RegistryHttpResponse(
        status, m^, String(unsafe_from_utf8=Span(body_bytes))
    )
