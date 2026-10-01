# =============================================================================
# kci_edge/network_accumulators.mojo — the NEUTRAL network output->input seam:
#   it carries a network node's discovered `physical_id` to a policy node.
# =============================================================================
#
# ── ⛔ WHAT PROBLEM THIS SOLVES, IN ONE PARAGRAPH ────────────────────────────
# A security group is VPC-SCOPED: `CreateSecurityGroup` takes a VpcId. A GCP
# firewall rule is NETWORK-scoped: `firewalls.insert` takes a network URL. On
# the ADOPT path neither id is authored — the kind-25 `RESOURCE_KIND_NETWORK`
# node DISCOVERS it at apply time, by reading the account's default VPC. So the
# kind-26 `RESOURCE_KIND_INGRESS_POLICY` node needs a value that does not exist
# when its spec is composed. `IngressPolicySpec.network_logical_id` names WHICH
# network; this accumulator is what carries that network's discovered id from
# the producing node to the consuming one.
#
# ── ⛔ WHY THE MAP-TIME RESOLUTION PATTERN DOES **NOT** COVER THIS ───────────
# The obvious precedent is `ApiEdgeSpec.backend_logical_id`, and it is the wrong
# one. `aws_api_edge_backend_function` resolves that at MAP time by scanning the
# manifest for the named node and then DERIVING the Lambda ARN from
# (partition, account, region, name) — every component authored or known. A
# Lambda ARN is derivable; a VpcId is not. `vpc-<id>` is a server-assigned
# string that exists in exactly one place: the answer to a live DescribeVpcs.
# ⇒ A mapper cannot compute it, so the value must travel at APPLY time, which is
# what an accumulator is for.
#
# ── ⛔ AND THE CONSUMER MUST NOT JUST READ IT ITSELF ─────────────────────────
# The live ingress-policy adapter holds an `Ec2Client` and could call
# `describe_vpc("")` on its own. That is the tempting shortcut and it is wrong
# TWICE: (a) it is a SECOND discovery site free to disagree with the first, and
# (b) — the binding half — the kind-25 node is where the REFUSALS live. It
# refuses a non-default VPC under EGRESS_MODE_PUBLIC, and refuses a `zone_count`
# larger than the supply. A policy node that discovered its own VpcId would
# install a fence in a network the network node had just refused to adopt.
#
# ── ★ WHY IT LIVES IN A PACKAGE NAMED `kci_edge` ─────────────────────────────
# This package is named for the kind-19 API_EDGE substrate that first needed a
# cross-node accumulator, but what it holds is THE NEUTRAL HOME FOR
# ACCUMULATOR SEAMS THAT CARRY AN APPLY-TIME-DISCOVERED VALUE BETWEEN GRAPH
# NODES — `BackendAddressAccumulator` (a live Cloud Run URL, backend -> edge) and
# `EdgeOutcomeAccumulator` (a published edge URL, edge -> driver) are two
# instances of exactly that, and this is the third. It is a `kci_iac` leaf that
# BOTH cloud conformer packages already name, so putting the third one beside
# the first two adds ZERO dependency edges and makes the pattern greppable as a
# pattern.
# ⚠ THE ALTERNATIVES ARE WORSE: a new package for one struct costs a build file
# and two new dep edges; and `kci_iac` is the ENGINE — a resource-kind-shaped
# accumulator there would put a network vocabulary below the graph that carries
# it. So the package's scope is the neutral cross-node accumulator substrate
# plus the DIRECT edge conformer.
#
# ── ENCAPSULATION ────────────────────────────────────────────────────────────
# ArcPointer interior — a SINGLE-thread synchronous `apply_graph` drive, NOT
# concurrent state under a fork-join barrier. A typed List of flat-String rows;
# no wildcard origin, no byte-slab, ZERO UnsafePointer.
# =============================================================================

from std.memory import ArcPointer


struct _NetworkRow(Copyable, Movable):
    """One (network node logical_id -> discovered network id + its zones) row.

    ★ TWO OBSERVATIONS, ONE ROW, FOR `_EdgeUrlRow`'s REASON. A placement needs
    BOTH the network id (to scope its fence) and the zone/subnet ids (to place
    the workload), and both come out of the SAME live read under the SAME
    refusals. Splitting them into two accumulators would let one be recorded and
    the other not, and the consumer of the missing half has no way to tell that
    from "the network node has not run yet".

    ⛔ AN EMPTY `network_id` ON A ROW THAT EXISTS IS THE **ABSENT** MARKER, NOT
    A DEFECT — it is the middle state of the tri-state. It can be
    written by `record_absent` and by nothing else: `record_network` refuses an
    empty id, so no other path can produce this shape. `is_recorded` is what
    distinguishes it from a key with no row at all."""

    var logical_id: String
    var network_id: String
    var zone_ids: List[String]

    def __init__(
        out self,
        var logical_id: String,
        var network_id: String,
        var zone_ids: List[String],
    ):
        self.logical_id = logical_id^
        self.network_id = network_id^
        self.zone_ids = zone_ids^

    def copy(self) -> Self:
        return Self(
            String(self.logical_id),
            String(self.network_id),
            self.zone_ids.copy(),
        )


