# =============================================================================
# src/komira_http/middleware/__init__.mojo — L3 middleware chain
# =============================================================================
#
# Ordered request/response interceptors.
#
# Submodules:
#   - middleware.mojo      — Middleware trait + RequestContext
#   - key_constraint.mojo  — KeyConstraint: the credential ATTENUATION carrier.
#                            May only SUBTRACT from membership-derived
#                            authority. Lives here for the SAME layering reason
#                            AuthedUser does: the credential resolver and the
#                            authorization decider are siblings, and
#                            komira_http is the one package both depend on.
#   - chain.mojo           — MiddlewareChain driver
#   - logging.mojo         — LoggingMiddleware
#   - tracing.mojo         — TracingMiddleware
#   - error_mapper.mojo    — ErrorMappingMiddleware (raises → attributed 500)
#   - fault_report.mojo    — the ONE attribution point every boundary 500 goes
#                            through (cause code + incident id on the wire, raw
#                            detail on stdout under that same id)
#   - cors.mojo            — CorsMiddleware (Origin / Methods / preflight)
#   - passthrough.mojo     — PassthroughMiddleware: the INERT innermost slot,
#                            for an app whose authorization lives inside its
#                            DISPATCHER (per-route or per-arm gates).
#                            Authorizes nothing; see its banner.
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
from .key_constraint import (
    KEY_MASK_UNCONSTRAINED,
    KeyConstraint,
    mask_allows_ordinal,
)
from .logging import LogEntry, LoggingMiddleware
from .passthrough import PassthroughMiddleware
from .middleware import (
    AuthedUser,
    GrantClaim,
    GRANT_CLAIM_CTX_REF_LEN,
    Middleware,
    RequestContext,
)
from .tracing import TracingMiddleware
