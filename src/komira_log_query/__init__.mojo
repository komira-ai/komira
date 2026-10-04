# =============================================================================
# komira_log_query — query a log that a service writes to an object store.
# =============================================================================
#
# A service that writes its log to an object store needs a way to read it back.
# This package is the read side: a seam a storage-specific reader conforms to,
# and an HTTP route a service mounts to answer log queries over that seam.
#
# ── WHAT IS IN HERE ─────────────────────────────────────────────────────────
#   hit.mojo          `ServiceLogQuery` / `ServiceLogHit` / `ServiceLogPage`:
#                     format-neutral values (a time window, an optional term,
#                     a page bound; hits as timestamp + score + JSON record).
#   search_seam.mojo  `ServiceLogSearch` (the trait a reader conforms to) +
#                     `ErasedServiceLogSearch` (the non-generic facade a service
#                     holds as one field).
#   access.mojo       `LogReadAccess` (the hook that decides who may read) +
#                     `DenyLogReads` and `HeaderTokenAccess`.
#   route.mojo        `GET <path>`: the match, the access check, the argument
#                     checks, the JSON render.
#
# ── WHAT THE EMBEDDING SERVICE SUPPLIES ─────────────────────────────────────
# The mount path, the access hook, the reader (a `ServiceLogSearch` conformer
# over its own store, erased once) and the current time. This package chooses
# none of them, reads no env and no clock, and ships no reader.
#
# ⛔ ACCESS IS DENIED UNLESS THE SERVICE'S HOOK SAYS YES. The hook is a required
# argument of the route, and no allow-everything hook ships here: see
# `access.mojo` for why.
#
# ⭐ A CLEAN LEAF ON `komira_http_core`. A reader conformer needs whatever
# search and storage libraries its at-rest layout needs; the service code that
# mounts the route need not. Keeping the trait here and the conformer elsewhere
# lets a service depend on this package without widening its closure:
#
#   THIS package (leaf)   ---- trait + route + hook ---->  the service's router
#   a reader package      ---- conformer            ---->  the `erase[S]` site
#
# ⛔ DO NOT ADD A SEARCH OR STORAGE LIBRARY TO THIS PACKAGE'S DEPS. The moment
# one appears, the leaf property is gone.
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
from komira_log_query.access import (
    DenyLogReads,
    HeaderTokenAccess,
    LogReadAccess,
)
from komira_log_query.route import (
    SERVICE_LOG_DEFAULT_LIMIT,
    SERVICE_LOG_DEFAULT_LOOKBACK_MS,
    SERVICE_LOG_LIMIT_PARAM,
    SERVICE_LOG_MAX_LIMIT,
    SERVICE_LOG_QUERY_PARAM,
    SERVICE_LOG_SINCE_PARAM,
    SERVICE_LOG_UNTIL_PARAM,
    is_service_log_request,
    service_log_response,
)
