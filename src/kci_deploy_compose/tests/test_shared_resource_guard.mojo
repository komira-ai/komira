# =============================================================================
# kci_deploy_compose/tests/test_shared_resource_guard.mojo
#   THE OWNERSHIP GATE: a per-app teardown may not reap a project-global
#   resource every other app depends on.
# =============================================================================
#
# `compose_api` composes the project-global API-Gateway backend-auth service
# account into EVERY edge-bearing app's OWN graph. Were it `RETENTION_DELETE`,
# deleting one app would delete the service account every other app's front
# door impersonates — and restoring it would not restore the system: the
# undelete mints a NEW uid and every policy that named the old one holds a stale
# `deleted:serviceAccount:…?uid=…` member.
#
# WHAT EACH SECTION FALSIFIES.
#   §A THE HAZARD     — the composition really does emit that node (assert the
#      premise, so nothing here can pass for the wrong reason), and it is
#      RETAIN_KEEP, so an ordinary `delete` skips it.
#   §B RETENTION IS NOT A FLOOR — `--delete-data` (and `--run-id`, which routes
#      through the same `force_delete_data` switch) LIFTS the RETAIN_KEEP skip.
#      This is why a retention alone is not a fix.
#   §C THE DISCRIMINATOR — a grant with ONE end in this graph is NOT a finding
#      (unbinding a `<svc>-role` member that is being deleted anyway takes
#      nothing from anyone); a grant with NEITHER end in this graph IS. Getting
#      this wrong in either direction makes the guard useless: noisy one way,
#      blind the other.
#   §D THE REFUSAL NAMES BOTH — the resource AND the sibling release machine
#      that depends on it, which is the whole requirement.
#   §E FAIL-CLOSED — an unknown `ResourceKind` RAISES rather than answering
#      "creates nothing"; an UNREADABLE sibling refuses rather than reading as
#      "nobody depends on this".
#   §F NOT BLOCKED — an ordinary `kci delete` of a real edge bundle, with real
#      siblings, returns NO refusal. A guard that refuses everything is a guard
#      somebody deletes.
#   §G THE SWEEP — `shared_resource_findings` over a REAL composition is the
#      project-global inventory, and it is DERIVED (never a list of node ids).
#
# Pure struct construction + pure functions — no store, no cloud, no
# UnsafePointer.
# =============================================================================
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from kci_deploy_compose.compose_api import (
    compose_api,
    EDGE_GATEWAY_SA_ACCOUNT_ID,
    DEPLOY_PRINCIPAL,
)
# THE PRODUCTION GRANT-SCOPE DERIVATION, used to build this file's grant
# FIXTURES so they cannot drift away from what a real compose emits.
from kci_deploy_compose.grant_scope import grant_scope_for

from kci_deploy_compose.shared_resource_guard import (
    SharedResourceFinding,
    SiblingGraph,
    created_identities,
    finding_resource_label,
    shared_resource_findings,
    shared_resource_refusal,
    sibling_graph_of,
    unreadable_sibling,
)

from full_manifest_rpc.full_manifest import (
    Capability,
    FullManifest,
    GrantSpec,
    GrantScope,
    ResourceNode,
    ResourceKind,
    Retention,
    FederatedAssumePrincipal,
    InAccountAssumePrincipal,
    ServiceAccountSpec,
)

from komira_rpc_bundle.app_bundle import (
    # `AppSpec.name_scope` (field 37) — UNSPECIFIED here: the authored name IS
    # the service name.
    NameScope,
    # The authoring-tier collection shape (`AppSpec.datastore_collections`,
    # field 35). Named here only to spell the EMPTY list this construction
    # passes.
    CloudVariant,
    DatastoreCollection,
    AppParameter,
    JobSpec,
    CronSpec,
    EphemeralScope,
    Matrix,
    DeployOutput,
    AppBundle,
    Tenancy,  # field 15 (tenancy): kci composes none; see `_bundle`
    AppKind,
    BuildTarget,
    ImageRef,
    BundleEnvVar,
    Scaling,
    AppSpec,
    BucketSpec,
    Wave,
    WebFrontendOverride,
    ValidateStep,
    TriggerSource,
    ServiceSpec,
    ValidationSet,
    Pipeline,
    SecuredInboundRoute,
    WebRouteRule,
)
from komira_rpc_bundle.deploy_model import (
    BundleIndexTable,
    InboundNeed,
    NetworkIngress,
    ComputeIntent,
    DatastoreNeed,
    SecretBinding,
)

