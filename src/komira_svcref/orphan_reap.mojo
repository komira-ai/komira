# =============================================================================
# komira_svcref/orphan_reap.mojo — the ORPHAN REPORT: the pure diff between the
#   registry CATALOG and the LIVE deployment set, plus the two value types the
#   reaping path returns.
# =============================================================================
#
# ⛔ WHY THIS EXISTS. A registry with `register` / `resolve` / `list` and no
# delete of any kind resolves a torn-down service FOREVER: a region migration
# leaves every old `service/<name>-<region>` key behind, still resolvable. The
# only way out is then to delete the raw object off the object store from
# outside the registry type — so the registry's own invariants (which keys
# belong to it, what a key resolves to) are never in the loop.
#
# ★ THE REPORT IS FREE; THE DELETION IS EXPLICIT. Everything here is a READ.
# `ServiceRegistry.orphan_scan` produces this report and mutates nothing;
# `ServiceRegistry.reap_orphans` plans by default and only deletes under an
# explicit `apply`. That is deliberately the thing you get if you forget which
# mode you meant.
#
# # THE DIFF IS A PURE FUNCTION OF TWO NAME LISTS
#
# `orphan_report(registered, live)` takes the registry catalog and the caller's
# LIVE deployment enumeration and partitions them three ways:
#
#   * `orphans` — REGISTERED, with no live deployment behind it. The reapable
#     set, and the only one any delete may touch.
#   * `matched` — REGISTERED and LIVE. The healthy steady state.
#   * `missing` — LIVE but NEVER REGISTERED. Not reapable (there is nothing to
#     delete) and not silence either: it is a service peers cannot resolve,
#     which is the opposite failure and belongs in the same report.
#
# It takes NO store and performs NO I/O, so a caller that already holds both
# lists reports without a second read, and the whole partition is testable
# against literals.
#
# # ⛔ THE TWO REFUSALS, AND WHY A REPORT ALONE IS NOT ENOUGH
#
# Both are one sentence: *the live enumeration is not trustworthy*, and both
# would otherwise read as "everything is an orphan" — i.e. a delete of the whole
# registry, with a green exit.
#
#   1. AN EMPTY LIVE SET. "Nothing is deployed" and "the enumeration failed" are
#      the SAME input. `live_observed` records which one the caller supplied,
#      and `reap_orphans` refuses to apply when it is False. The REPORT is still
#      produced — it is a read — it simply does not get to authorise a delete.
#   2. DISJOINT NAMESPACES. Two non-empty sets that share NO name are a naming
#      mismatch, not a 100%-orphaned registry. It is the shape a key
#      composition that differs from the service name produces (bundle `worker`
#      -> platform service `worker` -> registry key `worker-gcp-us-central1`):
#      a live enumeration and a catalog describing the same services under two
#      different names.
#
# Neither refusal is a heuristic about how many entries are orphaned — a
# legitimate teardown can leave a catalog that is mostly stale. Both are
# statements about whether the two lists are COMPARABLE at all.
#
# Encapsulation: the whole surface is `String` / `List[String]` / `Bool` in and
# out. ZERO UnsafePointer, zero origins, no I/O.
# =============================================================================


def _contains(names: List[String], want: String) -> Bool:
    """Linear membership. The catalog is one entry per deployed service — a
    handful to a few dozen — so a scan is the right shape and keeps this file
    dependency-free (no set type, no hashing, no allocation per probe)."""
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


# =============================================================================
# OrphanReport — the three-way partition of (catalog, live).
# =============================================================================
@fieldwise_init
struct OrphanReport(Copyable, Movable, Deinitable):
    """The result of diffing the registry CATALOG against the LIVE deployment
    set. A pure value: three name lists plus the one fact that decides whether
    it may authorise a delete.

    `orphans` is the ONLY reapable cell. `matched` and `missing` are printed
    with it because a report that names orphans and nothing else cannot be
    checked by the operator reading it: an orphan count is only meaningful next
    to the live count it was derived from."""

    var orphans: List[String]
    """REGISTERED with no live deployment behind it — the reapable set."""

    var matched: List[String]
    """REGISTERED and LIVE — the healthy steady state."""

    var missing: List[String]
    """LIVE but never registered — peers cannot resolve it. NOT reapable."""

    var live_observed: Bool
    """True iff the caller supplied a NON-EMPTY live enumeration.

    ⛔ THE LOAD-BEARING FIELD. An empty live set makes every registered entry
    look orphaned, and "nothing is deployed" is indistinguishable from "the
    enumeration failed". `reap_orphans` refuses to apply while this is False."""

    def orphan_count(self) -> Int:
        """How many entries have no live deployment behind them."""
        return len(self.orphans)

    def render(self) -> String:
        """A human report — one line per cell, counts first so an operator can
        sanity-check the diff against what they expected to be running."""
        var out = String("registry orphan report: ")
        out += String(len(self.orphans)) + String(" orphaned, ")
        out += String(len(self.matched)) + String(" live+registered, ")
        out += String(len(self.missing)) + String(" live+unregistered")
        if not self.live_observed:
            out += String(
                "\n  ⛔ THE LIVE SET WAS EMPTY. Every registered entry is listed"
                " as an orphan below because nothing was observed to be live —"
                " which is also what a FAILED live enumeration looks like. This"
                " report cannot authorise a reap."
            )
        out += String("\n  ORPHANED (registered, nothing live behind it):")
        out += _render_cell(self.orphans)
        out += String("\n  LIVE + REGISTERED:")
        out += _render_cell(self.matched)
        out += String("\n  LIVE + UNREGISTERED (peers cannot resolve these):")
        out += _render_cell(self.missing)
        return out^


