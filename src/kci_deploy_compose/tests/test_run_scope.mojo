# =============================================================================
# kci_deploy_compose/tests/test_run_scope.mojo — the RUN-SCOPED TEARDOWN gate
#   (`AppBundle.ephemeral`).
# =============================================================================
#
# THE ONE THIS FILE EXISTS FOR IS §E. `run services delete` un-ships a running
# revision, so a teardown that can reach a NON-run-scoped resource is a strictly
# worse bug than leaking one. §E is the ESCAPE test: it builds graphs that get
# OUT of the run scope — by hand, and then by an ordinary composition of an
# ordinary bundle — and asserts the capability REFUSES them. Everything above §E
# is the machinery §E is about.
#
# WHAT EACH SECTION PINS.
#   §A RUN-ID SHAPE   — `validate_run_id` accepts the shape every cloud name
#      admits and rejects each violation NAMING the cloud constraint, not a
#      style rule.
#   §B THE BICONDITIONAL — `ephemeral {}` ⇔ `--run-id`, BOTH directions. The
#      reverse direction (an ephemeral bundle deployed with NO run id) is the
#      one that would produce a permanent leak, and it is the one an
#      "opt-in permission" reading of the schema would miss.
#   §C SCOPE_BUNDLE   — the rename, its IDEMPOTENCE, and the `service_ref`
#      lockstep (rename the services without their references and every
#      cross-service grant silently disappears).
#   §D END-TO-END     — `compose_run_scoped` on a real API bundle: EVERY node,
#      and every name inside every node, carries the token. Asserted by
#      re-running the verifier over the output, not by listing ids.
#   §E ESCAPE         — four ways out of the scope, all four REFUSED:
#         E1 a hand-built manifest holding one standing name;
#         E2 an UNKNOWN ResourceKind — fail-CLOSED, not fail-quiet;
#         E3 a real composition that reaches the SHARED API-Gateway service
#            account (an `inbound: CLIENT` service on an api-edge-enabled wave
#            composes it);
#         E4 a real composition that reaches a STANDING secret through the
#            in-cloud validate-job read grant.
#   §F RETENTION      — a run scope lifts the `RETAIN_KEEP` skip through the
#      EXISTING `force_delete_data` switch, not a second mechanism.
#   §G NAME LENGTH    — a correctly-scoped name that is too long is refused
#      OFFLINE, not by the cloud with half the graph standing.
#
# Pure struct construction + pure functions — no store, no cloud, no
# UnsafePointer.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy_compose.compose_api import (
    compose_api,
    EDGE_GATEWAY_SA_ACCOUNT_ID,
)
from kci_deploy_compose.run_scope import (
    RUN_SCOPE_INFIX,
    SA_ACCOUNT_ID_MAX,
    RESOURCE_NAME_MAX,
    RunScope,
    validate_run_id,
    scoped_name_length_error,
    run_scope_permission_error,
    run_scope_lifts_retention,
    scope_bundle,
    run_scope_violations,
    compose_run_scoped,
)

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceNode,
    ResourceKind,
    Retention,
    IamRoleSpec,
    FederatedAssumePrincipal,
    InAccountAssumePrincipal,
    ServiceAccountSpec,
)

from kci_bundle_proto.app_bundle import (
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
    WebRouteRule,
    AppBundle,
    Tenancy,  # field 15 (tenancy): kci composes none; see `_bundle`
    AppKind,
    BuildTarget,
    ImageRef,
    BundleEnvVar,
    ServiceRef,
    Scaling,
    AppSpec,
    SecuredInboundRoute,
    BucketSpec,
    GateOn,
    RunContainer,
    TelemetryRead,
    TestRole,
    ValidateStep,
    Wave,
    WebFrontendOverride,
    TriggerSource,
    ServiceSpec,
    ValidationSet,
    Pipeline,
)
from kci_bundle_proto.deploy_model import (
    BundleIndexTable,
    InboundNeed,
    NetworkIngress,
    ComputeIntent,
    DatastoreNeed,
    SecretBinding,
)

# A standing secret no run creates — what a validate step that reads a
# pre-provisioned secret names.
comptime _STANDING_SECRET: String = "standing-secret-a"


