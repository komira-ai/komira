# =============================================================================
# komira_log_query — THE READ SEAM for a service's own operational log.
# =============================================================================
#
# `komira_log_index` is the WRITE half: `ServiceLogSink[Storage]` makes a bare
# `log.info[...]` in service code land in an object-store search index. This is
# the READ half. Without it the write half is a one-way door: a service can
# publish log splits that nothing deployed can open.
#
# ── WHAT IS IN HERE, AND WHY IT IS A SEPARATE PACKAGE ───────────────────────
#   hit.mojo          `ServiceLogHit` / `ServiceLogPage` — format-neutral values.
#   search_seam.mojo  `ServiceLogSearch` (the trait) + `ErasedServiceLogSearch`
#                     (the non-generic facade a dispatcher holds as one field).
#   route.mojo        `GET /internal/logs` — the match, the authorization policy,
#                     the JSON render.
#
# ⭐ A CLEAN LEAF ON `komira_http`, AND THAT IS THE WHOLE REASON IT IS NOT A
# FILE IN `komira_log_index`. The shipped conformer needs `komira_search` +
# `komira_search_s3`; the DISPATCHER that mounts the route must not. A service
# dispatcher that already links `komira_http` can depend on this package at no
# extra cost, while depending on `komira_log_index` would drag the whole search
# stack into it and into every test that instantiates it.
#
# The trait lives in the leaf; the conformer that needs the transport lives in
# the bridge package:
#
#   THIS package (leaf)  ---- trait + route ---->  the service dispatcher
#   komira_log_index     ---- conformer     ---->  the binary's `erase[S]` site
#
# ⛔ DO NOT ADD `komira_search`, `komira_search_s3` OR `komira_log_index` TO THIS
# PACKAGE'S DEPS. The moment one appears, the leaf property is gone and so is the
# reason the dispatcher could mount the route for free.
#
# ── THE AUTHORIZATION MODEL IS OPERATOR-ONLY, AND IT IS STATED IN route.mojo ─
# One paragraph, because it is the part people skip: these records are the
# service's OWN diagnostics and they name every tenant at once. They carry no
# `org_id` and no `run_id`, so they CANNOT be filed per-tenant without inventing
# an attribution. The route is therefore operator-only, fail-closed when
# unconfigured, and answers a byte-identical 404 to every refusal. A customer's
# run-scoped deploy narration is a different sink and a different, tenant-gated
# route.
# =============================================================================

from komira_log_query.hit import (
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
)
from komira_log_query.search_seam import (
    ErasedServiceLogSearch,
    ServiceLogSearch,
)
from komira_log_query.route import (
    SERVICE_LOG_DEFAULT_LIMIT,
    SERVICE_LOG_DEFAULT_LOOKBACK_MS,
    SERVICE_LOG_LIMIT_PARAM,
    SERVICE_LOG_MAX_LIMIT,
    SERVICE_LOG_QUERY_PARAM,
    SERVICE_LOG_ROUTE_PATH,
    SERVICE_LOG_SINCE_PARAM,
    SERVICE_LOG_TOKEN_HEADER,
    SERVICE_LOG_UNTIL_PARAM,
    is_service_log_request,
    service_log_response,
)
