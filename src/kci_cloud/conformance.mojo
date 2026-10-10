# =============================================================================
# kci_cloud/conformance.mojo: the conformance kit.
# =============================================================================
#
# One suite, parameterised by cloud, that every cloud built into kci runs. It
# drives the cloud only through this package's verbs (configure, validate,
# lower, the engine's owned scope), so what it proves is what kci will do on
# that cloud. Each step names itself in its failure.
#
#   1. plan       a dry run on an empty cloud plans only creates (or values
#                 known after apply), every action has an owner, and nothing
#                 is mutated;
#   2. apply      creates every wanted node;
#   3. labels     LABEL STAMPING: every live node carries labels the standard
#                 rule accepts, and they decode to that node's identity; it
#                 carries exactly one retention mark, the node's
#                 (`kci-retention=retain|delete`); and it carries the scope's
#                 validation run id under the run-id key exactly, or no
#                 run-id label when the scope has none;
#   4. re-apply   an IDEMPOTENT RE-APPLY under a NEW provenance (another run
#                 id and revision) is NOOP everywhere and mutates nothing:
#                 provenance is never part of a digest;
#   5. tamper     THE TAMPER PAIR: a MODELLED field changed out of band is
#                 planned as an update and converged; an UNMODELLED field
#                 changed out of band is planned beside a NOOP as an
#                 unmanaged difference, and is left as it was;
#   6. failed     a node the cloud reports FAILED is updated by the next
#                 apply (never refused, never re-created) and then settles;
#   7. change     a changed field is an UPDATE, never a silent no-op;
#   8. roles      ROLE REMOVAL (the closed world): turning a role off (a
#                 public service made internal, a `uses` line removed)
#                 deletes exactly those roles' objects, creates nothing, and
#                 then settles;
#   9. reference  DESTROY OF A GRAPH WITH A REFERENCE, with the store lost:
#                 a consumer whose value comes from another node is still
#                 found and deleted, and nothing is left;
#  10. foreign    FOREIGN REFUSAL: an unstamped object of a wanted name
#                 refuses the apply and the destroy before any change; the
#                 run that adopts it by name stamps it, and it is then ours;
#  11. race       TWO INTERLEAVED APPLIES of one cell: the second apply's
#                 create lands first; the first apply fails loud at the
#                 cloud (it never creates twice), and its re-run adopts the
#                 object (same stamp) and settles;
#  12. run tag    THE VALIDATION-RUN TAG, WHATEVER THE CALLER'S SCOPE: the
#                 kit applies `base` into the emptied cloud under a
#                 validation run id of its own (`KIT_VALIDATION_RUN`) and
#                 checks step 3's labels against it, destroys, then does the
#                 same with no validation run (no run-id label anywhere).
#                 A caller's scope without a run id cannot let an adapter
#                 whose create path skips the tag pass.
#  13. adoption   ADOPTION THROUGH `Resource.adopt`, into the emptied cloud:
#                 the kit adds to `base` one resource it can adopt
#                 (`_adoptable`: its type takes a cloud name, and its
#                 primary node reads no value of another node), a copy of
#                 the first such resource of `base`, else an empty body of
#                 its own (a bucket, a queue, a topic, a secret or a service
#                 account), with id and cloud name `KIT_ADOPTED`, no `uses`,
#                 writing `adopt` ADOPT, and plants the object its primary
#                 node declares (`plant_like`). `read_existing` must report that
#                 object present and unstamped, of the node's kind and
#                 under its cloud name. The apply that adopts it must not create it,
#                 and must leave it stamped for the node and carrying the
#                 adoption mark (`kci_adopted=true`). A modelled field
#                 changed out of band is then converged by an UPDATE that
#                 keeps the stamp and the mark (an adapter whose update
#                 rewrites the label map would drop the mark, and kci would
#                 then delete an object it did not create). An apply of
#                 `base` alone RELEASES it: the outcome lists
#                 it, the object still stands, unstamped, under its name,
#                 it carries no kci label, and `list_owned` no longer
#                 reports it. The kit then destroys the rest; the released
#                 object stays.
# Every apply that should finish must: one that stops part-way fails the kit
# with what landed and what is pending.
#
# A cloud adds the observation hooks of `ConformanceTarget`. Against an
# in-memory cloud they read its memory; against a real one, the live account
# (which is why the kit never runs against a real account outside a
# dedicated project).
#
# Not here, and named so nobody assumes otherwise: the cell's lease lock (the
# ledger's) that keeps two applies apart in the first place; step 11 proves
# only that, without it, nothing is created twice.
# =============================================================================