# A standing secret neither end of which any app graph creates — the shape a
# shared secret read by every app's validate job has.
comptime _SHARED_SECRET: String = "shared-secret-a"


# =============================================================================
# FIXTURES — a minimal, real API bundle, built the way `test_run_scope.mojo`
# builds its own: ONE place, so an edge fixture differs from a plain one by
# exactly the field that causes the edge and nothing else.
# =============================================================================
def _spec(inbound: Int = 0) raises -> AppSpec:
    return AppSpec(
        Optional[ImageRef](
            ImageRef(1, Optional[String](String("sha256:cafe")), None)
        ),
        Int32(8080),
        List[BundleEnvVar](),
        Optional[Scaling](Scaling(Int32(0), Int32(1))),
        ComputeIntent(ComputeIntent.COMPUTE_INTENT_SERVERLESS),
        DatastoreNeed(DatastoreNeed.DATASTORE_NEED_UNSPECIFIED),
        List[SecretBinding](),
        String(""),  # runtime_identity
        String(""),  # supervisor_child_health_path
        Int32(0),  # supervisor_child_health_port
        String(""),  # supervisor_cpu
        String(""),  # supervisor_memory
        String(""),  # web_slug
        String(""),  # web_domain
        List[String](),  # web_additional_domains
        List[String](),  # web_api_path_prefixes
        String(""),  # web_api_service_logical_id
        InboundNeed(inbound),  # inbound
        String(""),  # inbound_route_path
        List[BucketSpec](),  # buckets
        List[Int32](),  # runtime_extra_capabilities
        List[WebRouteRule](),  # web_route_rules
        String(""),  # region
        False,  # public_invoker
        None,  # keep_last_n
        List[SecuredInboundRoute](),  # secured_inbound_routes
        String(""),  # datastore_database
        String(""),  # datastore_database_ref
        List[BundleIndexTable](),  # index_tables
        None,  # ingress
        List[AppParameter](),  # parameters
        NetworkIngress(0),  # network_ingress
        # OUTBOUND PATH (field 33) — ABSENT: no vpc_access is rendered, so the
        # revision egresses over the public internet.
        None,
        None,  # mail_transport (field 34) — absent = no mail-transport nodes
        # THE COLLECTION SHAPES (field 35) — EMPTY: this construction authors
        # no collection (a `repeated` field writes nothing when empty).
        List[DatastoreCollection](),
        # THE PER-CLOUD SPEC VARIANTS (field 36) — EMPTY: NO variant is
        # selected on any cloud and the spec-level declarations stand.
        List[CloudVariant](),
        # THE NAME SCOPE (field 37) — UNSPECIFIED: the authored `name` IS this
        # service's name.
        NameScope(NameScope.NAME_SCOPE_UNSPECIFIED),
        # THE APP'S DECLARED COMPUTE ALLOCATION (fields 38-39) — ABSENT: the
        # composed node carries an UNSET cpu/memory. None here is NOT a default
        # — it is the honest "the bundle said nothing".
        None,  # cpu (field 38)
        None,  # memory (field 39)

        # THE APP'S HEALTHCHECK ENDPOINT (field 40) — ABSENT: the composed node
        # carries an UNSET health_check_path and the resource is NOT_GATED.
        None,  # health_check_path (field 40)
    )


