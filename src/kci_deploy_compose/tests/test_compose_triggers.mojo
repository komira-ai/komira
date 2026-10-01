# =============================================================================
# kci_deploy_compose/tests/test_compose_triggers.mojo — the STANDING
#   trigger-manifest composition gate.
# =============================================================================
#
# WHAT THIS PINS.
#   §A EMISSION — a bundle with N `triggers` composes (via `compose_triggers`, NO
#      env param) into a standing FullManifest with EXACTLY N Trigger nodes: each
#      arm 15 (`_oneof0_case == 15`), RETENTION_DELETE, `pipeline_ref == bundle.name`,
#      a STABLE name-keyed logical_id, and the intent-tier `source_kind` / `event`
#      enums TRANSLATED ordinal->ordinal to the standalone tier. The manifest is
#      env-INDEPENDENT (`environment == ""`) + content-addressed.
#   §B ARM-15 ROUND-TRIP (the SILENT-MISPARSE guard) — a manifest carrying a Trigger
#      node (arm 15) CO-RESIDENT with a ServerlessCompute node (arm 1), encoded then
#      decoded through the proto wire, survives with BOTH arms intact (no misparse, no
#      arm displacement) and every TriggerSpec field round-trips.
#   §C ZERO-TRIGGERS — a bundle with no triggers composes to an EMPTY standing
#      manifest (0 nodes) — the one-shot deployment identity — still content-addressed.
#
# Encapsulation: pure struct construction + `compose_triggers` + value asserts — no
# UnsafePointer, no store, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_serde import encode_proto, decode_proto

from kci_deploy_compose.compose_api import (
    CLOUD_GCP,
    compose_triggers,
    _trigger_node,
    _serverless_node,
)
from kci_deploy_compose.content_address import content_address

from full_manifest_rpc.full_manifest import (
    FullManifest,
    ResourceNode,
    ResourceKind,
    Retention,
    TriggerSpec,
    SourceKind,
    RegistryKind,
    ResolvedGitPush,
    ResolvedSchedule,
    ResolvedPackagePublished,
)

from komira_rpc_bundle.app_bundle import (
    # jobs (12) / crons (13) — constructed EMPTY by every fixture below.
    JobSpec,
    CronSpec,
    Matrix,
    DeployOutput,
    AppBundle,
    Tenancy,  # field 15 (tenancy): kci composes none; see `_bundle_with`
    AppKind,
    BuildTarget,
    Wave,
    ServiceSpec,
    ValidationSet,
    Pipeline,
    TriggerSource,
    GitPush,
    Schedule,
    PackagePublished,
    SourceKind as BundleSourceKind,
    RegistryKind as BundleRegistryKind,
)

# The `TriggerSource.on` / `TriggerSpec.on` arm indices — the 1-BASED ARM INDEX in
# declaration order, NOT the proto field numbers (intent 6/7/8, resolved 8/9/10).
comptime ARM_GIT_PUSH: Int = 1
comptime ARM_SCHEDULE: Int = 2
comptime ARM_PACKAGE_PUBLISHED: Int = 3


def _git_push_trigger(
    var name: String, sk: BundleSourceKind, var repo: String, var ref_: String
) -> TriggerSource:
    return TriggerSource(
        name^,
        ARM_GIT_PUSH,
        Optional[GitPush](GitPush(sk, repo^, ref_^)),
        None,
        None,
    )


def _schedule_trigger(
    var name: String, var cron: String, var tz: String
) -> TriggerSource:
    return TriggerSource(
        name^, ARM_SCHEDULE, None, Optional[Schedule](Schedule(cron^, tz^)), None
    )


def _package_trigger(
    var name: String, rk: BundleRegistryKind, var pkg: String, var vrange: String
) -> TriggerSource:
    return TriggerSource(
        name^,
        ARM_PACKAGE_PUBLISHED,
        None,
        None,
        Optional[PackagePublished](PackagePublished(rk, pkg^, vrange^)),
    )