from kci_reconciler import (
    AppliedNode,
    ChangeAction,
    CellScope,
    Creds,
    InMemoryStateStore,
    Label,
    Provenance,
    VERB_CREATE,
    VERB_DELETE,
    VERB_KNOWN_AFTER_APPLY,
    VERB_NOOP,
    VERB_UPDATE,
)
from komira_proto_codec import decode_json
from kci_resource_proto.resource import Adoption, Resource

from kci_cloud.adapter import CellContext, CloudAdapter, LoweredNode
from kci_cloud.catalog import Catalog, body_field, primary_node
from kci_cloud.deploy import (
    ApplyOutcome,
    apply_resources,
    destroy_resources,
    lower_data,
    plan_resources,
    refuse_unless_valid,
)
from kci_cloud.clouds import Clouds
from kci_cloud.labels import (
    adopted_by,
    is_kci_label_key,
    label_problems,
    retention_label_key,
    retention_label_value,
    validation_run_of,
)
from kci_cloud.metadata import PHYSICAL_NAME_FIELD


trait ConformanceTarget(CloudAdapter):
    """A cloud adapter the kit can observe."""

    def live_count(self) -> Int:
        """How many engine nodes exist on the cloud now."""
        ...

    def mutations(self) -> Int:
        """How many create / update / delete / relabel calls the cloud has
        served."""
        ...

    def tamper(mut self, logical_id: String) raises:
        """Change a MODELLED field of node `logical_id` out of band."""
        ...

    def tamper_unmodelled(mut self, logical_id: String) raises:
        """Change a field kci does NOT model on node `logical_id` out of band
        (a label added in a console)."""
        ...

    def unmodelled(self, logical_id: String) -> String:
        """The out-of-band unmodelled value on node `logical_id` (empty if
        none)."""
        ...

    def fail(mut self, logical_id: String) raises:
        """Put node `logical_id` into the cloud's failed state (a new version
        that never became ready), leaving it present."""
        ...

    def live_labels(self, logical_id: String) -> List[Label]:
        """The labels the live object of node `logical_id` carries."""
        ...

    def plant_foreign(mut self, logical_id: String) raises:
        """Create, out of band and unstamped, an object with node
        `logical_id`'s name."""
        ...

    def race_next_create(mut self):
        """Make the next create meet an object a second apply of the same
        cell just created (same name, same stamp)."""
        ...

    def raced(self) -> String:
        """The node the race hit (empty if none yet)."""
        ...

    def creates_of(self, logical_id: String) -> Int:
        """How many creates of node `logical_id` the cloud has served over
        its lifetime (the kit compares counts before and after a step)."""
        ...

    def plant_like(mut self, node: LoweredNode) raises:
        """Create, out of band and unstamped, the object `node` declares
        (its kind, its cloud name and its state): what an adoption of it
        expects to find."""
        ...


def _fail(step: String, msg: String) -> Error:
    return Error(String("conformance [") + step + String("]: ") + msg)


def _applied(step: String, outcome: ApplyOutcome) raises -> List[AppliedNode]:
    """The applied nodes of a finished apply; an apply that stopped part-way
    fails the kit, naming what landed and what is pending."""
    if outcome.error:
        var msg = String("the apply stopped: ") + outcome.error.value()
        msg += String(" (landed ") + String(len(outcome.landed))
        msg += String(", pending ") + String(len(outcome.pending)) + String(")")
        raise _fail(step, msg)
    return outcome.applied.copy()


def _all_noop(step: String, applied: List[AppliedNode]) raises:
    for i in range(len(applied)):
        if applied[i].verb != VERB_NOOP:
            raise _fail(step, applied[i].logical_id + String(" did not settle"))


