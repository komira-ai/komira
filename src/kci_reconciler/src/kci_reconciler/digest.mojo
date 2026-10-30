# =============================================================================
# kci_reconciler/digest.mojo: the digest rule, made mechanical.
# =============================================================================
#
# THE RULE. A node's digest covers EVERY field the catalog models, its
# default included, and nothing else:
#   * a modelled field changed out of band is DRIFT, converged and reported;
#   * a field the catalog does not model never enters the digest (it is
#     reported as an unmanaged difference, `ResourceStatus.unmanaged`);
#   * PROVENANCE (the run that last wrote the object, the revision) never
#     enters it either. A per-run value in the digest makes every apply a
#     diff: an idempotent re-apply would update every node, and on Cloud Run
#     mint a new revision on every push.
#
# `ModelledDigest` is the builder a conformer renders its desired and its
# live digest with, one `field(name, value)` per modelled field in a fixed
# order. It REFUSES a provenance name, so the third point cannot be broken by
# accident; the first two stay the conformer's to keep (only it knows its
# fields), and the conformance kit's tamper pair and new-provenance re-apply
# are what check them.
#
# Value-typed. Mojo 1.0.0b2.
# =============================================================================

comptime PROVENANCE_PREFIX = "kci_provenance."
"""Every provenance annotation key starts with this."""
comptime PROVENANCE_RUN_ID = "kci_provenance.run_id"
comptime PROVENANCE_REVISION = "kci_provenance.revision"


def is_provenance(name: String) -> Bool:
    """True for a provenance field name (never digested)."""
    return (
        name.startswith(PROVENANCE_PREFIX)
        or name == "run_id"
        or name == "revision"
    )


struct ModelledDigest(Movable):
    """`field(name, value)` once per modelled field, in a fixed order, then
    `text()`. A provenance name raises."""

    var _s: String
    var _n: Int

    def __init__(out self, kind: String):
        self._s = kind.copy()
        self._n = 0

    def field(mut self, name: String, value: String) raises:
        if is_provenance(name):
            raise Error(
                String("digest: \"")
                + name
                + String("\" is provenance (who last wrote the object), never")
                + String(" part of a digest")
            )
        self._s += String("|") + name + String("=") + value
        self._n += 1

    def fields(self) -> Int:
        return self._n

    def text(self) -> String:
        return self._s.copy()
