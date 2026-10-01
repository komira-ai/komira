# =============================================================================
# kci_deploy_compose/network_scope.mojo — THE TWO NETWORK NODE BUILDERS
#   (`RESOURCE_KIND_NETWORK` 25 / arm 21, `RESOURCE_KIND_INGRESS_POLICY` 26 /
#   arm 22) AND THE DEPLOY-GRAPH ALTITUDE'S ADOPT-ONLY FACTORY.
# =============================================================================
#
# WHY THIS IS ITS OWN MODULE AND NOT PART OF `compose_api`. The AWS mapper needs
#   `adopted_network_node` and `env_network_logical_id`, and it reaches only
#   SMALL modules of this package that declare the vocabulary both arms key on
#   (`grant_scope`, `param_resolve`), never a compose-sized compile unit: every
#   test of the mapper would otherwise elaborate all of `compose_api` to reach
#   four builders.
#
# THE ALTERNATIVE — A SECOND `ResourceNode(...)` CONSTRUCTION IN THE MAPPER —
#   IS THE ONE THAT MUST NOT BE TAKEN. Every arm of the `config` oneof is
#   `Optional`-typed, so a second construction site given 21 arguments where it
#   needed 22 STILL COMPILES and produces a node whose spec sits on the WRONG
#   ARM, readable by no conformer. One builder per kind, one arm index written
#   once, is what `test_compose_network_nodes` guards.
#
# `compose_api` DOES NOT IMPORT THIS MODULE, and that is not an oversight: it
#   never calls these builders. The network is composed at the ENVIRONMENT
#   altitude, not per `AppBundle`, so an `AppBundle` composer has no reason to
#   emit one.
# =============================================================================

from full_manifest_rpc.full_manifest import (
    EgressMode,
    IngressPolicySpec,
    IngressRule,
    NetworkSpec,
    ResourceKind,
    ResourceNode,
    Retention,
)

# The `Cloud` posture ordinals, MIRRORED from the env-binding layer (itself a
# mirror of `environment.proto`'s `Cloud`) — the SAME mirror `compose_api`
# carries and for the same dep-closure reason. Only the two ordinals this module
# ADJUDICATES are mirrored: a third name here would read as support for a cloud
# `deploy_graph_network_adopt_key` refuses by name.
comptime CLOUD_GCP: Int = 1
comptime CLOUD_AWS: Int = 2


# =============================================================================
# THE TWO NETWORK NODES (kind 25 NETWORK / arm 21, kind 26 INGRESS_POLICY /
#    arm 22).
#
# NEITHER IS APPENDED TO ANY COMPOSED MANIFEST BY THIS FILE, AND THAT IS
#    DELIBERATE. A node kind no arm can materialize, composed into EVERY
#    composition on BOTH clouds, blocks every apply: the AWS arm's apply form
#    raises on the FIRST unmappable node.
#
#    ⇒ THE BUILDERS LAND FIRST AND THE EMISSION LANDS WITH THE CONFORMER. A node
#    kind starts being composed in the change that gives it somewhere to go —
#    and the network specifically is composed once per ENVIRONMENT at bootstrap
#    (the `RESOURCE_KIND_BUCKET` / `RESOURCE_KIND_WIF_PROVIDER` shape), never
#    per-`AppBundle`.
# =============================================================================