def _bundle_with(triggers: List[TriggerSource]) raises -> AppBundle:
    """An API bundle named `orders-api` carrying `triggers` (kind/spec are
    irrelevant to `compose_triggers` — it reads only `triggers` + `name`)."""
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        String("orders-api"),
        List[BuildTarget](),
        None,
        List[Wave](),
        triggers.copy(),
        List[ServiceSpec](),
        List[ValidationSet](),
        Optional[Pipeline](),
        List[Matrix](),  # field 10 matrices
        List[DeployOutput](),  # field 11 outputs
        # jobs (12) / crons (13) / ephemeral (14) — empty/None.
        List[JobSpec](),
        List[CronSpec](),
        None,
        Tenancy(Tenancy.TENANCY_UNSPECIFIED),  # field 15 (tenancy): kci composes none
    )


# =============================================================================
# §A — EMISSION: N triggers -> N standing Trigger nodes (arm 15, translated enums).
# =============================================================================
def test_compose_triggers_emits_n_nodes() raises:
    var triggers = List[TriggerSource]()
    # A self-hosted push, an external push, and a SCHEDULE — the mixed fan-in,
    # now spanning two DIFFERENT arms rather than two values of one enum.
    triggers.append(
        _git_push_trigger(
            String("selfhosted-a"),
            BundleSourceKind(BundleSourceKind.SOURCE_KIND_GIT_SELFHOSTED),
            String("org/repo-a"),
            String("main"),
        )
    )
    triggers.append(
        _git_push_trigger(
            String("external-b"),
            BundleSourceKind(BundleSourceKind.SOURCE_KIND_GIT_EXTERNAL),
            String("org/repo-b"),
            String("release"),
        )
    )
    triggers.append(
        _schedule_trigger(
            String("weekly-sync"), String("0 6 * * 1"), String("UTC")
        )
    )
    var m = compose_triggers(_bundle_with(triggers))

    # env-independent standing manifest, content-addressed.
    assert_equal(m.environment, String(""), "standing manifest is env-independent")
    assert_equal(len(m.nodes), 3, "three Trigger nodes for three bundle.triggers")
    assert_true(m.content_address.startswith("sha256:"), "content_address sha256: prefix")
    assert_equal(m.content_address.byte_length(), 71, "content_address = 7 prefix + 64 hex")
    assert_equal(content_address(m), m.content_address, "content_address stamp is idempotent")

    # -- node 0: self-hosted PUSH on repo-a --------------------------------------
    var n0 = m.nodes[0].copy()
    assert_equal(
        n0.logical_id, String("trigger-selfhosted-a"), "n0 stable NAME-keyed id"
    )
    assert_equal(n0.kind.value, ResourceKind.RESOURCE_KIND_TRIGGER, "n0 kind TRIGGER")
    assert_equal(n0._oneof0_case, 15, "n0 trigger arm 15")
    assert_equal(len(n0.depends_on), 0, "n0 standing root (no deps)")
    assert_equal(n0.retention.value, Retention.RETENTION_DELETE, "n0 RETENTION_DELETE")
    var t0 = n0.trigger.value().copy()
    assert_equal(t0.name, String("selfhosted-a"), "n0 name carried to the resolved tier")
    assert_equal(t0._oneof0_case, ARM_GIT_PUSH, "n0 resolved on the git_push arm")
    var g0 = t0.git_push.value().copy()
    assert_equal(
        g0.source_kind.value, SourceKind.SOURCE_KIND_GIT_SELFHOSTED, "n0 source_kind translated (1)"
    )
    assert_equal(g0.repo_ref, String("org/repo-a"), "n0 repo_ref")
    assert_equal(g0.ref_, String("main"), "n0 ref")
    assert_equal(t0.pipeline_ref, String("orders-api"), "n0 pipeline_ref == bundle.name")
    assert_equal(
        t0.webhook_secret_ref,
        String("trigger-selfhosted-a-webhook-secret"),
        "n0 deterministic per-binding webhook-secret handle",
    )

    # -- node 1: external PUSH on repo-b -----------------------------------------
    var n1 = m.nodes[1].copy()
    assert_equal(
        n1.logical_id, String("trigger-external-b"), "n1 stable NAME-keyed id"
    )
    assert_equal(n1._oneof0_case, 15, "n1 trigger arm 15")
    var t1 = n1.trigger.value().copy()
    assert_equal(t1._oneof0_case, ARM_GIT_PUSH, "n1 resolved on the git_push arm")
    var g1 = t1.git_push.value().copy()
    assert_equal(
        g1.source_kind.value, SourceKind.SOURCE_KIND_GIT_EXTERNAL, "n1 source_kind translated (2)"
    )
    assert_equal(g1.repo_ref, String("org/repo-b"), "n1 repo_ref")
    assert_equal(g1.ref_, String("release"), "n1 ref")
    assert_equal(t1.pipeline_ref, String("orders-api"), "n1 pipeline_ref == bundle.name")

    # -- node 2: the SCHEDULE — the arm that was IMPOSSIBLE to express ------------
    # Before the payload oneof, `event: TRIGGER_EVENT_SCHEDULE` was settable and
    # MEANINGLESS: there was no cron field in either tier, so a machine could say
    # "I deploy on a schedule" with nowhere to say WHEN. This node is the whole
    # point of the reshape.
    var n2 = m.nodes[2].copy()
    assert_equal(
        n2.logical_id,
        String("trigger-weekly-sync"),
        "n2 NAME-keyed id — a schedule has NO repo to key on, which is exactly"
        " why the id moved off (source_kind, repo_ref)",
    )
    assert_equal(n2._oneof0_case, 15, "n2 trigger arm 15")
    var t2 = n2.trigger.value().copy()
    assert_equal(t2._oneof0_case, ARM_SCHEDULE, "n2 resolved on the schedule arm")
    var s2 = t2.schedule.value().copy()
    assert_equal(s2.cron, String("0 6 * * 1"), "n2 cron survives the compose")
    assert_equal(s2.timezone, String("UTC"), "n2 timezone survives the compose")
    assert_equal(t2.pipeline_ref, String("orders-api"), "n2 pipeline_ref == bundle.name")
    # A SCHEDULE HAS NO INBOUND WEBHOOK, SO NO HMAC SECRET HANDLE. Minting one
    # would advertise a secret no conformer will ever provision.
    assert_equal(
        t2.webhook_secret_ref,
        String(""),
        "a schedule has no inbound delivery — it must NOT carry a webhook-secret"
        " handle",
    )
    # And the git arms DO carry one, so the assertion above is a discrimination,
    # not a vacuous empty-string check.
    assert_true(
        t0.webhook_secret_ref.byte_length() > 0,
        "the git_push arm must still carry its webhook-secret handle",
    )
    print("  test_compose_triggers_emits_n_nodes: PASS")


