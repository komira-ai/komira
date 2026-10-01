# =============================================================================
# kci_deploy_compose/tests/test_compose_jobs.mojo — the JOBS-capability
#   composition gate (a one-shot container a bundle declares, instead of a
#   hand-rolled `gcloud run jobs` script).
# =============================================================================
#
# EVERY TEST HERE FAILS WITHOUT `_append_job_nodes`: without it,
# `AppBundle.jobs[]` would be authorable and compose to NOTHING — the schema
# existing and the resource not.
#
# WHAT THIS PINS.
#   §A EMISSION — N `jobs[]` -> N `RESOURCE_KIND_RUN_TO_COMPLETION_JOB` nodes
#      (arm 2), `<name>-job` logical ids, RETENTION_DELETE, and every authored
#      field carried onto the resolved spec: pinned image digest, runtime
#      identity, literal env, NAME-ONLY secret handles, `max_retries` PRESENCE,
#      task timeout, region.
#   §B THE ADDITIVE GUARD — a bundle with NO `jobs {}` block composes no job
#      node.
#   §C OUTBOUND AUTH — a job that references a sibling service gets (1) the
#      `__SVCREF` marker instead of a scraped URL, (2) an in-edge on that
#      service's node, and (3) an INVOKE_SERVICE grant; a job that mounts a
#      secret gets a READ_SECRET grant scoped to THAT NAMED SECRET. Without
#      these the job 403s at run time and the log reads like a product failure.
#   §D THE THREE REFUSALS — `value_from` on a job (no URL of its own to resolve
#      to), a ServiceRef naming a non-sibling (the grant could not be composed),
#      and a job with no identity anywhere (Cloud Run would silently substitute
#      the project default compute SA, which is broader than anything the bundle
#      declares).
#   §E `max_retries` PRESENCE vs ZERO — the proto3-optional property the whole
#      gate contract rests on: "the author demanded no retries" must not read as
#      "the author said nothing".
#
# Encapsulation: pure struct construction + `compose_api` + value asserts — no
# UnsafePointer, no store, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_deploy_compose.compose_api import (
    CLOUD_AWS,
    CLOUD_GCP,
    compose_api,
    JOB_NODE_SUFFIX,
    # The identity resolver, exercised DIRECTLY for the no-service case: a
    # bundle with neither a `services` list nor a singular `spec` is refused by
    # the auto-lift before compose ever reaches the jobs pass, so going through
    # `compose_api` would assert on a different refusal than the one under test.
    _job_runtime_identity,
)

from full_manifest_rpc.full_manifest import (
    FullManifest,
    ResourceKind,
    ResourceNode,
    Retention,
    Capability,
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
    AppBundle,
    Tenancy,  # field 15 (tenancy): kci composes none; see `_bundle`
    AppKind,
    AppSpec,
    ImageRef,
    BundleEnvVar,
    ServiceRef,
    ValueFrom,
    Scaling,
    ComputeIntent,
    ServiceSpec,
    BuildTarget,
    Wave,
    TriggerSource,
    ValidationSet,
    Pipeline,
    Matrix,
    DeployOutput,
    JobSpec,
    CronSpec,
    BucketSpec,
    WebRouteRule,
    SecuredInboundRoute,
)
from komira_rpc_bundle.deploy_model import (
    BundleIndexTable,
    DatastoreNeed,
    InboundNeed,
    NetworkIngress,
    SecretBinding,
    SecretCustody,
)


