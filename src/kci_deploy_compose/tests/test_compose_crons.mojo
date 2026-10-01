# =============================================================================
# kci_deploy_compose/tests/test_compose_crons.mojo — the CRON composition gate
#   (`AppBundle.crons[]` -> a SCHEDULED_CALL graph node).
# =============================================================================
#
# WHAT THIS PINS. Each section is written as the FALSIFIER of one claim the
# capability makes, because a cron that composes wrong fails in the one direction
# nothing reports: the deploy is green and the timer never fires (or fires at a
# URL nobody authorized it to call).
#
#   §A TWO NODES, NOT ONE — one authored cron composes a GRANT
#      {invoker, INVOKE_SERVICE, <T>-svc} AND a SCHEDULED_CALL that `depends_on`
#      BOTH the grant and the target. The two are only correct together: a cron
#      whose SA holds no run.invoker gets a 403 with an empty body on every
#      tick, forever, behind a green deploy.
#   §B THE FIELDS SURVIVE onto arm 20 (kind 21, RETENTION_DELETE), and the node
#      carries the TARGET'S LOGICAL ID — never a url. If a url ever appears on
#      this node, the whole "the address is observed, not authored" property is
#      gone and nothing else in the system would notice.
#   §C EMPTY invoker_identity DEFAULTS TO THE TARGET'S RUNTIME IDENTITY, never to
#      "no auth". There is deliberately no unauthenticated arm.
#   §D ZERO CRONS COMPOSES NO CRON NODE — the additive-safety guard, stated as
#      its falsifier: a cron-free bundle emits no SCHEDULED_CALL node and no cron
#      invoke grant, and its address is stable.
#   §E FAIL-CLOSED ON A TARGET THIS BUNDLE DOES NOT COMPOSE. Kahn's algorithm
#      does not fail on a dangling `depends_on` — it silently never schedules the
#      node — so compose must raise instead.
#
# Encapsulation: pure struct construction + `compose_api` + value asserts — no
# UnsafePointer, no store, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_deploy_compose.compose_api import compose_api
from kci_deploy_compose.content_address import content_address

from full_manifest_rpc.full_manifest import (
    FullManifest,
    ResourceNode,
    ResourceKind,
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
    BuildTarget,
    BundleEnvVar,
    BucketSpec,
    CronSpec,
    DeployOutput,
    ImageRef,
    JobSpec,
    Matrix,
    OutputFormat,
    Pipeline,
    Scaling,
    SecretBinding,
    SecuredInboundRoute,
    ServiceRef,
    ServiceSpec,
    TriggerSource,
    ValidationSet,
    Wave,
    WebRouteRule,
)
from komira_rpc_bundle.deploy_model import (
    BundleIndexTable,
    ComputeIntent,
    DatastoreNeed,
    InboundNeed,
    NetworkIngress,
)

# The SCHEDULED_CALL config-oneof arm index (kind 21, field 24). The generated
# `_oneof0_case` is the 1-BASED ARM INDEX in declaration order — there is no
# generated symbol for it, so it is pinned here by the same convention the
# TriggerSpec (15) / ApiEdgeSpec (19) tests use.
comptime ARM_SCHEDULED_CALL: Int = 20
# The GRANT arm, for the sibling invoke-grant node.
comptime ARM_GRANT: Int = 17


def _spec(var runtime_identity: String) raises -> AppSpec:
    """A minimal served AppSpec — a pinned digest, no datastore, no ingress."""
    return AppSpec(
        Optional[ImageRef](
            ImageRef(1, Optional[String](String("sha256:feedface")), None)
        ),
        Int32(8080),
        List[BundleEnvVar](),
        Optional[Scaling](Scaling(Int32(1), Int32(1))),
        ComputeIntent(ComputeIntent.COMPUTE_INTENT_SERVERLESS),
        DatastoreNeed(DatastoreNeed.DATASTORE_NEED_UNSPECIFIED),
        List[SecretBinding](),
        runtime_identity^,
        String(""),
        Int32(0),
        String(""),
        String(""),
        String(""),
        String(""),
        List[String](),
        List[String](),
        String(""),
        InboundNeed(0),
        String(""),
        List[BucketSpec](),
        List[Int32](),
        List[WebRouteRule](),
        String(""),
        False,
        None,
        List[SecuredInboundRoute](),
        String(""),
        String(""),
        List[BundleIndexTable](),
        None,
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


def _bundle(var name: String, var crons: List[CronSpec]) raises -> AppBundle:
    """A single-service API bundle named `name`, carrying `crons`. The service is
    AUTO-LIFTED from the spec, so its node ids are `<name>-svc` / `<name>-role`."""
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        name^,
        List[BuildTarget](),
        Optional[AppSpec](_spec(String(""))),
        List[Wave](),
        List[TriggerSource](),
        List[ServiceSpec](),
        List[ValidationSet](),
        Optional[Pipeline](),
        List[Matrix](),
        List[DeployOutput](),
        List[JobSpec](),
        crons^,
        None,
        Tenancy(Tenancy.TENANCY_UNSPECIFIED),  # field 15 (tenancy): kci composes none
    )


