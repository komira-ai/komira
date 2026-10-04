# =============================================================================
# komira_service_registry/http_contract.mojo — THE HTTP WIRE CONTRACT, in the
#   ONE package both ends of it depend on.
# =============================================================================
#
# ★★ WHY THESE CONSTANTS LIVE HERE AND NOT IN THE SERVER.
#
# The registry's HTTP server (an application) and its HTTP client (a leaf
# library) are two packages that must agree, BYTE FOR BYTE, on:
#
#     the request PATH        `/v1/services/<name>`
#     the response FIELDS     `found` / `value` / `key`
#     the response MARKER     `x-service-registry: 1`
#
# and they cannot import each other: the server is an application and the
# client is a leaf library a deployed service links. A constant spelled in both
# is a contract with two homes, and a contract with two homes drifts silently —
# the server renames a route, the client's GET starts 404ing, and the 404 is
# indistinguishable from the three OTHER parties that forge one (see
# `SERVICE_REGISTRY_MARKER_HEADER` below). The one place both ends already
# depend on is this package, so the wire lives here.
#
# ⚠ THE ROUTE PATTERN AND ITS PREFIX ARE BOTH HERE, ADJACENT, ON PURPOSE. The
# server registers the PATTERN (`/v1/services/:name`) and the client composes a
# CONCRETE path (`/v1/services/orders-api`). Those are two derivations of one
# string, and `path_pattern_is_the_prefix_plus_the_capture` asserts the
# relationship rather than trusting two literals to stay in step.
#
# ⛔ NO KOMIRA PRODUCT CONCEPT. Same rule as the rest of this package: these are
# properties of a key-value lookup over HTTP. No org, app, bundle, env, region
# or cloud appears on this wire, which is what lets an OSS consumer speak it.
# =============================================================================


# -----------------------------------------------------------------------------
# §1 — the RESPONSE MARKER.
# -----------------------------------------------------------------------------

comptime SERVICE_REGISTRY_MARKER_HEADER: String = "x-service-registry"
"""The header NAME every registry response carries, on EVERY status.

★★ IT IS THE ONLY THING THAT DISTINGUISHES A NON-2xx FROM THE REGISTRY FROM A
NON-2xx PRODUCED IN FRONT OF IT. Three parties on this path emit a 404 that is
byte-identical to an application 404, all three observed in deployment:

  * Google's serverless edge terminates `/healthz` with its OWN 404 before the
    Cloud Run IAM check;
  * a service with `internal-and-cloud-load-balancing` ingress answers 404 on
    EVERY path, including a nonsense control;
  * a DELETED service answers 404 too.

So `404 + marker` and `404 - marker` are DIFFERENT EVENTS with OPPOSITE fixes
(ship a client that matches the server's routes / fix the edge), and a client
that reads them the same way has thrown away the one bit that separates them.

Lowercase because `HttpResponse.headers` is a case-INSENSITIVE map with a
lowercase canonical spelling — a mixed-case key here is a second entry, not the
same one.

⚠ NO BRAND PREFIX, DELIBERATELY. Both ends are open source and hold no
product concept; a brand prefix in the WIRE contract would be one, and would
have to be renamed by anyone running the registry standalone."""

comptime SERVICE_REGISTRY_MARKER_VALUE: String = "1"
"""The header VALUE. A constant, not a version and not a build id: a caller must
be able to assert the exact bytes, and anything that varied per revision would
make the assertion a moving target."""


# -----------------------------------------------------------------------------
# §2 — the RESPONSE BODY's field names.
# -----------------------------------------------------------------------------

comptime WIRE_FIELD_FOUND: String = "found"
"""Whether a binding exists. A JSON `true`/`false` LITERAL — never the strings
`"true"`/`"false"`. A client that checks only that the key is PRESENT would
accept either; one that checks the VALUE would not, and `found` is the single
field every caller branches on."""

comptime WIRE_FIELD_VALUE: String = "value"
"""The bound value: the URL for a discovery lookup. Emitted as `""` when `found` is false — never omitted, so an
absent binding has the SAME BODY SHAPE as a hit and a client's parse has one
path."""

comptime WIRE_FIELD_KEY: String = "key"
"""The object key the SERVER consulted, e.g. `service/orders-api`.

⛔ A CLIENT MUST CARRY THIS VERBATIM AND MUST NOT RE-DERIVE IT. Re-deriving it
would make the client's log line report the client's own BELIEF about the key
composition, which is exactly the disagreement the field exists to make
diagnosable — comparing a belief with itself detects nothing."""

comptime WIRE_FIELD_ERROR: String = "error"
"""The single member of a non-2xx body. Names the SHAPE that was wrong, never a
store error's text (a store error can carry a bucket, a project or a principal,
and these routes are unauthenticated)."""


# -----------------------------------------------------------------------------
# §3 — the ROUTE PATHS. Patterns for the server, prefixes for the client.
# -----------------------------------------------------------------------------

comptime API_VERSION_PREFIX: StaticString = "/v1"
"""The version prefix, spelled once. It is on the ROUTES and not on the object
KEYS: the wire may version independently of the storage layout, and coupling
them would make a route rename a data migration."""

comptime PATH_CAPTURE_SUFFIX: StaticString = ":"
"""The character that opens a router capture. Held as a constant so
`path_pattern_is_the_prefix_plus_the_capture` can state the relationship between
a PATTERN and a PREFIX without either side hardcoding the other's spelling."""

comptime RESOLVE_SERVICE_PATH_PREFIX: StaticString = "/v1/services/"
"""DISCOVERY. The client appends the service NAME verbatim."""

comptime PARAM_NAME: String = "name"

comptime ROUTE_RESOLVE_SERVICE: StaticString = "/v1/services/:name"
"""The DISCOVERY route pattern the server registers."""


def resolve_service_path(name: String) -> String:
    """`/v1/services/<name>` — the concrete request path for a DISCOVERY lookup.

    ⚠ IT DOES NOT PERCENT-ENCODE, AND THAT IS NOT AN OVERSIGHT. The server does
    no percent-DECODING in its routes (a decoder there would be code no caller
    can exercise), so an encoding client would make the server consult a key
    containing a literal `%20`. The caller's obligation is therefore to REFUSE a
    name that is not safe in one path segment — a check that belongs in the
    client, because it is the caller who can name the offending byte."""
    return String(RESOLVE_SERVICE_PATH_PREFIX) + name
