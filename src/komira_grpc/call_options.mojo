# =============================================================================
# komira_grpc/call_options.mojo — per-call options
# =============================================================================
#
# Every generated RPC method takes a `CallOptions` that carries:
#   - `deadline_micros`: an absolute microsecond deadline (0 = unset).
#     Encoded into `Grpc-Timeout` request header on the wire; enforced
#     locally via the runtime's clock.
#   - `metadata`: RpcMetadata (the gRPC metadata header bundle).
#
# The cancellation `token: CancellationToken` is threaded as a SEPARATE
# `ref token` parameter per call — NOT a CallOptions field — because
# CancellationToken is non-Copyable and is owned by the caller's request
# tree, and a borrowed-pointer field would outlive it.
#
# Encapsulation: NO UnsafePointer; CallOptions is Movable (not Copyable),
# because RpcMetadata is Movable-only (owns its HeaderMap).
# =============================================================================

from komira_grpc.metadata import RpcMetadata


# =============================================================================
# §1 — DEADLINE_UNSET sentinel.
# =============================================================================

comptime CALL_DEADLINE_UNSET: Int = 0
"""Sentinel deadline value indicating no deadline is set on this call.
Mirrors komira_connect.deadline.DEADLINE_UNSET_MICROS for consistency."""


# =============================================================================
# §2 — CallOptions — per-call options bundle.
# =============================================================================


struct CallOptions(Movable, Deinitable):
    """Per-RPC-call options bundle.

    Generated stubs accept a `CallOptions` parameter on every method;
    the runtime applies the options at the wire layer:
      - `deadline_micros` → encode_grpc_timeout_us → `Grpc-Timeout` header.
      - `metadata` → user Custom-Metadata. Keys travel VERBATIM on classic
        gRPC and `grpc-metadata-`-prefixed on Connect — the builders pick,
        see `komira_grpc.headers._drain_user_metadata`.
    Movable, NOT Copyable — owns the RpcMetadata bundle (which owns
    HeaderMap, which is Movable-only).

    Pattern (codegen consumer):
        var opts = CallOptions.new()
        opts.with_relative_deadline_us(now_us, 5_000_000)  # 5-second deadline
        opts.metadata.set("user-id", "42")
        var resp = client.some_call(req, opts^, reactor, token)
    """

    var deadline_micros: Int
    """Absolute deadline in microseconds, OR CALL_DEADLINE_UNSET (0).

    NOTE on absolute-vs-relative: at API entry this is the deadline
    CLOCK reading (`runtime.now_us() + N`), not the relative timeout.
    A relative timeout is converted to absolute at API entry via the
    `with_relative_deadline_us` setter (which requires the runtime's clock).
    The runtime's clock is NOT threaded through this struct; consumers
    stage their absolute deadline value externally.
    """

    var metadata: RpcMetadata
    """Per-call user Custom-Metadata (+ base64 `-bin` values).

    ⚠ The header NAME depends on the protocol: verbatim over gRPC/HTTP2 (the
    key IS the header name, per PROTOCOL-HTTP2.md "Custom-Metadata"),
    `grpc-metadata-`-prefixed over Connect. Both drains are on RpcMetadata and
    `komira_grpc.headers._drain_user_metadata` selects between them; entries
    are stored UNPREFIXED here either way.

    Multi-valued: a key set twice emits two headers (APPEND), unlike
    `raw_metadata` below."""

    var raw_metadata: RpcMetadata
    """Per-call RAW (un-prefixed) transport headers. Unlike `metadata`,
    entries here are emitted VERBATIM — no `grpc-metadata-` prefix. This is
    the path for transport / routing headers the server matches as bare
    HTTP/2 header names: `authorization: Bearer <token>` (OAuth2) and
    `x-goog-request-params: bucket=projects/_/buckets/<b>` (the GCS gRPC
    routing header). The header builders drain this via
    `RpcMetadata.drain_raw_into_request_headers` (insert/REPLACE semantics,
    retry-idempotent)."""

    def __init__(out self):
        self.deadline_micros = CALL_DEADLINE_UNSET
        self.metadata = RpcMetadata.new()
        self.raw_metadata = RpcMetadata.new()

    @staticmethod
    def new() -> CallOptions:
        return CallOptions()

    def with_deadline_micros(mut self, micros: Int):
        """Set the deadline to `micros` microseconds (absolute).

        The `Grpc-Timeout` header on the wire is relative-to-now; the
        runtime computes `deadline_micros - now()` at request-emit time and
        serializes via `komira_connect.deadline.encode_grpc_timeout_us`.

        Pass CALL_DEADLINE_UNSET (0) to clear.
        """
        self.deadline_micros = micros

    def with_relative_deadline_us(mut self, now_us: Int, relative_us: Int):
        """Set the deadline to `now_us + relative_us` (absolute).

        Convenience for consumers that have the current clock value in
        hand. `relative_us` is interpreted as microseconds relative to
        `now_us`; negative or zero yields an already-tripped deadline.
        """
        if relative_us <= 0:
            # Already tripped — set to now_us (any clock check trips).
            self.deadline_micros = now_us
        else:
            self.deadline_micros = now_us + relative_us

    @always_inline
    def has_deadline(imm self) -> Bool:
        """True iff a deadline is set (deadline_micros != CALL_DEADLINE_UNSET)."""
        return self.deadline_micros != CALL_DEADLINE_UNSET

    @always_inline
    def is_deadline_expired(imm self, now_us: Int) -> Bool:
        """True iff this call's deadline is set AND now_us >= it."""
        return self.has_deadline() and now_us >= self.deadline_micros
