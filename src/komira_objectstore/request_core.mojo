# =============================================================================
# komira_objectstore/request_core.mojo — shared request core (a stub)
# =============================================================================
#
# Per file layout (the package file table): "shared request/response
# core; holds the ObjectStoreHttp handle (the HTTP client seam)". In its
# fully-wired shape, this module owns:
#   * the `ObjectStoreHttp` handle (the HTTP client seam, signed + retried)
#   * the request-builder helpers shared across backends (URL construction
#     given (authority, Path) + endpoint config)
#   * the response-parsing dispatch (XML / JSON) common to S3/GCS/Azure
#
# Today's (NETWORK-FREE) scope: a thin module that wires the
# `ObjectStoreHttpStub` shape into a per-backend handle skeleton, so the
# coalesce planner can be tested against an in-memory conformer WITHOUT
# the HTTP client being live. See the notes in `store.mojo` for how the
# real HTTP client trait replaces the stub.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public surface.
#   * ZERO wildcard origins.
# =============================================================================

from komira_objectstore.store import ObjectStoreHttpStub
from komira_objectstore.types import CoalescePolicy


# -----------------------------------------------------------------------------
# RequestCore — per-store request-issuing handle (a skeleton).
# -----------------------------------------------------------------------------
#
# The fully-wired shape extends this with:
#   * endpoint config (region, virtual-hosted vs path-style, custom endpoint)
#   * the SigningLayer handle (cloud-specific; HttpLayer that injects
#     Authorization + x-*-date + x-*-content-sha256 headers before the
#     request reaches the ObjectStoreHttp seam)
# * the RetryLayer config
# -----------------------------------------------------------------------------


@fieldwise_init
struct RequestCore[Http: ObjectStoreHttpStub](Movable, Deinitable):
    """Shared request core — a skeleton.

    Parameterized over `Http: ObjectStoreHttpStub` (a comptime trait bound)
    so the production HTTP client and the in-memory `ScriptedObjectStoreHttpStub`
    test conformer both monomorphize through this carrier without runtime
    dispatch overhead.

    Field layout:
      var http: Http                  — the (signed, retried, layered)
                                        HTTP client handle; held as a
                                        VALUE (Movable) so no wildcard
                                        origin / no UnsafePointer surface
      var coalesce_policy: CoalescePolicy
                                      — the active coalescing policy

    When a real `ObjectStoreHttp` trait replaces the stub, the type
    parameter `Http: ObjectStoreHttpStub` swaps to `Http: ObjectStoreHttp`
    by a single import + rename — no callsite churn.
    """

    var http: Self.Http
    var coalesce_policy: CoalescePolicy

    @staticmethod
    def with_default_policy(var http: Self.Http) -> RequestCore[Self.Http]:
        return RequestCore[Self.Http](http^, CoalescePolicy.default())
