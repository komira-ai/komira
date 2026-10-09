# =============================================================================
# src/komira_http_server/middleware/__init__.mojo — L3 middleware chain
# =============================================================================
#
# Ordered request/response interceptors.
#
# Submodules:
#   - middleware.mojo      — Middleware trait, RequestContext, and the
#                            Principal / Claims / PresentedCredential an
#                            embedder's own middleware attaches (the library
#                            gives the subject and claims no meaning)
#   - chain.mojo           — MiddlewareChain driver
#   - logging.mojo         — LoggingMiddleware
#   - tracing.mojo         — TracingMiddleware
#   - error_mapper.mojo    — ErrorMappingMiddleware (raises → attributed 500)
#   - fault_report.mojo    — the ONE attribution point every boundary 500 goes
#                            through (cause code + incident id on the wire, raw
#                            detail on stdout under that same id)
#   - cors.mojo            — CorsMiddleware (Origin / Methods / preflight)
#   - passthrough.mojo     — PassthroughMiddleware: the INERT innermost slot,
#                            for an embedder whose access checks live inside
#                            its DISPATCHER (per-route or per-arm gates).
#                            Authorizes nothing; see its banner.
#   - metrics.mojo         — MetricsMiddleware + MetricsSink, and
#                            PairMiddleware, which composes two middleware
#                            into one slot (nest it to compose more)
#
# Mojo 1.0.0b1 trait constraints (no HKT, no `impl Trait`) drive the
# composition-over-polymorphism chain shape: the chain holds the 4
# builtins as `Optional`-wrapped concrete-typed fields rather than a
# `List[OwnedPointer[Middleware]]`. This is the
# pragmatic shape.
# =============================================================================

from .chain import ChainOutcome, MiddlewareChain, run_chain
from .cors import CorsConfig, CorsMiddleware
from .error_mapper import ErrorMappingConfig, ErrorMappingMiddleware
from .fault_report import (
    FAULT_CODE_TRANSPORT,
    FAULT_CODE_UNATTRIBUTED,
    FAULT_SOURCE_RAISE,
    FAULT_SOURCE_RESPONSE,
    WIRING_UNWIRED_UNKNOWN,
    error_response_log_line,
    fault_envelope,
    fault_log_line,
    new_incident_id,
    observe_error_response,
    report_fault,
    response_body_text,
    trace_header_of,
)
from .logging import LogEntry, LoggingMiddleware
from .passthrough import PassthroughMiddleware
from .middleware import (
    Claims,
    Middleware,
    PresentedCredential,
    Principal,
    PRINCIPAL_SCHEME_JWT,
    PRINCIPAL_SCHEME_SESSION,
    RequestContext,
)
from .tracing import TracingMiddleware