struct _NetworkOutcomeState(Movable):
    """The accumulator interior — the per-network-node discovered identity, in
    first-recorded order. A typed List of flat-String rows; no wildcard, no
    byte-slab."""

    var rows: List[_NetworkRow]

    def __init__(out self):
        self.rows = List[_NetworkRow]()


struct NetworkOutcomeAccumulator(Movable, Deinitable):
    """The shared sink a kind-25 `RESOURCE_KIND_NETWORK` node records its
    DISCOVERED network identity into, KEYED by the node's `logical_id`, and that
    every node scoped to that network (kind 26 today; a placement tomorrow)
    reads at apply time.

    Behind an `ArcPointer[_NetworkOutcomeState]` so every `share()`d handle
    points at ONE state. Single-threaded synchronous drive."""

    var _p: ArcPointer[_NetworkOutcomeState]

    def __init__(out self):
        self._p = ArcPointer[_NetworkOutcomeState](_NetworkOutcomeState())

    def __init__(out self, *, var _share: ArcPointer[_NetworkOutcomeState]):
        self._p = _share^

    def share(self) -> NetworkOutcomeAccumulator:
        """A SECOND handle over ONE `_NetworkOutcomeState` (the network node
        writes; every scoped node reads).

        SAFETY: ArcPointer ref-counted shared ownership; a single-thread
        synchronous `apply_graph` walk."""
        return NetworkOutcomeAccumulator(
            _share=ArcPointer[_NetworkOutcomeState](copy=self._p)
        )

    def record_network(
        mut self,
        logical_id: String,
        network_id: String,
        zone_ids: List[String],
    ) raises:
        """Record `logical_id`'s DISCOVERED network id and the zones its
        placements land in.

        ⛔ AN EMPTY `network_id` IS A RAISE, NOT A SKIP — AND THIS IS WHERE THIS
        SEAM DELIBERATELY DIVERGES FROM `EdgeOutcomeAccumulator.record_url`,
        WHICH SKIPS. The difference is what an empty value MEANS on each seam. An
        edge URL is empty during the legitimate pre-converge window, so skipping
        keeps the key absent and the consumer falls back. A network node records
        ONLY after it has successfully adopted a live network, so an empty id
        there is an impossible state — a conformer defect — and skipping it would
        surface as "the network node never ran" at a consumer several nodes
        later. A raise names the producer.

        ⛔ RE-RECORDING A **DIFFERENT** ID UNDER ONE KEY IS ALSO A RAISE. The
        same node is read twice in a plan-then-apply cycle and must answer the
        same network both times; two answers mean two networks were adopted under
        one logical id, and last-writer-wins would silently fence workloads in
        whichever one happened to be second. Re-recording the SAME id refreshes
        the zone list in place, which is what makes the seam re-runnable."""
        if network_id.byte_length() == 0:
            raise Error(
                String(
                    "NetworkOutcomeAccumulator: REFUSED to record an EMPTY"
                    " network id for node '"
                )
                + logical_id
                + String(
                    "'. A network node records only after it has adopted a live"
                    " network, so an empty id here is a conformer defect. It is"
                    " a raise rather than a skip because a skipped record is"
                    " indistinguishable from 'the network node has not run yet'"
                    " at every consumer, which would send a reader to the graph"
                    " ordering instead of to the producer."
                )
            )
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                # ── ★ THE UPGRADE: an ABSENT row becomes a resolved one ───────
                # `apply_graph_tracked` walks PER NODE — read, then dispatch. On
                # a FIRST apply the network node's read answers ABSENT (and
                # records it, so a plan of a fresh environment can run), and its
                # `create` then builds the network and records the id. Treating
                # `'' -> vpc-…` as the different-id conflict below would refuse
                # the one walk this seam exists to make work.
                if self._p[].rows[i].network_id.byte_length() == 0:
                    self._p[].rows[i].network_id = network_id.copy()
                    self._p[].rows[i].zone_ids = zone_ids.copy()
                    return
                if self._p[].rows[i].network_id != network_id:
                    raise Error(
                        String(
                            "NetworkOutcomeAccumulator: REFUSED — node '"
                        )
                        + logical_id
                        + String("' already recorded network '")
                        + self._p[].rows[i].network_id
                        + String("' and is now recording '")
                        + network_id
                        + String(
                            "'. One logical id names ONE network. Two answers"
                            " mean two networks were adopted under one name, and"
                            " last-writer-wins would fence workloads in whichever"
                            " one happened to be second — a fence installed in a"
                            " network the workload is not in, which is the exact"
                            " failure `IngressPolicySpec.of` refuses an empty"
                            " vpc_id to prevent."
                        )
                    )
                self._p[].rows[i].zone_ids = zone_ids.copy()
                return
        self._p[].rows.append(
            _NetworkRow(logical_id.copy(), network_id.copy(), zone_ids.copy())
        )

    def record_absent(mut self, logical_id: String) raises:
        """Record that `logical_id`'s network node RAN and found NO network.

        ⛔⛔ THIS IS THE MIDDLE OF A TRI-STATE, AND WITHOUT IT `plan_graph` OVER A
        FRESH ENVIRONMENT CANNOT RUN. `network_for` answers EMPTY
        for two states a consumer must act on differently:

          | state | what happened | what a scoped node must do |
          |---|---|---|
          | key MISSING | the network node has NOT RUN — a missing `depends_on`, or a REVERSE walk, which cannot discover at all | **RAISE**, naming the producer |
          | key present, ABSENT | the node RAN and there is no network YET | report **ABSENT** — the fence does not exist either |
          | key present with an id | converged | resolve and read the live rule |

        The consumers' refusal on a missing key is LOAD-BEARING and stays: it is
        what makes the forward-pass contract loud instead of leaking a
        firewall rule on every teardown. This verb is what stops that same
        refusal from also firing on a legitimately-empty environment.

        ⛔ CALL IT ONLY FROM A VERB THAT PROVED THE NETWORK IS NOT THERE — never
        from a REFUSAL and never from a partially-realized read. A network the
        node refused to adopt, or one whose subnet never landed, is NOT absent:
        a fence may well exist in it, and marking it absent would plan that
        fence as `create` (which fails) or, on a teardown, skip it as
        nothing-to-delete (which leaks it — and on GCP then blocks the network's
        own delete). Those paths stay SILENT, so their consumers still raise.

        ⛔ DOWNGRADING A RESOLVED ROW IS A RAISE, for `record_network`'s reason
        restated: one logical id gives ONE answer per drive."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                if self._p[].rows[i].network_id.byte_length() > 0:
                    raise Error(
                        String("NetworkOutcomeAccumulator: REFUSED — node '")
                        + logical_id
                        + String("' already recorded network '")
                        + self._p[].rows[i].network_id
                        + String(
                            "' and is now reporting ABSENT. One logical id gives"
                            " ONE answer per drive. Accepting the second would"
                            " flip every scoped consumer from `resolve and"
                            " converge` to `report absent`, so a fence that"
                            " EXISTS would be planned as a create (which fails)"
                            " or, on a teardown, skipped as nothing-to-delete —"
                            " which leaks it, and on GCP then blocks the"
                            " network's own delete."
                        )
                    )
                # Idempotent: a plan and an apply both read the same still-absent
                # network, and the second read must not be a second row.
                return
        self._p[].rows.append(
            _NetworkRow(logical_id.copy(), String(""), List[String]())
        )

    def is_recorded(self, logical_id: String) -> Bool:
        """Whether `logical_id`'s network node has RUN — TRUE for a resolved row
        AND for one marked ABSENT, FALSE only when nothing has written the key.

        ⚠ THIS, NOT `network_for`, IS THE DISCRIMINATION. Both an absent row and
        a missing key answer EMPTY from `network_for`, on purpose: an absent row
        has no network id to give. A consumer that branched on `network_for`
        alone cannot tell "the producer has not run" from "the producer ran and
        there is nothing", and the two demand opposite behaviour."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                return True
        return False

    def network_for(self, logical_id: String) -> String:
        """The discovered network id recorded for `logical_id` — EMPTY when that
        network node has not been read yet, AND when it ran and reported ABSENT.
        Ask `is_recorded` to tell those two apart.

        ⛔ EMPTY NEVER MEANS "use the default" IN EITHER STATE. On AWS,
        `CreateSecurityGroup` with no VpcId does NOT fail — it silently creates
        the group in the account's DEFAULT VPC (GCP resolves an unnamed network
        to `global/networks/default` the same way) — so a consumer that treated
        empty as "unscoped" would install a fence in a network the workload is
        not in, behind a 200. The two empty states differ only in WHICH refusal
        is right: a MISSING key must RAISE and name the node it was waiting for;
        a key recorded ABSENT must report the scoped resource ABSENT too, and
        must still refuse any verb that would MUTATE — there is no network to
        mutate in."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                return self._p[].rows[i].network_id.copy()
        return String("")

    def zones_for(self, logical_id: String) -> List[String]:
        """The zone/subnet ids recorded for `logical_id`, in the producing
        node's own selection order — EMPTY when that node has not been read.

        ⚠ THE ORDER IS THE MEANING and is never re-sorted here: the network
        conformer selects a PREFIX of the eligible subnets in the cloud's own
        order so two identical plans pick the same zones, and sorting at this
        seam would make that choice depend on a server-generated hash."""
        for i in range(len(self._p[].rows)):
            if self._p[].rows[i].logical_id == logical_id:
                return self._p[].rows[i].zone_ids.copy()
        return List[String]()

    def logical_ids(self) -> List[String]:
        """The recorded network-node logical ids, in first-recorded order."""
        var out = List[String]()
        for i in range(len(self._p[].rows)):
            out.append(self._p[].rows[i].logical_id.copy())
        return out^

    def count(self) -> Int:
        """How many network nodes have recorded a discovered identity."""
        return len(self._p[].rows)
