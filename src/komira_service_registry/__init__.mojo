# =============================================================================
# komira_service_registry — THE CROSS-CLOUD SERVICE DISCOVERY CONTRACT.
#   The store, the lookup result and the HTTP wire.
# =============================================================================
#
# This package is DISCOVERY ONLY:
#
#   DISCOVERY   `name -> endpoint`   what a peer dials.     LAST-WRITER-WINS
#
# A URL changes on every redeploy, so the newest publish is the right one and a
# 412 from the conditional write is a retry (once), not a refusal.
#
# ⛔ ENROLLMENT IS NOT PART OF THIS PACKAGE. Binding a platform identity to a
# service name is authentication-adjacent: it belongs to the managed control
# plane, not to an open discovery library. Nothing here stores, resolves or
# revokes an identity, and nothing here tells a caller who a service IS -- only
# where it can currently be reached.
#
# ⛔ NO KOMIRA PRODUCT CONCEPTS LIVE HERE. No org_id, no app_id, no bundle, no
# env, no region, and not even a cloud enum. That emptiness is the feature: it
# is what keeps product vocabulary out of the release tooling, and it is why
# this package's only dependency is `komira_objectstore`.
#
# ⛔ THE REGISTRY DOES NOT MINT TOKENS. It records bindings and answers lookups.
# Deciding whether a WRITE is allowed belongs to the serving app; reads are
# unauthenticated by design.
#
# ⛔ THE HTTP WIRE LIVES HERE TOO (`http_contract.mojo`) — the marker header,
# the body field names and the route path. The SERVING app and the PEER CLIENT
# are two packages that cannot import each other, so a constant spelled in both
# would be a contract with two homes. See that file's header.
#
# ⛔ NO VALIDATE-AT-DEPLOY. The trade is LOGGING — which is why every lookup
# returns a `ResolveResult` carrying the key consulted, whether it was found,
# whether this call reached the store or a cache, and how stale the answer is.
# `describe()` renders that as the one line a service emits when it resolves a
# peer. A bare `Optional[String]` cannot answer either of the two questions a
# runtime-lookup incident opens with.
#
# # RELATIONSHIP TO `komira_svcref.ServiceRegistry`
#
# Both packages serve discovery. This one is WIRE-IDENTICAL to that module: same
# `service/<name>` key, same bare URL bytes, pinned by
# `test_the_endpoint_object_is_wire_identical_to_the_shipped_writer`. Switching a
# caller from one to the other is a code change with no data migration behind
# it. What this package ADDS is provenance on every lookup, a TTL cache with an
# injected clock, and a DELETE verb.
# =============================================================================

from .http_contract import (
    API_VERSION_PREFIX,
    PARAM_NAME,
    RESOLVE_SERVICE_PATH_PREFIX,
    ROUTE_RESOLVE_SERVICE,
    SERVICE_REGISTRY_MARKER_HEADER,
    SERVICE_REGISTRY_MARKER_VALUE,
    WIRE_FIELD_ERROR,
    WIRE_FIELD_FOUND,
    WIRE_FIELD_KEY,
    WIRE_FIELD_VALUE,
    resolve_service_path,
)
from .directory import (
    CachedServiceDirectory,
    ENDPOINT_PREFIX,
    ServiceDirectory,
)
from .resolve_result import (
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    RESOLVE_SOURCE_UNSET,
    ResolveResult,
)
