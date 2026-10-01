# =============================================================================
# tests/test_compose_network_nodes.mojo — THE FALSIFIER FOR THE CLOUD-AGNOSTIC
#   NETWORK RESOURCE BUILDERS: `RESOURCE_KIND_NETWORK` (25, oneof arm 21) and
#   `RESOURCE_KIND_INGRESS_POLICY` (26, oneof arm 22).
# =============================================================================
#
# ── WHAT THIS FILE IS ACTUALLY GUARDING, AND WHY IT IS NOT "the ctor works" ──
# Every arm of the `config` oneof is `Optional[...]`-typed, so a construction
# site given 21 arguments where it needed 22 STILL COMPILES on every other kind
# and produces a node whose spec silently sits on the WRONG ARM. An arity check
# catches a site left short; it cannot catch a shift. So the legs below assert
# the ARM INDEX and the ROUND-TRIP of each spec's fields, which is where a shift
# first becomes visible.
#
# ── THE ONE THING A READER WILL EXPECT AND NOT FIND ──────────────────────────
# There is no leg asserting that a composed manifest CONTAINS a network node,
# because NOTHING IN THIS PACKAGE EMITS ONE. That is deliberate and it is stated
# in `network_node`'s own docstring: a node no arm can materialize is the first
# unmappable node in every composition, and the apply-form arm raises on it. The
# emission lands with the conformer.
#
# ── MUTATION PROOF (each mutant produces a DISTINCT red) ─────────────────────
#   M1  `network_node` passes arm index 20 instead of 21
#       -> §1 "the NETWORK spec is not on arm 21"
#   M2  `ingress_policy_node` passes arm index 21 instead of 22
#       -> §2 "the INGRESS_POLICY spec is not on arm 22"
#   M3  `ingress_rule_from_cidr` sets the oneof case to 1 (peer_logical_id)
#       -> §3 "an external CIDR rule resolved as a graph peer"
#   M4  `network_node` hardcodes RETENTION_DELETE instead of taking `retention`
#       -> §4 "an ADOPTED network composed with RETENTION_DELETE"
#   M5  `ingress_policy_node` drops `network_logical_id`
#       -> §5 "the policy does not name the network it is scoped to"
#   M6  `network_node` swaps `zone_count` and the egress ordinal
#       -> §1 "`egress` round-trips as PUBLIC (ordinal 1)"
#       This mutant reds the EGRESS leg, not the zone_count one, because the
#       egress assertion runs first.
#   M7  `ingress_policy_node` composes RETAIN_KEEP
#       -> §5 "an ingress policy is app-owned"
#
# ── §6 — THE DEPLOY-GRAPH ALTITUDE. Its own mutation ledger, because its
#    subject is a DIFFERENT one: not "is the spec on the right arm" but "can this
#    altitude ever CREATE a network". ──────────────────────────────────────────
#   M8  `deploy_graph_network_adopt_key` returns `String("")` on CLOUD_GCP
#       -> §6a "THE DEPLOY-GRAPH GCP NODE RENDERED AN **EMPTY**
#          `adopt_existing_id`" (and the gate raises out of the ctor)
#   M9  `deploy_graph_network_adopt_key` returns the network name on CLOUD_AWS
#       -> §6b "the AWS deploy-graph node must carry the EMPTY adopt key"
#   M10 `refuse_unless_deploy_graph_network_adopts` drops the CLOUD_GCP arm
#       -> §6c "AN EMPTY ADOPT KEY ON CLOUD_GCP WAS ACCEPTED"
#       THIS IS THE MUTANT §6a/§6b CANNOT SEE — the renderer is still right, so
#       both value legs stay green. It is why §6c supplies the key by hand.
#   M11 `refuse_unless_deploy_graph_network_adopts` drops the CLOUD_AWS arm
#       -> §6c "A SERVER-ASSIGNED VPC ID ON CLOUD_AWS WAS ACCEPTED"
#   M12 `adopted_network_node` passes RETENTION_DELETE
#       -> §6d "a deploy-graph network node must be RETAIN_KEEP"
#   M13 `deploy_graph_network_adopt_key`'s final `raise` becomes
#       `return String("")` (an unknown cloud falls through to the AWS answer)
#       -> §6e "an unadjudicated cloud composed a network node"
#   M14 `adopted_network_node` drops its empty-`logical_id` refusal
#       -> §6e "an EMPTY logical id composed a network node"
#
# NO CLOUD, NO TRANSPORT, NO SEAM — proto values in, proto values out.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from full_manifest_rpc.full_manifest import (
    EgressMode,
    IngressRule,
    ResourceKind,
    Retention,
)

