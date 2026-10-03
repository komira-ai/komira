# =============================================================================
# kci_platform/conformance.mojo: the conformance kit.
# =============================================================================
#
# One suite, parameterised by platform, that every adapter set runs. It
# drives the platform only through this package's verbs (validate, lower,
# the engine), so what it proves is what kci will do on that platform:
#
#   1. a dry run on an empty platform plans only creates (or values known
#      after apply) and mutates nothing;
#   2. apply creates every node;
#   3. a re-apply is NOOP for every node and mutates nothing;
#   4. a change made out of band is seen as drift and converged;
#   5. a changed field is an UPDATE, never a silent no-op;
#   6. destroy leaves nothing behind.
#
# A platform adds the three observation hooks of `ConformanceTarget`. Against
# an in-memory platform they read its memory; against a real one, the live
# account (which is why the kit never runs against a real account outside a
# dedicated project).
#
# Not here yet, and named so nobody assumes otherwise: crash-and-resume mid
# apply, and the label-stamping check a real platform needs for leak
# ownership. Both need hooks the first real platform defines.
# =============================================================================

from kci_iac import (
    ChangeAction,
    Creds,
    InMemoryStateStore,
    VERB_CREATE,
    VERB_KNOWN_AFTER_APPLY,
    VERB_NOOP,
    VERB_UPDATE,
)
from kci_resource_proto.resource import Resource

from kci_platform.adapter import AdapterSet
from kci_platform.deploy import (
    apply_resources,
    destroy_resources,
    lower_resources,
    plan_resources,
)
from kci_platform.registry import Registry


trait ConformanceTarget(AdapterSet):
    """An adapter set the kit can observe."""

    def live_count(self) -> Int:
        """How many engine nodes exist on the platform now."""
        ...

    def mutations(self) -> Int:
        """How many create / update / delete calls the platform has served."""
        ...

    def tamper(mut self, logical_id: String) raises:
        """Change node `logical_id` out of band, as an operator would."""
        ...


def _fail(step: String, msg: String) -> Error:
    return Error(String("conformance [") + step + String("]: ") + msg)


def _verb_of(actions: List[ChangeAction], lid: String) -> Int:
    for i in range(len(actions)):
        if actions[i].logical_id == lid:
            return actions[i].verb
    return -1


def run_conformance[
    S: ConformanceTarget
](
    registry: Registry,
    mut platform: S,
    base: List[Resource],
    changed: List[Resource],
    tamper_node: String,
) raises:
    """Run the kit. `changed` is `base` with one field of one resource changed;
    `tamper_node` is a node of `base`'s lowering to change out of band. The
    platform must start empty. Raises naming the failed step."""
    var creds = Creds.none()
    var store = InMemoryStateStore()
    if platform.live_count() != 0:
        raise _fail("start", String("the platform is not empty"))

    # The node count, from the lowering itself.
    var nodes = lower_resources(platform, base).num_nodes()

    # 1. dry run on nothing
    var m0 = platform.mutations()
    var p1 = plan_resources(registry, platform, base, creds)
    if len(p1) != nodes:
        raise _fail("plan", String("planned ") + String(len(p1)) + " of " + String(nodes) + " nodes")
    for i in range(len(p1)):
        if p1[i].verb != VERB_CREATE and p1[i].verb != VERB_KNOWN_AFTER_APPLY:
            raise _fail(
                "plan",
                p1[i].logical_id + String(" planned ") + String(p1[i].verb_name()) + " on an empty platform",
            )
        if p1[i].owner.byte_length() == 0:
            raise _fail("plan", p1[i].logical_id + String(" has no owner in the plan"))
    if platform.mutations() != m0:
        raise _fail("plan", String("a dry run mutated the platform"))

    # 2. apply
    var a2 = apply_resources(registry, platform, base, creds, store)
    for i in range(len(a2)):
        if a2[i].verb != VERB_CREATE:
            raise _fail("apply", a2[i].logical_id + String(" was not created"))
    if platform.live_count() != nodes:
        raise _fail(
            "apply",
            String("live nodes ") + String(platform.live_count()) + " != " + String(nodes),
        )

    # 3. re-apply is a no-op
    var m3 = platform.mutations()
    var a3 = apply_resources(registry, platform, base, creds, store)
    for i in range(len(a3)):
        if a3[i].verb != VERB_NOOP:
            raise _fail("re-apply", a3[i].logical_id + String(" was not a no-op"))
    if platform.mutations() != m3:
        raise _fail("re-apply", String("a no-op re-apply mutated the platform"))

    # 4. out-of-band drift is seen and converged
    platform.tamper(tamper_node)
    var p4 = plan_resources(registry, platform, base, creds)
    if _verb_of(p4, tamper_node) != VERB_UPDATE:
        raise _fail("drift", tamper_node + String(" changed out of band but did not plan an update"))
    _ = apply_resources(registry, platform, base, creds, store)
    var a4 = apply_resources(registry, platform, base, creds, store)
    for i in range(len(a4)):
        if a4[i].verb != VERB_NOOP:
            raise _fail("drift", a4[i].logical_id + String(" did not settle after the repair"))

    # 5. a changed field is an update
    var a5 = apply_resources(registry, platform, changed, creds, store)
    var updates = 0
    for i in range(len(a5)):
        if a5[i].verb == VERB_UPDATE:
            updates += 1
        elif a5[i].verb == VERB_CREATE:
            raise _fail("change", a5[i].logical_id + String(" was re-created, not updated"))
    if updates == 0:
        raise _fail("change", String("a changed field produced no update"))

    # 6. destroy leaves nothing
    _ = destroy_resources(registry, platform, changed, creds, store)
    if platform.live_count() != 0:
        raise _fail(
            "destroy",
            String(platform.live_count()) + String(" nodes left after destroy"),
        )
