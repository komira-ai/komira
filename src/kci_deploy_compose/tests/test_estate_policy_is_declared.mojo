# =============================================================================
# kci_deploy_compose/tests/test_estate_policy_is_declared.mojo
#   WHAT A DEPLOYMENT'S OWN POLICY LOOKS LIKE TO THE COMPOSER: A DECLARATION
#   (by the bundle or by the target environment's definition), never a literal
#   the composer carries.
# =============================================================================
#
# The composer is generic: it knows no particular environment, secret, front-end
# key set or identity marker of any one deploying system. Each leg below pins one
# place where that is a behaviour rather than a comment:
#
#   §1 DEVELOPER ACCESS — a peer-only edge's developer-access principal composes
#      only when the CALLER says the target environment allows it
#      (`developer_access_allowed`), and is refused by name otherwise. The
#      default refuses, so an environment that says nothing is closed.
#   §2 AUTHORIZER ENV KEYS — an AWS identity-JWT edge's authorizer reads its
#      issuer and audience from env keys the BUNDLE declares. The schema this
#      package builds against cannot carry that declaration yet, so the edge is
#      refused, naming the field — never composed with invented key names.
#   §3 RUNTIME CONFIG — a static front end projects into its public
#      `config.json` only the keys the bundle declares public. Nothing is
#      declared in this schema, so nothing is projected, whatever the env holds.
#   §4 RETIRED PARAMETER MARKERS — the deploying system's identity markers
#      (deployment id, signing key set, org id, org mail domain) are refused by
#      name; the target-derived markers still render.
#   §5 NO BASE SECRET GRANT — a self-provisioned runtime SA gets a READ_SECRET
#      grant for exactly the secrets its service declares in `secret_bindings`,
#      and for nothing else.
#   §6 SUPERVISOR PLACEMENT FIELDS — the supervisor's image and report target
#      are facts of the placement side, so compose leaves them empty.
#
# Pure struct construction + pure functions — no store, no cloud, no
# UnsafePointer.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from kci_deploy_compose.compose_api import (
    CLOUD_AWS,
    compose,
    compose_api,
)
from kci_deploy_compose.param_resolve import param_marker_token

from full_manifest_rpc.full_manifest import (
    Capability,
    FullManifest,
    ResourceKind,
)

from komira_rpc_bundle.app_bundle import (
    NameScope,
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
    IngressSpec,
    EdgeCallerClass,
    ParamMarker,
)
from komira_rpc_bundle.deploy_model import (
    BundleIndexTable,
    InboundNeed,
    NetworkIngress,
    ComputeIntent,
    DatastoreNeed,
    SecretBinding,
    SecretCustody,
)


comptime _ENV: String = "env-a"
comptime _ISSUER: String = "https://issuer.example.com"
comptime _AUDIENCE: String = "aud-a"
comptime _DEV_PRINCIPAL: String = "dev-a@example.com"


# =============================================================================
# FIXTURES
# =============================================================================
def _spec(
    inbound: Int,
    var runtime_identity: String,
    var secret_bindings: List[SecretBinding],
    var env: List[BundleEnvVar],
    var ingress: Optional[IngressSpec],
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
        secret_bindings^,
        runtime_identity^,  # runtime_identity
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
        ingress^,  # ingress
        List[AppParameter](),  # parameters
        NetworkIngress(0),  # network_ingress
        None,  # network_egress
        None,  # mail_transport
        List[DatastoreCollection](),  # datastore_collections
        List[CloudVariant](),  # cloud_variants
        NameScope(NameScope.NAME_SCOPE_UNSPECIFIED),  # name_scope
        None,  # cpu
        None,  # memory
        None,  # health_check_path
    )


