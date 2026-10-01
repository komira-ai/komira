# =============================================================================
# komira_service_registry/record.mojo — THE RECORD. What a registered service
#   IS, and why it is stored as TWO objects rather than one.
# =============================================================================
#
# ★★ THE DESIGN DECISION OF THIS PACKAGE. Read this before changing any of it.
#
# The registry has two generic jobs and they are NOT symmetric:
#
#   DISCOVERY   `name -> endpoint`    A URL changes on every redeploy.
#                                     LAST-WRITER-WINS is CORRECT: the newest
#                                     deploy's URL is the one peers should
#                                     reach. A 412 is a RETRY.
#
#   ENROLLMENT  `identity -> service` A binding says WHO A SERVICE IS.
#                                     Last-writer-wins here means the most
#                                     recent writer DECIDES who a service is.
#                                     So it is CREATE-OR-CONFLICT: a 412 from a
#                                     DIFFERENT claimant is a REFUSAL.
#
# A `compare_and_swap` precondition is over an OBJECT. One object therefore
# carries exactly one write policy. Two policies need two objects:
#
#     service/<name>     -> the served URL bytes       (last-writer-wins)
#     identity/<fp>      -> the service NAME bytes     (create-or-conflict)
#
# `ServiceRecord` is the JOIN of those two objects for one service. It is what
# a diagnostic or the reap tooling reads; it is NOT a stored row, and there is no
# key that holds one.
#
# # ⛔ THE COMPETING DESIGN, AND WHY IT LOSES ON THREE COUNTS
#
# The alternative considered was ONE record per service carrying both the
# endpoint and its identity binding(s), with FIELD-LEVEL write authority — the
# precedent being a deployment record that fuses an endpoint with a credential
# in a single row. It loses:
#
#  1. FIELD-LEVEL AUTHORITY IS NOT A THING THE STORE CAN ENFORCE. The
#     precondition is over the whole object, so the endpoint writer — which
#     retries on 412 by design — must read-modify-write the WHOLE record,
#     identity field included. Its retry would therefore re-read a binding a
#     concurrent enroller had just written and write it back out. The refusal
#     would then rest on the endpoint writer voluntarily comparing a field it
#     has no interest in: a CONVENTION, checked in application code, on the hot
#     path of every redeploy. The entire reason to be on a CAS store is that the
#     store enforces the invariant instead.
#
#  2. IT CANNOT DELIVER THE STRUCTURAL UNIQUENESS THE REGISTRY NEEDS. Keyed by
#     service, two services claiming ONE identity write to TWO different keys.
#     Nothing collides. Detecting the double-claim needs a LIST-and-compare —
#     which is O(N), and is a race in exactly the window that matters (both
#     claimants scan, both see nothing, both write). Keyed by the identity
#     FINGERPRINT, the two claims address ONE object and the second one's
#     `If-None-Match: *` fails. Structure, not vigilance.
#
#  3. THE CARDINALITY IS NOT 1:1. One logical service legitimately holds a GCP
#     identity AND an AWS one. In a per-service record that is a LIST field, and
#     "create-or-conflict" would have to hold per LIST ELEMENT — a thing an
#     object-level CAS cannot express at all.
#
# ⚠ AND THE DEPLOYMENT-RECORD PRECEDENT DOES NOT TRANSFER, on inspection. Its
# endpoint and its credential are written by the SAME writer, at the SAME
# moment, under the SAME authority — the deploy. Fusion is free when there is
# one writer. Here the writers differ in lifetime and in authority: the deploy
# rewrites the endpoint on every wave, while the enrollment is written once and
# must never be silently rewritten by anyone. Fusing writers that disagree about
# how often they may win is what produces a row whose CAS semantics is whichever
# writer touched it last.
#
# ⇒ ONE RECORD AS A CONCEPT, TWO OBJECTS AS STORAGE, AND THE SPLIT FALLS EXACTLY
#   ON THE WRITE-POLICY BOUNDARY.
# =============================================================================

from .identity import PlatformIdentity


struct ServiceRecord(Copyable, Movable, Deinitable):
    """Everything the registry knows about ONE logical service — the JOIN of its
    discovery object and its enrollment objects.

    Assembled by `ServiceDirectory.describe`; never stored under any key. This
    is the shape the reap tooling reads to find an orphan (an endpoint with no
    identity, or an identity naming a service with no endpoint)."""

    var name: String
    """The logical service name — the discovery key's only variable part, and
    the value every one of `identities` is bound to."""

    var endpoint: Optional[String]
    """The URL this service last published, or `None` if it has never
    published one (or has been withdrawn)."""

    var identities: List[PlatformIdentity]
    """Every platform identity enrolled AS this service. Zero, one, or one per
    cloud the service runs on — the cardinality is not 1:1."""

    def __init__(
        out self,
        var name: String,
        var endpoint: Optional[String],
        var identities: List[PlatformIdentity],
    ):
        self.name = name^
        self.endpoint = endpoint^
        self.identities = identities^

    @always_inline
    def has_endpoint(self) -> Bool:
        """Whether this service has a published endpoint. An enrolled service
        with no endpoint is a service that has never converged — which is a
        thing the reap tooling reports, not an error here."""
        return self.endpoint.__bool__()

    @always_inline
    def is_orphan(self) -> Bool:
        """No endpoint AND no identity: a name the registry holds nothing for.
        The reap tooling's primary predicate."""
        return (not self.endpoint) and len(self.identities) == 0