# =============================================================================
# §A2 — the PACKAGE_PUBLISHED arm + the two fail-closed compose refusals.
# =============================================================================
def test_compose_triggers_package_arm() raises:
    var triggers = List[TriggerSource]()
    triggers.append(
        _package_trigger(
            String("upstream-widget"),
            BundleRegistryKind(BundleRegistryKind.REGISTRY_KIND_GITHUB_PACKAGES),
            String("acme/widget"),
            String("^2.0.0"),
        )
    )
    var m = compose_triggers(_bundle_with(triggers))
    assert_equal(len(m.nodes), 1, "one package trigger -> one node")
    var t = m.nodes[0].trigger.value().copy()
    assert_equal(t._oneof0_case, ARM_PACKAGE_PUBLISHED, "resolved on the package arm")
    var p = t.package_published.value().copy()
    assert_equal(
        p.registry_kind.value,
        RegistryKind.REGISTRY_KIND_GITHUB_PACKAGES,
        "registry_kind translated ordinal->ordinal",
    )
    assert_equal(p.package_ref, String("acme/widget"))
    assert_equal(p.version_range, String("^2.0.0"))
    # A package publish IS an inbound webhook, so it DOES get a secret handle —
    # the discrimination partner of the schedule assertion above.
    assert_equal(
        t.webhook_secret_ref, String("trigger-upstream-widget-webhook-secret")
    )
    print("  test_compose_triggers_package_arm: PASS")


def test_compose_refuses_an_armless_trigger() raises:
    """An armless trigger names no firing condition. Emitting it would put a node
    in the standing manifest that no conformer can act on — while the >=1-node
    identifier says CONTINUOUS. Fail fast."""
    var triggers = List[TriggerSource]()
    triggers.append(TriggerSource(String("armless"), 0, None, None, None))
    var raised = False
    var detail = String("")
    try:
        var m = compose_triggers(_bundle_with(triggers))
        detail = (
            String("compose ACCEPTED an armless trigger; it emitted ")
            + String(len(m.nodes))
            + String(" node(s)")
        )
    except e:
        raised = True
        detail = String(e)
    assert_true(raised, detail)
    print("  test_compose_refuses_an_armless_trigger: PASS")