def _bundle(
    var name: String, var spec: AppSpec, var waves: List[Wave]
) raises -> AppBundle:
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        name^,
        List[BuildTarget](),
        Optional[AppSpec](spec^),
        waves^,
        List[TriggerSource](),
        List[ServiceSpec](),
        List[ValidationSet](),
        Optional[Pipeline](),
        List[Matrix](),
        List[DeployOutput](),
        List[JobSpec](),
        List[CronSpec](),
        Optional[EphemeralScope](),
        Tenancy(Tenancy.TENANCY_UNSPECIFIED),  # field 15 (tenancy): kci composes none
    )


def _edge_bundle(var name: String) raises -> AppBundle:
    """A bundle whose `env-a` wave has `api_edge_enabled`, with a CLIENT-inbound
    service — the exact shape that composes the shared gateway SA."""
    var waves = List[Wave]()
    waves.append(
        Wave(
            String("env-a"),
            List[ValidateStep](),
            True,  # api_edge_enabled
            List[BundleEnvVar](),
            List[AppParameter](),
            String(""),  # peer_identity_issuer (6)
            String(""),  # developer_access_principal (7)
            Optional[WebFrontendOverride](),  # web_override (8)
            List[String](),  # api_edge_services (9) — EMPTY
        )
    )
    return _bundle(
        name^, _spec(inbound=InboundNeed.INBOUND_NEED_CLIENT), waves^
    )


def _grant_node(
    var logical_id: String,
    var principal: String,
    var target: String,
    retention: Int,
) raises -> ResourceNode:
    """A hand-built GRANT node — the ONLY hand-built shape in this file, and it
    exists so §C can vary the two ends independently. Everything else composes."""
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_GRANT),
        List[String](),
        Retention(retention),
        17,
        None, None, None, None, None, None, None, None, None, None,
        None, None, None, None, None, None,  # arms 1-16
        Optional[GrantSpec](
            GrantSpec(
                principal^,
                Capability(Capability.CAPABILITY_READ_SECRET),
                target.copy(),
                # ⭐ field 4 `scope`, through the PRODUCTION derivation.
                Optional[GrantScope](
                    grant_scope_for(Capability.CAPABILITY_READ_SECRET, target)
                ),
            )
        ),  # arm 17 (grant)
        None, None, None,  # arms 18-20
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _sa_node(var logical_id: String, var account_id: String) raises -> ResourceNode:
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
        List[String](),
        Retention(Retention.RETENTION_DELETE),
        11,
        None, None, None, None, None, None, None, None, None, None,
        Optional[ServiceAccountSpec](
            ServiceAccountSpec(
                account_id^,
                String("fixture"),
                False,
                False,
                List[FederatedAssumePrincipal](),
                List[InAccountAssumePrincipal](),
            )
        ),
        None, None, None, None, None, None, None, None,
        None,
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def _one_edge_sibling() raises -> List[SiblingGraph]:
    """The sibling corpus used by every section that needs one: ONE other
    edge-bearing release machine, composed for real.

    EXCLUSIVITY IS A CROSS-GRAPH FACT, so a hazard cannot be observed without a
    sibling. Handing `shared_resource_findings` an empty list is a claim that
    nothing else in the environment declares anything, which is true only for the
    last machine out — §D2 pins exactly that reading."""
    var out = List[SiblingGraph]()
    out.append(
        sibling_graph_of(
            String("app-b"),
            compose_api(_edge_bundle(String("app-b")), String("env-a")),
        )
    )
    return out^


def _finding_for(
    findings: List[SharedResourceFinding], logical_id: String
) -> Int:
    for i in range(len(findings)):
        if findings[i].logical_id == logical_id:
            return i
    return -1