def _verb_of(actions: List[ChangeAction], lid: String) -> Int:
    for i in range(len(actions)):
        if actions[i].logical_id == lid:
            return actions[i].verb
    return -1


def _verb_of_applied(applied: List[AppliedNode], lid: String) -> Int:
    for i in range(len(applied)):
        if applied[i].logical_id == lid:
            return applied[i].verb
    return -1


def _action_of(actions: List[ChangeAction], lid: String) -> Optional[ChangeAction]:
    for i in range(len(actions)):
        if actions[i].logical_id == lid:
            return actions[i].copy()
    return None


def _with_run(ctx: CellContext, run: String) -> CellContext:
    var c = ctx.copy()
    c.scope.provenance = Provenance(run, String("rev-") + run)
    return c^


def _with_adopt(ctx: CellContext, lid: String) -> CellContext:
    var c = ctx.copy()
    c.scope.adopt.append(lid)
    return c^


comptime KIT_VALIDATION_RUN = "kit-run-5e0b71"
"""The validation run id step 12 applies under: a legal id that is no
caller's default."""


def _with_validation_run(ctx: CellContext, run: Optional[String]) -> CellContext:
    var c = ctx.copy()
    c.scope.validation_run_id = run.copy()
    return c^


def _shown(v: Optional[String]) -> String:
    return v.value().copy() if v else String("(none)")


def _check_labels[
    S: ConformanceTarget
](step: String, cloud: S, ctx: CellContext, lowered: List[LoweredNode]) raises:
    """Every wanted node's live labels: the standard rule, the node's
    identity, one retention mark (the node's), and the scope's validation
    run (or none)."""
    var mark_key = retention_label_key()
    for k in range(len(lowered)):
        if not lowered[k].wanted:
            continue
        var labels = cloud.live_labels(lowered[k].id)
        var problems = label_problems(labels)
        if len(problems) > 0:
            raise _fail(step, lowered[k].id + String(": ") + problems[0])
        var want = ctx.scope.stamp(lowered[k].owner, lowered[k].id).identity()
        var got = cloud.identity_of(labels)
        if got != want:
            raise _fail(
                step,
                lowered[k].id + String(" carries \"") + got + String("\", not \"") + want + String("\""),
            )
        var want_mark = retention_label_value(lowered[k].retention)
        var marks = 0
        var mark = String("(none)")
        for i in range(len(labels)):
            if labels[i].key == mark_key:
                marks += 1
                mark = labels[i].value.copy()
        if marks != 1 or mark != want_mark:
            raise _fail(
                step,
                lowered[k].id + String(" carries ") + String(marks) + String(" retention mark(s), \"")
                + mark + String("\"; want one, \"") + want_mark + String("\""),
            )
        var run = validation_run_of(labels)
        var want_run = ctx.scope.validation_run_id.copy()
        var same = Bool(run) == Bool(want_run)
        if same and Bool(run):
            same = run.value() == want_run.value()
        if not same:
            raise _fail(
                step,
                lowered[k].id + String(" carries validation run \"") + _shown(run)
                + String("\", not \"") + _shown(want_run) + String("\""),
            )


comptime KIT_ADOPTED = "kitadopt"
"""The id and the cloud name of the resource step 13 adopts: letters only
and 8 bytes, inside every shape's name rule."""


def _kit_arms() -> List[String]:
    """The bodies step 13 tries, written empty, when no resource of `base`
    can be copied: each a standalone type that reads no other resource."""
    return ["bucket", "queue", "topic", "secret", "serviceAccount"]


def _candidate(base: List[Resource], i: Int) raises -> Resource:
    """Candidate `i` of step 13: a copy of `base[i]` for `i < len(base)`,
    else an empty body of `_KIT_ARMS`; with id and cloud name
    `KIT_ADOPTED`, no `uses`, writing `adopt` ADOPT."""
    var r: Resource
    if i < len(base):
        r = base[i].copy()
    else:
        r = decode_json[Resource](
            String('{"id":"x","') + _kit_arms()[i - len(base)] + String('":{}}')
        )
    r.id = String(KIT_ADOPTED)
    r.uses.clear()
    r.physical_name = String(KIT_ADOPTED)
    r.adopt = Adoption(Adoption.ADOPT)
    return r^


