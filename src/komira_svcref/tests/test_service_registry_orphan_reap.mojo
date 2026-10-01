"""The registry DELETE verb + the ORPHAN REPORT acceptance gate.

Hermetic (no live bucket, no cloud call) test for the reaping half of the
service registry: `ServiceRegistry.deregister` / `deregister_key`, the
key-addressed reads (`name_for_key` / `resolve_key`), and the
`orphan_report` / `reap_orphans` plan-by-default reaping path
(`komira_svcref.service_registry` + `komira_svcref.orphan_reap`), over the
in-process `SharedInMemoryConditionalStore`.

⛔ WHY THIS EXISTS. A registry with `register` / `resolve` / `list` and NO
delete of any kind resolves a torn-down service FOREVER: a region migration
leaves every old `service/<name>-us-south1` key behind. Deleting the raw object
off the store from outside the registry type reaches PAST it, so the registry's
own invariants (which keys are its own, what a key resolves to) are not in the
loop at all.

Gates:

  1. DEREGISTER:      register -> deregister -> True, resolve -> None.
  2. IDEMPOTENT:      deregister of an absent name -> False, never a raise (a
                      re-run of a partially completed cleanup must land on the
                      post-condition and exit clean).
  3. KEY-ADDRESSED:   an operator's reap addresses a FULL OBJECT KEY
                      (`service/<name>`), not a name. `name_for_key` /
                      `resolve_key` / `deregister_key` are the registry's own
                      key seam, and `resolve_key` is the read a reap tool
                      prints its LIVE line from — see gate 4.
  4. FOREIGN PREFIX:  a key that is NOT under this registry's prefix is a
                      REFUSAL, never a silent decode. `staged-image/example-api`
                      under prefix `service` must raise — the head is checked,
                      not merely the length.
  5. ORPHAN REPORT:   given the registry catalog and the LIVE deployment set,
                      the report names EXACTLY the entries with no live
                      deployment behind them (set equality, both directions),
                      plus the two other cells an operator needs: `matched`
                      (registered AND live) and `missing` (live but never
                      registered).
  6. PLAN BY DEFAULT: `reap_orphans(live, apply=False)` deletes NOTHING and
                      returns the plan. The report is free; the deletion is
                      explicit.
  7. NEVER A LIVE ONE: `apply=True` removes every orphan and leaves every live
                      entry resolvable.
  8. EMPTY LIVE SET:  a REFUSAL, not "everything is an orphan". An empty live
                      enumeration is indistinguishable from an enumeration that
                      failed, and that is the difference between a report and a
                      wipe.
  9. NAMESPACE MISMATCH: both sets non-empty and DISJOINT is a REFUSAL. That is
                      the `worker` / `worker-gcp-us-central1` shape — two
                      enumerations that do not share a namespace read
                      as "100% orphaned", and applying it deletes the whole live
                      registry.

⛔ GATES 10-15 EXIST BECAUSE GATES 1-9 PROVED THE CODE WAS NOT DELETED AND
PROVED NOTHING ABOUT IT BEING RIGHT. Each was added by applying a NAMED MUTANT
to the production code, WATCHING GATES 1-9 STAY GREEN, and then writing the arm
that reds. The mutant each one kills is named in its docstring; an arm nobody
watched fail under its mutant is not evidence, so do not delete one without
re-running its mutant.

 10. FAULT != ABSENT (probe):  `deregister`'s presence probe must PROPAGATE a
                      transport/auth fault. Returning False turns "I could not
                      find out" into "it was not there" — an operator is told
                      their cleanup is done when nothing was even reachable.
 11. FAULT != ABSENT (delete): the same, one line lower, on the delete itself.
 12. FAULT != NO-OP (reap):    a reap that cannot reach the store RAISES; it
                      does not return a green `ReapOutcome` whose empty
                      `deleted` reads as "the orphans were already gone".
 13. NONE ONLY ON 404:  `resolve_key` returns None for an ABSENT key and RAISES
                      on anything else. This is the read a reap tool's
                      "nothing to reap" + exit 0 arm rests on; a bare
                      `except: present = False` there is fail-open.
 14. NOT A THRESHOLD:  the disjointness refusal is a COMPARABILITY test, not a
                      heuristic on how many entries are orphaned. A legitimate
                      teardown leaves a mostly-stale catalog and MUST still
                      reap; only a catalog sharing NOT ONE name refuses.
 15. REFUSE ON A PLAN: both refusals fire with `apply=False` too. A plan whose
                      input cannot authorise a delete is not a preview of
                      anything — printing a list of reapable names and
                      refusing the apply teaches the operator to reach for
                      the flag.

⛔ AND GATES 16-17 WERE ADDED THE SAME WAY, against a RE-MUTATION of everything
above. Gates 1-15 stay GREEN under each mutant below.

 16. WHAT WENT != WHAT WAS PLANNED:  in `reap_orphans`, discarding
                      `deregister`'s return value (`_ = self.deregister(...)`
                      then an unconditional append) makes `deleted` a COPY of
                      `planned`. `ReapOutcome`'s own docstring calls that
                      distinction load-bearing and nothing held it: gate 7 is
                      the only arm that reads `deleted` on an apply, and its
                      fixture has every orphan genuinely present, so the two
                      lists coincide. ⚠ REACHABLE WITH NO FAULT AT ALL —
                      object-store LIST is eventually consistent, so `list()`
                      can name a key `head` then 404s on, and the operator is
                      told "3 deleted" for a run that deleted 1.
 17. AN EMPTY CATALOG IS NOT A MISMATCH:  the disjointness refusal reads TWO
                      cells and only ONE of them was pinned. `len(orphans) > 0`
                      -> `>= 0` (keyed on `matched` alone) and -> `len(missing)
                      > 0` (keyed on the wrong cell) BOTH survived gates 1-16;
                      swapping the FIRST cell is caught, by gate 9. Both
                      survivors refuse an EMPTY catalog against a live set —
                      a fresh environment, and the post-condition of a
                      COMPLETED cleanup — with a text that is nonsense there.

No FFI, no vendor-static link — pure Mojo over the in-memory CAS conformer plus
two in-file doubles (`_FaultingStore`, gates 10-13; `_PhantomListingStore`,
gate 16 — a LISTING/objects disagreement, injecting no error at all).
"""