from kci_deploy_compose.network_scope import (
    CLOUD_AWS,
    CLOUD_GCP,
    adopted_network_node,
    env_network_logical_id,
    ingress_policy_node,
    ingress_rule_from_cidr,
    ingress_rule_from_peer_node,
    network_node,
    refuse_unless_deploy_graph_network_adopts,
)


# =============================================================================
# 1 — THE NETWORK NODE: kind 25, ARM 21, and every field round-trips.
# =============================================================================
def test_the_network_node_sits_on_arm_21_and_round_trips() raises:
    """THE ARM INDEX IS THE ASSERTION THAT SURVIVES A SHIFT.

    `_oneof0_case` is the ONLY thing that distinguishes "the NetworkSpec is on
    the network arm" from "a NetworkSpec-shaped value landed on the arm next
    door with every other arm still None". Both compile; both produce a node;
    only one is decodable by a conformer keyed on kind 25.
    """
    var n = network_node(
        String("env-a-network"),
        String("vpc-0a1b2c3d"),
        EgressMode.EGRESS_MODE_PUBLIC,
        4,
        Retention.RETENTION_RETAIN_KEEP,
    )
    assert_equal(
        n.kind.value,
        ResourceKind.RESOURCE_KIND_NETWORK,
        "the node's kind is 25 NETWORK",
    )
    assert_equal(
        n._oneof0_case,
        21,
        "the NETWORK spec is not on arm 21. The `config` oneof's first arm is"
        " `serverless_compute = 5` and the codegen indexes arms from 1, so field"
        " 25 is arm 21. A spec on the wrong arm still compiles — every arm is"
        " Optional — and produces a node no conformer can read.",
    )
    assert_true(
        Bool(n.network),
        "…and the arm index and the SET arm must agree: `_oneof0_case == 21`"
        " with `network` unset is a node that claims a spec it does not carry",
    )
    assert_equal(
        n.network.value().adopt_existing_id,
        String("vpc-0a1b2c3d"),
        "`adopt_existing_id` round-trips — this is the ADOPT arm",
    )
    assert_equal(
        Int(n.network.value().egress.value),
        EgressMode.EGRESS_MODE_PUBLIC,
        "`egress` round-trips as PUBLIC (ordinal 1)",
    )
    assert_equal(
        Int(n.network.value().zone_count),
        4,
        "`zone_count` round-trips. Asserted separately from `egress` because"
        " both are small integers and swapping the two arguments compiles.",
    )
    assert_equal(
        len(n.depends_on),
        0,
        "an ENVIRONMENT-scoped network depends on nothing in the graph — it is"
        " what everything else is placed INTO",
    )
    print("  test_the_network_node_sits_on_arm_21_and_round_trips: PASS")


# =============================================================================
# 2 — THE INGRESS-POLICY NODE: kind 26, ARM 22.
# =============================================================================
def test_the_ingress_policy_node_sits_on_arm_22_and_round_trips() raises:
    """Same instrument as §1, one arm further along — and the two are asserted
    SEPARATELY on purpose. A migration that shifted both by one would leave §1
    and §2 mutually consistent; each pins an absolute index."""
    var rules = List[IngressRule]()
    rules.append(ingress_rule_from_cidr(String("0.0.0.0/0"), 443, String("tcp")))
    var deps = List[String]()
    deps.append(String("env-a-network"))
    deps.append(String("svc-a"))
    var p = ingress_policy_node(
        String("svc-a-ingress"),
        String("svc-a"),
        String("env-a-network"),
        rules^,
        deps^,
    )
    assert_equal(
        p.kind.value,
        ResourceKind.RESOURCE_KIND_INGRESS_POLICY,
        "the node's kind is 26 INGRESS_POLICY",
    )
    assert_equal(
        p._oneof0_case,
        22,
        "the INGRESS_POLICY spec is not on arm 22 (field 26 - 4 = arm 22)",
    )
    assert_true(Bool(p.ingress_policy), "…and the arm is SET")
    assert_equal(
        p.ingress_policy.value().backend_logical_id,
        String("svc-a"),
        "`backend_logical_id` names the ONE workload this fence protects",
    )
    assert_equal(
        len(p.ingress_policy.value().rules),
        1,
        "the authored rule survives composition",
    )
    assert_equal(
        len(p.depends_on),
        2,
        "the policy depends on BOTH the network that scopes it and the workload"
        " it attaches to — a fence created before either has nothing to be",
    )
    print("  test_the_ingress_policy_node_sits_on_arm_22_and_round_trips: PASS")