def _cron(
    var name: String,
    var cron: String,
    var target: String,
    var path: String,
    var invoker: String,
) raises -> CronSpec:
    return CronSpec(
        name^,
        cron^,
        String("Etc/UTC"),
        Optional[ServiceRef](ServiceRef(target^)),
        path^,
        String("POST"),
        invoker^,
        Int32(300),
    )


def _find(m: FullManifest, lid: String) -> Int:
    for i in range(len(m.nodes)):
        if m.nodes[i].logical_id == lid:
            return i
    return -1


# =============================================================================
# §A — TWO NODES: the grant AND the scheduled call, with the ordering edges.
# =============================================================================
def test_a_cron_composes_its_invoker_grant_and_depends_on_it() raises:
    var crons = List[CronSpec]()
    crons.append(
        _cron(
            String("reconcile-backstop"),
            String("* * * * *"),
            String("svc-a"),
            # A route the service actually serves: a mechanism test proves any
            # string survives compose, so the string it demonstrates with should
            # be one people can copy.
            String("/internal/backstop"),
            String("svc-a-role"),
        )
    )
    var m = compose_api(_bundle(String("svc-a"), crons^), String("env-a"))

    var gi = _find(m, String("reconcile-backstop-cron-invoke-grant"))
    var ci = _find(m, String("reconcile-backstop-cron"))
    assert_true(gi >= 0, "the invoker GRANT node must exist")
    assert_true(ci >= 0, "the SCHEDULED_CALL node must exist")

    # The grant: the invoker is authorized INVOKE_SERVICE on the target's served
    # node, and it is ordered AFTER that node (grant-after-target-exists).
    assert_equal(
        m.nodes[gi].kind.value, ResourceKind.RESOURCE_KIND_GRANT, "grant kind"
    )
    assert_equal(m.nodes[gi]._oneof0_case, ARM_GRANT, "grant arm 17")
    ref gs = m.nodes[gi].grant.value()
    assert_equal(
        gs.principal_identity_ref,
        String("svc-a-role"),
        "the grant's member is the cron's invoker identity",
    )
    assert_equal(
        gs.capability.value,
        Capability.CAPABILITY_INVOKE_SERVICE,
        "the grant is INVOKE_SERVICE — the run.invoker-class binding the cron"
        " needs",
    )
    assert_equal(
        gs.target_resource_logical_id,
        String("svc-a-svc"),
        "the grant targets the served node the cron calls",
    )
    assert_equal(len(m.nodes[gi].depends_on), 1, "grant has one edge")
    assert_equal(
        m.nodes[gi].depends_on[0],
        String("svc-a-svc"),
        "grant-after-target-exists",
    )

    # The cron depends on BOTH. This is the assertion that matters: drop either
    # edge and the scheduler object can be created before the thing it calls
    # exists, or before that call is authorized — and a 403 on a cron tick is
    # silent.
    ref deps = m.nodes[ci].depends_on
    assert_equal(len(deps), 2, "the cron has TWO edges, not one")
    var saw_svc = False
    var saw_grant = False
    for i in range(len(deps)):
        if deps[i] == String("svc-a-svc"):
            saw_svc = True
        if deps[i] == String("reconcile-backstop-cron-invoke-grant"):
            saw_grant = True
    assert_true(saw_svc, "the cron depends_on the served node it calls")
    assert_true(
        saw_grant,
        "the cron depends_on its OWN invoker grant — without this edge the"
        " scheduler object can exist before the identity it authenticates as is"
        " authorized, and every tick 403s behind a green deploy",
    )


# =============================================================================
# §B — the fields survive onto arm 20, and NO URL appears anywhere on the node.
# =============================================================================
def test_the_scheduled_call_carries_the_target_id_and_never_a_url() raises:
    var crons = List[CronSpec]()
    crons.append(
        _cron(
            String("reconcile-backstop"),
            String("* * * * *"),
            String("svc-a"),
            # A route the service actually serves: a mechanism test proves any
            # string survives compose, so the string it demonstrates with should
            # be one people can copy.
            String("/internal/backstop"),
            String("svc-a-role"),
        )
    )
    var m = compose_api(_bundle(String("svc-a"), crons^), String("env-a"))
    var ci = _find(m, String("reconcile-backstop-cron"))
    assert_true(ci >= 0, "the SCHEDULED_CALL node must exist")

    assert_equal(
        m.nodes[ci].kind.value,
        ResourceKind.RESOURCE_KIND_SCHEDULED_CALL,
        "kind 21",
    )
    assert_equal(m.nodes[ci]._oneof0_case, ARM_SCHEDULED_CALL, "arm 20")
    assert_equal(
        m.nodes[ci].retention.value,
        Retention.RETENTION_DELETE,
        "a cron holds no data and is deterministically recreatable — a KEPT cron"
        " on a destroyed service is a timer calling a 404 forever, and it bills",
    )
    ref sc = m.nodes[ci].scheduled_call.value()
    assert_equal(
        sc.target_logical_id,
        String("svc-a-svc"),
        "the target is named by LOGICAL ID",
    )
    assert_equal(sc.cron, String("* * * * *"), "the schedule survives")
    assert_equal(sc.timezone, String("Etc/UTC"), "the timezone survives")
    assert_equal(sc.path, String("/internal/backstop"), "the path survives")
    assert_equal(sc.http_method, String("POST"), "the method survives")
    assert_equal(
        sc.invoker_identity,
        String("svc-a-role"),
        "the invoker identity survives — and it is the SAME string the sibling"
        " grant authorizes, so the account that mints the token and the account"
        " the target authorizes cannot be two different accounts",
    )
    assert_equal(
        Int(sc.attempt_deadline_seconds), 300, "the attempt deadline survives"
    )
    # THE URL FALSIFIER. Nothing on this node may look like an address: the
    # serving URL is assigned by the cloud at service-create with a
    # server-generated hash, so an authored one is a guess that fails closed and
    # silent. This assertion is what keeps a well-meaning "just cache the url
    # here" from landing.
    assert_true(
        not sc.target_logical_id.startswith(String("http")),
        "the target is a logical id, not a url",
    )
    assert_true(
        sc.path.startswith(String("/")),
        "the path is a path, not an absolute url",
    )


