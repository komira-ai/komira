# =============================================================================
# src/komira_http_client/service.mojo — Service + Layer traits
# =============================================================================
#
# Signing, retry, redirect, timeout are layers, not hardcoded HttpClient
# features. The middleware seam is a tower-style Service + Layer seam
# rather than a request-mutating interceptor.
#
# The trait shapes, plus a no-op layer
# (`NoopLayer`) that wraps an `HttpService` into the same `HttpService`
# unchanged. Retry / Redirect / Timeout live in their own files.
#
# The base service is `HttpClient.send` (in `client.mojo`). A layer
# wraps it; the wrap is parametric, so the composition chain
# monomorphizes — no fn-ptr table.
#
# Note: `ref [self]` returns are not usable on
# trait methods"), trait methods that need to call into a wrapped
# service do so via the delegating-method form (pass the service as a
# parameter), NOT via a ref-return through self.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_client.body import EmptyBody, RequestBody
from komira_http_client.error import HttpError
from komira_http_client.header_map import HeaderMap
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.state_machine import ClientResponse
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.transport.io_stream import Connector


# =============================================================================
# §1 — ClientRequest — the input to an HttpService call.
# =============================================================================
# sketch: `struct ClientRequest[B: Body]`. This version ships the
# concrete-body shape (caller chooses BytesBody / EmptyBody at build
# site) without the trait parameterization — the HttpClient.send
# takes a pre-serialized request_bytes List[UInt8]. introduces the
# parametric form. for now we ship the request struct with the typed
# surfaces wired up but body left as List[UInt8] (the writer's output).


struct ClientRequest[B: RequestBody = EmptyBody](
    Movable, Deinitable,
):
    """ClientRequest. Parametric on the request-body conformer
    `B: RequestBody`. The body conformer is held as `Optional[B]` so
    that Mojo 1.0.0b1's borrow-check is happy with partial-move
    semantics: `Optional.take()` cleanly produces the body in one step
    while leaving the Optional in a destructor-safe `None` state.

    Default `B = EmptyBody` keeps the GET/HEAD builders mechanical —
    `ClientRequest()` without explicit type argument resolves to
    `ClientRequest[EmptyBody]`. Builders with bodies pin the parameter
    explicitly (`build_request_with_body[BytesBody]`).

    NOTE: this widening is the type-system change only.
    (StreamingBody) is when the `body` Optional gains semantic meaning
    at wire-write time; today the OutboundDriver still drains
    request_bytes as one contiguous blob for buffered shapes.

    Fields:
      method        — for log lines and the writer's request-line.
      url           — for log lines, Host header injection, and the
                      writer's request-target.
      headers       — caller-supplied headers (Host / Content-Length /
                      User-Agent injected by the writer if absent).
      request_bytes — pre-serialized request head + body, ready for the
                      state machine to drain.
      body          — Optional[B] body conformer. For buffered
                      shapes (EmptyBody/BytesBody drained into
                      request_bytes), the Optional is populated with
                      the typed marker. For StreamingBody, the
                      OutboundDriver takes ownership of the Optional's
                      inner B via Optional.take() and drains it on the
                      wire.
      _request_budget_us — THE DEADLINE THIS REQUEST CARRIES. See
                      `request_budget_us()` below; read it through the
                      accessor, never off the field.
    """

    var method: HttpMethod
    var url: Url
    var headers: HeaderMap
    var request_bytes: List[UInt8]
    var body: Optional[Self.B]

    var _request_budget_us: Int
    """★ THE SEAM A DEADLINE LAYER WAS MISSING. The wall-clock
    budget, in microseconds, that THIS request carries down to whatever drives
    it. `0` means "this request states no budget of its own" — the value every
    builder produces, so every pre-existing caller is byte-identical.

    ⛔ WHY A FIELD ON THE REQUEST AND NOT A PARAMETER ANYWHERE. `HttpService`
    has exactly one input — the request — and a LAYER cannot reach the driver
    that does the waiting: `TimeoutLayer` composes over an ARBITRARY inner
    `HttpService`, so there is no signature it could add an argument to. With
    nowhere to state a deadline, the layer could only sample the clock either
    side of `inner.call` and RELABEL what it measured. That is what the layer's
    own header called a follow-up ("plumb through the OutboundDriver's
    pending loop + reactor-timer"), and it is what this field is.

    ⚠ IT IS A RELATIVE BUDGET, NOT AN ABSOLUTE DEADLINE, AND THAT IS FORCED. A
    layer samples an INJECTED `Clock` whose epoch is its own business
    (`MockClock` starts wherever the test says); the driver arms against
    `CLOCK_MONOTONIC`. An absolute instant is not transferable between them; a
    duration is. It is therefore the SAME NUMBER, in the same units, that
    `OutboundDriver.set_request_timeout_us` already takes, which is why it adds
    no third notion of "a budget" to this client.

    ⛔ AND IT IS NOT A THIRD BUDGET. Where a request budget and a client-config
    budget are both stated over one call, the TIGHTER binds
    (`tighter_budget_us`), and the single number that results is handed to the
    one already-composed head+body budget (`OutboundDriver._deadline_us`,
    Envoy's `route.timeout` shape). Two budgets over one call resolve to one;
    they never run side by side."""

    def __init__(
        out self,
        method: HttpMethod,
        var url: Url,
        var headers: HeaderMap,
        var request_bytes: List[UInt8],
        var body: Self.B,
    ):
        self.method = method
        self.url = url^
        self.headers = headers^
        self.request_bytes = request_bytes^
        self.body = Optional[Self.B](body^)
        # DELIBERATELY NOT A CONSTRUCTOR ARGUMENT. 125 sites construct a
        # `ClientRequest`; a sixth positional would be a migration, and the
        # honest default for every one of them is "states no budget". A caller
        # that HAS one says so in a second statement.
        self._request_budget_us = 0

    @always_inline
    def request_budget_us(self) -> Int:
        """The wall-clock budget (µs) this request carries, or 0 when it
        states none. POD `Int` — nothing crosses a module boundary but a
        number."""
        return self._request_budget_us

    def set_request_budget_us(mut self, us: Int):
        """State this request's own wall-clock budget (µs). `us <= 0` clears
        it back to "states none".

        ⭐ TIGHTENS ONLY, NEVER LOOSENS. A budget already on the request is
        kept when it is the SMALLER of the two, so composing layers
        (`TimeoutLayer(RetryLayer(TimeoutLayer(client)))`) resolve to the
        tightest bound any of them stated rather than to whichever one ran
        last. A setter that let the inner layer overwrite an outer layer's
        tighter deadline would be a deadline the call path could defeat by
        being wrapped in the wrong order."""
        if us <= 0:
            return
        if self._request_budget_us <= 0 or us < self._request_budget_us:
            self._request_budget_us = us