def _adoptable[
    S: ConformanceTarget
](clouds: Clouds, mut cloud: S, ctx: CellContext, base: List[Resource]) raises -> List[Resource]:
    """`base` and, after it, the first candidate (`_candidate`) step 13 can
    adopt, or empty: its type takes a cloud name, the list with it is valid
    on `cloud`, and its primary node is wanted and reads no value of another
    node (so the object `plant_like` makes is the one the node declares).
    Nothing in `base` names it, so `base` alone is the list it leaves."""
    var catalog = Catalog.v1()
    for i in range(len(base) + len(_kit_arms())):
        try:
            var r = _candidate(base, i)
            var t = catalog.index_of(body_field(r))
            if t < 0 or not catalog.types[t].takes_name:
                continue
            var adopting = base.copy()
            adopting.append(r^)
            refuse_unless_valid(clouds, cloud, ctx, adopting)
            var pid = primary_node(catalog, adopting, String(KIT_ADOPTED))
            var nodes = lower_data(cloud, adopting)
            for k in range(len(nodes)):
                if nodes[k].id == pid and nodes[k].wanted and len(nodes[k].inputs) == 0:
                    return adopting^
        except:
            continue
    return List[Resource]()


def _check_adopted[
    S: ConformanceTarget
](step: String, cloud: S, ctx: CellContext, node: LoweredNode, when: String) raises:
    """The live object of `node` carries the stamp of `node` and the
    adoption mark."""
    var labels = cloud.live_labels(node.id)
    var want = ctx.scope.stamp(node.owner, node.id).identity()
    var got = cloud.identity_of(labels)
    if got != want:
        raise _fail(step, node.id + String(" ") + when + String(" carries \"") + got + String("\", not \"") + want + String("\""))
    if not adopted_by(labels):
        raise _fail(
            step,
            node.id + String(" ") + when
            + String(" does not carry the adoption mark kci_adopted=true; without it kci would delete an object it did not create"),
        )


def _wanted(nodes: List[LoweredNode]) -> Int:
    var n = 0
    for i in range(len(nodes)):
        if nodes[i].wanted:
            n += 1
    return n