def network_node(
    var logical_id: String,
    var adopt_existing_id: String,
    egress: Int,
    zone_count: Int,
    retention: Int,
) raises -> ResourceNode:
    """The Network node (kind 25, config oneof arm 21, field 25).

    RETENTION IS AN ARGUMENT, NOT A DEFAULT, AND THIS IS THE SECOND KIND FOR
    WHICH THAT IS TRUE (`RESOURCE_KIND_MAIL_DOMAIN_IDENTITY` is the first, for
    the identical reason). The two answers are destructive in OPPOSITE
    directions: RETENTION_DELETE on an ADOPTED network tears down a VPC every
    other workload in the account sits in; RETAIN_KEEP on one we CREATED leaks a
    VPC, its subnets and its internet gateway forever. A default would pick one
    of those silently, and which one is right is a property of
    `adopt_existing_id` that the CALLER knows.

    NO CALLER SHOULD PASS BOTH `adopt_existing_id` NON-EMPTY AND
    RETENTION_DELETE. That combination is not refused HERE — a composer that
    refused it would be enforcing a conformer's contract at the wrong altitude,
    and the conformer's `delete` refuses an adopted network by name regardless of
    what the node says. It is stated so a reader does not read the absence of a
    check as permission.

    Vendor-neutral: NO vendor primitive rides here — "VPC", "subnet" and
    "internet gateway" are named only inside conformers."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_NETWORK),
        List[String](),
        Retention(retention),
        21,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-20
        Optional[NetworkSpec](
            NetworkSpec(
                adopt_existing_id^,
                EgressMode(egress),
                Int32(zone_count),
            )
        ),  # arm 21 (network, field 25)
        None,  # arm 22 (ingress_policy)
    )


# =============================================================================
# THE DEPLOY-GRAPH ALTITUDE — an ADOPT-ONLY kind-25 node, on BOTH clouds.
#
# THE RULE: **the BOOTSTRAP graph is the only place `RESOURCE_KIND_NETWORK` is
#    ever CREATED. Every deploy-graph reference to it is a READ.** A deploy
#    graph needs a kind-25 node at all because the network outcome accumulator
#    is constructed PER MAPPER CALL — the bootstrap network node's outcome is in
#    a DIFFERENT graph and is invisible to a deploy apply — so a service whose
#    subnets are deferred to a network node must have that node in ITS OWN
#    graph. Without this altitude the deferred `ContainerServiceSpec.
#    scoped_to_node` resolves against an empty accumulator forever.
#
# AND THE THING THAT MAKES THIS A FACTORY RATHER THAN A CALL TO `network_node`:
#    **THE TWO CLOUDS SPELL "ADOPT" WITH OPPOSITE BYTES**, so "pass a non-empty
#    `adopt_existing_id`" is a rule that is RIGHT on GCP and WRONG on AWS:
#
#      | cloud | `adopt_existing_id` EMPTY | NON-EMPTY |
#      |-------|---------------------------|-----------|
#      | AWS   | ADOPT the account's DEFAULT VPC (read-only) | adopt that VPC id — and the AWS conformer REFUSES any NON-DEFAULT VPC under the only implemented egress mode, so the only id that can succeed is one nobody can derive at compose time |
#      | GCP   | **CREATE** a custom-mode VPC + subnet | adopt that network BY NAME |
#
#    ⇒ a single literal cannot express the rule. What CAN is a function that
#    renders the ADOPT spelling FOR the cloud, plus a refusal over the rendered
#    bytes — which is what makes CREATE structurally unspellable at this
#    altitude rather than merely undone by convention.
#
# THE AWS ADOPT KEY IS EMPTY AND THAT IS NOT A LOOPHOLE. It is the AWS arm's
#   ONLY read-only adopt statement: the conformer's `create`, `update` and
#   `delete` each refuse by name and its retention answers RETAIN_UNDELETABLE
#   unconditionally as a CAPABILITY, so on that arm there is no byte string
#   whatsoever that reaches a mutation. Baking a `vpc-…` id here instead would
#   hardcode one account's SERVER-ASSIGNED id into the composer.
# =============================================================================

comptime ENV_NETWORK_LOGICAL_ID: String = "kci-env-network"
"""The logical id of the ONE `RESOURCE_KIND_NETWORK` node an ENVIRONMENT has.

ONE DERIVATION, READ BY BOTH ALTITUDES, WHICH IS THE WHOLE POINT. The bootstrap
composition (once per ENVIRONMENT, never per `AppBundle`) and every deploy graph
that references it must name the SAME node, or the deploy graph adopts a network
the bootstrap graph did not build. Two spellings of one name is how those two
come to disagree, so there is one and it lives here.

ENVIRONMENT-SCOPED, NOT BUNDLE-SCOPED, AND THE CONSTANT IS WHAT ENFORCES IT.
Every graph in one environment renders the SAME id, so N bundles deploying into
one environment cannot produce N networks even in principle — the failure mode
("a VPC per bundle per deploy") is unreachable by construction rather than by
review. It is NOT qualified by env NAME because a graph is already scoped to one
environment: the account and region are the apply's, not the id's.