# =============================================================================
# §2 — HttpService trait.
# =============================================================================
# `HttpService.call(req, ...) -> ClientResponse raises HttpError`.
# This is the unifying surface that the RetryLayer /
# RedirectLayer / TimeoutLayer / SigningLayer all conform to and wrap.
#
# Following the MENU / reframe: trait methods do NOT return refs
# through self. They take the runtime/reactor/connector as explicit
# parameters and return owned values. This is the bring-your-own-event-
# loop pattern stated precisely.


trait HttpService(Movable, Deinitable):
    """Base service abstraction. One `call` method that
    consumes a request and returns a response.

    The HttpClient (in `client.mojo`) is the canonical base conformer.
    Layers wrap services; the wrap is parametric so the chain
    monomorphizes.

    The method is parametric on `[RT: Runtime, C: Connector]` so the
    runtime + connector can be selected per call site. The reactor +
    connector are passed explicitly (NOT recovered via `rt.reactor()`)
    — same pattern as IoStream.
    """

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        ...

    def call_pooled[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """The KEEPALIVE-AWARE
        buffered analog of `call`. The DEFAULT implementation delegates 1-1 to
        `call` (no keepalive) so every existing conformer + test double gets it
        for free — this is a migration, NOT an additive parallel API. Only the
        base transports that own a per-worker keepalive cache
        (`HttpClient` / `SigV4SignedTransport`) OVERRIDE this to reuse an idle
        connection for the request's origin instead of fresh-dialing.

        Same `[RT, C, B]` shape as `call`; the override pools only when the
        per-call connector's stream type matches the client's own cache stream
        type (the broker path: `C == Self.C`)."""
        return self.call[RT, C, B](req^, connector, reactor)


# =============================================================================
# §3 — HttpLayer trait.
# =============================================================================
# A layer wraps an HttpService into another HttpService. says
# the wrap forms a tower-style chain: SigningLayer(RetryLayer(Timeout
# Layer(HttpClient))) for example.
#
# This version ships the trait shape + one no-op conformer (`NoopLayer`)
# that wraps S into the same surface unchanged.


trait HttpLayer(Movable, Deinitable):
    """Layer abstraction. A layer composes an inner
    HttpService into an outer HttpService — same `call` shape, but with
    pre/post logic interposed.

    The layer is parametric over its wrapped service type. The
    canonical layers (RetryLayer / RedirectLayer / Timeout
    Layer / SigningLayer) each ship a struct with their own state +
    config + an inner `_inner: S` field; they conform to HttpService
    and dispatch via `self._inner.call[RT, C](...)`.
    """

    def layer_name(self) -> String:
        """Symbolic name for log lines + test assertions."""
        ...


# =============================================================================
# §4 — NoopLayer.
# =============================================================================
# A layer that adds no behavior — exists as the first conformer + as
# the identity element in any composition chain. Tests using NoopLayer
# verify that the trait shape compiles + monomorphizes correctly.


@fieldwise_init
struct NoopLayer[S: HttpService](
    HttpLayer, HttpService, Movable, Deinitable,
):
    """No-op layer: wraps an HttpService into an HttpService that
    delegates 1-1. Used as:
      * the identity element in tests
      * a placeholder when no layers are configured
      * a verification that the parametric Service composition shape
        compiles on Mojo 1.0.0b1.
    """

    var _inner: Self.S

    @staticmethod
    def wrap(var inner: Self.S) -> NoopLayer[Self.S]:
        return NoopLayer[Self.S](_inner=inner^)

    def layer_name(self) -> String:
        return String("noop")

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """Delegate to the inner service. No-op pre/post."""
        return self._inner.call[RT, C, B](req^, connector, reactor)
