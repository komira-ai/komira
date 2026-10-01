# =============================================================================
# src/komira_http/client/owned_byte_body.mojo — OwnedByteBody fast-path
# =============================================================================
#
# The small-body fast-path ResponseBody conformer.
#
# PERF-CRITICAL — do NOT delete / fold into BufferedResponseBody without
# re-measuring. A per-body-size comparison of the two read paths:
#
#   size (B)   Path-A_ns   Path-B_ns   ratio (b/a)
#   64         366-453     738-817     1.80-2.02×
#   256        441-465     1088-1093   2.34-2.48×
#   1024       779-780     2224-2239   2.85-2.87×
#   4096       1703-1716   6063-6071   3.53-3.56×
#   16384      5023-5054   20641-20668 4.09-4.11×
#
# Path A (OwnedByteBody, modeled via BufferedResponseBody — which is
# structurally identical) beats Path B (RecvRingBody) by 1.80× on the
# smallest 64 B body.
#
# Root cause of the structural overhead: RecvRingBody's
# `new_content_length` path does an EXTRA per-byte memcpy from
# `pre_body_bytes` (driver-extracted from `_recv_buf`) into `_accum`
# (response_body.mojo:420). OwnedByteBody avoids this by having the
# OutboundDriver memcpy bytes DIRECTLY into the owned slurp List that
# OwnedByteBody takes by ownership transfer (zero post-construction
# memcpy).
#
# Why this exists ALONGSIDE BufferedResponseBody:
# ------------------------------------------------------------------
# BufferedResponseBody (`response_body.mojo`) and OwnedByteBody (this
# file) are STRUCTURALLY IDENTICAL — both hold a `List[UInt8]` body, both
# yield a single Data frame + End. They differ in semantic purpose:
#
#   * BufferedResponseBody — v1-bridge / HttpService.call layered-
#     surface return type. Constructed by HttpService.call AFTER
#     collect_body has drained the streaming body into one List. Used
#     by RetryLayer / TimeoutLayer / etc. for full-body inspection +
#     replay semantics.
#
#   * OwnedByteBody (THIS FILE) — small-body fast-path conformer.
#     Constructed by OutboundDriver DIRECTLY when the response is
#     framed by a small (<= small_body_fast_path_threshold) Content-Length
#     and the body bytes fit entirely within the recv_buf's pre-body
#     bytes. Avoids the structural overhead above (1.80-4.11×
#     on small bodies).
#
# The two MAY converge once production data on real
# IMDS/STS/S3-HEAD workloads tells us whether the layered surface (which
# currently goes through collect_body) is hot enough to warrant unifying.
#
# Production wiring:
# ------------------------------------------------------------------
# The OutboundDriver fast-path-selection logic (i.e., flipping between
# RecvRingBody and OwnedByteBody based on the parsed Content-Length
# value) is separate work. This file is a STANDALONE
# conformer + the differential test that verifies
# byte-identical decode against RecvRingBody on every body fixture.
# The HttpClientConfig.small_body_fast_path_threshold knob + the
# OutboundDriver fast-path branch is a follow-up.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * OwnedByteBody owns its `_buf: List[UInt8]`. Movable, NOT
#     Copyable.
# =============================================================================

from komira_async.cancellation.token import CancellationToken
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http.client.body_frame import (
    BODY_FRAME_KIND_DATA,
    BODY_FRAME_KIND_END,
    BodyFrame,
)
from komira_http.client.response_body import ResponseBody


# =============================================================================
# §1 — OwnedByteBody — the small-body fast-path conformer.
# =============================================================================


struct OwnedByteBody(ResponseBody, Movable, Deinitable):
    """Small-body fast-path ResponseBody conformer.

    Constructed when the response body is small (<= threshold) AND
    framed by a known Content-Length AND fits entirely within the
    OutboundDriver's recv_buf pre-body bytes. The OutboundDriver hands
    ownership of the slurped body bytes to this conformer via
    `from_bytes(bs)`; ZERO post-construction memcpy is performed.

    `poll_frame` yields ONE Data(chunk) frame transferring ownership of
    the entire body to the caller, then End frames idempotently.

    PERF-CRITICAL: this is the fast-path conformer. Empirical hc08
    evidence shows it beats RecvRingBody by 1.80× at 64 B → 4.11× at
    16 KiB on the small-body size distribution. See file header for
    full numbers.

    Construction:
      * `OwnedByteBody.from_bytes(bs)` — take ownership of the slurped
        body bytes. First poll_frame yields Data(bs); subsequent polls
        yield End.
      * `OwnedByteBody.empty()` — empty body (HEAD / 204 / 304 / CL=0).
        First poll yields End directly.

    State:
      _buf            — owned body bytes.
      _data_emitted   — True once the single Data frame has been
                        returned.

    Movable, NOT Copyable — owns the buffer.
    """

    var _buf: List[UInt8]
    var _data_emitted: Bool

    def __init__(out self):
        """Empty body. First poll_frame returns End directly."""
        self._buf = List[UInt8]()
        self._data_emitted = True  # No Data to emit for empty body.

    @staticmethod
    def empty() -> OwnedByteBody:
        """Construct an empty body. poll_frame returns End on first
        call."""
        return OwnedByteBody()

    @staticmethod
    def from_bytes(var bs: List[UInt8]) -> OwnedByteBody:
        """Construct from slurped body bytes. Ownership of `bs` is
        moved into the conformer with ZERO memcpy.

        The first poll_frame returns Data(bs) (ownership transferred);
        subsequent calls return End.
        """
        var rb = OwnedByteBody()
        rb._buf = bs^
        # An empty buf has no Data frame to emit; treat as already-emitted.
        rb._data_emitted = rb._buf.__len__() == 0
        return rb^

    # ----- The ResponseBody trait method -----------------------------------

    def poll_frame[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        ref token: CancellationToken,
    ) raises -> BodyFrame:
        """Yield one Data frame transferring ownership of the full body,
        then End frames idempotently.

        OwnedByteBody does NOT drive the reactor — the body is fully
        contained in the conformer at construction. The `reactor` +
        `token` parameters are present for trait conformance.

        Cancellation: the body is already owned, so cancellation cannot
        interrupt a read (there is no in-flight read). The conformer
        ignores token; this is correct per the BufferedResponseBody
        precedent.
        """
        if self._data_emitted:
            return BodyFrame.end()
        # First poll: emit the full body as ONE Data frame.
        self._data_emitted = True
        var chunk = List[UInt8]()
        swap(chunk, self._buf)
        return BodyFrame.data(chunk^)

    # ----- Read-only accessors --------------------------------------------

    @always_inline
    def bytes_remaining(self) -> Int:
        """Bytes still un-emitted (i.e., if poll_frame has not yet been
        called on a non-empty body). For tests + invariants."""
        if self._data_emitted:
            return 0
        return self._buf.__len__()

    @always_inline
    def data_emitted(self) -> Bool:
        """Whether the single Data frame has been consumed."""
        return self._data_emitted