# =============================================================================
# §A — THE HAZARD. The premise, then the retention, then the actAs grant.
# =============================================================================
def test_A1_the_edge_composition_really_emits_the_shared_gateway_sa() raises:
    # Assert the PREMISE. If the edge composition stops emitting this node, every
    # other assertion in this file would pass vacuously.
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var found = False
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value != ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT:
            continue
        if not m.nodes[i].service_account:
            continue
        if m.nodes[i].service_account.value().account_id == String(
            EDGE_GATEWAY_SA_ACCOUNT_ID
        ):
            found = True
    assert_true(
        found,
        "an `inbound: CLIENT` service on an api-edge-enabled wave composes the"
        " PROJECT-GLOBAL gateway backend-auth SA into THIS app's graph",
    )


def test_A2_the_shared_gateway_sa_is_retain_keep() raises:
    # Under `RETENTION_DELETE`, `kci delete <any-edge-app>` would remove the SA
    # every OTHER edge app's front door impersonates.
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var checked = False
    for i in range(len(m.nodes)):
        if m.nodes[i].logical_id != String("edge-gateway-sa"):
            continue
        checked = True
        assert_equal(
            m.nodes[i].retention.value,
            Retention.RETENTION_RETAIN_KEEP,
            "the project-global gateway SA is RETAIN_KEEP — a resource N graphs"
            " CREATE and 1 graph DELETES is owned by none of them",
        )
    assert_true(checked, "the node id `edge-gateway-sa` is the one under test")


def test_A3_the_gateway_actas_grant_is_retain_keep() raises:
    # Its sibling grant has BOTH ends foreign: the deploy principal is
    # bootstrap's, the target is the SA above. Unbinding it makes the NEXT edge
    # deploy of ANY OTHER app fail `CreateApiConfig` FAILED_PRECONDITION — the
    # exact failure this pair of nodes is here to prevent.
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var checked = False
    for i in range(len(m.nodes)):
        if m.nodes[i].logical_id != String(
            "edge-gateway-sa-deploy-sa-user-grant"
        ):
            continue
        checked = True
        assert_equal(
            m.nodes[i].retention.value,
            Retention.RETENTION_RETAIN_KEEP,
            "the deploy-caller actAs binding on the shared gateway SA survives a"
            " per-app teardown",
        )
    assert_true(checked, "the actAs grant node is present")


def test_A4_an_ordinary_delete_reaps_nothing_shared() raises:
    # The retention half, EXPRESSED AS THE GUARD SEES IT: with no
    # `--delete-data`, nothing foreign is reachable.
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var reaped = 0
    for ref f in shared_resource_findings(m, _one_edge_sibling(), False):
        if f.reaped:
            reaped += 1
    assert_equal(
        reaped,
        0,
        "an ordinary `kci delete` of an edge app reaches NO resource the"
        " app's graph does not own",
    )


# =============================================================================
# §B — RETENTION IS NOT A FLOOR. `--delete-data` lifts the skip.
# =============================================================================
def test_B_delete_data_lifts_the_skip_and_the_guard_still_sees_it() raises:
    # THIS IS WHY THE RETENTION ALONE IS NOT A FIX. `--delete-data` (and
    # `--run-id`, via `run_scope_lifts_retention`) sets `force_delete_data`,
    # which lifts RETAIN_KEEP project-wide. The SA is reachable again — and the
    # guard is what still says so.
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var fs = shared_resource_findings(m, _one_edge_sibling(), True)
    var idx = _finding_for(fs, String("edge-gateway-sa-deploy-sa-user-grant"))
    assert_true(
        idx >= 0,
        "under --delete-data the shared gateway actAs binding is a REACHABLE"
        " foreign-addressed node",
    )
    assert_true(fs[idx].reaped, "and the guard reports it as reaped")
    assert_equal(
        fs[idx].resource,
        String(EDGE_GATEWAY_SA_ACCOUNT_ID),
        "named by the resource, not by the node id",
    )
    # AND THE CREATE NODE ITSELF — the one the reverse walk would delete. A
    # guard that asked only "does this graph create the SA?" would get YES
    # (every edge-bearing graph does) and could not produce this row; ownership
    # has to be EXCLUSIVE ownership for this assertion to pass.
    var sa_idx = _finding_for(fs, String("edge-gateway-sa"))
    assert_true(
        sa_idx >= 0,
        "the project-global gateway SA CREATE node is a hazard: N graphs create"
        " it, so no single graph may delete it",
    )
    assert_true(fs[sa_idx].reaped, "and --delete-data reaches it")