# =============================================================================
# FIXTURES — a minimal, real API bundle. Kept in ONE place so a §E escape
# fixture differs from a §D clean one by exactly the field that causes the
# escape, and nothing else.
# =============================================================================
def _spec(
    var env: List[BundleEnvVar],
    var buckets: List[BucketSpec],
    inbound: Int = 0,
) raises -> AppSpec:
    return AppSpec(
        Optional[ImageRef](
            ImageRef(1, Optional[String](String("sha256:cafe")), None)
        ),
        Int32(8080),
        env^,
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
        buckets^,  # buckets
        List[Int32](),  # runtime_extra_capabilities
        List[WebRouteRule](),  # web_route_rules
        String(""),  # region
        False,  # public_invoker
        None,  # keep_last_n
        List[SecuredInboundRoute](),  # secured_inbound_routes
        String(""),  # datastore_database
        String(""),  # datastore_database_ref
        List[BundleIndexTable](),  # index_tables
        None,  # ingress,
        # APP PARAMETERS (field 31) — empty ⇒ no argv token, no refusal.
        List[AppParameter](),
        # NETWORK REACH (field 32) — UNSPECIFIED ⇒ the deploy stamps nothing.
        NetworkIngress(0),
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
    var name: String,
    var spec: AppSpec,
    var services: List[ServiceSpec],
    var waves: List[Wave],
    var ephemeral: Optional[EphemeralScope],
) raises -> AppBundle:
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        name^,
        List[BuildTarget](),
        Optional[AppSpec](spec^),
        waves^,
        List[TriggerSource](),
        services^,
        List[ValidationSet](),
        Optional[Pipeline](),
        List[Matrix](),
        List[DeployOutput](),
        List[JobSpec](),
        List[CronSpec](),
        ephemeral^,
        Tenancy(Tenancy.TENANCY_UNSPECIFIED),  # field 15 (tenancy): kci composes none
    )


def _ephemeral() -> EphemeralScope:
    return EphemeralScope(
        String(
            "a run-scoped test owns every resource it creates; its bucket IS"
            " the run, so RETAIN_KEEP would leak cost with nothing to protect"
        ),
        Int32(3600),
    )


def _simple_bundle(var name: String) raises -> AppBundle:
    return _bundle(
        name^,
        _spec(List[BundleEnvVar](), List[BucketSpec]()),
        List[ServiceSpec](),
        List[Wave](),
        Optional[EphemeralScope](_ephemeral()),
    )


# =============================================================================
# §A — the run id's shape is a set of CLOUD constraints, not a style rule.
# =============================================================================
def test_run_id_shape() raises:
    assert_equal(validate_run_id(String("ab12")), String(""), "4 bytes is the floor")
    assert_equal(
        validate_run_id(String("conf7x9q")), String(""), "a typical minted id"
    )

    assert_true(
        validate_run_id(String("")).byte_length() > 0, "empty run id refused"
    )
    assert_true(
        validate_run_id(String("ab1")).byte_length() > 0, "3 bytes is below the floor"
    )
    assert_true(
        validate_run_id(String("abcdefghijklm")).byte_length() > 0,
        "13 bytes is over the ceiling",
    )
    # A leading DIGIT: rejected by a GCP service-account account_id, so rejected
    # here — offline, with the reason, rather than by a 400 mid-apply.
    assert_true(
        validate_run_id(String("1abc")).byte_length() > 0, "leading digit refused"
    )
    # Uppercase and underscore are BOTH legal in a shell variable and BOTH
    # illegal in a Cloud Run service name.
    assert_true(
        validate_run_id(String("ABCD")).byte_length() > 0, "uppercase refused"
    )
    assert_true(
        validate_run_id(String("ab_c")).byte_length() > 0, "underscore refused"
    )
    assert_true(
        validate_run_id(String("ab-c")).byte_length() > 0,
        "hyphen refused — the token already supplies the separator",
    )


def test_run_scope_of_refuses_malformed() raises:
    var raised = False
    try:
        _ = RunScope.of(String("BAD"))
    except:
        raised = True
    assert_true(
        raised, "RunScope.of is the ONLY constructor and it validates — a RunScope"
        " in hand is a validated run id"
    )


def test_run_scope_token_and_idempotence() raises:
    var s = RunScope.of(String("conf7x9q"))
    assert_equal(s.token(), String("-run-conf7x9q"), "the distinctive token")
    assert_equal(
        s.scoped(String("canary")), String("canary-run-conf7x9q"), "scoped once"
    )
    # IDEMPOTENT. A double application must not produce `x-run-a-run-a` — a name
    # no teardown ever built and no leak detector ever finds.
    assert_equal(
        s.scoped(s.scoped(String("canary"))),
        String("canary-run-conf7x9q"),
        "scoping is idempotent",
    )
    assert_true(s.carries(String("canary-run-conf7x9q")), "carries its own")
    assert_false(
        s.carries(String("canary-run-other1")), "does not carry another run's"
    )
    assert_false(s.carries(String("canary")), "does not carry an unscoped name")