# =============================================================================
# §C — an EMPTY invoker defaults to the target's runtime identity, never no-auth.
# =============================================================================
def test_an_empty_invoker_defaults_to_the_targets_runtime_identity() raises:
    var crons = List[CronSpec]()
    crons.append(
        _cron(
            String("tick"),
            String("0 * * * *"),
            String("orders-api"),
            String("/tick"),
            String(""),  # EMPTY — the default path
        )
    )
    var m = compose_api(_bundle(String("orders-api"), crons^), String("env-a"))
    var ci = _find(m, String("tick-cron"))
    assert_true(ci >= 0, "the SCHEDULED_CALL node must exist")
    ref sc = m.nodes[ci].scheduled_call.value()
    assert_equal(
        sc.invoker_identity,
        String("orders-api-role"),
        "an EMPTY invoker_identity resolves to the TARGET's runtime identity —"
        " the derived `<service>-role`. It must NEVER resolve to 'no auth': an"
        " unauthenticated arm here is how a scheduled call to a private service"
        " becomes a scheduled call to a public one",
    )
    # And the grant follows the same value, so there is exactly one account.
    var gi = _find(m, String("tick-cron-invoke-grant"))
    assert_true(gi >= 0, "the invoker GRANT node must exist")
    assert_equal(
        m.nodes[gi].grant.value().principal_identity_ref,
        String("orders-api-role"),
        "the grant authorizes the SAME account the cron mints as",
    )


# =============================================================================
# §D — ZERO crons composes no cron node (the additive-safety falsifier).
# =============================================================================
def test_zero_crons_composes_byte_identically() raises:
    var without = compose_api(
        _bundle(String("orders-api"), List[CronSpec]()), String("env-a")
    )
    # Recompose the SAME cron-free bundle: no SCHEDULED_CALL node, no
    # cron-invoke-grant node, and a stable content address.
    var again = compose_api(
        _bundle(String("orders-api"), List[CronSpec]()), String("env-a")
    )
    assert_equal(
        without.content_address,
        again.content_address,
        "compose stays deterministic",
    )
    for i in range(len(without.nodes)):
        assert_true(
            without.nodes[i].kind.value
            != ResourceKind.RESOURCE_KIND_SCHEDULED_CALL,
            "a bundle authoring no `crons {}` emits ZERO SCHEDULED_CALL nodes —"
            " this is the additive-safety claim stated as its falsifier",
        )
        assert_true(
            not without.nodes[i].logical_id.endswith(
                String("-cron-invoke-grant")
            ),
            "and ZERO cron invoke grants",
        )
    # The address is a pure function of the emitted graph, so an unchanged graph
    # is an unchanged address: this is what "additive" means here.
    assert_equal(
        content_address(without),
        without.content_address,
        "the pinned address is the address of the emitted graph",
    )


# =============================================================================
# §E — FAIL-CLOSED on a target this bundle does not compose.
# =============================================================================
def test_a_cron_targeting_an_uncomposed_service_raises() raises:
    var crons = List[CronSpec]()
    crons.append(
        _cron(
            String("tick"),
            String("0 * * * *"),
            String("some-other-app"),  # not a service THIS bundle composes
            String("/tick"),
            String("orders-api-role"),
        )
    )
    var raised = False
    try:
        var _m = compose_api(
            _bundle(String("orders-api"), crons^), String("env-a")
        )
    except:
        raised = True
    assert_true(
        raised,
        "a cron whose target this bundle does not COMPOSE must RAISE. Kahn's"
        " algorithm does not fail on a dangling `depends_on` — it silently never"
        " schedules the node — so the deploy would report converged with no cron"
        " and nothing would name the missing edge",
    )


def main() raises:
    test_a_cron_composes_its_invoker_grant_and_depends_on_it()
    test_the_scheduled_call_carries_the_target_id_and_never_a_url()
    test_an_empty_invoker_defaults_to_the_targets_runtime_identity()
    test_zero_crons_composes_byte_identically()
    test_a_cron_targeting_an_uncomposed_service_raises()
    print("PASS test_compose_crons")