# =============================================================================
# 3 — THE PEER ONEOF: a CIDR peer and a graph peer are DIFFERENT ARMS.
# =============================================================================
def test_a_cidr_peer_and_a_graph_peer_are_distinguishable() raises:
    """THE WHOLE REASON `peer` IS A ONEOF RATHER THAN TWO STRINGS.

    Absent and empty are the SAME BYTES to a plain string field. A conformer
    reading two strings has to guess which one the author meant when one of
    them is "", and both guesses are wrong in a security-relevant direction:
    reading a blank `peer_cidr` as `0.0.0.0/0` opens the workload to the
    internet, and reading a blank `peer_logical_id` as "no peer" silently drops
    a rule the author wrote.

    AND `0.0.0.0/0` IS A LEGAL, MEANINGFUL VALUE HERE, which is what makes the
    ambiguity load-bearing rather than theoretical."""
    var external = ingress_rule_from_cidr(
        String("203.0.113.0/24"), 443, String("tcp")
    )
    assert_equal(
        external._oneof0_case,
        2,
        "an external CIDR rule resolved as a graph peer (arm 1) instead of a"
        " CIDR (arm 2). A conformer would then look for a node named"
        " '203.0.113.0/24' in the graph, find none, and either refuse or — worse"
        " — compose no rule at all",
    )
    assert_true(Bool(external.peer_cidr), "the CIDR arm is SET")
    assert_false(
        Bool(external.peer_logical_id),
        "…and the graph-peer arm is NOT — a oneof with two arms set is a value"
        " the encoder cannot round-trip",
    )
    assert_equal(external.peer_cidr.value(), String("203.0.113.0/24"))

    var peer = ingress_rule_from_peer_node(
        String("edge-lb"), 8080, String("tcp")
    )
    assert_equal(
        peer._oneof0_case, 1, "a graph peer is arm 1 (`peer_logical_id`)"
    )
    assert_true(Bool(peer.peer_logical_id), "the graph-peer arm is SET")
    assert_false(Bool(peer.peer_cidr), "…and the CIDR arm is NOT")
    assert_equal(peer.peer_logical_id.value(), String("edge-lb"))

    # The non-oneof fields survive on BOTH shapes — they are emitted BEFORE the
    # discriminant in the generated struct, so a mis-ordered ctor lands here.
    assert_equal(Int(external.port), 443, "the CIDR rule's port round-trips")
    assert_equal(Int(peer.port), 8080, "the graph-peer rule's port round-trips")
    assert_equal(peer.protocol, String("tcp"), "…and its protocol")
    print("  test_a_cidr_peer_and_a_graph_peer_are_distinguishable: PASS")


# =============================================================================
# 4 — RETENTION ON A NETWORK IS AN ARGUMENT. Both answers are destructive.
# =============================================================================
def test_network_retention_is_stated_by_the_caller_not_defaulted() raises:
    """THE SECOND KIND IN THIS SCHEMA FOR WHICH RETENTION IS INPUT.

    `RESOURCE_KIND_MAIL_DOMAIN_IDENTITY` is the first, and the argument is the
    same one: the two answers fail in OPPOSITE directions, so there is no safe
    one to guess.

      * DELETE on an ADOPTED network -> a reverse walk tears down a VPC every
        other workload in the account is placed in. Against AWS that call
        SUCCEEDS if the VPC happens to be empty.
      * RETAIN_KEEP on one we CREATED -> a VPC, its subnets and its internet
        gateway leak forever, and a leak checker classifies that as LEFT-BEHIND
        rather than as a billing leak.

    This leg asserts the composer TRANSMITS the caller's answer rather than
    imposing one — it deliberately does NOT assert which answer is right for a
    given `adopt_existing_id`, because that is the conformer's refusal to make
    and enforcing it here would put a conformer's contract at the wrong
    altitude."""
    var adopted = network_node(
        String("env-a-network"),
        String("vpc-0a1b2c3d"),
        EgressMode.EGRESS_MODE_PUBLIC,
        0,
        Retention.RETENTION_RETAIN_KEEP,
    )
    assert_equal(
        adopted.retention.value,
        Retention.RETENTION_RETAIN_KEEP,
        "an ADOPTED network composed with RETENTION_DELETE — a reverse walk"
        " would delete a VPC this deployment did not create",
    )
    var created = network_node(
        String("tenant-net"),
        String(""),
        EgressMode.EGRESS_MODE_PUBLIC,
        2,
        Retention.RETENTION_DELETE,
    )
    assert_equal(
        created.retention.value,
        Retention.RETENTION_DELETE,
        "a CREATED network composed with RETAIN_KEEP would leak a VPC forever",
    )
    assert_equal(
        created.network.value().adopt_existing_id,
        String(""),
        "…and an EMPTY `adopt_existing_id` is the CREATE arm — the field is what"
        " the two lifecycles differ on",
    )
    print(
        "  test_network_retention_is_stated_by_the_caller_not_defaulted: PASS"
    )