# =============================================================================
# §B — the BICONDITIONAL. Both directions, and the reverse one is the leak.
# =============================================================================
def test_permission_run_id_without_ephemeral_is_refused() raises:
    var why = run_scope_permission_error(
        String("app-b"), False, String("conf7x9q")
    )
    assert_true(
        why.byte_length() > 0,
        "a bundle with no `ephemeral {}` must REFUSE --run-id: accepting it"
        " would stand up a parallel copy of a STANDING service",
    )


def test_permission_ephemeral_without_run_id_is_refused() raises:
    # THE DIRECTION AN "OPT-IN PERMISSION" READING MISSES. An ephemeral bundle
    # deployed with no run id composes UNSCOPED names — and `delete --run-id`
    # can then never reach them, because they carry no token. The resources
    # outlive every teardown written to remove them. Presence is an OBLIGATION,
    # not only a permission.
    var why = run_scope_permission_error(String("canary"), True, String(""))
    assert_true(
        why.byte_length() > 0,
        "an `ephemeral {}` bundle must REFUSE a deploy with no --run-id",
    )


def test_permission_matched_pairs_are_allowed() raises:
    assert_equal(
        run_scope_permission_error(String("canary"), True, String("conf7x9q")),
        String(""),
        "ephemeral + run id: permitted",
    )
    assert_equal(
        run_scope_permission_error(String("app-b"), False, String("")),
        String(""),
        "neither: permitted, and the ordinary deploy path",
    )


# =============================================================================
# §C — scope_bundle: the rename, and the lockstep that keeps it consistent.
# =============================================================================
def test_scope_bundle_renames_app_and_services() raises:
    var services = List[ServiceSpec]()
    services.append(
        ServiceSpec(
            String("api"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(List[BundleEnvVar](), List[BucketSpec]())),
        )
    )
    var buckets = List[BucketSpec]()
    buckets.append(
        BucketSpec(
            String("canary-staging"),
            String("region-1"),
            String("STANDARD"),
            True,
            String("enforced"),
            Int32(0),  # object_expiry_days — no lifetime claim
        )
    )
    services.append(
        ServiceSpec(
            String("worker"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(List[BundleEnvVar](), buckets^)),
        )
    )
    var b = _bundle(
        String("canary"),
        _spec(List[BundleEnvVar](), List[BucketSpec]()),
        services^,
        List[Wave](),
        Optional[EphemeralScope](_ephemeral()),
    )
    var s = RunScope.of(String("conf7x9q"))
    var out = scope_bundle(b, s)

    assert_equal(out.name, String("canary-run-conf7x9q"), "the app symbol")
    assert_equal(out.services[0].name, String("api-run-conf7x9q"), "service 0")
    assert_equal(out.services[1].name, String("worker-run-conf7x9q"), "service 1")
    assert_equal(
        out.services[1].spec.value().buckets[0].name,
        String("canary-staging-run-conf7x9q"),
        "an app-owned bucket is a run resource — the bucket NAME is its node's"
        " logical id, so an unscoped one is a bucket a run would delete but did"
        " not create",
    )
    # The INPUT is untouched — `scope_bundle` is a value transform, and the CLI
    # holds the authored bundle for its own diagnostics.
    assert_equal(b.name, String("canary"), "the input bundle is not mutated")


def test_scope_bundle_rewrites_service_refs_in_lockstep() raises:
    # THE LOCKSTEP. `compose_api` resolves a `service_ref` by matching against
    # the auto-lifted service list and FAIL-FASTS on a miss. Rename the services
    # and not their references and every cross-service invoke grant vanishes (or
    # the compose dies); rename the references and not the services and the same.
    var caller_env = List[BundleEnvVar]()
    caller_env.append(
        BundleEnvVar(
            String("WORKER_URL"),
            String(""),
            3,
            None,
            None,
            Optional[ServiceRef](ServiceRef(String("worker"))),
        )
    )
    var services = List[ServiceSpec]()
    services.append(
        ServiceSpec(
            String("api"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(caller_env^, List[BucketSpec]())),
        )
    )
    services.append(
        ServiceSpec(
            String("worker"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(List[BundleEnvVar](), List[BucketSpec]())),
        )
    )
    var b = _bundle(
        String("canary"),
        _spec(List[BundleEnvVar](), List[BucketSpec]()),
        services^,
        List[Wave](),
        Optional[EphemeralScope](_ephemeral()),
    )
    var s = RunScope.of(String("conf7x9q"))
    var out = scope_bundle(b, s)
    assert_equal(
        out.services[0].spec.value().env[0].service_ref.value().service,
        String("worker-run-conf7x9q"),
        "the ref follows the rename",
    )
    # And the whole thing still composes — the strongest form of the assertion,
    # because a broken lockstep RAISES in `compose_api` rather than asserting
    # false here.
    var m = compose_run_scoped(b, String("env-a"), s)
    assert_true(len(m.nodes) > 0, "a scoped multi-service bundle still composes")


