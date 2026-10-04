# =============================================================================
# komira_service_registry_client/transport.mojo — THE NETWORK SEAM, and the
#   three facts a registry lookup is allowed to depend on.
# =============================================================================
#
# ★ THE TRAIT NAMES NO HTTP TYPE, AND THAT IS THE DESIGN.
#
# `RegistryHttpResponse` is `(status, marker, body)` — an Int and two Strings.
# It is deliberately NOT `HttpResponse`, not a `HeaderMap`, not a body stream:
#
#  1. THE CLASSIFIER CANNOT GROW A NEW INPUT BY ACCIDENT. Every rule in
#     `answer.mojo` is a function of exactly these three values, so "which bytes
#     decide whether we reached the registry" is answerable by reading one
#     struct. Hand the classifier a HeaderMap and the answer becomes "whichever
#     headers someone reached for", which is how a discriminator quietly
#     acquires a second, weaker one.
#  2. A CONFORMER NEED NOT BE `komira_http_client`. An AWS Lambda with a platform fetch,
#     a test with a scripted script, an on-prem service behind a proxy library —
#     all can speak this seam. That is what keeps the package OSS-partitionable
#     rather than OSS-shaped.
#  3. ONE HEADER IS PART OF THE CONTRACT AND THE REST ARE NOT. `x-service-registry`
#     is the only header any rule reads (see `SERVICE_REGISTRY_MARKER_HEADER`),
#     so the seam carries it by name and carries nothing else.
#
# ⛔⛔ `get` MUST NOT RAISE ON A 4xx / 5xx. A non-2xx is a CLASSIFIED OUTCOME,
# and a transport that raised on one would collapse `PEER_REGISTRY_ERROR`,
# `PEER_PROTOCOL_ERROR` and `PEER_UNREACHABLE` into a single unreachable —
# destroying the distinction this whole package exists to make. `raises` is for
# a genuine transport fault ONLY: DNS, TCP, TLS, timeout, a malformed URL.
#
# ⛔ NO AUTH. The seam carries no credential, no token source and no signer. The
# registry read is unauthenticated by the mandate, and a peer applies its own
# auth to the PEER call AFTER resolution — a different call, to a different
# host, with a different audience. An auth parameter here would be the first
# product concept in this package and would pull a token stack into its
# closure.
#
# ENCAPSULATION: pure value types across the seam. ZERO UnsafePointer, ZERO
# wildcard origins, no FFI. def-based.
# =============================================================================


@fieldwise_init
struct RegistryHttpResponse(Copyable, Movable, Deinitable):
    """One registry response, reduced to the three facts every rule reads."""

    var status: Int
    """The HTTP status. Reported VERBATIM — never normalised, never folded into
    a boolean. `404` and `503` have different corrections and a transport that
    reported `ok: False` for both would be the collapse this package refuses."""

    var marker: String
    """The value of the `x-service-registry` response header, or `""` when the
    header is ABSENT.

    ⚠ `""` FOR ABSENT IS SAFE HERE — and only because the writer's value is a
    non-empty constant, which is the same argument
    `service_registry_marker_of` makes on the server's read side. A conformer
    MUST NOT substitute a placeholder for a missing header: absence is the
    signal."""

    var body: String
    """The response body, verbatim. Not parsed, not trimmed, not lowercased —
    `answer.mojo` is strict about the bytes and a helpful transport would
    silently repair a body the strictness exists to catch."""

    @staticmethod
    def unmarked(status: Int, var body: String) -> Self:
        """A response with NO marker header — i.e. one that some party in front
        of the registry may have produced. The named constructor exists so a
        test cannot express this state by forgetting an argument."""
        return Self(status, String(""), body^)


trait RegistryTransport(Movable, Deinitable):
    """GET one absolute URL and SURFACE the response.

    `Movable` so the directory can own and move a conformer; `Deinitable` so a
    generic field is droppable.

    See the ⛔ block in this module's header: a 4xx/5xx is a return value, not
    an exception."""

    def get(mut self, url: String) raises -> RegistryHttpResponse:
        """GET `url`; return status + marker + body.

        Args:
            url: The absolute URL to fetch, already composed by the caller.

        Returns:
            The three facts the classifier reads.
        """
        ...