def _bundle(
    kind: Int, var name: String, var spec: AppSpec, var waves: List[Wave]
) raises -> AppBundle:
    return AppBundle(
        AppKind(kind),
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


def _peer_only_bundle(var developer_access_principal: String) raises -> AppBundle:
    """One CLIENT-inbound service whose `ingress` answers PEER_INTERNAL, on an
    api-edge-enabled wave that names the issuer its peers trust."""
    var ing = IngressSpec(
        String(""),  # gateway_service_account
        String(""),  # gateway_region
        List[String](),  # allowed_sources
        False,  # enable_required_services
        EdgeCallerClass(EdgeCallerClass.EDGE_CALLER_CLASS_PEER_INTERNAL),
        String(_AUDIENCE),  # peer_identity_audience
    )
    var waves = List[Wave]()
    waves.append(
        Wave(
            String(_ENV),
            List[ValidateStep](),
            True,  # api_edge_enabled
            List[BundleEnvVar](),
            List[AppParameter](),
            String(_ISSUER),  # peer_identity_issuer (6)
            developer_access_principal^,  # developer_access_principal (7)
            Optional[WebFrontendOverride](),  # web_override (8)
            List[String](),  # api_edge_services (9)
        )
    )
    return _bundle(
        AppKind.APP_KIND_API,
        String("svc-a"),
        _spec(
            InboundNeed.INBOUND_NEED_CLIENT,
            String(""),
            List[SecretBinding](),
            List[BundleEnvVar](),
            Optional[IngressSpec](ing^),
        ),
        waves^,
    )


def _literal(var name: String, var value: String) raises -> BundleEnvVar:
    return BundleEnvVar(name^, String(""), 1, Optional[String](value^), None, None)


def _edge_index(m: FullManifest) -> Int:
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value == ResourceKind.RESOURCE_KIND_API_EDGE:
            return i
    return -1


# =============================================================================
# §1 — DEVELOPER ACCESS IS AN ENVIRONMENT-DEFINITION FACT.
# =============================================================================
def test_developer_access_requires_env_definition() raises:
    # Without the environment's opt-in, a wave that authors a developer-access
    # principal is REFUSED, and the refusal names the environment-definition
    # field that would allow it.
    var raised = False
    var msg = String("")
    try:
        _ = compose_api(_peer_only_bundle(String(_DEV_PRINCIPAL)), String(_ENV))
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "a developer-access principal composed on an env whose definition did"
        " not allow it — the default must refuse",
    )
    assert_true(
        String("developer_access_allowed") in msg,
        String("the refusal names the environment-definition field; got: ") + msg,
    )

    # With the opt-in, the same bundle composes and the edge carries the
    # principal.
    var m = compose_api(
        _peer_only_bundle(String(_DEV_PRINCIPAL)),
        String(_ENV),
        developer_access_allowed=True,
    )
    var ei = _edge_index(m)
    assert_true(ei >= 0, "the peer-only edge is composed")
    assert_equal(
        m.nodes[ei].api_edge.value().developer_access_principal,
        String(_DEV_PRINCIPAL),
        "the allowed principal rides the edge",
    )
    assert_equal(
        m.nodes[ei].api_edge.value().identity_issuer,
        String(_ISSUER),
        "and the edge trusts the wave's issuer",
    )

    # And a wave that authors NO principal composes on any env, opt-in or not:
    # the gate is about the principal, not about peer-only edges.
    var plain = compose_api(_peer_only_bundle(String("")), String(_ENV))
    var pi = _edge_index(plain)
    assert_true(pi >= 0, "a peer-only edge without a principal composes")
    assert_equal(
        plain.nodes[pi].api_edge.value().developer_access_principal,
        String(""),
        "no principal authored, none composed",
    )
    print("  test_developer_access_requires_env_definition: PASS")


def test_compose_threads_developer_access_allowed() raises:
    # The dispatcher `compose` forwards the opt-in to the API composition.
    var m = compose(
        _peer_only_bundle(String(_DEV_PRINCIPAL)),
        String(_ENV),
        developer_access_allowed=True,
    )
    var ei = _edge_index(m)
    assert_true(ei >= 0, "the peer-only edge is composed through `compose`")
    assert_equal(
        m.nodes[ei].api_edge.value().developer_access_principal,
        String(_DEV_PRINCIPAL),
    )
    print("  test_compose_threads_developer_access_allowed: PASS")