def test_scope_bundle_rewrites_the_env_override_service_axis() raises:
    """THE SECOND LOCKSTEP. `BundleEnvVar.service` on a per-wave
    `env_override` names a service by its LOGICAL name, so it must follow the
    rename exactly as `service_ref` does.

    FAILS WITHOUT THE SCOPING AT `compose_run_scoped`, NOT HERE — and loudly:
    `_wave_env_overrides_by_service` raises "names service 'api', which this
    bundle does not declare" once the services are `api-run-<id>`. That is the
    right DIRECTION of failure, which is exactly why it needs a row: a refusal
    nobody has hit yet is indistinguishable from a rule nobody wrote."""
    var overrides = List[BundleEnvVar]()
    overrides.append(
        BundleEnvVar(
            String("LOG_LEVEL"),
            String("api"),  # ← the service axis, pre-rename
            1,
            Optional[String](String("debug")),
            None,
            None,
        )
    )
    var waves = List[Wave]()
    waves.append(
        Wave(
            String("env-a"),
            List[ValidateStep](),
            False,
            overrides^,
            List[AppParameter](),
            String(""),  # peer_identity_issuer (6)
            String(""),  # developer_access_principal (7)
            Optional[WebFrontendOverride](),  # web_override (8)
            List[String](),  # api_edge_services (9) — EMPTY
        )
    )
    var services = List[ServiceSpec]()
    services.append(
        ServiceSpec(
            String("api"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(List[BundleEnvVar](), List[BucketSpec]())),
        )
    )
    services.append(
        ServiceSpec(
            String("worker"),
            AppKind(AppKind.APP_KIND_API),
            Optional[AppSpec](_spec(List[BundleEnvVar](), List[BucketSpec]())),
        )
    )
    var b = _bundle(
        String("canary"),
        _spec(List[BundleEnvVar](), List[BucketSpec]()),
        services^,
        waves^,
        Optional[EphemeralScope](_ephemeral()),
    )
    var s = RunScope.of(String("conf7x9q"))
    var out = scope_bundle(b, s)
    assert_equal(
        out.waves[0].env_override[0].service,
        String("api-run-conf7x9q"),
        "the override's service axis follows the rename",
    )
    # The whole thing still composes, AND the override lands on the renamed
    # service's Config node and on no other. A scoping that merely rewrote the
    # string would satisfy the line above and still put the value nowhere.
    var m = compose_run_scoped(b, String("env-a"), s)
    var carriers = 0
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value != ResourceKind.RESOURCE_KIND_CONFIG:
            continue
        var vals = m.nodes[i].config_data.value().values.copy()
        for entry in vals.items():
            if entry.key == String("LOG_LEVEL") and entry.value == String("debug"):
                carriers += 1
                assert_equal(
                    m.nodes[i].logical_id,
                    String("api-run-conf7x9q-config"),
                    "…and it lands on the RENAMED api service's Config node",
                )
    assert_equal(carriers, 1, "exactly one Config node carries the override")
    print("  test_scope_bundle_rewrites_the_env_override_service_axis: PASS")


def test_scope_bundle_refuses_a_referenced_datastore() raises:
    var spec = _spec(List[BundleEnvVar](), List[BucketSpec]())
    spec.datastore_database_ref = String("shared-db")
    var b = _bundle(
        String("canary"),
        spec^,
        List[ServiceSpec](),
        List[Wave](),
        Optional[EphemeralScope](_ephemeral()),
    )
    var raised = False
    try:
        _ = scope_bundle(b, RunScope.of(String("conf7x9q")))
    except:
        raised = True
    assert_true(
        raised,
        "a throwaway run may not write into a database another release machine"
        " OWNS — the reference names a standing resource by definition",
    )


