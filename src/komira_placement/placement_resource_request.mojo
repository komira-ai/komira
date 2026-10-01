# =============================================================================
# komira_placement/placement_resource_request.mojo — HOW MUCH CPU AND MEMORY
#   one placement UNIT needs, in cloud-neutral units, summed across its
#   containers.
# =============================================================================
#
# ── WHY IT IS HERE AND NOT IN A BRIDGE ──────────────────────────────────────
# It is the SAME split `k8s_quantity.mojo` already argues, one level up:
#
#   THE PARSE      (a Kubernetes quantity -> a number)  — shared. `k8s_quantity`.
#   THE AGGREGATE  (N containers -> ONE unit's need)    — shared. THIS FILE.
#   THE MAPPING    (a need -> a SKU)                    — NEVER shared.
#                  Each cloud bridge owns its own size table.
#
# The aggregate is cloud-neutral because the question is about the PLACEMENT
# UNIT, not about any cloud: a `PlacementSpec` holding N containers (the
# co-location shape) puts all N on ONE box, so the box must carry
# the SUM. That sentence is true of an EC2 instance, a GCE instance, a k8s pod
# and a Fargate task alike. What differs is which SKU provides it, and that is
# where the closed catalogs live.
#
# ── ⛔ THE THREE RULES, AND WHY EACH IS THE ONE IT IS ────────────────────────
#
#   1. SUM ACROSS CONTAINERS, NEVER TAKE THE FIRST. A VM placed for a
#      multi-container unit runs ALL of them. Sizing it from
#      `containers[0]` — which is what the single-container Fargate path does,
#      correctly, because a Fargate task IS one container's worth — would
#      under-provision every co-located placement by exactly the co-located
#      containers' share, and the failure mode is an OOM-kill of whichever
#      container happened to allocate last. `container_count() >= 2` is a
#      SUPPORTED shape (`PlacementSpec`'s own docstring), so this is not a
#      hypothetical.
#
#   2. AN EMPTY QUANTITY CONTRIBUTES ZERO, WHICH IS KUBERNETES' OWN SEMANTIC
#      FOR AN UNSTATED REQUEST — and is NOT the same as the whole unit stating
#      nothing. A sidecar that declares no request genuinely asks for no
#      guaranteed share; the unit is still sized by the containers that did ask.
#
#   3. ⛔ "NOTHING WAS STATED" IS ITS OWN ANSWER, CARRIED AS A FLAG, AND IT IS
#      NOT `0`. A unit where NO container states either quantity has made no
#      request at all, and the correct response is the CONFORMER's environment
#      default (the fleet's configured instance/machine type) — not the smallest
#      SKU in a table, which would be this file inventing a size, and not a
#      refusal, which would break every placement made without a stated size.
#      Collapsing that onto `millicores == 0` would make "asked for nothing" and
#      "asked for zero" the same bytes — the absent-vs-empty failure, one layer
#      down.
#
# ENCAPSULATION: pure value type + pure functions. No pointer, no origin, no
# I/O, no cloud call.
# =============================================================================

from komira_placement.placement_types import PlacementSpec
from komira_placement.k8s_quantity import (
    k8s_memory_mib_ceil,
    parse_k8s_cpu_millicores,
)


@fieldwise_init
struct PlacementResourceRequest(Copyable, Movable, Deinitable):
    """What ONE placement unit asks for, in cloud-neutral units.

    `millicores` is Kubernetes millicores (1000 == 1 vCPU) and `mib` is whole
    mebibytes, both SUMMED across the unit's containers. `stated` is False iff
    NOT ONE container named either quantity — see rule 3: that is a different
    answer from asking for zero, and the conformer treats it differently."""

    var millicores: Int
    var mib: Int
    var stated: Bool

    @staticmethod
    def none_stated() -> PlacementResourceRequest:
        """The unit asked for nothing. ⛔ The conformer must fall back to its
        environment default here, NOT to the smallest SKU in a table."""
        return PlacementResourceRequest(0, 0, False)

    def describe(self) -> String:
        """`"1500m cpu / 2048MiB memory"` — for a refusal or an escalation line
        that must state the request it is talking about rather than merely that
        one was too big."""
        return (
            String(self.millicores)
            + String("m cpu / ")
            + String(self.mib)
            + String("MiB memory")
        )


def sum_container_requests(spec: PlacementSpec) raises -> PlacementResourceRequest:
    """The unit's total CPU + memory request, summed across ALL its containers.

    ⛔ IT RAISES ON AN UNPARSEABLE QUANTITY rather than skipping it, because
    `k8s_quantity` raises and the alternative here would be to treat a typo as
    "this container asked for nothing" — silently under-provisioning the box by
    exactly the amount somebody meant to reserve. The `k8s_quantity` header
    states the same choice for the same reason: "unparseable -> leave it alone"
    is the right contract for a FLOOR and the wrong one for a TRANSLATION.

    An EMPTY quantity is skipped (rule 2 — an unstated request), and a unit in
    which nothing was stated comes back `stated=False` (rule 3)."""
    var millicores = 0
    var mib = 0
    var stated = False
    for i in range(len(spec.containers)):
        ref c = spec.containers[i]
        if c.cpu.byte_length() > 0:
            millicores += parse_k8s_cpu_millicores(c.cpu)
            stated = True
        if c.memory.byte_length() > 0:
            mib += k8s_memory_mib_ceil(c.memory)
            stated = True
    if not stated:
        return PlacementResourceRequest.none_stated()
    return PlacementResourceRequest(millicores, mib, True)