# =============================================================================
# 5 — THE POLICY NAMES ITS NETWORK, and is app-owned.
# =============================================================================
def test_the_policy_names_its_network_and_is_app_owned() raises:
    """`network_logical_id` IS STATED, NOT INFERRED FROM `depends_on`.

    A security group is VPC-scoped and a GCP firewall rule is network-scoped, so
    the network is an INPUT to creating one — while `depends_on` is an ORDERING
    edge that may carry any number of unrelated predecessors. Reading the
    network off the edge list works only while there is exactly one network per
    environment, and picks an arbitrary one the day that stops being true. This
    leg pins the field so that the day it stops being true, nothing has to be
    re-derived.

    AND AN EMPTY RULE LIST IS COMPOSABLE. It means "no peer may reach this
    workload inbound", which is the correct posture for an egress-only worker
    and is NOT the same as having no policy node at all."""
    var empty = List[IngressRule]()
    var deps = List[String]()
    deps.append(String("env-a-network"))
    var p = ingress_policy_node(
        String("worker-ingress"),
        String("worker-svc"),
        String("env-a-network"),
        empty^,
        deps^,
    )
    assert_equal(
        p.ingress_policy.value().network_logical_id,
        String("env-a-network"),
        "the policy does not name the network it is scoped to. Without it a"
        " conformer has to guess a VpcId from the depends_on list, which is"
        " correct only while exactly one network exists per environment.",
    )
    assert_equal(
        len(p.ingress_policy.value().rules),
        0,
        "an EMPTY rule list survives composition — it is a fence that admits"
        " nobody, not an absent fence",
    )
    assert_equal(
        p.retention.value,
        Retention.RETENTION_DELETE,
        "an ingress policy is app-owned: it holds no data, is deterministically"
        " recreatable, and is created BY this graph FOR a workload this graph"
        " also creates. RETAIN_KEEP would leak one security group per workload"
        " per teardown, and AWS refuses to delete a VPC that still has any.",
    )
    print("  test_the_policy_names_its_network_and_is_app_owned: PASS")


# =============================================================================
# 6 — THE DEPLOY-GRAPH ALTITUDE IS ADOPT-ONLY, ON BOTH CLOUDS. The bootstrap
#     graph is the ONLY place a `RESOURCE_KIND_NETWORK` is CREATED; every
#     deploy-graph reference is a READ.
#
# THE SUBJECT IS NOT "the factory works". It is the ONE failure this rule
#    exists to make unreachable: **a VPC per bundle per deploy.** On GCP that is
#    one line away — an empty `adopt_existing_id` means `networks.insert` — so
#    the legs below assert the RENDERED BYTES per cloud, and §6c drives the gate
#    with a HAND-SUPPLIED wrong key so it is falsifiable independently of the
#    function that normally computes it.
# =============================================================================
def test_the_deploy_graph_network_node_adopts_on_gcp() raises:
    """FAILS ON A GCP ARM THAT RENDERS AN EMPTY ADOPT KEY — which is exactly the
    CREATE spelling."""
    var n = adopted_network_node(
        env_network_logical_id(),
        CLOUD_GCP,
        EgressMode.EGRESS_MODE_PUBLIC,
        1,
    )
    assert_equal(
        n.kind.value,
        ResourceKind.RESOURCE_KIND_NETWORK,
        "the deploy-graph node is kind 25 NETWORK",
    )
    assert_true(
        n.network.value().adopt_existing_id.byte_length() > 0,
        "THE DEPLOY-GRAPH GCP NODE RENDERED AN **EMPTY** `adopt_existing_id`,"
        " which on the GCP arm means CREATE (`networks.insert` +"
        " `subnetworks.insert`). Composed per bundle that is ONE VPC PER BUNDLE"
        " PER DEPLOY, in an environment whose network the BOOTSTRAP graph owns.",
    )
    assert_equal(
        n.network.value().adopt_existing_id,
        env_network_logical_id(),
        "…and it adopts the ENVIRONMENT's network BY NAME — the same id the"
        " bootstrap composition assigns. A different string here adopts a"
        " network nothing built, and the GCP network conformer's create then refuses"
        " by name rather than silently creating it.",
    )
    print("  test_the_deploy_graph_network_node_adopts_on_gcp: PASS")