# =============================================================================
# fixtures
# =============================================================================
def _spec(var runtime_identity: String) raises -> AppSpec:
    """A minimal serving AppSpec (a pinned digest, no env, no secrets)."""
    return AppSpec(
        Optional[ImageRef](
            ImageRef(1, Optional[String](String("sha256:svc")), None)
        ),
        Int32(8080),
        List[BundleEnvVar](),
        Optional[Scaling](Scaling(Int32(0), Int32(1))),
        ComputeIntent(ComputeIntent.COMPUTE_INTENT_SERVERLESS),
        DatastoreNeed(DatastoreNeed.DATASTORE_NEED_UNSPECIFIED),
        List[SecretBinding](),
        runtime_identity^,
        String(""), Int32(0), String(""), String(""),
        String(""), String(""), List[String](), List[String](), String(""),
        InboundNeed(0), String(""),
        List[BucketSpec](), List[Int32](), List[WebRouteRule](),
        String(""), False, None,
        List[SecuredInboundRoute](), String(""), String(""),
        List[BundleIndexTable](),
        None,  # ingress (field 30),
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


def _service(var name: String, var runtime_identity: String) raises -> ServiceSpec:
    return ServiceSpec(
        name^, AppKind(AppKind.APP_KIND_API), Optional[AppSpec](_spec(runtime_identity^))
    )


def _literal(var name: String, var value: String) raises -> BundleEnvVar:
    return BundleEnvVar(name^, String(""), 1, Optional[String](value^), None, None)


def _svcref(var name: String, var target: String) raises -> BundleEnvVar:
    return BundleEnvVar(
        name^,
        String(""), 3, None, None, Optional[ServiceRef](ServiceRef(target^))
    )


def _deploy_url(var name: String) raises -> BundleEnvVar:
    return BundleEnvVar(
        name^,
        String(""),
        2,
        None,
        Optional[ValueFrom](ValueFrom(ValueFrom.VALUE_FROM_DEPLOY_URL)),
        None,
    )


def _binding(var handle: String) raises -> SecretBinding:
    return SecretBinding(
        handle^,
        String("cap"),
        False,
        SecretCustody(SecretCustody.SECRET_CUSTODY_OPERATOR),
    )


def _job(
    var name: String,
    var env: List[BundleEnvVar],
    var bindings: List[SecretBinding],
    var runtime_identity: String,
    var max_retries: Optional[Int32],
    task_timeout_seconds: Int32 = Int32(0),
    var region: String = String(""),
    # `JobSpec.args` (field 9) — appended last and defaulted, so a call site
    # that authors none passes nothing.
    var args: List[String] = List[String](),
) raises -> JobSpec:
    return JobSpec(
        name^,
        Optional[ImageRef](
            ImageRef(1, Optional[String](String("sha256:jobval")), None)
        ),
        env^,
        bindings^,
        runtime_identity^,
        max_retries^,
        task_timeout_seconds,
        region^,
        args^,
    )


def _bundle(
    var services: List[ServiceSpec], var jobs: List[JobSpec]
) raises -> AppBundle:
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        String("queue-a"),
        List[BuildTarget](),
        None,  # no singular spec — the services list is authoritative
        List[Wave](),
        List[TriggerSource](),
        services^,
        List[ValidationSet](),
        Optional[Pipeline](),
        List[Matrix](),
        List[DeployOutput](),
        jobs^,
        List[CronSpec](),
        None,
        Tenancy(Tenancy.TENANCY_UNSPECIFIED),  # field 15 (tenancy): kci composes none
    )


def _node_index(m: FullManifest, logical_id: String) -> Int:
    for i in range(len(m.nodes)):
        if m.nodes[i].logical_id == logical_id:
            return i
    return -1


def _has_dep(node: ResourceNode, logical_id: String) -> Bool:
    for i in range(len(node.depends_on)):
        if node.depends_on[i] == logical_id:
            return True
    return False


def _count_kind(m: FullManifest, kind: Int) -> Int:
    var n = 0
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value == kind:
            n += 1
    return n