# =============================================================================
# §2 — THE AUTHORIZER'S ENV KEYS ARE THE BUNDLE'S DECLARATION.
# =============================================================================
def test_authorizer_env_keys_are_declared() raises:
    # An AWS identity-JWT edge needs a CUSTOM REQUEST authorizer that reads the
    # issuer and audience from env keys. Those keys are the authorizer's own
    # contract; this schema has no field to declare them, so the edge is
    # refused naming the field — never composed with a kci-invented key.
    var raised = False
    var msg = String("")
    try:
        _ = compose_api(
            _peer_only_bundle(String("")), String(_ENV), cloud=CLOUD_AWS
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "an AWS identity-JWT edge composed without a declared authorizer env key",
    )
    assert_true(
        String("authorizer_issuer_env") in msg,
        String("the refusal names the declaration it needs; got: ") + msg,
    )
    print("  test_authorizer_env_keys_are_declared: PASS")


# =============================================================================
# §3 — RUNTIME CONFIG PROJECTS ONLY DECLARED KEYS.
# =============================================================================
def test_runtime_config_projects_declared_keys_only() raises:
    var env = List[BundleEnvVar]()
    env.append(_literal(String("PUBLIC_A"), String("value-a")))
    env.append(_literal(String("CLIENT_API_KEY"), String("value-b")))
    var b = _bundle(
        AppKind.APP_KIND_STATIC_FRONTEND,
        String("site-a"),
        _spec(
            InboundNeed.INBOUND_NEED_UNSPECIFIED,
            String(""),
            List[SecretBinding](),
            env^,
            None,
        ),
        List[Wave](),
    )
    var m = compose(b, String(_ENV))
    assert_equal(len(m.nodes), 1, "one front-door node")
    assert_true(Bool(m.nodes[0].web_frontend), "the node carries its spec")
    assert_equal(
        len(m.nodes[0].web_frontend.value().runtime_config),
        0,
        "no key is declared public, so nothing reaches the public config.json —"
        " not even a key whose NAME looks like a client identifier",
    )
    print("  test_runtime_config_projects_declared_keys_only: PASS")


# =============================================================================
# §4 — THE DEPLOYING SYSTEM'S IDENTITY MARKERS ARE REFUSED.
# =============================================================================
def _refuses(marker: Int) raises -> String:
    try:
        _ = param_marker_token(ParamMarker(marker))
    except e:
        return String(e)
    return String("")


def test_retired_param_markers_refuse() raises:
    var retired = List[Int]()
    retired.append(ParamMarker.PARAM_MARKER_APP_DEPLOYMENT_ID)
    retired.append(ParamMarker.PARAM_MARKER_APP_SIGNING_JWKS)
    retired.append(ParamMarker.PARAM_MARKER_ORG_MAIL_DOMAIN)
    retired.append(ParamMarker.PARAM_MARKER_ORG_ID)
    for i in range(len(retired)):
        var msg = _refuses(retired[i])
        assert_true(
            String("unsupported parameter marker") in msg,
            String("marker ordinal ")
            + String(retired[i])
            + String(" must be refused by name; got: '")
            + msg
            + String("'"),
        )
    # The markers the deploy target itself answers still render.
    assert_equal(
        String(param_marker_token(ParamMarker(ParamMarker.PARAM_MARKER_PROJECT))),
        String("${project}"),
    )
    assert_equal(
        String(param_marker_token(ParamMarker(ParamMarker.PARAM_MARKER_REGION))),
        String("${region}"),
    )
    print("  test_retired_param_markers_refuse: PASS")