# =============================================================================
# §C — THE DISCRIMINATOR. One end ours -> not a finding. Neither -> a finding.
# =============================================================================
def test_C1_a_grant_whose_principal_this_graph_creates_is_not_a_finding() raises:
    # `<svc>-role` reading a STANDING shared secret. The target is foreign, but
    # the MEMBER is deleted in the same reverse walk, so unbinding it removes
    # nothing anyone else holds. Reporting this would make the guard refuse every
    # ordinary teardown — noisy to the point of being switched off.
    var nodes = List[ResourceNode]()
    nodes.append(_sa_node(String("canary-role-sa"), String("canary-role")))
    nodes.append(
        _grant_node(
            String("canary-role-access-secret-grant"),
            String("canary-role"),
            String(_SHARED_SECRET),
            Retention.RETENTION_DELETE,
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var fs = shared_resource_findings(m, List[SiblingGraph](), False)
    assert_equal(
        len(fs),
        0,
        "a binding with ONE end in this graph belongs to this graph",
    )


def test_C2_a_grant_with_neither_end_in_this_graph_is_a_finding() raises:
    # The deploy principal reading a STANDING shared secret: NEITHER end is in
    # this graph. Every app composes this identical node, so whichever app is
    # deleted first unbinds the authority all the others' validate jobs run on.
    var nodes = List[ResourceNode]()
    nodes.append(_sa_node(String("canary-role-sa"), String("canary-role")))
    nodes.append(
        _grant_node(
            String("deploy-principal-reads-shared-secret"),
            String(DEPLOY_PRINCIPAL),
            String(_SHARED_SECRET),
            Retention.RETENTION_DELETE,
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var fs = shared_resource_findings(m, List[SiblingGraph](), False)
    assert_equal(len(fs), 1, "a binding with NEITHER end in this graph is foreign")
    assert_equal(fs[0].resource, String(_SHARED_SECRET))
    assert_equal(fs[0].principal, String(DEPLOY_PRINCIPAL))
    assert_true(
        fs[0].reaped, "and RETENTION_DELETE means the reverse walk reaches it"
    )


def test_C3_a_project_scoped_binding_reads_as_the_project() raises:
    # An EMPTY grant target is `projects/<P>` — the most-shared resource there
    # is. Printing `''` would read as a bug rather than as the project, and the
    # sharing is invisible in the node id: `<bundle>-validator-datastore-read-
    # grant` is keyed on the BUNDLE, while the binding it produces is one single
    # `(projects/<P>, deploy principal, roles/datastore.viewer)` triple.
    var nodes = List[ResourceNode]()
    nodes.append(
        _grant_node(
            String("appA-validator-datastore-read-grant"),
            String(DEPLOY_PRINCIPAL),
            String(""),
            Retention.RETENTION_DELETE,
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var fs = shared_resource_findings(m, List[SiblingGraph](), False)
    assert_equal(len(fs), 1)
    assert_equal(
        finding_resource_label(fs[0]),
        String("<the project itself>"),
        "an empty target renders as the project, never as an empty string",
    )


# =============================================================================
# §D — THE REFUSAL NAMES BOTH.
# =============================================================================
def test_D_the_refusal_names_the_resource_and_the_sibling() raises:
    var victim = compose_api(_edge_bundle(String("canary")), String("env-a"))
    # The SIBLING: another edge-bearing machine, whose graph also creates the
    # shared gateway SA.
    var sib_m = compose_api(_edge_bundle(String("app-b")), String("env-a"))
    var siblings = List[SiblingGraph]()
    siblings.append(sibling_graph_of(String("app-b"), sib_m))

    var why = shared_resource_refusal(
        String("canary"), victim, siblings, True  # --delete-data
    )
    assert_true(why.byte_length() > 0, "the teardown is REFUSED")
    assert_true(
        why.__contains__(String(EDGE_GATEWAY_SA_ACCOUNT_ID)),
        "the refusal names the RESOURCE",
    )
    assert_true(
        why.__contains__(String("app-b")),
        "the refusal names the OTHER app that depends on it — 'naming both' is"
        " the requirement, because an operator who is not told who else needs"
        " the resource cannot act on the refusal",
    )
    assert_true(
        why.__contains__(String("canary")), "and the app being torn down"
    )


def test_D2_no_sibling_means_no_refusal() raises:
    # The LAST app out may take the shared resource with it. A refusal that
    # persisted after every dependent was gone would make the resource
    # permanently unreapable, which is the leak the run-scope module refuses to
    # create in the other direction.
    var victim = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var why = shared_resource_refusal(
        String("canary"), victim, List[SiblingGraph](), True
    )
    assert_equal(
        why,
        String(""),
        "with no sibling declaring the resource, --delete-data may reap it",
    )


# =============================================================================
# §E — FAIL-CLOSED, both ways.
# =============================================================================
def test_E1_an_unknown_resource_kind_raises() raises:
    # A default arm answering "creates nothing" would make a NEW resource kind
    # invisible to this guard — and invisible here means reapable by a graph that
    # does not own it.
    var nodes = List[ResourceNode]()
    nodes.append(
        ResourceNode(
            String("mystery"),
            ResourceKind(99),
            List[String](),
            Retention(Retention.RETENTION_DELETE),
            0,
            None, None, None, None, None, None, None, None, None, None,
            None, None, None, None, None, None, None, None, None,
            None,
            None, None,  # arms 21-22 (network, ingress_policy)
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var raised = False
    try:
        _ = shared_resource_findings(m, List[SiblingGraph](), False)
    except:
        raised = True
    assert_true(
        raised,
        "an unknown ResourceKind REFUSES rather than being treated as creating"
        " nothing",
    )


def test_E2_an_unreadable_sibling_refuses_when_something_is_reaped() raises:
    # "I could not read that bundle" and "no bundle depends on this" must not be
    # the same answer when the second one licenses a delete.
    var victim = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var siblings = List[SiblingGraph]()
    siblings.append(
        unreadable_sibling(String("app-c"), String("parse error at line 4"))
    )
    var why = shared_resource_refusal(
        String("canary"), victim, siblings, True  # --delete-data: foreign reached
    )
    assert_true(
        why.byte_length() > 0,
        "with something foreign being reaped, an unreadable sibling refuses: the"
        " question cannot be answered, so it may not be answered 'no'",
    )
    assert_true(
        why.__contains__(String("app-c")),
        "and the refusal names WHICH bundle it could not read",
    )


def test_E3_an_unreadable_sibling_does_NOT_refuse_an_ordinary_delete() raises:
    # THE ORDER IS LOAD-BEARING. One unparseable bundle anywhere in the corpus
    # would, under an unconditional unreadable-sibling refusal, make EVERY
    # `kci delete` refuse over a bundle that has nothing to do with the resource
    # being reaped.
    #
    # "I could not read that bundle" only licenses a delete when the answer would
    # have changed the decision. When nothing foreign is reached, there is no
    # decision for it to change.
    var victim = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var siblings = List[SiblingGraph]()
    siblings.append(
        unreadable_sibling(
            String("app-d"), String("bundle: at least one wave is required")
        )
    )
    assert_equal(
        shared_resource_refusal(String("canary"), victim, siblings, False),
        String(""),
        "an unreadable sibling does NOT block an ordinary teardown that reaps"
        " nothing foreign — a guard that blocks the operation it exists to make"
        " safe is a guard somebody deletes, and then nothing guards anything",
    )


# =============================================================================
# §F — NOT BLOCKED. The ordinary path stays open.
# =============================================================================
def test_F_an_ordinary_delete_with_real_siblings_is_not_refused() raises:
    # A guard that refuses every teardown is a guard somebody deletes. With the
    # retention in place, an ordinary `kci delete` reaches nothing foreign, so
    # the refusal is EMPTY even with a sibling that shares the SA.
    var victim = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var sib_m = compose_api(_edge_bundle(String("app-b")), String("env-a"))
    var siblings = List[SiblingGraph]()
    siblings.append(sibling_graph_of(String("app-b"), sib_m))
    assert_equal(
        shared_resource_refusal(String("canary"), victim, siblings, False),
        String(""),
        "an ordinary teardown is not blocked by this guard",
    )


# =============================================================================
# §G — THE SWEEP, over a REAL composition.
# =============================================================================
def test_G1_created_identities_holds_the_apps_own_resources() raises:
    var m = compose_api(_edge_bundle(String("canary")), String("env-a"))
    var ids = created_identities(m)
    var has_svc = False
    var has_gw = False
    for i in range(len(ids)):
        if ids[i] == String("canary-svc"):
            has_svc = True
        if ids[i] == String(EDGE_GATEWAY_SA_ACCOUNT_ID):
            has_gw = True
    assert_true(has_svc, "the app's own Cloud Run service is an owned identity")
    # THE GATEWAY SA *IS* IN THE CREATED SET, AND THAT IS CORRECT AND SUBTLE.
    # This graph really does create it (get-or-create); what it does not have is
    # EXCLUSIVE ownership. That is why the answer is a retention on the create
    # node plus a cross-bundle refusal — not an "is it in my created set" test,
    # which would answer yes and miss the whole hazard.
    assert_true(
        has_gw,
        "the shared SA is created BY this graph too — N creators is fine; it is"
        " the single deleter that is wrong",
    )


def test_G2_the_sweep_is_derived_not_a_list() raises:
    # The inventory changes with the BUNDLE, with no edit here: a bundle with no
    # edge composes no gateway SA and no actAs grant, so those rows vanish. A
    # hand-written list of shared node ids could not do that, and would go stale
    # the day somebody adds the next project-global node.
    var plain = compose_api(
        _bundle(String("canary"), _spec(), List[Wave]()), String("env-a")
    )
    var fs = shared_resource_findings(plain, _one_edge_sibling(), True)
    assert_equal(
        _finding_for(fs, String("edge-gateway-sa-deploy-sa-user-grant")),
        -1,
        "a bundle with no edge has no gateway rows — the sweep is derived from"
        " the graph, not from a list",
    )


def main() raises:
    test_A1_the_edge_composition_really_emits_the_shared_gateway_sa()
    test_A2_the_shared_gateway_sa_is_retain_keep()
    test_A3_the_gateway_actas_grant_is_retain_keep()
    test_A4_an_ordinary_delete_reaps_nothing_shared()
    test_B_delete_data_lifts_the_skip_and_the_guard_still_sees_it()
    test_C1_a_grant_whose_principal_this_graph_creates_is_not_a_finding()
    test_C2_a_grant_with_neither_end_in_this_graph_is_a_finding()
    test_C3_a_project_scoped_binding_reads_as_the_project()
    test_D_the_refusal_names_the_resource_and_the_sibling()
    test_D2_no_sibling_means_no_refusal()
    test_E1_an_unknown_resource_kind_raises()
    test_E2_an_unreadable_sibling_refuses_when_something_is_reaped()
    test_E3_an_unreadable_sibling_does_NOT_refuse_an_ordinary_delete()
    test_F_an_ordinary_delete_with_real_siblings_is_not_refused()
    test_G1_created_identities_holds_the_apps_own_resources()
    test_G2_the_sweep_is_derived_not_a_list()
    print("OK test_shared_resource_guard")
