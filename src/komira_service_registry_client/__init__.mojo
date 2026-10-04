# =============================================================================
# komira_service_registry_client — THE PEER CLIENT. What a deployed service uses
#   at runtime to turn a peer's NAME into the URL it dials.
# =============================================================================
#
# `komira_service_registry` is the CONTRACT (service discovery with
# last-writer-wins publish, a provenance-carrying lookup, and the HTTP wire).
# The serving app is the READ-ONLY door in front of it. THIS package is
# the other end of that door: the type a service holds so that
#
#     "dial job-manager"
#
# becomes a URL, across clouds, with no credential for the cloud the registry
# runs in, and WITHOUT the registry becoming a hard dependency of every
# service-to-service call in the mesh.
#
#   the caller ──> RemotePeerDirectory[T]  ──T.get──> the registry's HTTP door
#                        │  TTL cache + a stated staleness bound
#                        └─> PeerResolution: one of EIGHT dispositions
#
# ⛔ FOUR THINGS IT DOES NOT DO, EACH ONE A RULING:
#
#  1. IT IS NOT A `ConditionalWriteStore` CONFORMER. Three of that trait's verbs
#     are WRITES the server does not serve, so a conformer would raise on its
#     own capabilities — a type that lies, in the seam whose job is that the
#     store enforces the invariant. See `directory.mojo`.
#  2. IT MINTS, VERIFIES AND CARRIES NO AUTH. Discovery only. The caller applies
#     its own authentication to the PEER call, AFTER resolution — a different
#     call, to a different host, with a different audience.
#  3. IT HOLDS NO KOMIRA PRODUCT CONCEPT. No org_id, app_id, bundle, env, region
#     or cloud enum. A peer is a NAME and the registry is a URL.
#  4. IT DOES NOT KNOW WHAT A STAGE IS. One registry serves one stage, but which
#     stage a service belongs to is decided entirely by WHICH URL it is given,
#     supplied at deploy time. Nothing here can read, check or
#     default it. See `endpoint.mojo`.
#
# ★ THE THREE ANSWERS THIS PACKAGE IS THE ANSWER TO:
#
#   CACHING/STALENESS  a TTL cache, and on a FAILED fetch an expired entry is
#                      served within `max_stale_ms`, saying so and saying how
#                      old it is. A registry outage must not become an outage of
#                      everything that dials a peer. `directory.mojo`'s header.
#   FAILURE SEMANTICS  eight dispositions, all VALUES, never exceptions. A 404
#                      is NEVER absence — with the marker it is a route that does
#                      not exist, without it the registry was not reached.
#                      `answer.mojo`'s table.
#   BOOTSTRAP          the registry's own address is SUPPLIED, from a required
#                      FLAG, and a service without one refuses to start. It can
#                      never be a registry lookup and must not be DNS or platform
#                      metadata. `endpoint.mojo`'s header.
#
# ★★ THE DEP CLOSURE IS PART OF THE DESIGN: `komira_service_registry` (the
# contract), `komira_http_client` + `komira_http_core` (the one production
# transport) and `komira_async` (the blocking runtime it runs on). NO auth
# provider, NO token stack, NO proto codegen. An auth provider added here would
# pull a credential stack into every consumer's closure.
# =============================================================================

from .answer import (
    ANSWER_NOT_REACHED,
    ANSWER_OK,
    ANSWER_PROTOCOL_ERROR,
    ANSWER_REFUSED,
    ANSWER_REGISTRY_ERROR,
    RegistryAnswer,
    classify_registry_response,
    parse_resolve_body,
)
from .directory import RemotePeerDirectory
from .endpoint import (
    RegistryEndpoint,
    SERVICE_REGISTRY_URL_FLAG,
    host_of_base_url,
    refuse_unsafe_segment,
    registry_url_unset_refusal,
)
from .live_transport import REGISTRY_DIAL_TIMEOUT_US, LiveRegistryTransport
from .resolution import (
    MARKER_ABSENT,
    MARKER_NOT_DIALLED,
    MARKER_PRESENT,
    PEER_ABSENT,
    PEER_CACHED,
    PEER_FRESH,
    PEER_PROTOCOL_ERROR,
    PEER_REFUSED,
    PEER_REGISTRY_ERROR,
    PEER_STALE,
    PEER_UNREACHABLE,
    PeerResolution,
)
from .transport import RegistryHttpResponse, RegistryTransport