IT IS ALSO THE GCP NETWORK'S **NAME**. The GCP bridge's network name is the
identity function over the logical id, so this string is what `networks.get`
asks for — which is why it must satisfy RFC1035 (lowercase, leading letter, no
underscores). The GCP placement spec refuses one that does not."""


def env_network_logical_id() -> String:
    """The environment's network node id. A function and not a bare constant so
    every reader goes through one symbol that `git grep` finds."""
    return String(ENV_NETWORK_LOGICAL_ID)


def deploy_graph_network_adopt_key(cloud: Int) raises -> String:
    """The bytes that spell ADOPT on `cloud` — see the section header's table.

    IT RAISES ON EVERY OTHER CLOUD RATHER THAN PICKING ONE. `CLOUD_LOCAL` is
    the GCP posture run against EMULATORS and there is no Compute Engine
    emulator, so rendering GCP's answer there would produce a node whose apply
    reaches the real `compute.googleapis.com` from a run that believed it was
    offline. Azure and Kubernetes need their own arm's adjudication; kind 25 has
    no conformer on either."""
    if cloud == CLOUD_AWS:
        return String("")
    if cloud == CLOUD_GCP:
        return env_network_logical_id()
    raise Error(
        String(
            "deploy_graph_network_adopt_key: REFUSED cloud ordinal "
        )
        + String(cloud)
        + String(
            ". A deploy-graph network node must ADOPT, and 'adopt' is spelled"
            " with OPPOSITE bytes on the two clouds that have a kind-25"
            " conformer (AWS: an EMPTY adopt key means the account's DEFAULT"
            " VPC and is read-only; GCP: an empty key means CREATE, and the"
            " network NAME is the key). There is no third answer to guess:"
            " CLOUD_LOCAL is the GCP posture over EMULATORS and has no Compute"
            " Engine to adopt, and neither Azure nor Kubernetes has a kind-25"
            " arm at all. Compose no network node on those clouds rather than"
            " composing one that cannot be materialized."
        )
    )


def refuse_unless_deploy_graph_network_adopts(
    cloud: Int, adopt_existing_id: String
) raises:
    """THE ADOPT-ONLY GATE, STATED OVER THE RENDERED BYTES.

    This is the check that makes the adopt-only rule a PROPERTY rather than a
    convention: whatever produced `adopt_existing_id`, it must be the ADOPT
    spelling for `cloud` before a node carrying it can exist.

    It is a SEPARATE, EXPORTED function and not three lines inside
    `adopted_network_node` for one reason: a guard that can only be reached
    through the code that computes the value it guards can only ever agree with
    it, so a falsifier cannot tell whether the guard is doing anything. Called
    with a hand-supplied wrong key it goes red, which is what makes the ADOPT-vs-
    CREATE distinction mutation-provable."""
    if cloud == CLOUD_GCP and adopt_existing_id.byte_length() == 0:
        raise Error(
            String(
                "refuse_unless_deploy_graph_network_adopts: REFUSED an EMPTY"
                " adopt key on CLOUD_GCP. On the GCP arm an empty"
                " `adopt_existing_id` means **CREATE** — `networks.insert` plus"
                " `subnetworks.insert` — so a deploy-graph node carrying it"
                " would build ONE VPC PER BUNDLE PER DEPLOY, in an environment"
                " whose network the BOOTSTRAP graph owns. The deploy altitude"
                " reads the network; it never creates one. Pass"
                " `deploy_graph_network_adopt_key(CLOUD_GCP)`, which renders the"
                " bootstrap network's own name."
            )
        )
    if cloud == CLOUD_AWS and adopt_existing_id.byte_length() > 0:
        raise Error(
            String(
                "refuse_unless_deploy_graph_network_adopts: REFUSED the"
                " NON-EMPTY adopt key '"
            )
            + adopt_existing_id
            + String(
                "' on CLOUD_AWS. Adopting the account's DEFAULT VPC is spelled"
                " with an EMPTY key there, and it is the only target the arm"
                " accepts: the AWS network conformer REFUSES a NON-DEFAULT VPC"
                " under EGRESS_MODE_PUBLIC, the only implemented mode. So a"
                " non-empty key is either a SERVER-ASSIGNED `vpc-…` id"
                " hardcoded into a composer, or an id whose apply refuses"
                " minutes later. EMPTY IS NOT 'unset' HERE: on this arm it is"
                " the adopt-the-default STATEMENT, and the arm can reach no"
                " mutation at all (create/update/delete each refuse by name)."
            )
        )
    if cloud != CLOUD_AWS and cloud != CLOUD_GCP:
        # Re-stated rather than delegated: this function is reachable from
        # callers that did not go through `deploy_graph_network_adopt_key`, and
        # a gate that silently passes an unknown cloud is a gate with a hole in
        # exactly the direction it exists to close.
        _ = deploy_graph_network_adopt_key(cloud)


def adopted_network_node(
    var logical_id: String, cloud: Int, egress: Int, zone_count: Int
) raises -> ResourceNode:
    """The DEPLOY-GRAPH `RESOURCE_KIND_NETWORK` node: adopt-only, both clouds.

    `retention` IS **NOT** AN ARGUMENT HERE, AND THAT IS THE ONE PLACE THIS
    FACTORY DELIBERATELY NARROWS `network_node`. That one takes retention as an
    argument precisely because the answer is a property of `adopt_existing_id`
    THE CALLER KNOWS. At this altitude the caller does not have that freedom: the
    node adopts, by construction, so RETENTION_DELETE is the answer that tears
    down the network every other workload in the environment is placed in — on
    one bundle's ordinary teardown. RETAIN_KEEP is the only correct value and an
    argument would be a way to get it wrong.

    THE AWS ARM OVERRIDES IT ANYWAY, AND THE VALUE IS STILL NOT A NO-OP. The
    AWS network conformer's retention answers RETAIN_UNDELETABLE unconditionally
    (a CAPABILITY: it never creates, so it has no delete), so on AWS this
    ordinal is passed and unused. On GCP the node factory THREADS the node's
    ordinal into the conformer, so the value here is what stops a
    `--delete-data` teardown of one bundle taking the environment's network
    with it.

    `depends_on` IS EMPTY, INHERITED FROM `network_node`. The network is the
    thing everything else in the graph is placed IN; it depends on nothing. The
    edges that matter run the other way, and the consumer states them — see the
    AWS mapper's ECS-service arm, which puts this node's id in the SERVICE's
    `depends_on` so the accumulator is filled before it is read."""
    if logical_id.byte_length() == 0:
        raise Error(
            String(
                "adopted_network_node: REFUSED an EMPTY logical_id. It is the"
                " key a deferred placement resolves against"
                " (`ContainerServiceSpec.network_logical_id`), so an empty one"
                " defers the subnets to nothing and surfaces at the CONSUMER as"
                " a missing accumulator row — which reads as a graph-ordering"
                " problem rather than as the empty field it is."
            )
        )
    var adopt = deploy_graph_network_adopt_key(cloud)
    refuse_unless_deploy_graph_network_adopts(cloud, adopt)
    return network_node(
        logical_id^,
        adopt^,
        egress,
        zone_count,
        Retention.RETENTION_RETAIN_KEEP,
    )


def ingress_rule_from_peer_node(
    var peer_logical_id: String, port: Int, var protocol: String
) raises -> IngressRule:
    """One allow rule whose peer is ANOTHER NODE in this graph.

    THE GENERATED ARM INDEX IS 1 (`peer_logical_id`), NOT THE FIELD NUMBER.
    The `peer` oneof's first arm is field 1, and the codegen indexes arms from 1,
    so they coincide here — an accident of arithmetic that must not be relied on
    by the sibling below, where it does NOT coincide with anything meaningful."""
    return IngressRule(
        Int32(port), protocol^, 1, Optional[String](peer_logical_id^), None
    )


def ingress_rule_from_cidr(
    var peer_cidr: String, port: Int, var protocol: String
) raises -> IngressRule:
    """One allow rule whose peer is an EXTERNAL CIDR — the one place raw
    networking is deliberately exposed, because an external peer has no logical
    id to derive anything from. Arm index 2."""
    return IngressRule(
        Int32(port), protocol^, 2, None, Optional[String](peer_cidr^)
    )


def ingress_policy_node(
    var logical_id: String,
    var backend_logical_id: String,
    var network_logical_id: String,
    var rules: List[IngressRule],
    var depends_on: List[String],
) raises -> ResourceNode:
    """The IngressPolicy node (kind 26, config oneof arm 22, field 26).

    RETENTION_DELETE, unconditionally and with no argument — the opposite of
    `network_node` above, and the asymmetry is the point. A security group / VPC
    firewall rule holds no data, is deterministically recreatable from the spec,
    and is created BY this graph FOR one workload this graph also creates. There
    is no adopt arm, so there is no second answer to choose between.

    AN EMPTY `rules` IS MEANINGFUL AND IS NOT A DEFECT: it composes a fence
    that admits nobody, which is the correct posture for an egress-only worker.
    It is NOT the same as omitting the node, which leaves the substrate's own
    default in force — on AWS that is the VPC's default security group.

    `depends_on` must carry BOTH the network node and the workload: the fence
    cannot be created before the VPC that scopes it, and attaching it before the
    workload exists has nothing to attach to."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_INGRESS_POLICY),
        depends_on^,
        Retention(Retention.RETENTION_DELETE),
        22,
        None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None, None,  # arms 1-21
        Optional[IngressPolicySpec](
            IngressPolicySpec(
                backend_logical_id^,
                rules^,
                network_logical_id^,
            )
        ),  # arm 22 (ingress_policy, field 26)
    )