from komira_svcref.service_registry import ServiceRegistry
from komira_svcref.orphan_reap import (
    OrphanReport,
    ReapOutcome,
    orphan_report,
    refuse_untrustworthy_live_set,
)

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# -----------------------------------------------------------------------------
# _FaultingStore — a `ConditionalWriteStore` decorator that raises a TRANSPORT /
# AUTH fault at ONE named seam, so the "a fault is not an absence" arms (gates
# 10-13) can be exercised with no cloud call.
#
# ⛔ THE MESSAGE CARRIES NO NOT-FOUND TOKEN, AND THAT IS THE WHOLE POINT.
# `service_registry._is_not_found` matches `StoreError[NOT_FOUND]` / `not_found`
# / `NotFound` / `NoSuchKey` / `404`. This string contains NONE of them (`403`,
# not `404`), so a registry verb that classifies it as an absence is
# fail-OPEN — it has decided "the object is not there" from an error that says
# only "I could not find out". If you "fix" this string to carry a 404 you
# defeat every gate below it.
# -----------------------------------------------------------------------------
comptime _FAULT_NONE: Int = 0
comptime _FAULT_HEAD: Int = 1
comptime _FAULT_GET: Int = 2
comptime _FAULT_DELETE: Int = 3

comptime _TRANSPORT_FAULT: String = (
    "StoreError[PERMISSION_DENIED] gs://bootstrap/service/x: 403 the caller"
    " does not have storage.objects.get access to the bootstrap bucket"
)


struct _FaultingStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var _inner: SharedInMemoryConditionalStore
    var _mode: Int

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, mode: Int
    ):
        self._inner = inner^
        self._mode = mode

    # ---- ObjectStore surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        if self._mode == _FAULT_HEAD:
            raise Error(_TRANSPORT_FAULT)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if self._mode == _FAULT_GET:
            raise Error(_TRANSPORT_FAULT)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        if self._mode == _FAULT_DELETE:
            raise Error(_TRANSPORT_FAULT)
        self._inner.delete(path)


# -----------------------------------------------------------------------------
# Assertion helpers.
# -----------------------------------------------------------------------------


def _contains(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


def _render(names: List[String]) -> String:
    var out = String("[")
    for i in range(len(names)):
        if i > 0:
            out += String(", ")
        out += names[i]
    out += String("]")
    return out^


def _same_set(got: List[String], want: List[String], ctx: String) raises:
    """Set equality BOTH WAYS — a subset check would pass a report that named
    every entry as an orphan."""
    for i in range(len(want)):
        if not _contains(got, want[i]):
            raise Error(
                ctx
                + ": missing '"
                + want[i]
                + "' — got "
                + _render(got)
                + ", want "
                + _render(want)
            )
    for i in range(len(got)):
        if not _contains(want, got[i]):
            raise Error(
                ctx
                + ": UNEXPECTED '"
                + got[i]
                + "' — got "
                + _render(got)
                + ", want "
                + _render(want)
            )


def _expect_none(got: Optional[String], ctx: String) raises:
    if got:
        raise Error(ctx + ": expected None but got '" + got.value() + "'")


def _eq_opt(got: Optional[String], want: String, ctx: String) raises:
    if not got:
        raise Error(ctx + ": expected '" + want + "' but got None")
    if got.value() != want:
        raise Error(
            ctx + ": expected '" + want + "' but got '" + got.value() + "'"
        )


def _seed() raises -> ServiceRegistry[SharedInMemoryConditionalStore]:
    """A registry holding three LIVE services and two ORPHANS — the shape a
    region migration leaves behind (`*-us-south1` keys)."""
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("example-api"), String("https://api"))
    reg.register(String("scheduler"), String("https://scheduler"))
    reg.register(String("worker-gcp-us-central1"), String("https://worker"))
    reg.register(String("example-api-us-south1"), String("https://old-api"))
    reg.register(String("worker-us-south1"), String("https://old-worker"))
    return reg^


def _live() -> List[String]:
    var live = List[String]()
    live.append(String("example-api"))
    live.append(String("scheduler"))
    live.append(String("worker-gcp-us-central1"))
    return live^


def _orphans_expected() -> List[String]:
    var want = List[String]()
    want.append(String("example-api-us-south1"))
    want.append(String("worker-us-south1"))
    return want^


# -----------------------------------------------------------------------------
# Gate 1 + 2 — the DELETE verb, and its idempotence.
# -----------------------------------------------------------------------------


