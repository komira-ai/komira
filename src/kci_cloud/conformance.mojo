# =============================================================================
# kci_cloud/conformance.mojo: the conformance kit.
# =============================================================================
#
# One suite, parameterised by cloud, that every cloud adapter runs. It
# drives the cloud only through this package's verbs (validate, lower,
# the engine), so what it proves is what kci will do on that cloud:
#
#   1. a dry run on an empty cloud plans only creates (or values known
#      after apply) and mutates nothing;
#   2. apply creates every node;
#   3. a re-apply is NOOP for every node and mutates nothing;
#   4. a change made out of band is seen as drift and converged;
#   5. a node the cloud reports FAILED is updated by the next apply (never
#      refused, never re-created) and then settles: failed, then fixed;
#   6. a changed field is an UPDATE, never a silent no-op;
#   7. destroy leaves nothing behind.
# Every apply must finish: an apply that stops part-way fails the kit with
# what landed and what is pending.
#
# A cloud adds the four observation hooks of `ConformanceTarget`. Against an
# in-memory cloud they read its memory; against a real one, the live account
# (which is why the kit never runs against a real account outside a
# dedicated project).
#
# Not here yet, and named so nobody assumes otherwise: crash-and-resume mid
# apply, the ownership-label stamp and the refusal of a foreign object of
# the same name, closed-world role removal, the modelled/unmodelled tamper
# pair, and two interleaved applies. Each needs the engine's ownership stamp
# and the cell's ledger, which do not exist yet.
# =============================================================================

from kci_reconciler import (
    AppliedNode,
    ChangeAction,
    Creds,
    InMemoryStateStore,
    VERB_CREATE,
    VERB_KNOWN_AFTER_APPLY,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_resource_proto.resource import Resource

from kci_cloud.adapter import CloudAdapter
from kci_cloud.deploy import (
    ApplyOutcome,
    apply_resources,
    destroy_resources,
    lower_resources,
    plan_resources,
)
from kci_cloud.clouds import Clouds


trait ConformanceTarget(CloudAdapter):
    """A cloud adapter the kit can observe."""

    def live_count(self) -> Int:
        """How many engine nodes exist on the cloud now."""
        ...

    def mutations(self) -> Int:
        """How many create / update / delete calls the cloud has served."""
        ...

    def tamper(mut self, logical_id: String) raises:
        """Change node `logical_id` out of band, as an operator would."""
        ...

    def fail(mut self, logical_id: String) raises:
        """Put node `logical_id` into the cloud's failed state (a new version
        that never became ready), leaving it present."""
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


def _verb_of(actions: List[ChangeAction], lid: String) -> Int:
    for i in range(len(actions)):
        if actions[i].logical_id == lid:
            return actions[i].verb
    return -1


def run_conformance[
    S: ConformanceTarget
](
    clouds: Clouds,
    mut cloud: S,
    base: List[Resource],
    changed: List[Resource],
    tamper_node: String,
) raises:
    """Run the kit. `changed` is `base` with one field of one resource changed;
    `tamper_node` is a node of `base`'s lowering to change out of band. The
    cloud must start empty. Raises naming the failed step."""
    var creds = Creds.none()
    var store = InMemoryStateStore()
    if cloud.live_count() != 0:
        raise _fail("start", String("the cloud is not empty"))

    # The node count, from the lowering itself.
    var nodes = lower_resources(cloud, base).num_nodes()

    # 1. dry run on nothing
    var m0 = cloud.mutations()
    var p1 = plan_resources(clouds, cloud, base, creds)
    if len(p1) != nodes:
        raise _fail("plan", String("planned ") + String(len(p1)) + " of " + String(nodes) + " nodes")
    for i in range(len(p1)):
        if p1[i].verb != VERB_CREATE and p1[i].verb != VERB_KNOWN_AFTER_APPLY:
            raise _fail(
                "plan",
                p1[i].logical_id + String(" planned ") + String(p1[i].verb_name()) + " on an empty cloud",
            )
        if p1[i].owner.byte_length() == 0:
            raise _fail("plan", p1[i].logical_id + String(" has no owner in the plan"))
    if cloud.mutations() != m0:
        raise _fail("plan", String("a dry run mutated the cloud"))

    # 2. apply
    var a2 = _applied("apply", apply_resources(clouds, cloud, base, creds, store))
    for i in range(len(a2)):
        if a2[i].verb != VERB_CREATE:
            raise _fail("apply", a2[i].logical_id + String(" was not created"))
    if cloud.live_count() != nodes:
        raise _fail(
            "apply",
            String("live nodes ") + String(cloud.live_count()) + " != " + String(nodes),
        )

    # 3. re-apply is a no-op
    var m3 = cloud.mutations()
    var a3 = _applied("re-apply", apply_resources(clouds, cloud, base, creds, store))
    for i in range(len(a3)):
        if a3[i].verb != VERB_NOOP:
            raise _fail("re-apply", a3[i].logical_id + String(" was not a no-op"))
    if cloud.mutations() != m3:
        raise _fail("re-apply", String("a no-op re-apply mutated the cloud"))

    # 4. out-of-band drift is seen and converged
    cloud.tamper(tamper_node)
    var p4 = plan_resources(clouds, cloud, base, creds)
    if _verb_of(p4, tamper_node) != VERB_UPDATE:
        raise _fail("drift", tamper_node + String(" changed out of band but did not plan an update"))
    _ = _applied("drift", apply_resources(clouds, cloud, base, creds, store))
    var a4 = _applied("drift", apply_resources(clouds, cloud, base, creds, store))
    for i in range(len(a4)):
        if a4[i].verb != VERB_NOOP:
            raise _fail("drift", a4[i].logical_id + String(" did not settle after the repair"))

    # 5. failed, then fixed: the next apply updates the failed node in place
    cloud.fail(tamper_node)
    var p5 = plan_resources(clouds, cloud, base, creds)
    if _verb_of(p5, tamper_node) != VERB_UPDATE:
        raise _fail("failed", tamper_node + String(" is FAILED but did not plan an update"))
    var f5 = _applied("failed", apply_resources(clouds, cloud, base, creds, store))
    for i in range(len(f5)):
        if f5[i].logical_id == tamper_node:
            if f5[i].verb != VERB_UPDATE:
                raise _fail(
                    "failed",
                    tamper_node + String(" was ") + String(f5[i].verb) + String(", not updated"),
                )
        elif f5[i].verb != VERB_NOOP:
            raise _fail("failed", f5[i].logical_id + String(" changed while fixing another node"))
    var s5 = _applied("failed", apply_resources(clouds, cloud, base, creds, store))
    for i in range(len(s5)):
        if s5[i].verb != VERB_NOOP:
            raise _fail("failed", s5[i].logical_id + String(" did not settle after the fix"))

    # 6. a changed field is an update
    var a5 = _applied("change", apply_resources(clouds, cloud, changed, creds, store))
    var updates = 0
    for i in range(len(a5)):
        if a5[i].verb == VERB_UPDATE:
            updates += 1
        elif a5[i].verb == VERB_CREATE:
            raise _fail("change", a5[i].logical_id + String(" was re-created, not updated"))
    if updates == 0:
        raise _fail("change", String("a changed field produced no update"))

    # 7. destroy leaves nothing
    _ = destroy_resources(clouds, cloud, changed, creds, store)
    if cloud.live_count() != 0:
        raise _fail(
            "destroy",
            String(cloud.live_count()) + String(" nodes left after destroy"),
        )