def test_the_deploy_graph_network_node_adopts_the_default_vpc_on_aws() raises:
    """FAILS ON AN AWS ARM THAT RENDERS A NON-EMPTY KEY.

    THE ASSERTION IS THE OPPOSITE OF §6a's AND BOTH ARE 'ADOPT'. On AWS an
    EMPTY key IS the adopt-the-default-VPC statement, and it is the only target
    the AWS network conformer accepts (it REFUSES a NON-DEFAULT VPC under
    EGRESS_MODE_PUBLIC, the only implemented mode). A non-empty value here is a
    SERVER-ASSIGNED `vpc-…` id hardcoded into a composer."""
    var n = adopted_network_node(
        env_network_logical_id(),
        CLOUD_AWS,
        EgressMode.EGRESS_MODE_PUBLIC,
        0,
    )
    assert_equal(
        n.network.value().adopt_existing_id,
        String(""),
        "the AWS deploy-graph node must carry the EMPTY adopt key — the"
        " adopt-the-account's-DEFAULT-VPC statement. Any other value is either"
        " a hardcoded server-assigned id or one the arm refuses at apply.",
    )
    assert_equal(
        Int(n.network.value().zone_count),
        0,
        "`zone_count` round-trips, and 0 means EVERY zone rather than none —"
        " the schema's stated semantics on both arms",
    )
    print(
        "  test_the_deploy_graph_network_node_adopts_the_default_vpc_on_aws:"
        " PASS"
    )


def test_the_adopt_only_gate_refuses_a_create_spelling_on_either_cloud() raises:
    """THE GATE, DRIVEN WITH HAND-SUPPLIED KEYS.

    §6a/§6b can only ever agree with the function that computes the key. This
    leg calls the gate DIRECTLY with the wrong bytes for each cloud, so a mutant
    that deletes either refusal goes red HERE even though the renderer is still
    correct. Without it the gate is unfalsifiable and could be removed with
    nothing going red."""
    var gcp_create_refused = False
    try:
        refuse_unless_deploy_graph_network_adopts(CLOUD_GCP, String(""))
    except e:
        gcp_create_refused = True
    assert_true(
        gcp_create_refused,
        "AN EMPTY ADOPT KEY ON CLOUD_GCP WAS ACCEPTED. That is the CREATE"
        " spelling; accepting it at the deploy-graph altitude is the"
        " VPC-per-bundle-per-deploy defect with no diagnostic.",
    )
    var aws_hardcoded_refused = False
    try:
        refuse_unless_deploy_graph_network_adopts(
            CLOUD_AWS, String("vpc-0a1b2c3d")
        )
    except e:
        aws_hardcoded_refused = True
    assert_true(
        aws_hardcoded_refused,
        "A SERVER-ASSIGNED VPC ID ON CLOUD_AWS WAS ACCEPTED. `read` refuses"
        " every NON-DEFAULT VPC under the only implemented egress mode, so the"
        " value is either unreachable or an account's id baked into a composer.",
    )
    # …and the two CORRECT spellings pass, so the gate is not simply "refuse
    # everything" — a gate with no accepting case reds honestly and gates
    # nothing.
    refuse_unless_deploy_graph_network_adopts(CLOUD_GCP, String("some-net"))
    refuse_unless_deploy_graph_network_adopts(CLOUD_AWS, String(""))
    print(
        "  test_the_adopt_only_gate_refuses_a_create_spelling_on_either_cloud:"
        " PASS"
    )