def test_deregister_removes_the_entry() raises:
    print("-- test_deregister_removes_the_entry --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("worker-us-south1"), String("https://old-worker"))
    _eq_opt(
        reg.resolve(String("worker-us-south1")),
        String("https://old-worker"),
        "before deregister",
    )
    if not reg.deregister(String("worker-us-south1")):
        raise Error("deregister of a PRESENT entry must report True (deleted)")
    _expect_none(
        reg.resolve(String("worker-us-south1")), "after deregister"
    )
    print("   register -> deregister -> resolve None OK")


def test_deregister_is_idempotent() raises:
    print("-- test_deregister_is_idempotent --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    if reg.deregister(String("never-registered")):
        raise Error("deregister of an ABSENT entry must report False, not True")
    reg.register(String("x"), String("https://x"))
    _ = reg.deregister(String("x"))
    if reg.deregister(String("x")):
        raise Error("a SECOND deregister must report False (already absent)")
    print("   absent deregister -> False, no raise OK")


# -----------------------------------------------------------------------------
# Gate 3 + 4 — the KEY-ADDRESSED seam (what an operator's reap actually
# holds) and its foreign-prefix refusal.
# -----------------------------------------------------------------------------


def test_key_addressed_read_and_delete() raises:
    print("-- test_key_addressed_read_and_delete --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("worker-us-south1"), String("https://old-worker"))

    # A reap of `service/worker-us-south1` holds a KEY. Resolving
    # it as if it were a NAME composes `service/service/...` and reads None — the
    # defect this seam removes.
    if reg.name_for_key(String("service/worker-us-south1")) != String(
        "worker-us-south1"
    ):
        raise Error("name_for_key must strip exactly the `<prefix>/` head")
    _eq_opt(
        reg.resolve_key(String("service/worker-us-south1")),
        String("https://old-worker"),
        "resolve_key",
    )
    if not reg.deregister_key(String("service/worker-us-south1")):
        raise Error("deregister_key of a PRESENT key must report True")
    _expect_none(
        reg.resolve_key(String("service/worker-us-south1")),
        "resolve_key after deregister_key",
    )
    print("   name_for_key / resolve_key / deregister_key round-trip OK")


def test_foreign_prefix_key_is_refused() raises:
    print("-- test_foreign_prefix_key_is_refused --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    var raised = False
    try:
        _ = reg.name_for_key(String("staged-image/example-api"))
    except:
        raised = True
    if not raised:
        raise Error(
            "a key under a DIFFERENT prefix must RAISE — decoding"
            " 'staged-image/example-api' to the name 'image/example-api' is a"
            " delete addressed at another registry's namespace"
        )
    # And the two verbs that ride it refuse for the same reason.
    var raised_del = False
    try:
        _ = reg.deregister_key(String("staged-content/web"))
    except:
        raised_del = True
    if not raised_del:
        raise Error("deregister_key must refuse a foreign-prefix key")
    # A key with NO prefix at all is equally a refusal.
    var raised_bare = False
    try:
        _ = reg.name_for_key(String("example-api"))
    except:
        raised_bare = True
    if not raised_bare:
        raise Error("a bare name is not a key — name_for_key must refuse it")
    print("   foreign / bare keys refused OK")


# -----------------------------------------------------------------------------
# Gate 5 — the ORPHAN REPORT names EXACTLY the orphans.
# -----------------------------------------------------------------------------


def test_orphan_report_names_exactly_the_orphans() raises:
    print("-- test_orphan_report_names_exactly_the_orphans --")
    var reg = _seed()
    var rep = reg.orphan_scan(_live())
    _same_set(rep.orphans, _orphans_expected(), "report.orphans")
    _same_set(rep.matched, _live(), "report.matched")
    if len(rep.missing) != 0:
        raise Error(
            "no live service is unregistered here; report.missing must be empty,"
            " got "
            + _render(rep.missing)
        )
    if not rep.live_observed:
        raise Error("a non-empty live set must set live_observed")
    if rep.orphan_count() != 2:
        raise Error(
            "orphan_count must agree with the list it counts, got "
            + String(rep.orphan_count())
        )
    # The RENDER is the operator-facing half and is asserted, not assumed: a
    # report nobody can read is the same as no report. It must name each orphan
    # AND carry the two counts that make the orphan count checkable.
    var text = rep.render()
    if text.find("example-api-us-south1") < 0:
        raise Error("render() must NAME each orphan; got:\n" + text)
    if text.find("worker-us-south1") < 0:
        raise Error("render() must NAME each orphan; got:\n" + text)
    if text.find("2 orphaned") < 0 or text.find("3 live+registered") < 0:
        raise Error("render() must carry the counts; got:\n" + text)
    print("   orphans / matched / missing partition the catalog OK")


def test_orphan_report_names_a_live_service_that_never_registered() raises:
    print("-- test_orphan_report_names_a_live_service_that_never_registered --")
    var reg = _seed()
    var live = _live()
    live.append(String("example-push"))  # live, but never registered
    var rep = reg.orphan_scan(live)
    _same_set(rep.orphans, _orphans_expected(), "orphans unaffected")
    var want_missing = List[String]()
    want_missing.append(String("example-push"))
    _same_set(rep.missing, want_missing, "report.missing")
    print("   a live-but-unregistered service is reported, not reaped OK")


def test_orphan_report_is_pure_over_two_name_lists() raises:
    """The diff is a PURE function of (catalog, live) — no store, so a caller
    that already holds both lists (the CLI, a validator) reports without a
    second read."""
    print("-- test_orphan_report_is_pure_over_two_name_lists --")
    var registered = List[String]()
    registered.append(String("a"))
    registered.append(String("b"))
    var live = List[String]()
    live.append(String("b"))
    live.append(String("c"))
    var rep = orphan_report(registered, live)
    var want_orph = List[String]()
    want_orph.append(String("a"))
    _same_set(rep.orphans, want_orph, "pure orphans")
    var want_match = List[String]()
    want_match.append(String("b"))
    _same_set(rep.matched, want_match, "pure matched")
    var want_missing = List[String]()
    want_missing.append(String("c"))
    _same_set(rep.missing, want_missing, "pure missing")
    print("   pure (catalog, live) -> report OK")


# -----------------------------------------------------------------------------
# Gate 6 + 7 — PLAN BY DEFAULT; apply removes orphans and only orphans.
# -----------------------------------------------------------------------------


def test_reap_orphans_plans_by_default() raises:
    print("-- test_reap_orphans_plans_by_default --")
    var reg = _seed()
    var out = reg.reap_orphans(_live(), False)
    if out.applied:
        raise Error("apply=False must NOT report applied")
    _same_set(out.planned, _orphans_expected(), "planned")
    if len(out.deleted) != 0:
        raise Error(
            "apply=False must delete NOTHING, got " + _render(out.deleted)
        )
    # And the store is untouched: every seeded entry still resolves.
    _eq_opt(
        reg.resolve(String("worker-us-south1")),
        String("https://old-worker"),
        "orphan survives a plan",
    )
    if len(reg.list()) != 5:
        raise Error("a plan must leave all 5 entries in place")
    print("   plan-by-default deletes nothing OK")


def test_reap_orphans_apply_removes_only_orphans() raises:
    print("-- test_reap_orphans_apply_removes_only_orphans --")
    var reg = _seed()
    var out = reg.reap_orphans(_live(), True)
    if not out.applied:
        raise Error("apply=True must report applied")
    _same_set(out.deleted, _orphans_expected(), "deleted")
    _expect_none(reg.resolve(String("worker-us-south1")), "orphan gone")
    _expect_none(reg.resolve(String("example-api-us-south1")), "orphan gone")
    _eq_opt(reg.resolve(String("example-api")), String("https://api"), "live")
    _eq_opt(
        reg.resolve(String("scheduler")), String("https://scheduler"), "live"
    )
    _eq_opt(
        reg.resolve(String("worker-gcp-us-central1")),
        String("https://worker"),
        "live",
    )
    _same_set(reg.list(), _live(), "catalog after apply")

    # Idempotent: a second apply finds nothing to do.
    var again = reg.reap_orphans(_live(), True)
    if len(again.planned) != 0 or len(again.deleted) != 0:
        raise Error("a second apply must be a no-op")
    print("   apply removes exactly the orphans, and is idempotent OK")


# -----------------------------------------------------------------------------
# Gate 8 + 9 — the two REFUSALS. Both are "the live enumeration is not
# trustworthy", and both would otherwise read as "everything is an orphan".
# -----------------------------------------------------------------------------


def test_empty_live_set_is_a_refusal() raises:
    print("-- test_empty_live_set_is_a_refusal --")
    var reg = _seed()
    var none_live = List[String]()
    var raised = False
    try:
        _ = reg.reap_orphans(none_live, True)
    except:
        raised = True
    if not raised:
        raise Error(
            "an EMPTY live set must REFUSE: 'nothing is deployed' and 'the live"
            " enumeration failed' are the same input, and one of them licenses"
            " deleting the entire registry"
        )
    if len(reg.list()) != 5:
        raise Error("the refusal must delete nothing")
    # The REPORT itself is free — it is a read, and it says the live set was
    # not observed rather than calling every entry an orphan.
    var rep = reg.orphan_scan(none_live)
    if rep.live_observed:
        raise Error("an empty live set must NOT set live_observed")
    # ⛔ AND THE REPORT MUST SAY SO IN ITS OWN TEXT. It DOES list all five as
    # orphans — that is the honest diff of what it was given — so without this
    # line an operator reads a clean-looking "5 orphaned" and reaches for
    # `--apply`. The refusal lives in the reap; the WARNING lives in the report.
    var text = rep.render()
    if text.find("THE LIVE SET WAS EMPTY") < 0:
        raise Error(
            "a report from an empty live set must SAY the live set was empty;"
            " got:\n"
            + text
        )
    print("   empty live set: report yes (with the warning), reap no OK")


def test_disjoint_namespaces_are_a_refusal() raises:
    print("-- test_disjoint_namespaces_are_a_refusal --")
    var reg = _seed()
    # The shape: a live enumeration in a DIFFERENT namespace (bare
    # names) against a catalog of region-qualified ones. Nothing matches, so a
    # naive diff calls 100% of the registry orphaned.
    var live = List[String]()
    live.append(String("worker"))
    live.append(String("api"))
    var raised = False
    try:
        _ = reg.reap_orphans(live, True)
    except:
        raised = True
    if not raised:
        raise Error(
            "two non-empty name sets that share NOTHING is a namespace"
            " mismatch, not a 100%-orphaned registry — apply must refuse"
        )
    if len(reg.list()) != 5:
        raise Error("the refusal must delete nothing")
    print("   disjoint catalog/live namespaces refused OK")


# -----------------------------------------------------------------------------
# Gates 10-13 — ⛔ A FAULT IS NOT AN ABSENCE.
#
# Every verb here answers a question of the form "is this object there?", and
# each has exactly one honest way to say "I could not find out": RAISE. Turning
# a transport or auth fault into False / None / an empty `deleted` list tells an
# operator their cleanup is DONE when the bucket was never reached — the
# fail-open shape of a bare `except: present = False`, which prints "nothing to
# reap" and exits 0 on an auth failure.
#
# `_TRANSPORT_FAULT` carries no not-found token, so a verb can only "handle" it
# by having decided absence from an error that states nothing of the kind.
# -----------------------------------------------------------------------------


def _seed_shared(
    var inner: SharedInMemoryConditionalStore,
) raises -> SharedInMemoryConditionalStore:
    """Seed the region-migration shape through a NON-faulting handle and hand
    the shared map back. The faulting registry is then constructed over a clone
    of it, so the fault is injected at the verb under test and not at the
    fixture."""
    var seed = ServiceRegistry(inner.clone())
    seed.register(String("example-api"), String("https://api"))
    seed.register(String("scheduler"), String("https://scheduler"))
    seed.register(String("worker-gcp-us-central1"), String("https://worker"))
    seed.register(String("example-api-us-south1"), String("https://old-api"))
    seed.register(String("worker-us-south1"), String("https://old-worker"))
    return inner^


def test_deregister_probe_fault_is_not_an_absence() raises:
    """Gate 10. KILLS THE MUTANT: `deregister`'s presence probe rewritten as a
    bare `except: return False`.

    False from `deregister` means ALREADY ABSENT — the post-condition a re-run
    of a partial cleanup lands on, and the value `reap_orphans` reads to decide
    an orphan needed no delete. A 403 is not that answer."""
    print(
        "-- test_deregister_probe_fault_is_not_an_absence"
        " --"
    )
    var inner = _seed_shared(SharedInMemoryConditionalStore())
    var reg = ServiceRegistry(_FaultingStore(inner.clone(), _FAULT_HEAD))
    var raised = False
    try:
        _ = reg.deregister(String("worker-us-south1"))
    except:
        raised = True
    if not raised:
        raise Error(
            "deregister must PROPAGATE a transport/auth fault from its presence"
            " probe, not report False. False means ALREADY ABSENT — a cleanup"
            " that never reached the bucket would report its post-condition met"
        )
    # And nothing was removed: the entry still resolves through a clean handle.
    _eq_opt(
        ServiceRegistry(inner.clone()).resolve(String("worker-us-south1")),
        String("https://old-worker"),
        "the entry survives a failed probe",
    )
    print("   a 403 on the presence probe raises, and deletes nothing OK")


def test_deregister_delete_fault_is_not_an_absence() raises:
    """Gate 11. The same contract one line lower — `deregister`'s DELETE arm
    returns False only on a raced 404 (another reap got there first, same
    post-condition). A 403 there is equally "I could not find out"."""
    print(
        "--"
        " test_deregister_delete_fault_is_not_an_absence"
        " --"
    )
    var inner = _seed_shared(SharedInMemoryConditionalStore())
    var reg = ServiceRegistry(_FaultingStore(inner.clone(), _FAULT_DELETE))
    var raised = False
    try:
        _ = reg.deregister(String("worker-us-south1"))
    except:
        raised = True
    if not raised:
        raise Error(
            "deregister must PROPAGATE a transport/auth fault from the delete"
            " itself. False there means a RACED 404 (another reap won, same"
            " post-condition) — a 403 has reached no such post-condition"
        )
    _eq_opt(
        ServiceRegistry(inner.clone()).resolve(String("worker-us-south1")),
        String("https://old-worker"),
        "the entry survives a failed delete",
    )
    print("   a 403 on the delete raises, and deletes nothing OK")


def test_reap_apply_fault_is_not_a_green_no_op() raises:
    """Gate 12. The operator-facing consequence of gates 10-11, at the verb an
    operator actually runs.

    Under a `deregister` that swallows faults, `reap_orphans(apply=True)`
    returns `applied=True` with an EMPTY `deleted` — which is EXACTLY what a
    successful re-run of an already-completed cleanup returns. The two states
    would be indistinguishable, and the reachable one is the wrong one."""
    print(
        "--"
        " test_reap_apply_fault_is_not_a_green_no_op"
        " --"
    )
    var inner = _seed_shared(SharedInMemoryConditionalStore())
    var reg = ServiceRegistry(_FaultingStore(inner.clone(), _FAULT_HEAD))
    var raised = False
    try:
        _ = reg.reap_orphans(_live(), True)
    except:
        raised = True
    if not raised:
        raise Error(
            "a reap that cannot reach the store must RAISE. Returning"
            " applied=True with an empty `deleted` is byte-for-byte what a"
            " re-run of a COMPLETED cleanup returns — an operator cannot tell"
            " 'the orphans were already gone' from 'the bucket was never"
            " reached'"
        )
    if len(ServiceRegistry(inner.clone()).list()) != 5:
        raise Error("a failed reap must leave all 5 entries in place")
    print("   a reap that cannot reach the store raises, not a green no-op OK")


def test_resolve_key_returns_none_only_on_a_404() raises:
    """Gate 13. KILLS THE MUTANT: `resolve`'s 404 arm rewritten as a bare
    `except: return Optional[String]()`.

    ★ A reap tool that prints "nothing to reap" + exit 0 on `not resolved`
    puts the ENTIRE weight of that arm on `resolve_key` returning None for an
    absent key AND ONLY for an absent key. Both halves are asserted here; the None half alone is satisfied
    by a verb that returns None for everything."""
    print("-- test_resolve_key_returns_none_only_on_a_404 --")
    var inner = _seed_shared(SharedInMemoryConditionalStore())

    # (a) ABSENT -> None. The arm a reap tool reads as "nothing to reap".
    _expect_none(
        ServiceRegistry(inner.clone()).resolve_key(
            String("service/never-registered")
        ),
        "an absent key resolves to None",
    )
    # (b) PRESENT -> the URL. Without this, (a) is satisfied by always-None.
    _eq_opt(
        ServiceRegistry(inner.clone()).resolve_key(
            String("service/worker-us-south1")
        ),
        String("https://old-worker"),
        "a present key resolves to its URL",
    )
    # (c) KEY vs NAME, pinned by its MECHANISM: `resolve` takes a NAME and
    # composes the key itself, so handing it a KEY composes `service/service/…`
    # and reads as ABSENT for an object that is very much present. A tool that
    # printed its LIVE line from that would show a blank URL for every key it
    # ever reaped. The two verbs
    # must therefore DISAGREE on a key — a `resolve` that tolerated one would
    # make `resolve_key` an alias and the defect re-introducible in one edit.
    _expect_none(
        ServiceRegistry(inner.clone()).resolve(
            String("service/worker-us-south1")
        ),
        "resolve() given a KEY double-composes and finds nothing",
    )
    # (d) A FAULT -> a RAISE, never None.
    var reg = ServiceRegistry(_FaultingStore(inner.clone(), _FAULT_GET))
    var raised = False
    try:
        _ = reg.resolve_key(String("service/worker-us-south1"))
    except:
        raised = True
    if not raised:
        raise Error(
            "resolve_key must RAISE on a transport/auth fault. None is a reap"
            " tool's 'nothing to reap' + exit 0 arm — returning it here tells"
            " an operator their cleanup is complete because the bucket could"
            " not be read"
        )
    print("   None on 404, the URL when present, a RAISE on a fault OK")


# -----------------------------------------------------------------------------
# Gate 14 — the disjointness refusal is a COMPARABILITY test, NOT a threshold.
# -----------------------------------------------------------------------------


def test_the_disjointness_refusal_is_not_an_orphan_count_threshold() raises:
    """Gate 14. KILLS THE MUTANT: `if len(report.matched) == 0 and
    len(report.orphans) > 0` rewritten as `if len(report.orphans) >
    len(report.matched)`.

    That mutant refuses on BOTH existing refusal fixtures (the disjoint one has
    matched=0, so any orphan count exceeds it) and on the healthy fixture it
    correctly stays quiet (2 orphans vs 3 matched) — so gates 1-9 cannot see it.
    What it breaks is the case the module header states in one sentence: *a
    legitimate teardown can leave a catalog that is mostly stale*. Region
    migrations are exactly that shape, and this is the registry refusing to
    clean up after the migration it exists to clean up after."""
    print("-- test_the_disjointness_refusal_is_not_an_orphan_count_threshold --")

    # THREE orphans against ONE match — a real post-migration catalog. The two
    # name sets SHARE a name, so they are comparable and the reap must proceed.
    var registered = List[String]()
    registered.append(String("example-api"))
    registered.append(String("example-api-us-south1"))
    registered.append(String("scheduler-us-south1"))
    registered.append(String("worker-us-south1"))
    var live = List[String]()
    live.append(String("example-api"))
    var rep = orphan_report(registered, live)
    if len(rep.orphans) != 3 or len(rep.matched) != 1:
        raise Error(
            "fixture drift: this gate needs orphans > matched with a non-empty"
            " intersection, got "
            + String(len(rep.orphans))
            + " orphans / "
            + String(len(rep.matched))
            + " matched"
        )
    # The judgement itself, called directly: comparable sets => no refusal.
    # Caught and re-stated, so the red names the CONTRACT rather than leaving
    # the reader to notice that the propagated refusal text ("share NOT ONE
    # name") is false of the very report it was raised on.
    var refused = String("")
    try:
        refuse_untrustworthy_live_set(rep)
    except e:
        refused = String(e)
    if refused != String(""):
        raise Error(
            "the refusal must NOT fire on two sets that SHARE a name — it is a"
            " comparability test, not a threshold on the orphan count. This"
            " catalog is 3-stale-to-1-live, the ordinary shape after a region"
            " migration, and refusing it is the registry declining to clean up"
            " after the migration it exists to clean up after. Got: "
            + refused
        )

    # And end to end, through the verb an operator runs: it REAPS.
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    reg.register(String("example-api"), String("https://api"))
    reg.register(String("example-api-us-south1"), String("https://old-api"))
    reg.register(String("scheduler-us-south1"), String("https://old-scheduler"))
    reg.register(String("worker-us-south1"), String("https://old-worker"))
    var out = reg.reap_orphans(live, True)
    var want_gone = List[String]()
    want_gone.append(String("example-api-us-south1"))
    want_gone.append(String("scheduler-us-south1"))
    want_gone.append(String("worker-us-south1"))
    _same_set(out.deleted, want_gone, "a mostly-stale catalog still reaps")
    _eq_opt(
        reg.resolve(String("example-api")),
        String("https://api"),
        "the one live entry survives",
    )

    # The other direction, so this gate cannot be satisfied by a refusal that
    # never fires: share NOT ONE name and it MUST raise.
    var disjoint = List[String]()
    disjoint.append(String("worker"))
    var raised = False
    try:
        refuse_untrustworthy_live_set(orphan_report(registered, disjoint))
    except:
        raised = True
    if not raised:
        raise Error(
            "sets sharing NOT ONE name must still refuse — this gate loosens the"
            " threshold, it does not remove the refusal"
        )
    print("   mostly-stale reaps; share-nothing refuses OK")


# -----------------------------------------------------------------------------
# Gate 15 — both refusals fire on a PLAN, not only on an apply.
# -----------------------------------------------------------------------------


def test_the_refusals_fire_on_a_plan_too() raises:
    """Gate 15. KILLS THE MUTANT: `refuse_untrustworthy_live_set(report)`
    rewritten as `if apply: refuse_untrustworthy_live_set(report)`.

    Gates 8 and 9 both pass `apply=True`, so the plan/apply posture the module
    states — *"the refusal fires on a PLAN too"* — would be pinned by nothing.

    ⚠ WHY IT MATTERS, given a plan deletes nothing either way: a plan is what an
    operator READS before reaching for `--apply`. A plan that prints five
    reapable names and then refuses the apply teaches them the refusal is a
    formality standing between them and a list they have already been shown.
    `orphan_scan` is the verb for looking at a diff that cannot authorise a
    delete — it never raises, and gate 8 already pins that it warns in its own
    text."""
    print("-- test_the_refusals_fire_on_a_plan_too --")
    var reg = _seed()

    var none_live = List[String]()
    var raised_empty = False
    try:
        _ = reg.reap_orphans(none_live, False)
    except:
        raised_empty = True
    if not raised_empty:
        raise Error(
            "an EMPTY live set must refuse a PLAN as well as an apply — a plan"
            " whose input cannot authorise a delete is not a preview of"
            " anything, it is a list of names the operator is being invited to"
            " pass --apply on"
        )

    var disjoint = List[String]()
    disjoint.append(String("worker"))
    disjoint.append(String("api"))
    var raised_disjoint = False
    try:
        _ = reg.reap_orphans(disjoint, False)
    except:
        raised_disjoint = True
    if not raised_disjoint:
        raise Error(
            "DISJOINT namespaces must refuse a PLAN as well as an apply, for the"
            " same reason"
        )

    if len(reg.list()) != 5:
        raise Error("a refused plan must leave all 5 entries in place")
    # The REPORT remains available for both — that is the escape hatch, and it
    # is what makes refusing the plan cost the operator nothing.
    if reg.orphan_scan(none_live).orphan_count() != 5:
        raise Error("orphan_scan must still produce the report it refuses to act on")
    if reg.orphan_scan(disjoint).orphan_count() != 5:
        raise Error("orphan_scan must still produce the report it refuses to act on")
    print("   both refusals fire on a plan; orphan_scan still reports OK")


# -----------------------------------------------------------------------------
# Gate 16 — ⛔ `deleted` IS WHAT WENT, NOT A COPY OF `planned`.
#
# A MUTANT THAT GATES 1-15 DO NOT CATCH: in `reap_orphans`, discard
# `deregister`'s return value —
#
#     _ = self.deregister(report.orphans[i])
#     deleted.append(String(report.orphans[i]))
#
# Gates 1-15 all stay green. Gate 7 is the only one that reads `deleted` on an
# apply, and its fixture has every orphan genuinely present, so `deregister`
# returns True for all of them and the two lists coincide. `ReapOutcome`'s own
# docstring calls the distinction load-bearing — *"'what would go' and 'what
# went' can never be reported by the same number"* — and nothing else holds it.
#
# ⚠ IT IS REACHABLE WITH NO FAULT AT ALL, which is what separates it from gates
# 10-13. Object-store LIST is eventually consistent: `list()` can name a key
# that `head` then 404s on, and a concurrent reaper is the same shape. The
# operator is then told "3 deleted" for a run that deleted 1 — and the count
# they are reading is the one they check their cleanup against.
#
# The double below produces exactly that: a real store whose listing carries one
# key the object half does not have.
# -----------------------------------------------------------------------------

comptime _PHANTOM_NAME: String = "phantom-us-south1"


struct _PhantomListingStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A store whose LISTING names one key its object half does not hold.

    Every verb delegates to a real `SharedInMemoryConditionalStore`; the ONLY
    added behaviour is one extra `ObjectMeta` in `list_with_delimiter` — no
    error is injected anywhere, because this defect needs none. A `head` of the
    phantom takes the store's ORDINARY absent path and raises its ORDINARY 404,
    which `deregister` classifies correctly and reports as False.

    ⚠ NOT A FAULT DOUBLE. `_FaultingStore` above models "I could not find out";
    this models "the listing and the objects disagree", which is what an
    eventually-consistent LIST does with no failure at all."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        var res = self._inner.list_with_delimiter(prefix)
        var phantom = String("service/") + String(_PHANTOM_NAME)
        if _starts_with_prefix(phantom, prefix.raw()):
            res.objects.append(
                ObjectMeta(phantom, Int64(0), String("ghost"), Int64(-1), String(""))
            )
        return res^

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _starts_with_prefix(s: String, prefix: String) -> Bool:
    if prefix.byte_length() == 0:
        return True
    return s.find(prefix) == 0


def test_deleted_reports_what_WENT_not_what_was_PLANNED() raises:
    """Gate 16. KILLS THE MUTANT named in the block above.

    THE ASSERTION THAT DISCRIMINATES is the pair of COUNTS, plus the phantom's
    membership of one list and not the other. An arm that only checked
    `len(deleted) > 0`, or that `deleted` contains the two real orphans, passes
    under the mutant."""
    print("-- test_deleted_reports_what_WENT_not_what_was_PLANNED --")
    var inner = _seed_shared(SharedInMemoryConditionalStore())
    var reg = ServiceRegistry(_PhantomListingStore(inner.clone()))

    # ── FIXTURE PRECONDITION. The catalog must name the phantom and the object
    # half must NOT hold it — otherwise this gate is an ordinary reap wearing a
    # conformer, and it would pass under the mutant.
    var catalog = reg.list()
    if not _contains(catalog, String(_PHANTOM_NAME)):
        raise Error(
            "fixture drift: the listing must name the phantom, got "
            + _render(catalog)
        )
    if len(catalog) != 6:
        raise Error(
            "fixture drift: 5 seeded + 1 phantom, got "
            + String(len(catalog))
            + ": "
            + _render(catalog)
        )
    var probe = ServiceRegistry(inner.clone())
    if probe.deregister(String(_PHANTOM_NAME)):
        raise Error(
            "fixture drift: the phantom must be ABSENT from the object half —"
            " deregister reported it deleted, so the listing and the objects"
            " agree and this gate tests nothing"
        )

    var out = reg.reap_orphans(_live(), True)

    # PLANNED names all three entries with no live deployment behind them,
    # phantom included: the plan is derived from the CATALOG, which is exactly
    # what the operator was shown.
    var want_planned = List[String]()
    want_planned.append(String("example-api-us-south1"))
    want_planned.append(String("worker-us-south1"))
    want_planned.append(String(_PHANTOM_NAME))
    _same_set(out.planned, want_planned, "planned")

    # DELETED names the TWO that were there to remove.
    var want_deleted = List[String]()
    want_deleted.append(String("example-api-us-south1"))
    want_deleted.append(String("worker-us-south1"))
    if len(out.deleted) != 2:
        raise Error(
            "`deleted` must report what WENT, not a copy of `planned`. This run"
            " planned "
            + String(len(out.planned))
            + " and removed 2 — the third ('"
            + String(_PHANTOM_NAME)
            + "') was named by the LISTING and absent from the objects, which"
            " is what an eventually-consistent LIST does with no fault at all."
            " `ReapOutcome`'s own docstring calls this distinction the"
            " difference between a dry run and a delete. Got deleted="
            + _render(out.deleted)
        )
    _same_set(out.deleted, want_deleted, "deleted")
    if _contains(out.deleted, String(_PHANTOM_NAME)):
        raise Error(
            "an entry whose deregister reported ALREADY-ABSENT must not appear"
            " in `deleted` — that is the operator being told a cleanup removed"
            " something it never touched"
        )
    if not _contains(out.planned, String(_PHANTOM_NAME)):
        raise Error(
            "...and it must still appear in `planned`: the plan is what the"
            " operator was shown, and dropping the phantom from BOTH lists"
            " would hide the disagreement instead of reporting it"
        )
    if len(out.planned) == len(out.deleted):
        raise Error(
            "the two counts must DIFFER on this fixture — equal counts are"
            " precisely the state the mutant produces"
        )
    if not out.applied:
        raise Error("apply=True must still report applied")

    # And the two real orphans really are gone, through a CLEAN handle: the
    # distinction is about the REPORT, and the delete itself is unaffected.
    var clean = ServiceRegistry(inner.clone())
    _expect_none(clean.resolve(String("example-api-us-south1")), "orphan gone")
    _expect_none(clean.resolve(String("worker-us-south1")), "orphan gone")
    _eq_opt(clean.resolve(String("example-api")), String("https://api"), "live")
    print("   deleted != planned when the listing and the objects disagree OK")


# -----------------------------------------------------------------------------
# Gate 17 — ⛔ AN EMPTY CATALOG IS NOT A NAMESPACE MISMATCH.
#
# The disjointness refusal is `len(report.matched) == 0 and
# len(report.orphans) > 0`. TWO one-token rewrites of that line stay GREEN
# against gates 1-16:
#
#   * `len(report.orphans) > 0`  ->  `len(report.orphans) >= 0`
#     (the refusal keyed on `matched` ALONE)
#   * `len(report.orphans) > 0`  ->  `len(report.missing) > 0`
#     (the refusal keyed on the WRONG CELL)
#
# A third — `len(report.matched)` -> `len(report.missing)` — IS caught, by
# gate 9. So the cell the refusal reads was pinned in one position out of two.
#
# WHAT BOTH SURVIVORS BREAK IS THE SAME REACHABLE STATE: an EMPTY catalog
# against a non-empty live set. `matched` is 0 because there is nothing to
# match, and both mutants then refuse. That is a fresh environment, and it is
# also the exact post-condition of a completed cleanup — a registry with
# nothing in it. The
# refusal text an operator would read is nonsense in that state ("the live set
# (3 names) and the registry catalog (0 names) share NOT ONE name"), and the
# reap they were running had nothing to do.
#
# ⚠ THE REFUSAL IS ABOUT COMPARABILITY, AND TWO SETS ARE VACUOUSLY COMPARABLE
# WHEN ONE IS EMPTY. There is no delete to authorise, so there is nothing to
# refuse — which is why this is one arm and not a threshold.
# -----------------------------------------------------------------------------


def test_an_EMPTY_catalog_is_not_a_namespace_mismatch() raises:
    """Gate 17. KILLS BOTH SURVIVING CELL REWRITES named in the block above."""
    print("-- test_an_EMPTY_catalog_is_not_a_namespace_mismatch --")
    var reg = ServiceRegistry(SharedInMemoryConditionalStore())
    var live = _live()

    # ── FIXTURE PRECONDITION, stated so a drifted seed cannot make this
    # vacuous: catalog EMPTY, live OBSERVED, nothing orphaned, nothing matched.
    var rep = reg.orphan_scan(live)
    if len(reg.list()) != 0:
        raise Error("fixture drift: this gate needs an EMPTY catalog")
    if not rep.live_observed:
        raise Error("fixture drift: the live set must be OBSERVED")
    if len(rep.orphans) != 0 or len(rep.matched) != 0 or len(rep.missing) != 3:
        raise Error(
            "fixture drift: want 0 orphans / 0 matched / 3 missing, got "
            + String(len(rep.orphans))
            + " / "
            + String(len(rep.matched))
            + " / "
            + String(len(rep.missing))
        )

    # ── THE JUDGEMENT, CALLED DIRECTLY. Caught and re-stated, so the red names
    # the CONTRACT rather than leaving the reader to notice that the propagated
    # refusal text is false of the very report it was raised on.
    var refused = String("")
    try:
        refuse_untrustworthy_live_set(rep)
    except e:
        refused = String(e)
    if refused != String(""):
        raise Error(
            "an EMPTY catalog must NOT refuse. The refusal is a COMPARABILITY"
            " test, and there is nothing to compare: no delete is being"
            " authorised, so there is nothing to refuse. This is a fresh"
            " environment, and it is also the post-condition of a COMPLETED"
            " cleanup. Keying the refusal on `matched` alone (`orphans >= 0`)"
            " or on the wrong cell (`missing > 0`) both land here. Got: "
            + refused
        )

    # ── AND END TO END, through the verbs an operator runs. Both modes: a plan
    # is what they read before reaching for --apply (gate 15's reason).
    var planned = reg.reap_orphans(live, False)
    if len(planned.planned) != 0 or len(planned.deleted) != 0:
        raise Error(
            "a plan over an empty catalog reaps nothing and refuses nothing"
        )
    var out = reg.reap_orphans(live, True)
    if len(out.planned) != 0 or len(out.deleted) != 0:
        raise Error(
            "an apply over an empty catalog is a clean NO-OP, got planned="
            + _render(out.planned)
            + " deleted="
            + _render(out.deleted)
        )
    if not out.applied:
        raise Error("apply=True must still report applied")

    # ── THE OTHER DIRECTION, so this gate cannot be satisfied by DELETING the
    # refusal — which is the obvious wrong fix for the red it produces. A
    # NON-EMPTY catalog sharing not one name still refuses, in both modes.
    var seeded = _seed()
    var disjoint = List[String]()
    disjoint.append(String("worker"))
    disjoint.append(String("api"))
    var still_refuses_apply = False
    try:
        _ = seeded.reap_orphans(disjoint, True)
    except:
        still_refuses_apply = True
    var still_refuses_plan = False
    try:
        _ = seeded.reap_orphans(disjoint, False)
    except:
        still_refuses_plan = True
    if not still_refuses_apply or not still_refuses_plan:
        raise Error(
            "this gate loosens the refusal for an EMPTY catalog; it does not"
            " remove it. A non-empty catalog sharing NOT ONE name with a"
            " non-empty live set must still refuse, on a plan and on an apply"
        )
    if len(seeded.list()) != 5:
        raise Error("the refusal must still delete nothing")
    print("   an empty catalog reaps clean; a disjoint one still refuses OK")


def main() raises:
    print("== registry delete verb + orphan report gate ==")
    test_deregister_removes_the_entry()
    test_deregister_is_idempotent()
    test_key_addressed_read_and_delete()
    test_foreign_prefix_key_is_refused()
    test_orphan_report_names_exactly_the_orphans()
    test_orphan_report_names_a_live_service_that_never_registered()
    test_orphan_report_is_pure_over_two_name_lists()
    test_reap_orphans_plans_by_default()
    test_reap_orphans_apply_removes_only_orphans()
    test_empty_live_set_is_a_refusal()
    test_disjoint_namespaces_are_a_refusal()
    test_deregister_probe_fault_is_not_an_absence()
    test_deregister_delete_fault_is_not_an_absence()
    test_reap_apply_fault_is_not_a_green_no_op()
    test_resolve_key_returns_none_only_on_a_404()
    test_the_disjointness_refusal_is_not_an_orphan_count_threshold()
    test_the_refusals_fire_on_a_plan_too()
    test_deleted_reports_what_WENT_not_what_was_PLANNED()
    test_an_EMPTY_catalog_is_not_a_namespace_mismatch()
    print("== ALL GATES PASSED ==")