def run_conformance[
    S: ConformanceTarget
](
    clouds: Clouds,
    mut cloud: S,
    ctx: CellContext,
    base: List[Resource],
    changed: List[Resource],
    roles_off: List[Resource],
    tamper_node: String,
) raises:
    """Run the kit. `changed` is `base` with one field of one resource
    changed; `roles_off` is `changed` with at least one role turned off (a
    `public {}` service made internal, or a `uses` line removed) and must
    hold a value reference; `tamper_node` is a wanted node of all three. The
    cloud must start empty. Raises naming the failed step."""
    var creds = Creds.none()
    var store = InMemoryStateStore()
    if cloud.live_count() != 0:
        raise _fail("start", String("the cloud is not empty"))

    var lowered = lower_data(cloud, base)
    var nodes = len(lowered)
    var wanted = _wanted(lowered)

    # 1. dry run on nothing
    var m0 = cloud.mutations()
    var p1 = plan_resources(clouds, cloud, ctx, base, creds, store)
    if len(p1) != nodes:
        raise _fail("plan", String("planned ") + String(len(p1)) + " of " + String(nodes) + " nodes")
    for i in range(len(p1)):
        var ok = (
            p1[i].verb == VERB_CREATE
            or p1[i].verb == VERB_KNOWN_AFTER_APPLY
            or p1[i].verb == VERB_NOOP  # a role turned off, and absent
        )
        if not ok:
            raise _fail(
                "plan",
                p1[i].logical_id + String(" planned ") + String(p1[i].verb_name()) + " on an empty cloud",
            )
        if p1[i].owner.byte_length() == 0:
            raise _fail("plan", p1[i].logical_id + String(" has no owner in the plan"))
    if cloud.mutations() != m0:
        raise _fail("plan", String("a dry run mutated the cloud"))

    # 2. apply
    var a2 = _applied("apply", apply_resources(clouds, cloud, ctx, base, creds, store))
    for i in range(len(a2)):
        var want_create = False
        for k in range(len(lowered)):
            if lowered[k].id == a2[i].logical_id:
                want_create = lowered[k].wanted
        if want_create and a2[i].verb != VERB_CREATE:
            raise _fail("apply", a2[i].logical_id + String(" was not created"))
    if cloud.live_count() != wanted:
        raise _fail(
            "apply",
            String("live nodes ") + String(cloud.live_count()) + " != " + String(wanted),
        )

    # 3. label stamping
    _check_labels("labels", cloud, ctx, lowered)

    # 4. an idempotent re-apply, under a new run id and revision
    var m4 = cloud.mutations()
    var again = _with_run(ctx, String("conformance-again"))
    _all_noop("re-apply", _applied("re-apply", apply_resources(clouds, cloud, again, base, creds, store)))
    if cloud.mutations() != m4:
        raise _fail("re-apply", String("a re-apply under a new provenance mutated the cloud"))

    # 5. the tamper pair
    cloud.tamper(tamper_node)
    var p5 = plan_resources(clouds, cloud, ctx, base, creds, store)
    if _verb_of(p5, tamper_node) != VERB_UPDATE:
        raise _fail("tamper", tamper_node + String(": a modelled field changed out of band but did not plan an update"))
    _ = _applied("tamper", apply_resources(clouds, cloud, ctx, base, creds, store))
    _all_noop("tamper", _applied("tamper", apply_resources(clouds, cloud, ctx, base, creds, store)))
    cloud.tamper_unmodelled(tamper_node)
    var p5b = plan_resources(clouds, cloud, ctx, base, creds, store)
    var act = _action_of(p5b, tamper_node)
    if not act or act.value().verb != VERB_NOOP:
        raise _fail("tamper", tamper_node + String(": an unmodelled change was planned as a change"))
    if act.value().unmanaged.byte_length() == 0:
        raise _fail("tamper", tamper_node + String(": an unmodelled change was not reported"))
    var m5 = cloud.mutations()
    _all_noop("tamper", _applied("tamper", apply_resources(clouds, cloud, ctx, base, creds, store)))
    if cloud.mutations() != m5 or cloud.unmodelled(tamper_node).byte_length() == 0:
        raise _fail("tamper", tamper_node + String(": an unmodelled field was touched"))

    # 6. failed, then fixed: the next apply updates the failed node in place
    cloud.fail(tamper_node)
    var p6 = plan_resources(clouds, cloud, ctx, base, creds, store)
    if _verb_of(p6, tamper_node) != VERB_UPDATE:
        raise _fail("failed", tamper_node + String(" is FAILED but did not plan an update"))
    var f6 = _applied("failed", apply_resources(clouds, cloud, ctx, base, creds, store))
    for i in range(len(f6)):
        if f6[i].logical_id == tamper_node:
            if f6[i].verb != VERB_UPDATE:
                raise _fail(
                    "failed",
                    tamper_node + String(" was ") + String(f6[i].verb) + String(", not updated"),
                )
        elif f6[i].verb != VERB_NOOP:
            raise _fail("failed", f6[i].logical_id + String(" changed while fixing another node"))
    _all_noop("failed", _applied("failed", apply_resources(clouds, cloud, ctx, base, creds, store)))

    # 7. a changed field is an update
    var a7 = _applied("change", apply_resources(clouds, cloud, ctx, changed, creds, store))
    var updates = 0
    for i in range(len(a7)):
        if a7[i].verb == VERB_UPDATE:
            updates += 1
        elif a7[i].verb == VERB_CREATE:
            raise _fail("change", a7[i].logical_id + String(" was re-created, not updated"))
    if updates == 0:
        raise _fail("change", String("a changed field produced no update"))

    # 8. role removal
    var live8 = cloud.live_count()
    var a8 = _applied("roles", apply_resources(clouds, cloud, ctx, roles_off, creds, store))
    var deletes = 0
    for i in range(len(a8)):
        if a8[i].verb == VERB_DELETE:
            deletes += 1
        elif a8[i].verb == VERB_CREATE:
            raise _fail("roles", a8[i].logical_id + String(" was created while turning roles off"))
    if deletes == 0:
        raise _fail("roles", String("turning a role off deleted nothing"))
    if cloud.live_count() != live8 - deletes:
        raise _fail(
            "roles",
            String("live nodes ") + String(cloud.live_count()) + " after " + String(deletes)
            + " deletes from " + String(live8),
        )
    _all_noop("roles", _applied("roles", apply_resources(clouds, cloud, ctx, roles_off, creds, store)))

    # 9. destroy of a graph with a reference, with the store lost
    var with_ref = lower_data(cloud, roles_off)
    var has_ref = False
    for i in range(len(with_ref)):
        if len(with_ref[i].inputs) > 0:
            has_ref = True
    if not has_ref:
        raise _fail("reference", String("the kit needs roles_off to hold a value reference"))
    var lost = InMemoryStateStore()
    _ = destroy_resources(clouds, cloud, ctx, roles_off, creds, lost)
    if cloud.live_count() != 0:
        raise _fail(
            "reference",
            String(cloud.live_count()) + String(" nodes left after destroy"),
        )

    # 10. foreign refusal, then adoption by name
    var first = String("")
    var first_owner = String("")
    for k in range(len(lowered)):
        if lowered[k].wanted:
            first = lowered[k].id.copy()
            first_owner = lowered[k].owner.copy()
            break
    cloud.plant_foreign(first)
    var m10 = cloud.mutations()
    var store10 = InMemoryStateStore()
    var o10 = apply_resources(clouds, cloud, ctx, base, creds, store10)
    if not o10.refused() or o10.error.value().find(first + String(": foreign")) < 0:
        var e10 = o10.error.value() if o10.error else String("it applied")
        raise _fail("foreign", String("a foreign ") + first + String(" was not refused: ") + e10)
    if cloud.mutations() != m10 or len(o10.landed) != 0:
        raise _fail("foreign", String("the refused apply changed something"))
    var refused_destroy = False
    try:
        _ = destroy_resources(clouds, cloud, ctx, base, creds, store10)
    except e:
        refused_destroy = String(e).find(String("foreign")) >= 0
    if not refused_destroy or cloud.live_count() != 1:
        raise _fail("foreign", String("destroy did not refuse the foreign object"))
    var adopt = _with_adopt(ctx, first)
    var a10 = _applied("foreign", apply_resources(clouds, cloud, adopt, base, creds, store10))
    for i in range(len(a10)):
        if a10[i].logical_id == first and a10[i].verb == VERB_CREATE:
            raise _fail("foreign", first + String(" was re-created, not adopted"))
    var lab = cloud.identity_of(cloud.live_labels(first))
    if lab != ctx.scope.stamp(first_owner, first).identity():
        raise _fail("foreign", first + String(" was not stamped by the adoption: ") + lab)
    _all_noop("foreign", _applied("foreign", apply_resources(clouds, cloud, ctx, base, creds, store10)))
    _ = destroy_resources(clouds, cloud, ctx, base, creds, store10)
    if cloud.live_count() != 0:
        raise _fail("foreign", String("the adopted graph was not destroyed"))

    # 11. two interleaved applies (create counts are the cloud's lifetime
    # totals, so each is compared with its count before this step)
    var before = List[Int]()
    for k in range(len(lowered)):
        before.append(cloud.creates_of(lowered[k].id))
    var store11 = InMemoryStateStore()
    cloud.race_next_create()
    var o11 = apply_resources(clouds, cloud, ctx, base, creds, store11)
    if not o11.error:
        raise _fail("race", String("an apply whose create met an existing object did not fail"))
    var hit = cloud.raced()
    if hit.byte_length() == 0:
        raise _fail("race", String("the cloud never raced a create"))
    var hit_before = 0
    for k in range(len(lowered)):
        if lowered[k].id == hit:
            hit_before = before[k]
    if cloud.creates_of(hit) - hit_before != 1:
        raise _fail(
            "race",
            hit + String(" was created ") + String(cloud.creates_of(hit) - hit_before)
            + String(" times"),
        )
    var a11 = _applied("race", apply_resources(clouds, cloud, ctx, base, creds, store11))
    for i in range(len(a11)):
        if a11[i].logical_id == hit and a11[i].verb != VERB_NOOP:
            raise _fail("race", hit + String(" was not adopted by the re-run"))
    if cloud.creates_of(hit) - hit_before != 1:
        raise _fail("race", hit + String(" was created twice"))
    _all_noop("race", _applied("race", apply_resources(clouds, cloud, ctx, base, creds, store11)))
    _ = destroy_resources(clouds, cloud, ctx, base, creds, store11)
    if cloud.live_count() != 0:
        raise _fail("race", String("nodes left after the final destroy"))

    # 12. the validation-run tag, under the kit's own run id and under none
    for p in range(2):
        var run: Optional[String] = None
        if p == 0:
            run = String(KIT_VALIDATION_RUN)
        var c12 = _with_validation_run(ctx, run)
        var store12 = InMemoryStateStore()
        _ = _applied("run tag", apply_resources(clouds, cloud, c12, base, creds, store12))
        _check_labels("run tag", cloud, c12, lowered)
        _ = destroy_resources(clouds, cloud, c12, base, creds, store12)
        if cloud.live_count() != 0:
            raise _fail("run tag", String("nodes left after the run-tag destroy"))

    # 13. adoption through the resource's adopt field
    var adopting = _adoptable(clouds, cloud, ctx, base)
    if len(adopting) == 0:
        raise _fail(
            "adopt",
            String("no resource of base, and none of the kit's own, can be adopted on this cloud: a type that")
            + String(" takes a cloud name, whose primary node reads no value of another node"),
        )
    var rest = base.copy()
    var pid = primary_node(Catalog.v1(), adopting, String(KIT_ADOPTED))
    var low13 = lower_data(cloud, adopting)
    var pnode = low13[0].copy()
    for k in range(len(low13)):
        if low13[k].id == pid:
            pnode = low13[k].copy()
    var name13 = pnode.field(String(PHYSICAL_NAME_FIELD))
    cloud.plant_like(pnode)
    var seen = cloud.read_existing(creds, pnode)
    if not seen.present or seen.stamped:
        raise _fail("adopt", pid + String(": read_existing does not report the planted object, present and unstamped"))
    if seen.kind != pnode.kind or seen.name != name13:
        raise _fail(
            "adopt",
            pid + String(": read_existing reports kind \"") + seen.kind + String("\" and name \"") + seen.name
            + String("\"; the object is kind \"") + pnode.kind + String("\" named \"") + name13 + String("\""),
        )
    var store13 = InMemoryStateStore()
    var creates13 = cloud.creates_of(pid)
    _ = _applied("adopt", apply_resources(clouds, cloud, ctx, adopting, creds, store13))
    if cloud.creates_of(pid) != creates13:
        raise _fail("adopt", pid + String(" was created, not adopted"))
    _check_adopted("adopt", cloud, ctx, pnode, String("after the adoption"))
    cloud.tamper(pid)
    var u13 = _applied("adopt", apply_resources(clouds, cloud, ctx, adopting, creds, store13))
    if _verb_of_applied(u13, pid) != VERB_UPDATE:
        raise _fail("adopt", pid + String(": a modelled field changed out of band did not update the adopted object"))
    _check_adopted("adopt", cloud, ctx, pnode, String("after an update"))
    var r13 = apply_resources(clouds, cloud, ctx, rest, creds, store13)
    _ = _applied("release", r13)
    var released = False
    for i in range(len(r13.released)):
        if r13.released[i] == pid:
            released = True
    if not released:
        raise _fail("release", pid + String(" left the list but the apply did not release it"))
    var after = cloud.read_existing(creds, pnode)
    if not after.present or after.stamped or after.name != name13:
        raise _fail("release", pid + String(": the released object does not still stand, unstamped, under its name"))
    var left = cloud.live_labels(pid)
    for i in range(len(left)):
        if is_kci_label_key(left[i].key):
            raise _fail("release", pid + String(" still carries the kci label ") + left[i].key)
    var owned = cloud.list_owned(creds, ctx.scope)
    for i in range(len(owned)):
        if owned[i].owner_node == pid:
            raise _fail("release", pid + String(" is still listed as kci's"))
    _ = destroy_resources(clouds, cloud, ctx, rest, creds, store13)