def test_the_deploy_graph_node_is_retain_keep_and_not_authorable() raises:
    """FAILS ON A DEPLOY-GRAPH NODE COMPOSED RETENTION_DELETE.

    THE SISTER LEG §4 ASSERTS THE OPPOSITE PROPERTY FOR `network_node` — that
    retention is the CALLER's to state — and both are right at their own
    altitude. `network_node` serves the bootstrap composer, which genuinely
    chooses; this factory serves a DEPLOY graph, where the node always adopts, so
    RETENTION_DELETE would tear the environment's network down on ONE bundle's
    ordinary teardown. An argument here would be a way to get that wrong."""
    var gcp = adopted_network_node(
        env_network_logical_id(), CLOUD_GCP, EgressMode.EGRESS_MODE_PUBLIC, 1
    )
    assert_equal(
        gcp.retention.value,
        Retention.RETENTION_RETAIN_KEEP,
        "a deploy-graph network node must be RETAIN_KEEP. On GCP"
        " the GCP node factory THREADS this ordinal into the conformer, so"
        " RETENTION_DELETE here is one bundle's teardown deleting the network"
        " every other workload in the environment is placed in.",
    )
    var aws = adopted_network_node(
        env_network_logical_id(), CLOUD_AWS, EgressMode.EGRESS_MODE_PUBLIC, 0
    )
    assert_equal(
        aws.retention.value,
        Retention.RETENTION_RETAIN_KEEP,
        "…and the same on AWS. The AWS conformer overrides it with"
        " RETAIN_UNDELETABLE as a CAPABILITY, so this value is passed and"
        " unused there — asserted anyway, because a node that says DELETE and"
        " is saved by a conformer is one conformer change from being true.",
    )
    print(
        "  test_the_deploy_graph_node_is_retain_keep_and_not_authorable: PASS"
    )


def test_an_unadjudicated_cloud_is_refused_rather_than_guessed() raises:
    """FAILS ON A FACTORY THAT DEFAULTS AN UNKNOWN CLOUD TO EITHER ARM.

    CLOUD_LOCAL (5) is the GCP posture over EMULATORS. Rendering GCP's answer
    there produces a node whose apply reaches the real
    `compute.googleapis.com` from a run that believed it was offline; rendering
    AWS's produces a node that adopts a VPC in an account the run has no
    credentials for. Neither is a safe guess, so there is none."""
    var refused = False
    try:
        _ = adopted_network_node(
            env_network_logical_id(),
            5,  # CLOUD_LOCAL — deliberately a literal: this file mirrors only
            # the two ordinals the factory adjudicates, and naming the third
            # would imply it is supported.
            EgressMode.EGRESS_MODE_PUBLIC,
            1,
        )
    except e:
        refused = True
    assert_true(
        refused,
        "an unadjudicated cloud composed a network node. There is no third"
        " spelling of ADOPT to guess — kind 25 has a conformer on exactly two"
        " clouds.",
    )
    var empty_id_refused = False
    try:
        _ = adopted_network_node(
            String(""), CLOUD_AWS, EgressMode.EGRESS_MODE_PUBLIC, 0
        )
    except e:
        empty_id_refused = True
    assert_true(
        empty_id_refused,
        "an EMPTY logical id composed a network node. It is the key a deferred"
        " placement resolves against, so an empty one defers the subnets to"
        " nothing and surfaces at the CONSUMER as a missing accumulator row.",
    )
    print("  test_an_unadjudicated_cloud_is_refused_rather_than_guessed: PASS")


def main() raises:
    print("test_compose_network_nodes: kinds 25 / 26, oneof arms 21 / 22")
    test_the_network_node_sits_on_arm_21_and_round_trips()
    test_the_ingress_policy_node_sits_on_arm_22_and_round_trips()
    test_a_cidr_peer_and_a_graph_peer_are_distinguishable()
    test_network_retention_is_stated_by_the_caller_not_defaulted()
    test_the_policy_names_its_network_and_is_app_owned()
    test_the_deploy_graph_network_node_adopts_on_gcp()
    test_the_deploy_graph_network_node_adopts_the_default_vpc_on_aws()
    test_the_adopt_only_gate_refuses_a_create_spelling_on_either_cloud()
    test_the_deploy_graph_node_is_retain_keep_and_not_authorable()
    test_an_unadjudicated_cloud_is_refused_rather_than_guessed()
    print("test_compose_network_nodes: ALL PASS")