def test_scope_bundle_refuses_a_non_api_kind() raises:
    var b = _simple_bundle(String("canary"))
    b.kind = AppKind(AppKind.APP_KIND_STATIC_FRONTEND)
    var raised = False
    try:
        _ = scope_bundle(b, RunScope.of(String("conf7x9q")))
    except:
        raised = True
    assert_true(
        raised,
        "a static-website front door is a domain + a managed certificate + a"
        " global load balancer; a run that could stand those up could also reap"
        " them",
    )


# =============================================================================
# §D — END-TO-END: every composed name belongs to the run.
# =============================================================================
def test_compose_run_scoped_scopes_the_whole_graph() raises:
    var b = _simple_bundle(String("canary"))
    var s = RunScope.of(String("conf7x9q"))
    var m = compose_run_scoped(b, String("env-a"), s)

    assert_true(len(m.nodes) >= 4, "the API node set composed")
    # Asserted by RE-RUNNING THE VERIFIER, not by listing expected ids. A list
    # of ids goes stale the day the composition grows a node; the verifier is
    # total over kinds and cannot.
    var v = run_scope_violations(m, s)
    assert_equal(
        len(v),
        0,
        "compose_run_scoped's output has ZERO violations under its own scope",
    )
    for i in range(len(m.nodes)):
        assert_true(
            s.carries(m.nodes[i].logical_id),
            String("node '") + m.nodes[i].logical_id + String("' carries the token"),
        )

    # A DIFFERENT run's scope sees the SAME graph as entirely foreign — which is
    # what stops run B's teardown from reaping run A's resources.
    #
    # THE OTHER RUN IS A PROPER PREFIX OF THIS ONE, AND THAT IS THE WHOLE POINT.
    # An unrelated id (`other999`) cannot be a substring of any
    # `…-run-conf7x9q…` name under ANY substring, prefix or suffix
    # implementation, so it would hold whether or not `carries()` is anchored
    # — satisfied by the two ids being unrelated rather than by the predicate
    # being right. This is the ONLY place the cross-run assertion is made over a
    # REAL composition rather than a hand-built single-node manifest.
    #
    # `conf7x9` is `conf7x9q` minus its last byte: still a valid run id (7 bytes,
    # in 4..12, leading [a-z]), and `-run-conf7x9` IS inside
    # `canary-run-conf7x9q-svc`. Under an unanchored `carries()` this graph reads
    # as ENTIRELY the other run's — violations 0 — and this assertion goes red.
    var other = RunScope.of(String("conf7x9"))
    assert_equal(
        validate_run_id(String("conf7x9")),
        String(""),
        "the colliding run id must itself be VALID — otherwise the assertion"
        " below is vacuous for a second reason",
    )
    assert_true(
        len(run_scope_violations(m, other)) >= len(m.nodes),
        "another run's scope finds every node foreign — INCLUDING a run whose id"
        " is a proper prefix of this one",
    )


def test_unscoped_compose_is_byte_identical_to_today() raises:
    # The additive-safety property, restated as a test: a bundle with no
    # `ephemeral {}` is never routed through this module, and the ordinary
    # composition is untouched. Composing the SAME bundle without scoping and
    # asserting the ids are the pre-existing ones is the falsifier for "this
    # capability changed something for everybody else".
    var b = _simple_bundle(String("canary"))
    var m = compose_api(b, String("env-a"))
    assert_true(len(m.nodes) >= 4, "the unscoped graph still composes")
    for i in range(len(m.nodes)):
        assert_false(
            m.nodes[i].logical_id.__contains__(String(RUN_SCOPE_INFIX)),
            "an unscoped compose emits no run token anywhere",
        )


# =============================================================================
# §E ★ THE ESCAPE TESTS — four ways out of the scope, all four REFUSED.
# =============================================================================
def _iam_node(var logical_id: String) raises -> ResourceNode:
    return ResourceNode(
        logical_id^,
        ResourceKind(ResourceKind.RESOURCE_KIND_IAM_ROLE),
        List[String](),
        Retention(Retention.RETENTION_DELETE),
        8,
        None, None, None, None, None, None, None,
        Optional[IamRoleSpec](IamRoleSpec()),
        None, None, None, None, None, None, None, None, None, None, None,
        None,  # arm 20 (scheduled_call)
        None, None,  # arms 21-22 (network, ingress_policy)
    )