def test_compose_refuses_an_unnamed_trigger() raises:
    """The name IS the node id (`trigger-<name>`). An empty name would collide
    every unnamed trigger onto one node — so it is refused, not defaulted."""
    var triggers = List[TriggerSource]()
    triggers.append(
        _schedule_trigger(String(""), String("0 6 * * 1"), String("UTC"))
    )
    var raised = False
    var detail = String("")
    try:
        var m = compose_triggers(_bundle_with(triggers))
        detail = (
            String("compose ACCEPTED an unnamed trigger; node id was '")
            + m.nodes[0].logical_id
            + String("'")
        )
    except e:
        raised = True
        detail = String(e)
    assert_true(raised, detail)
    print("  test_compose_refuses_an_unnamed_trigger: PASS")


# =============================================================================
# §B — ARM-15 ROUND-TRIP: trigger (arm 15) co-resident with serverless (arm 1);
#      encode->decode survives with BOTH arms intact (no misparse / displacement).
# =============================================================================
def test_trigger_node_arm15_roundtrip_no_misparse() raises:
    var svc = _serverless_node(
        String("orders-svc"),
        List[String](),
        String("sha256:img"),
        Int32(8080),
        Int32(0),
        Int32(1),
        String("orders-role"),
        None,  # supervisor — not exercised by this arm round-trip
        None,  # keep_last_n (retention) — unset (default applied downstream)
        List[String](),  # args (parameter argv) — none; this arm tests triggers
        None,  # network_ingress — UNSET, so the deploy stamps nothing
        None,  # network_egress — UNSET, so no vpc_access is rendered
        # `cloud` — required, no default. CLOUD_GCP because this arm round-trip
        # is about TRIGGER encode/decode, not about a cloud: the assertion is
        # that arms 15 and 1 survive co-resident without misparse, which is
        # cloud-independent. A non-GCP value here would exercise the AWS gate
        # and test something this file does not claim to.
        CLOUD_GCP,
        # `cpu` / `memory` — required, no default. UNSET: a presence-typed
        # `optional string` writes no bytes when absent, which keeps the
        # no-misparse assertion about arms 15 and 1 and not about a field this
        # file does not claim to test.
        None,  # cpu (field 12) — UNSET
        None,  # memory (field 13) — UNSET
        # THE APP'S HEALTHCHECK ENDPOINT — None: this construction declares
        # none, so the node's field is UNSET and its resource is NOT_GATED. The
        # parameter takes NO DEFAULT on purpose, so saying `None` is a STATEMENT
        # rather than an omission nobody wrote down.
        None,  # health_check_path
)
    var trig = _trigger_node(
        String("trigger-external-push"),
        String("external-push"),
        ARM_GIT_PUSH,
        Optional[ResolvedGitPush](
            ResolvedGitPush(
                SourceKind(SourceKind.SOURCE_KIND_GIT_EXTERNAL),
                String("org/repo"),
                String("main"),
            )
        ),
        None,
        None,
        String("orders-api"),
        String("wh-secret"),
    )
    var nodes = List[ResourceNode]()
    nodes.append(svc^)
    nodes.append(trig^)
    var m = FullManifest(String("env-a"), String(""), nodes^)

    # pre-encode: the arms are as built (serverless arm 1 NOT displaced by arm 15).
    assert_equal(m.nodes[0]._oneof0_case, 1, "serverless still arm 1 pre-encode")
    assert_equal(m.nodes[1]._oneof0_case, 15, "trigger arm 15 pre-encode")

    # round-trip through the proto wire — a WRONG arm index would misparse here.
    var bytes = encode_proto[FullManifest](m)
    var m2 = decode_proto[FullManifest](bytes^)
    assert_equal(len(m2.nodes), 2, "both nodes survive the wire")

    # serverless node: arm 1 intact, spec fields survive.
    assert_equal(m2.nodes[0]._oneof0_case, 1, "serverless arm 1 survives the wire")
    assert_equal(
        m2.nodes[0].kind.value, ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE, "n0 kind survives"
    )
    var sc = m2.nodes[0].serverless_compute.value().copy()
    assert_equal(sc.image_digest, String("sha256:img"), "serverless digest survives")
    assert_equal(sc.port, Int32(8080), "serverless port survives")

    # trigger node: arm 15 intact (NO misparse), every TriggerSpec field survives.
    assert_equal(m2.nodes[1]._oneof0_case, 15, "trigger arm 15 survives the wire (no misparse)")
    assert_equal(m2.nodes[1].kind.value, ResourceKind.RESOURCE_KIND_TRIGGER, "n1 kind TRIGGER survives")
    var has_trig = False
    if m2.nodes[1].trigger:
        has_trig = True
    assert_true(has_trig, "the trigger arm is populated after the round-trip")
    var has_grant = False
    if m2.nodes[1].invoke_grant:
        has_grant = True
    assert_true(not has_grant, "arm 16 (invoke_grant) stays unset on the trigger node")
    var ts = m2.nodes[1].trigger.value().copy()
    assert_equal(ts.name, String("external-push"), "trigger name survives")
    assert_equal(ts.pipeline_ref, String("orders-api"), "pipeline_ref survives")
    assert_equal(ts.webhook_secret_ref, String("wh-secret"), "webhook_secret_ref survives")
    # THE INNER ONEOF, over the wire. There are now TWO nested oneofs on this node
    # (ResourceNode.config arm 15, and TriggerSpec.on arm 1) — a wrong index in
    # EITHER is a silent misparse, so both are pinned.
    assert_equal(ts._oneof0_case, ARM_GIT_PUSH, "inner git_push arm survives the wire")
    var gp = ts.git_push.value().copy()
    assert_equal(gp.source_kind.value, SourceKind.SOURCE_KIND_GIT_EXTERNAL, "source_kind survives")
    assert_equal(gp.repo_ref, String("org/repo"), "repo_ref survives")
    assert_equal(gp.ref_, String("main"), "ref survives")
    var has_sched = False
    if ts.schedule:
        has_sched = True
    assert_true(not has_sched, "the schedule arm stays unset on a git_push trigger")
    print("  test_trigger_node_arm15_roundtrip_no_misparse: PASS")