# =============================================================================
# §5 — A RUNTIME SA READS EXACTLY THE SECRETS ITS SERVICE DECLARES.
# =============================================================================
def test_runtime_sa_has_no_seed_grant() raises:
    var bindings = List[SecretBinding]()
    bindings.append(
        SecretBinding(
            String("seed-like"),
            String("cap"),
            False,
            SecretCustody(SecretCustody.SECRET_CUSTODY_OPERATOR),
        )
    )
    var b = _bundle(
        AppKind.APP_KIND_API,
        String("svc-a"),
        _spec(
            InboundNeed.INBOUND_NEED_UNSPECIFIED,
            String("svc-a-runtime"),
            bindings^,
            List[BundleEnvVar](),
            None,
        ),
        List[Wave](),
    )
    var m = compose_api(b, String(_ENV))
    var reads = List[String]()
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value != ResourceKind.RESOURCE_KIND_GRANT:
            continue
        ref g = m.nodes[i].grant.value()
        if g.capability.value != Capability.CAPABILITY_READ_SECRET:
            continue
        reads.append(g.target_resource_logical_id.copy())
        assert_equal(
            g.principal_identity_ref,
            String("svc-a-runtime"),
            "the declared secret is granted to the service's runtime SA",
        )
    assert_equal(
        len(reads),
        1,
        "exactly one READ_SECRET grant: the declared binding, and no base grant"
        " on a secret the bundle never named",
    )
    assert_equal(reads[0], String("seed-like"), "the declared handle")
    print("  test_runtime_sa_has_no_seed_grant: PASS")


# =============================================================================
# §6 — THE SUPERVISOR'S PLACEMENT FIELDS ARE NOT COMPOSED.
# =============================================================================
def test_supervisor_placement_fields_are_empty() raises:
    var b = _bundle(
        AppKind.APP_KIND_API,
        String("svc-a"),
        _spec(
            InboundNeed.INBOUND_NEED_UNSPECIFIED,
            String(""),
            List[SecretBinding](),
            List[BundleEnvVar](),
            None,
        ),
        List[Wave](),
    )
    var m = compose_api(b, String(_ENV))
    var checked = 0
    for i in range(len(m.nodes)):
        if m.nodes[i].kind.value != ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE:
            continue
        ref sc = m.nodes[i].serverless_compute.value()
        assert_true(Bool(sc.supervisor), "the served node carries a supervisor")
        assert_equal(
            sc.supervisor.value().supervisor_image_digest,
            String(""),
            "the supervisor image is the placement side's to supply",
        )
        assert_equal(
            sc.supervisor.value().report_target,
            String(""),
            "the heartbeat report target is the placement side's to supply",
        )
        checked += 1
    assert_equal(checked, 1, "one served node checked")
    print("  test_supervisor_placement_fields_are_empty: PASS")


def main() raises:
    # Every leg runs, and a failure is recorded rather than stopping the run, so
    # one run reports every leg that is red.
    var failed = String("")
    try:
        test_developer_access_requires_env_definition()
    except e:
        print("  FAIL developer_access: " + String(e))
        failed += String(" developer_access")
    try:
        test_compose_threads_developer_access_allowed()
    except e:
        print("  FAIL compose_threads: " + String(e))
        failed += String(" compose_threads")
    try:
        test_authorizer_env_keys_are_declared()
    except e:
        print("  FAIL authorizer_keys: " + String(e))
        failed += String(" authorizer_keys")
    try:
        test_runtime_config_projects_declared_keys_only()
    except e:
        print("  FAIL runtime_config: " + String(e))
        failed += String(" runtime_config")
    try:
        test_retired_param_markers_refuse()
    except e:
        print("  FAIL param_markers: " + String(e))
        failed += String(" param_markers")
    try:
        test_runtime_sa_has_no_seed_grant()
    except e:
        print("  FAIL no_seed_grant: " + String(e))
        failed += String(" no_seed_grant")
    try:
        test_supervisor_placement_fields_are_empty()
    except e:
        print("  FAIL supervisor_fields: " + String(e))
        failed += String(" supervisor_fields")
    if failed.byte_length() > 0:
        raise Error(String("test_estate_policy_is_declared: FAILED:") + failed)
    print("test_estate_policy_is_declared: ALL PASS")