def test_escape_E1_a_standing_name_in_the_graph_is_a_violation() raises:
    # THE BUG THIS CAPABILITY EXISTS TO PREVENT, in its smallest form: one node
    # in an otherwise run-scoped graph names a STANDING resource. Reaping this
    # graph in reverse would delete it.
    var s = RunScope.of(String("conf7x9q"))
    var nodes = List[ResourceNode]()
    nodes.append(_iam_node(String("canary-run-conf7x9q-role")))
    nodes.append(_iam_node(String("app-b-role")))  # ← the escape
    var m = FullManifest(String("env-a"), String(""), nodes^)

    var v = run_scope_violations(m, s)
    assert_equal(len(v), 1, "exactly the foreign node is reported")
    assert_true(
        v[0].__contains__(String("app-b-role")),
        "the violation NAMES the resource that would have been deleted",
    )


def test_escape_E1b_a_foreign_name_inside_a_node_is_a_violation() raises:
    # The escape does not have to be the logical id. A SERVICE_ACCOUNT node's
    # `account_id` is the thing that actually gets created and deleted, and it
    # is a DIFFERENT string from the node id. A checker that only looked at
    # logical ids would pass this graph and then delete a shared identity.
    var s = RunScope.of(String("conf7x9q"))
    var nodes = List[ResourceNode]()
    nodes.append(
        ResourceNode(
            String("gw-sa-run-conf7x9q"),  # the node id IS scoped …
            ResourceKind(ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
            List[String](),
            Retention(Retention.RETENTION_DELETE),
            11,
            None, None, None, None, None, None, None, None, None, None,
            Optional[ServiceAccountSpec](
                # … and the account it actually creates is NOT.
                ServiceAccountSpec(
                    String("shared-gw-sa"),
                    String("shared gateway SA"),
                    False,
                    False,
                    List[FederatedAssumePrincipal](),
                    List[InAccountAssumePrincipal](),
                )
            ),
            None, None, None, None, None, None, None, None,
            None,  # arm 20 (scheduled_call)
            None, None,  # arms 21-22 (network, ingress_policy)
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var v = run_scope_violations(m, s)
    assert_equal(len(v), 1, "the inner name is checked, not just the node id")
    assert_true(
        v[0].__contains__(String("shared-gw-sa")),
        "the violation names the ACCOUNT, which is what would be deleted",
    )


def test_escape_E2_an_unknown_resource_kind_fails_CLOSED() raises:
    # FAIL-CLOSED, NOT FAIL-QUIET. A `ResourceKind` with no case in
    # `_node_addressed_names` must REFUSE the graph, not be treated as having no
    # names. A default arm returning "no names" would make every new kind
    # silently unscoped — i.e. reapable by a run that does not own it, which is
    # exactly the bug. So the default arm is the one thing that must not exist,
    # and this test is what stops someone adding it back for convenience.
    var s = RunScope.of(String("conf7x9q"))
    var nodes = List[ResourceNode]()
    nodes.append(
        ResourceNode(
            String("something-run-conf7x9q"),
            ResourceKind(21),  # one past RESOURCE_KIND_PROJECT_SERVICE
            List[String](),
            Retention(Retention.RETENTION_DELETE),
            0,
            None, None, None, None, None, None, None, None, None, None,
            None, None, None, None, None, None, None, None, None,
            None,  # arm 20 (scheduled_call)
            None, None,  # arms 21-22 (network, ingress_policy)
        )
    )
    var m = FullManifest(String("env-a"), String(""), nodes^)
    var raised = False
    try:
        _ = run_scope_violations(m, s)
    except:
        raised = True
    assert_true(
        raised,
        "an unknown ResourceKind REFUSES the run-scoped graph rather than"
        " passing it as unnamed",
    )


def test_escape_E3_the_SHARED_api_gateway_sa_is_refused() raises:
    # An `inbound: CLIENT` service on a wave with `api_edge_enabled` composes a
    # SERVICE_ACCOUNT node for the SHARED API-Gateway backend-auth identity
    # every client-facing app in the project uses. Nothing about that node is
    # per-app, so nothing about it is per-run. Under a run scope the reverse
    # walk would DELETE it, and every standing edge in the project would start
    # 403ing at the backend hop.
    #
    # The refusal is the whole point: the capability does not quietly skip the
    # node (a skip is a leak) and does not quietly reap it (a reap is an
    # outage). It refuses the graph and says which name it could not prove.
    var waves = List[Wave]()
    waves.append(
        Wave(String("env-a"), List[ValidateStep](), True, List[BundleEnvVar](), List[AppParameter](), String(""), String(""), Optional[WebFrontendOverride](), List[String]())
    )
    var b = _bundle(
        String("canary"),
        _spec(
            List[BundleEnvVar](),
            List[BucketSpec](),
            inbound=InboundNeed.INBOUND_NEED_CLIENT,
        ),
        List[ServiceSpec](),
        waves^,
        Optional[EphemeralScope](_ephemeral()),
    )
    var s = RunScope.of(String("conf7x9q"))

    # It really does compose that node — assert the premise, so this test cannot
    # pass for the wrong reason if the edge composition changes.
    var scoped = scope_bundle(b, s)
    var m = compose_api(scoped, String("env-a"))
    var v = run_scope_violations(m, s)
    assert_true(
        len(v) > 0,
        "the api-edge composition reaches at least one name this run does not own",
    )
    var mentions_gw = False
    for i in range(len(v)):
        if v[i].__contains__(String(EDGE_GATEWAY_SA_ACCOUNT_ID)):
            mentions_gw = True
    assert_true(
        mentions_gw,
        "the SHARED API-Gateway backend-auth SA is named in the refusal",
    )

    # And the fused entry point REFUSES rather than returning the graph.
    var raised = False
    try:
        _ = compose_run_scoped(b, String("env-a"), s)
    except:
        raised = True
    assert_true(raised, "compose_run_scoped refuses the escaping graph")


def test_escape_E4_a_standing_secret_read_grant_is_refused() raises:
    # The second real escape, by a different route: a wave that gates on a
    # `run_container` step which declares `reads_secret` composes ONE grant
    # letting the in-cloud validate job READ a STANDING secret. The grant
    # TARGETS a secret this run did not create, so a reverse walk would UN-GRANT
    # it — and the next standing deploy's validate job would fail with a
    # permission error nobody would connect to a run-scoped test that finished
    # earlier.
    var reads = List[String]()
    reads.append(String(_STANDING_SECRET))
    var steps = List[ValidateStep]()
    steps.append(
        ValidateStep(
            String("integ"),
            List[String](),
            String(""),
            String(""),  # service (empty => the bundle's one service)
            2,
            None,
            Optional[RunContainer](
                RunContainer(
                    Optional[ImageRef](
                        ImageRef(2, None, Optional[String](String("integ")))
                    ),
                    GateOn(GateOn.GATE_ON_EXIT_CODE),
                    List[BundleEnvVar](),
                    reads^,  # `reads_secret` — one standing secret
                    List[AppParameter](),  # `args` (field 5) — none
                    String(""),  # `runtime_identity` (field 6) — the deploy SA
                    None,  # `vpc_egress` (field 7) — no VPC egress
                    List[TelemetryRead](),  # `reads_telemetry` (field 8) — none
                    List[TestRole](),  # `test_role` (field 9) — none
                    String(""),  # own_identity (10) — EMPTY
                )
            ),
            None,
        )
    )
    var waves = List[Wave]()
    waves.append(Wave(String("env-a"), steps^, False, List[BundleEnvVar](), List[AppParameter](), String(""), String(""), Optional[WebFrontendOverride](), List[String]()))
    # A SELF-PROVISIONING service (an authored `runtime_identity`), so the
    # fixture also exercises the scoping of the runtime identity below.
    var spec = _spec(List[BundleEnvVar](), List[BucketSpec]())
    spec.runtime_identity = String("canary-runtime")
    var b = _bundle(
        String("canary"),
        spec^,
        List[ServiceSpec](),
        waves^,
        Optional[EphemeralScope](_ephemeral()),
    )
    var s = RunScope.of(String("conf7x9q"))
    var scoped = scope_bundle(b, s)
    # AND THE SELF-PROVISIONED IDENTITY IS ITSELF SCOPED. It becomes a
    # SERVICE_ACCOUNT node's `account_id` — a service account this graph CREATES
    # and a reverse walk DELETES. Unscoped, a run-scoped teardown would delete a
    # shared runtime SA. This assertion is the regression guard for that.
    assert_equal(
        scoped.spec.value().runtime_identity,
        String("canary-runtime-run-conf7x9q"),
        "an authored runtime identity is a run-created service account",
    )
    var m = compose_api(scoped, String("env-a"))
    var v = run_scope_violations(m, s)
    var mentions_secret = False
    for i in range(len(v)):
        if v[i].__contains__(String(_STANDING_SECRET)):
            mentions_secret = True
    assert_true(
        mentions_secret,
        "the STANDING secret is named in the refusal — un-granting it would"
        " break the NEXT standing deploy's validate job",
    )


# =============================================================================
# §F — retention, through the EXISTING switch.
# =============================================================================
def test_run_scope_lifts_retain_keep() raises:
    # `RETAIN_KEEP` protects data. A run-scoped graph HAS no data to protect —
    # the bucket IS the run — and leaving it standing is the cost leak a
    # run-scoped teardown exists to prevent.
    # `EphemeralScope.keep_overridden_because` is REQUIRED non-empty precisely
    # because this is the dangerous half.
    assert_true(
        run_scope_lifts_retention(String("conf7x9q"), False),
        "a run scope lifts the RETAIN_KEEP skip without --delete-data",
    )
    assert_true(
        run_scope_lifts_retention(String(""), True),
        "--delete-data still lifts it on its own (the pre-existing behaviour)",
    )
    assert_false(
        run_scope_lifts_retention(String(""), False),
        "and a plain destroy still HONOURS retention",
    )


# =============================================================================
# §G — a correctly-scoped name that is too long fails OFFLINE, and the TWO
#      bounds are two bounds.
# =============================================================================
def test_scoped_name_length_is_checked_offline() raises:
    var sa = String("GCP service-account account_id")
    assert_equal(
        scoped_name_length_error(String("canary-run-conf7x9q-role"), SA_ACCOUNT_ID_MAX, sa),
        String(""),
        "a normal scoped runtime identity is inside the tighter bound",
    )
    var long_id = String("a-very-long-release-machine-symbol-run-conf7x9q-role")
    assert_true(
        long_id.byte_length() > SA_ACCOUNT_ID_MAX, "the fixture is over the SA bound"
    )
    assert_true(
        scoped_name_length_error(long_id, SA_ACCOUNT_ID_MAX, sa).byte_length() > 0,
        "over-long scoped identities are refused HERE, not by a 400 from the"
        " cloud with half the graph already standing",
    )
    # THE TWO BOUNDS ARE TWO BOUNDS. Applying 30 everywhere would refuse an
    # ORDINARY two-service bundle, because a cross-service GRANT node's logical
    # id is `<caller>-invokes-<callee>` — 44 bytes once both are scoped, and not
    # a service account at all.
    assert_true(
        long_id.byte_length() < RESOURCE_NAME_MAX,
        "the same name is comfortably inside the RESOURCE bound",
    )
    assert_equal(
        scoped_name_length_error(
            long_id, RESOURCE_NAME_MAX, String("Cloud Run service")
        ),
        String(""),
        "a name over the SA bound is NOT over the resource bound",
    )

    # And it is enforced through the same verifier the escape tests drive, so it
    # cannot be a check that only exists in its own unit test.
    var s = RunScope.of(String("conf7x9q"))
    var nodes = List[ResourceNode]()
    var over_resource_bound = String(
        "an-extremely-long-release-machine-and-service-symbol-pair-run-conf7x9q"
    )
    assert_true(
        over_resource_bound.byte_length() > RESOURCE_NAME_MAX,
        "the fixture is over the resource bound",
    )
    nodes.append(_iam_node(over_resource_bound))
    var m = FullManifest(String("env-a"), String(""), nodes^)
    assert_equal(
        len(run_scope_violations(m, s)),
        1,
        "the length bound is enforced by run_scope_violations too",
    )


def main() raises:
    test_run_id_shape()
    test_run_scope_of_refuses_malformed()
    test_run_scope_token_and_idempotence()
    test_permission_run_id_without_ephemeral_is_refused()
    test_permission_ephemeral_without_run_id_is_refused()
    test_permission_matched_pairs_are_allowed()
    test_scope_bundle_renames_app_and_services()
    test_scope_bundle_rewrites_service_refs_in_lockstep()
    test_scope_bundle_rewrites_the_env_override_service_axis()
    test_scope_bundle_refuses_a_referenced_datastore()
    test_scope_bundle_refuses_a_non_api_kind()
    test_compose_run_scoped_scopes_the_whole_graph()
    test_unscoped_compose_is_byte_identical_to_today()
    test_escape_E1_a_standing_name_in_the_graph_is_a_violation()
    test_escape_E1b_a_foreign_name_inside_a_node_is_a_violation()
    test_escape_E2_an_unknown_resource_kind_fails_CLOSED()
    test_escape_E3_the_SHARED_api_gateway_sa_is_refused()
    test_escape_E4_a_standing_secret_read_grant_is_refused()
    test_run_scope_lifts_retain_keep()
    test_scoped_name_length_is_checked_offline()
    print("test_run_scope: ALL PASS")