# =============================================================================
# §C — ZERO-TRIGGERS: no triggers -> EMPTY standing manifest (0 nodes).
# =============================================================================
def test_compose_triggers_zero_triggers_empty() raises:
    var m = compose_triggers(_bundle_with(List[TriggerSource]()))
    assert_equal(m.environment, String(""), "env-independent standing manifest")
    assert_equal(len(m.nodes), 0, "zero triggers -> EMPTY standing manifest")
    assert_true(m.content_address.startswith("sha256:"), "still content-addressed")
    assert_equal(content_address(m), m.content_address, "idempotent stamp on the empty manifest")
    print("  test_compose_triggers_zero_triggers_empty: PASS")


# =============================================================================
# §D — DETERMINISM: same bundle in -> byte-identical standing manifest + address.
# =============================================================================
def _bytes_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_compose_triggers_deterministic() raises:
    var triggers = List[TriggerSource]()
    triggers.append(
        _git_push_trigger(
            String("selfhosted-a"),
            BundleSourceKind(BundleSourceKind.SOURCE_KIND_GIT_SELFHOSTED),
            String("org/repo-a"),
            String("main"),
        )
    )
    # A SCHEDULE too — content-addressing must be deterministic across arms, and
    # the schedule arm is the one carrying a brand-new nested message.
    triggers.append(
        _schedule_trigger(String("weekly"), String("0 6 * * 1"), String("UTC"))
    )
    var m1 = compose_triggers(_bundle_with(triggers))
    var m2 = compose_triggers(_bundle_with(triggers))
    assert_equal(m1.content_address, m2.content_address, "two composes -> same address")
    var b1 = encode_proto[FullManifest](m1)
    var b2 = encode_proto[FullManifest](m2)
    assert_true(_bytes_equal(b1, b2), "two composes -> byte-identical standing manifest")
    print("  test_compose_triggers_deterministic: PASS")


def main() raises:
    test_compose_triggers_emits_n_nodes()
    test_compose_triggers_package_arm()
    test_compose_refuses_an_armless_trigger()
    test_compose_refuses_an_unnamed_trigger()
    test_trigger_node_arm15_roundtrip_no_misparse()
    test_compose_triggers_zero_triggers_empty()
    test_compose_triggers_deterministic()
    print("PASS test_compose_triggers")
