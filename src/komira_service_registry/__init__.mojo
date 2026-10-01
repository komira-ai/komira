# =============================================================================
# komira_service_registry — THE CROSS-CLOUD SERVICE REGISTRY CONTRACT.
#   The record and the store.
# =============================================================================
#
# ONE registry per stage. TWO GENERIC JOBS:
#
#   DISCOVERY   `name -> endpoint`     what a peer dials.        LAST-WRITER-WINS
#   ENROLLMENT  `identity -> service`  the checkable claim.  CREATE-OR-CONFLICT
#
# Those two policies are OPPOSITE, a CAS precondition is over an OBJECT, and one
# object therefore carries one policy — so the registry is TWO keyspaces on one
# store, and `ServiceRecord` is the JOIN rather than a stored row. The full
# argument, including the competing one-record design and why it loses, is at
# the top of `record.mojo`. Read it before changing the shape.
#
# ⛔ NO KOMIRA PRODUCT CONCEPTS LIVE HERE. No org_id, no app_id, no bundle, no
# env, no region, and not even a cloud ENUM — the platform is a free-form token
# (`identity.mojo` says why the obvious reuse of the five `CLOUD_*` ordinals is
# refused). That emptiness is the feature: it is what keeps product vocabulary
# out of the release tooling, and it is why this package's only dependency is
# `komira_objectstore`.
#
# ⛔ THE REGISTRY DOES NOT MINT TOKENS. It records bindings and answers lookups.
# Authenticating a WRITE by platform attestation belongs to the serving app;
# reads are unauthenticated by design.
#
# ⛔ THE HTTP WIRE LIVES HERE TOO (`http_contract.mojo`) — the marker header,
# the three body field names and the two route paths. The SERVING app and the
# PEER CLIENT are two packages that cannot import each other, so a constant
# spelled in both would be a contract with two homes. See that file's header.
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
# That module serves the discovery half alone. This package is WIRE-IDENTICAL
# to it on that half: same `service/<name>` key, same bare URL bytes, pinned by
# `test_the_endpoint_object_is_wire_identical_to_the_shipped_writer`. Switching a
# caller from one to the other is a code change with no data migration behind
# it. What this package ADDS is the second job (enrollment), provenance on every
# lookup, and a DELETE verb.
# =============================================================================

from .http_contract import (
    API_VERSION_PREFIX,
    PARAM_FINGERPRINT,
    PARAM_NAME,
    RESOLVE_IDENTITY_PATH_PREFIX,
    RESOLVE_SERVICE_PATH_PREFIX,
    ROUTE_RESOLVE_IDENTITY,
    ROUTE_RESOLVE_SERVICE,
    SERVICE_REGISTRY_MARKER_HEADER,
    SERVICE_REGISTRY_MARKER_VALUE,
    WIRE_FIELD_ERROR,
    WIRE_FIELD_FOUND,
    WIRE_FIELD_KEY,
    WIRE_FIELD_VALUE,
    resolve_identity_path,
    resolve_service_path,
)
from .directory import (
    CachedServiceDirectory,
    ENDPOINT_PREFIX,
    IDENTITY_PREFIX,
    ServiceDirectory,
)
from .identity import (
    PlatformIdentity,
    escape_principal,
    identity_fingerprint,
    identity_from_fingerprint,
    unescape_principal,
    validate_platform,
)
from .record import ServiceRecord
from .resolve_result import (
    RESOLVE_SOURCE_CACHE,
    RESOLVE_SOURCE_STORE,
    RESOLVE_SOURCE_UNSET,
    ResolveResult,
)