# =============================================================================
# §A — EMISSION: every authored field lands on the resolved node.
# =============================================================================
def test_job_node_carries_every_authored_field() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))

    var env = List[BundleEnvVar]()
    env.append(_literal(String("TARGET_TO"), String("a@example.com")))
    var bindings = List[SecretBinding]()
    bindings.append(_binding(String("SECRET_A_B64")))

    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("job-a"),
            env^,
            bindings^,
            String("job-a-role"),
            Optional[Int32](Int32(0)),
            Int32(600),
            String("region-1"),
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))

    var i = _node_index(m, String("job-a") + JOB_NODE_SUFFIX)
    assert_true(i >= 0, "the job node is emitted under `<name>-job`")
    ref node = m.nodes[i]
    assert_equal(
        node.kind.value,
        ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB,
        "kind is RUN_TO_COMPLETION_JOB",
    )
    assert_equal(node._oneof0_case, 2, "config oneof arm 2 is set")
    assert_equal(
        node.retention.value,
        Retention.RETENTION_DELETE,
        "app-owned: the deploy graph's lifecycle IS this job's",
    )
    assert_true(Bool(node.run_to_completion_job), "the arm-2 spec is present")
    var js = node.run_to_completion_job.value().copy()
    # IMAGE-DIGEST PINNING — a pinned digest, never a mutable `:latest` tag.
    assert_equal(js.image_digest, String("sha256:jobval"), "pinned digest")
    assert_equal(
        js.runtime_identity, String("job-a-role"), "runs as its own SA"
    )
    assert_equal(len(js.env), 1, "the literal env entry")
    assert_equal(
        js.env[String("TARGET_TO")],
        String("a@example.com"),
        "literal env value",
    )
    assert_equal(len(js.secret_handles), 1, "one NAME-ONLY secret handle")
    assert_equal(
        js.secret_handles[0],
        String("SECRET_A_B64"),
        "the handle, never a value",
    )
    assert_true(Bool(js.max_retries), "max_retries PRESENT")
    assert_equal(Int(js.max_retries.value()), 0, "and it is the demanded 0")
    assert_equal(Int(js.task_timeout_seconds), 600, "the 10-minute budget")
    assert_equal(js.region, String("region-1"), "the authored region")
    # SUPERVISOR is NOT injected onto a bundle-declared gate job.
    assert_true(
        not Bool(js.supervisor),
        "no platform supervisor on a gate job — its exit code IS the verdict",
    )