def _render_cell(names: List[String]) -> String:
    """One indented line per name, or an explicit `(none)` — an empty cell must
    read as measured-and-empty, never as a line someone forgot to print."""
    if len(names) == 0:
        return String(" (none)")
    var out = String("")
    for i in range(len(names)):
        out += String("\n    ") + names[i]
    return out^


# =============================================================================
# ReapOutcome — what a reap PLANNED and what it actually DELETED.
# =============================================================================
@fieldwise_init
struct ReapOutcome(Copyable, Movable, Deinitable):
    """The result of `ServiceRegistry.reap_orphans`.

    `planned` and `deleted` are SEPARATE fields on purpose. A plan run returns a
    non-empty `planned` with an EMPTY `deleted`, so "what would go" and "what
    went" can never be reported by the same number — which is the difference
    between a dry run and a delete, and the one thing a caller must not have to
    infer from a flag it also passed in."""

    var planned: List[String]
    """The orphans this run identified as reapable."""

    var deleted: List[String]
    """The entries actually removed. EMPTY on a plan run, by construction."""

    var applied: Bool
    """True iff this run was permitted to delete (an explicit `apply`)."""


# =============================================================================
# orphan_report — the pure diff.
# =============================================================================


def orphan_report(
    registered: List[String], live: List[String]
) -> OrphanReport:
    """Partition `registered` (the registry catalog) against `live` (the
    caller's live-deployment enumeration) into orphaned / matched / missing.

    PURE: no store, no I/O, no raise. Order follows the input lists, so a caller
    that sorted its catalog gets a sorted report and one that did not gets the
    store's listing order — this does not impose an order it cannot justify.

    ⚠ It does NOT decide whether the diff may be acted on. That is
    `reap_orphans`, and it reads `live_observed` plus the disjointness of the
    two sets. Keeping the judgement out of the diff is what lets the REPORT be
    produced unconditionally (an operator must be able to look at a bad diff)
    while the DELETE stays refused."""
    var orphans = List[String]()
    var matched = List[String]()
    var missing = List[String]()
    for i in range(len(registered)):
        if _contains(live, registered[i]):
            matched.append(String(registered[i]))
        else:
            orphans.append(String(registered[i]))
    for i in range(len(live)):
        if not _contains(registered, live[i]):
            missing.append(String(live[i]))
    return OrphanReport(
        orphans^, matched^, missing^, len(live) > 0
    )


# =============================================================================
# refuse_untrustworthy_live_set — the shared refusal both reap paths take.
# =============================================================================


def refuse_untrustworthy_live_set(report: OrphanReport) raises:
    """RAISE if `report` came from a live enumeration that cannot authorise a
    delete. Called by `ServiceRegistry.reap_orphans` BEFORE it deletes anything,
    and separate from the diff so the same judgement is available to any other
    caller that reaps through a registry.

    The two arms are documented in this module's header. Neither is a threshold
    on how many entries are orphaned: a legitimate teardown may leave a catalog
    that is entirely stale, and this must not stand in its way. Both are
    statements about whether the two lists are COMPARABLE."""
    if not report.live_observed:
        raise Error(
            String(
                "registry reap: REFUSING — the live deployment set is EMPTY, so"
                " every one of the "
            )
            + String(len(report.orphans))
            + String(
                " registered entries reads as an orphan. 'Nothing is deployed'"
                " and 'the live enumeration failed' are the same input here,"
                " and one of them licenses deleting the whole registry. Pass"
                " the enumeration you actually observed; if an environment"
                " genuinely runs nothing, reap its entries by name."
            )
        )
    if len(report.matched) == 0 and len(report.orphans) > 0:
        raise Error(
            String("registry reap: REFUSING — the live set (")
            + String(len(report.missing))
            + String(" names) and the registry catalog (")
            + String(len(report.orphans))
            + String(
                " names) share NOT ONE name. That is a NAMESPACE MISMATCH, not"
                " a 100%-orphaned registry: it is the shape of a live"
                " enumeration and a catalog that describe the same services"
                " under two different names (e.g. `worker` vs"
                " `worker-gcp-us-central1`). Applying it would delete the"
                " entire live registry with a green exit. Check that both sides"
                " are naming services the same way before reaping."
            )
        )