def test_two_jobs_compose_two_nodes_in_declaration_order() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("first"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    jobs.append(
        _job(
            String("second"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    assert_equal(
        _count_kind(m, ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB),
        2,
        "two declared jobs -> two nodes",
    )
    assert_true(
        _node_index(m, String("first-job"))
        < _node_index(m, String("second-job")),
        "declaration order is preserved (deterministic compose)",
    )


def test_unset_max_retries_and_region_flow_through_as_unset() raises:
    """UNSET is not the same as zero, and compose must not substitute either.

    An empty `region` means "the mapper's env binding decides"; compose has no
    binding and inventing one here is how a job lands in the wrong project's
    region with a green deploy."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("plain"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var js = m.nodes[
        _node_index(m, String("plain-job"))
    ].run_to_completion_job.value().copy()
    assert_true(
        not Bool(js.max_retries),
        "UNSET max_retries stays UNSET (the platform default applies)",
    )
    assert_equal(Int(js.task_timeout_seconds), 0, "0 = platform default")
    assert_equal(js.region, String(""), "empty = the env binding's region")


def test_from_build_image_carries_the_symbolic_marker() raises:
    """A job's image goes through the SAME `_resolve_image_digest` a service's
    does, so a `from_build` job image is the pinned-later marker rather than a
    tag the pipeline cannot key on."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        JobSpec(
            String("built"),
            Optional[ImageRef](
                ImageRef(2, None, Optional[String](String("job_image")))
            ),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,
            Int32(0),
            String(""),
            List[String](),  # args (field 9)
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var js = m.nodes[
        _node_index(m, String("built-job"))
    ].run_to_completion_job.value().copy()
    assert_equal(
        js.image_digest,
        String("from_build:job_image"),
        "the from_build marker the pipeline pins later",
    )


# =============================================================================
# §B — THE ADDITIVE GUARD.
# =============================================================================
def test_a_bundle_with_no_jobs_composes_zero_job_nodes() raises:
    """The additive-safety property, stated as its falsifier: a bundle that does
    not author `jobs {}` must gain NOTHING from this capability existing."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var m = compose_api(
        _bundle(services^, List[JobSpec]()), String("env-a")
    )
    assert_equal(
        _count_kind(m, ResourceKind.RESOURCE_KIND_RUN_TO_COMPLETION_JOB),
        0,
        "no jobs authored -> no job nodes",
    )
    for i in range(len(m.nodes)):
        assert_true(
            not m.nodes[i].logical_id.endswith(JOB_NODE_SUFFIX),
            "no node acquires the job suffix",
        )


# §B2 — THE JOB'S OWN IDENTITY NODE.
# =============================================================================
#
# A job's authored `runtime_identity` must name an identity SOMETHING IN THE
# GRAPH CREATES: Cloud Run's `CreateJob` accepts a `serviceAccount` that does not
# exist, and ECS `RegisterTaskDefinition` accepts a `taskRoleArn` that does not
# exist. Both report the truth only at EXECUTION, which is the failure class
# every refusal in this file is written to prevent.
#
# THE MINT IS GATED ON THE **AUTHORED** FIELD, NOT ON THE RESOLVED IDENTITY,
# and the difference is a resource-ownership one. A job that INHERITS from a
# service that does not self-provision resolves to `<svc>-role` — an identity
# BOOTSTRAP owns. Minting it here would make this deploy its creator AND, under
# RETENTION_DELETE, its deleter. `test_an_inherited_identity_is_never_minted`
# is that falsifier.
# =============================================================================
def test_a_job_with_an_authored_identity_mints_its_own_service_account() raises:
    """Without the identity pass, zero SERVICE_ACCOUNT nodes carry the job's
    identity, and the job runs as a principal no node creates."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("job-b"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("job-b-role"),  # AUTHORED, and no sibling has it
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))

    var si = _node_index(m, String("job-b-role-sa"))
    assert_true(
        si >= 0,
        String(
            "no SERVICE_ACCOUNT node for the job's authored identity. The job"
            " would be created naming a principal nothing mints, and BOTH"
            " clouds accept that at create time and fail only at execution."
        ),
    )
    assert_equal(
        m.nodes[si].kind.value,
        ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT,
        "the node minted for a job identity is a SERVICE_ACCOUNT node",
    )
    assert_true(
        Bool(m.nodes[si].service_account),
        "kind/arm agreement: the SERVICE_ACCOUNT node carries a spec",
    )
    assert_equal(
        m.nodes[si].service_account.value().account_id,
        String("job-b-role"),
        String(
            "the SA's account_id is not the string the job runs as. These must"
            " be the SAME string — the identity created and the identity the"
            " job names are one field on two nodes."
        ),
    )
    assert_equal(
        len(m.nodes[si].depends_on),
        0,
        "the identity is a graph ROOT — it must precede its grants and the job",
    )
    assert_equal(
        m.nodes[si].retention.value,
        Retention.RETENTION_DELETE,
        String(
            "app-owned: this deploy's lifecycle IS the job SA's, the same"
            " answer `<svc>-role` gets"
        ),
    )
    assert_false(
        m.nodes[si].service_account.value().externally_owned,
        "an identity THIS graph mints is not externally owned",
    )

    # And the job ORDERS AFTER it. Kahn's algorithm does not fail on a missing
    # edge — it schedules the job whenever, which is a `CreateJob` racing the
    # `CreateServiceAccount` it needs.
    var ji = _node_index(m, String("job-b-job"))
    assert_true(ji >= 0, "the job node exists")
    assert_true(
        _has_dep(m.nodes[ji], String("job-b-role-sa")),
        String(
            "the job does not depend_on the identity this pass minted for it"
        ),
    )


def test_a_job_sharing_a_sibling_identity_mints_no_second_account() raises:
    """ONE identity, ONE node. A second SERVICE_ACCOUNT node for the same
    `account_id` is two creators of one resource — and on teardown, two
    deleters."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("sharer"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),  # the sibling's self-provisioned identity
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    assert_equal(
        _count_kind(m, ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
        1,
        String(
            "the job minted a SECOND SA node for an identity the service"
            " already composes"
        ),
    )


def test_an_inherited_identity_is_never_minted() raises:
    """THE OWNERSHIP GUARD. A service that authors NO `runtime_identity`
    derives `<svc>-role` and deliberately self-provisions NOTHING — that identity
    is bootstrap's. A job inheriting it must not turn this deploy into its
    creator, because RETENTION_DELETE would then make it its deleter too."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("")))  # NOT self-provisioned
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("inheritor"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String(""),  # UNSET -> inherits `svc-a-role`
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    assert_equal(
        _count_kind(m, ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
        0,
        String(
            "an INHERITED identity was minted. `svc-a-role` here is derived,"
            " not self-provisioned — bootstrap owns it, and a node under"
            " RETENTION_DELETE would delete it on this app's teardown."
        ),
    )


def test_a_colliding_job_sa_logical_id_is_refused() raises:
    """Two nodes with ONE logical id is a graph nothing can order. It is
    representable — a service named `svc-a` authoring `runtime_identity: x-role`
    composes `svc-a-role-sa` for account `x-role`, and a job authoring
    `svc-a-role` derives the SAME logical id for a DIFFERENT account — so it is
    refused by name rather than resolved by whichever append ran last."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("x-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("collider"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    var raised = False
    var msg = String("")
    try:
        var _m = compose_api(_bundle(services^, jobs^), String("env-a"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a colliding SA logical id must refuse")
    assert_true(
        String("svc-a-role-sa") in msg,
        String("the refusal names the colliding logical id; got: ") + msg,
    )


def test_a_bundle_with_no_jobs_mints_no_job_identity() raises:
    """The additive guard, restated for THIS pass: a bundle that authors no
    `jobs {}` block gains no node from it."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var m = compose_api(_bundle(services^, List[JobSpec]()), String("env-a"))
    assert_equal(
        _count_kind(m, ResourceKind.RESOURCE_KIND_SERVICE_ACCOUNT),
        1,
        "exactly the service's own SA — this pass adds nothing",
    )


# =============================================================================
# §C — OUTBOUND AUTH: the marker, the in-edge, and the two grants.
# =============================================================================
def test_service_ref_becomes_a_marker_an_edge_and_an_invoke_grant() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var env = List[BundleEnvVar]()
    env.append(_svcref(String("SVC_URL"), String("svc-a")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("job-a"),
            env^,
            List[SecretBinding](),
            String("job-a-role"),
            Optional[Int32](Int32(0)),
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))

    var ji = _node_index(m, String("job-a-job"))
    assert_true(ji >= 0, "job node present")
    var js = m.nodes[ji].run_to_completion_job.value().copy()
    # (1) THE MARKER, NOT A SCRAPED URL: a scraped-URL derivation fails with an
    # EMPTY STRING rather than an error.
    assert_equal(
        js.env[String("SVC_URL__SVCREF")],
        String("svc-a"),
        "the typed sibling ref, resolved by the same seam every consumer uses",
    )
    assert_true(
        String("SVC_URL") not in js.env,
        "the raw key is NOT baked — the URL does not exist at compose time",
    )
    # (2) THE IN-EDGES — the job is defined only after the service it will call
    # AND after the identity it runs as.
    # This job authors an identity no sibling composes, so this pass MINTS its
    # SERVICE_ACCOUNT node and the job orders after it.
    assert_equal(len(m.nodes[ji].depends_on), 2, "two in-edges")
    assert_equal(
        m.nodes[ji].depends_on[0], String("svc-a-svc"), "on the callee's node"
    )
    assert_equal(
        m.nodes[ji].depends_on[1],
        String("job-a-role-sa"),
        "and on the identity node this pass minted for it",
    )
    # (3) THE INVOKE GRANT — without it the call 403s with an empty body.
    var gi = _node_index(m, String("job-a-job-invokes-svc-a"))
    assert_true(gi >= 0, "the invoke grant is composed, not assumed")
    var g = m.nodes[gi].grant.value().copy()
    assert_equal(
        g.principal_identity_ref,
        String("job-a-role"),
        "principal is the JOB's identity, not the service's",
    )
    assert_equal(
        g.capability.value,
        Capability.CAPABILITY_INVOKE_SERVICE,
        "INVOKE_SERVICE",
    )
    assert_equal(g.target_resource_logical_id, String("svc-a-svc"), "on the callee")


def test_a_mounted_secret_gets_a_resource_scoped_read_grant() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var bindings = List[SecretBinding]()
    bindings.append(_binding(String("secret-a")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("job-a"),
            List[BundleEnvVar](),
            bindings^,
            String("job-a-role"),
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var gi = _node_index(
        m, String("job-a-job-reads-secret-a")
    )
    assert_true(
        gi >= 0,
        "the secret read grant is composed — declared graph state, not a manual"
        " one-time prerequisite",
    )
    var g = m.nodes[gi].grant.value().copy()
    assert_equal(
        g.capability.value, Capability.CAPABILITY_READ_SECRET, "READ_SECRET"
    )
    assert_equal(
        g.target_resource_logical_id,
        String("secret-a"),
        "scoped to the NAMED secret, never project-wide",
    )


def test_a_job_inherits_the_first_service_identity_when_unset() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("inheritor"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String(""),  # UNSET
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var js = m.nodes[
        _node_index(m, String("inheritor-job"))
    ].run_to_completion_job.value().copy()
    assert_equal(
        js.runtime_identity,
        String("svc-a-role"),
        "the bundle's identity — never a broader one",
    )


def test_a_derived_service_identity_is_what_a_job_inherits() raises:
    """A service with NO authored `runtime_identity` derives `<name>-role`; a job
    inheriting from it must get that same derived string, not an empty one."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("inheritor"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String(""),
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var js = m.nodes[
        _node_index(m, String("inheritor-job"))
    ].run_to_completion_job.value().copy()
    assert_equal(js.runtime_identity, String("svc-a-role"), "the derived identity")


# =============================================================================
# §D — THE THREE REFUSALS.
# =============================================================================
def test_value_from_on_a_job_is_refused() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var env = List[BundleEnvVar]()
    env.append(_deploy_url(String("TARGET_URL")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("g"),
            env^,
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    var raised = False
    var msg = String("")
    try:
        var _m = compose_api(_bundle(services^, jobs^), String("env-a"))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a job has no serving URL of its own -> refuse")
    assert_true(
        String("service_ref") in msg,
        "and the refusal names the spelling that IS answerable",
    )


def test_a_non_sibling_service_ref_is_refused() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var env = List[BundleEnvVar]()
    env.append(_svcref(String("OTHER_URL"), String("not-in-this-bundle")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("g"),
            env^,
            List[SecretBinding](),
            String("svc-a-role"),
            None,
        )
    )
    var raised = False
    try:
        var _m = compose_api(_bundle(services^, jobs^), String("env-a"))
    except e:
        raised = True
    assert_true(
        raised,
        "the invoke grant is composed from this graph, so the target must be"
        " in it",
    )


def test_a_job_with_no_identity_anywhere_is_refused() raises:
    """Cloud Run fills an empty `service_account_email` with the project DEFAULT
    compute SA — broader than anything the bundle declares, and scoped by no
    grant here. Defaulting to it silently is the failure this refusal prevents."""
    var orphan = _job(
        String("orphan"),
        List[BundleEnvVar](),
        List[SecretBinding](),
        String(""),
        None,
    )
    var raised = False
    var msg = String("")
    try:
        var _id = _job_runtime_identity(
            orphan, List[ServiceSpec](), CLOUD_GCP
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "no identity to inherit -> refuse")
    assert_true(
        String("DEFAULT compute service account") in msg,
        "and the message says WHY, not just that it refused",
    )


# =============================================================================
# §D2 — ONE PRINCIPAL PER GRAPH-MINTED ROLE, so a job in a SERVICE-BEARING
#   bundle must author its own identity ON AWS.
# =============================================================================
def test_an_inherited_job_identity_is_refused_on_aws() raises:
    """Without the refusal the job silently inherits the service's identity, and
    on AWS that is ONE IAM role a Lambda and an ECS task both run as — which
    cannot trust one service principal, so it would have to trust both.

    The refusal is CLOUD-ASYMMETRIC and that is the accepted cost. This case
    and the GCP one below are the two halves of that statement."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("inheritor"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String(""),  # UNSET -> would inherit
            None,
        )
    )
    var raised = False
    var msg = String("")
    try:
        var _m = compose_api(
            _bundle(services^, jobs^), String("env-b"), cloud=CLOUD_AWS
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        String(
            "a job inheriting a service's identity composed cleanly on AWS. One"
            " IAM role would then be run by both a Lambda and an ECS task."
        ),
    )
    # THE MESSAGE MUST TEACH. This refusal WILL surprise the first author who
    # adds a job to a service-bearing bundle, so each leg below is one thing that
    # author needs and would otherwise have to go and find.
    assert_true(
        String("inheritor") in msg,
        String("(a) names the JOB that failed; got: ") + msg,
    )
    assert_true(
        String("svc-a-role") in msg and String("'svc-a'") in msg,
        String("(b) names what it WOULD have inherited, and from where"),
    )
    assert_true(
        String("ecs-tasks.amazonaws.com") in msg
        and String("lambda.amazonaws.com") in msg,
        String(
            "(c) names BOTH principals — a message naming one tells an operator"
            " a fact, not a difference"
        ),
    )
    assert_true(
        String("On GCP") in msg,
        String(
            "(d) says the asymmetry is deliberate. Without it the author"
            " reasonably concludes the composer is broken, because the same"
            " bundle composes on the other cloud."
        ),
    )
    assert_true(
        String("`runtime_identity:") in msg,
        String("(e) names THE FIX — author `runtime_identity` on the job"),
    )
    assert_true(
        String("REJECTED") in msg
        and String("<job>-job-role") in msg,
        String(
            "(f) names the two answers already rejected, so the next reader"
            " does not re-propose inheritance or a derived `<job>-job-role`"
        ),
    )


def test_the_same_inheriting_bundle_composes_on_gcp() raises:
    """THE OTHER HALF OF THE ASYMMETRY, ASSERTED RATHER THAN COMMENTED. If
    this ever goes red the refusal above stopped being cloud-scoped and became a
    breaking change to every GCP bundle that inherits."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("inheritor"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String(""),
            None,
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var js = m.nodes[
        _node_index(m, String("inheritor-job"))
    ].run_to_completion_job.value().copy()
    assert_equal(
        js.runtime_identity,
        String("svc-a-role"),
        "on GCP the inheritance is unchanged — one SA runs the service and the"
        " job, and no trust document exists to be widened",
    )


def test_an_authored_job_identity_composes_on_aws() raises:
    """The refusal is about INHERITANCE, not about jobs on AWS. A job that
    authors its own identity composes, and this pass mints it."""
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("job-b"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("job-b-role"),
            None,
        )
    )
    var m = compose_api(
        _bundle(services^, jobs^), String("env-b"), cloud=CLOUD_AWS
    )
    assert_true(
        _node_index(m, String("job-b-role-sa")) >= 0,
        "the authored identity is minted on AWS too",
    )
    var js = m.nodes[
        _node_index(m, String("job-b-job"))
    ].run_to_completion_job.value().copy()
    assert_equal(
        js.runtime_identity,
        String("job-b-role"),
        "and the job runs as it — a role no service in this graph runs as",
    )


# =============================================================================
# §E — the proto3-optional property, end to end through compose.
# =============================================================================
def test_demanded_zero_retries_is_distinguishable_from_silence() raises:
    var services = List[ServiceSpec]()
    services.append(_service(String("svc-a"), String("svc-a-role")))
    var jobs = List[JobSpec]()
    jobs.append(
        _job(
            String("gate"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            Optional[Int32](Int32(0)),  # "a failure is the verdict"
        )
    )
    jobs.append(
        _job(
            String("quiet"),
            List[BundleEnvVar](),
            List[SecretBinding](),
            String("svc-a-role"),
            None,  # said nothing
        )
    )
    var m = compose_api(_bundle(services^, jobs^), String("env-a"))
    var gate = m.nodes[
        _node_index(m, String("gate-job"))
    ].run_to_completion_job.value().copy()
    var quiet = m.nodes[
        _node_index(m, String("quiet-job"))
    ].run_to_completion_job.value().copy()
    assert_true(Bool(gate.max_retries), "the demand survives compose")
    assert_equal(Int(gate.max_retries.value()), 0, "as 0")
    assert_true(
        not Bool(quiet.max_retries),
        "and silence stays silence — collapsing the two would let a gate whose"
        " whole contract is exit-code-is-verdict acquire retries",
    )


def main() raises:
    test_job_node_carries_every_authored_field()
    test_two_jobs_compose_two_nodes_in_declaration_order()
    test_unset_max_retries_and_region_flow_through_as_unset()
    test_from_build_image_carries_the_symbolic_marker()
    test_a_bundle_with_no_jobs_composes_zero_job_nodes()
    test_a_job_with_an_authored_identity_mints_its_own_service_account()
    test_a_job_sharing_a_sibling_identity_mints_no_second_account()
    test_an_inherited_identity_is_never_minted()
    test_a_colliding_job_sa_logical_id_is_refused()
    test_a_bundle_with_no_jobs_mints_no_job_identity()
    test_service_ref_becomes_a_marker_an_edge_and_an_invoke_grant()
    test_a_mounted_secret_gets_a_resource_scoped_read_grant()
    test_a_job_inherits_the_first_service_identity_when_unset()
    test_a_derived_service_identity_is_what_a_job_inherits()
    test_value_from_on_a_job_is_refused()
    test_a_non_sibling_service_ref_is_refused()
    test_a_job_with_no_identity_anywhere_is_refused()
    test_an_inherited_job_identity_is_refused_on_aws()
    test_the_same_inheriting_bundle_composes_on_gcp()
    test_an_authored_job_identity_composes_on_aws()
    test_demanded_zero_retries_is_distinguishable_from_silence()
    print("PASS test_compose_jobs")
