# =============================================================================
# kci_deploy_compose/tests/test_app_declares_its_healthcheck.mojo
#   WITHOUT A DECLARED HEALTHCHECK, `ACTIVE` MEANS "THE CLOUD ACCEPTED OUR
#   CREATE" — AND EVERY READER OF IT BELIEVES IT MEANS "THE APP IS SERVING".
# =============================================================================
#
# An app defines a healthcheck endpoint, and the placement service polls it
# until it answers before marking the resource ACTIVE.
#
# WHY. A Cloud Run service HAS a URL, and appears in a `list_services`
# enumerate, the INSTANT the service resource is created — before the revision
# is READY and before the container has opened a socket. A registry that adopts
# a resource PROVISIONING -> ACTIVE on that evidence says ACTIVE for a service
# that might be answering 503, and every reader of the status reads it as
# "serving".
#
# WHAT THIS FILE PINS. `AppSpec.health_check_path` (40) — the app's OWN
# declaration of what the placement service should ask it — and the carry
# through `compose_api` onto `ServerlessComputeSpec.health_check_path` (14).
#
# IT IS NOT THE TWO THINGS IT LOOKS LIKE, AND §1 ASSERTS BOTH DISTINCTIONS.
#   * `supervisor_child_health_path` (9) is SUPERVISOR -> CHILD, inside the
#     container, over loopback, by a sidecar already running. Different
#     direction, different altitude, different meaning of a failure, different
#     party acting on it. This file gives it a DIFFERENT non-empty value
#     throughout so a carry that read field 9 shows up in the VALUE.
#   * `DEPLOY_STARTUP_PROBE_PATH` is an env var the APPLIER consumes and strips;
#     it renders GCP's OWN startup probe, evaluated by Cloud Run inside the
#     revision, and nothing in the placement service can read it. Same
#     conceptual quantity, different consumer, different substrate.
#
# SECTIONS, each answering "what wrong value would still make this pass?":
#   §1 THE CARRY — a bundle declaring a path composes a ServerlessCompute node
#      carrying EXACTLY that string, and the supervisor's own (different) path is
#      untouched.
#   §2 ABSENT STAYS ABSENT — a bundle declaring NOTHING composes an UNSET field.
#      NOT "/healthz". A fabricated path makes the placement service probe an
#      endpoint the app never offered, and the verdict is a give-up against an
#      app that is working. UNSET is the NOT_GATED policy: adopt on cloud
#      existence, and SAY that is what happened.
#   §3 THE AUTHORED-EMPTY REFUSAL — `health_check_path: ""` is REFUSED BY NAME at
#      compose. "The bundle said nothing" and "the bundle asked us to probe the
#      empty path" are different statements and must not arrive as the same bytes.
#   §4 THE FIELD NUMBERS ARE PINNED ON THE WIRE, NOT BY ROUND-TRIP. A round trip
#      CANNOT see a swap of two same-typed field numbers — encoder and decoder
#      move together — so this asserts the literal varint TAG bytes: AppSpec 40
#      -> 0xC2 0x02, ServerlessComputeSpec 14 -> 0x72, and that the value does
#      NOT appear under the neighbouring fields' tags. A proto field number is
#      FOREVER.
#   §5 UNSET WRITES NO BYTES — the additive-safety property. A presence-typed
#      `optional string` must emit nothing when absent, or every composed
#      ServerlessCompute node gains bytes and every manifest content address
#      moves.
#
# Pure struct construction + pure functions — no store, no cloud, no
# UnsafePointer, no wildcard origin.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import encode_proto, decode_proto

from kci_deploy_compose.compose_api import compose_api

from kci_manifest_proto.full_manifest import (
    FullManifest,
    ResourceKind,
    ServerlessComputeSpec,
)

from kci_bundle_proto.app_bundle import (
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
    Tenancy,
    AppKind,
    BuildTarget,
    ImageRef,
    BundleEnvVar,
    Scaling,
    AppSpec,
    BucketSpec,
    Wave,
    ValidateStep,
    TriggerSource,
    ServiceSpec,
    ValidationSet,
    Pipeline,
    SecuredInboundRoute,
    WebRouteRule,
)
from kci_bundle_proto.deploy_model import (
    BundleIndexTable,
    InboundNeed,
    NetworkIngress,
    ComputeIntent,
    DatastoreNeed,
    SecretBinding,
)


comptime _SERVICE: String = "healthcheck-app"
# THE DECLARED HEALTH PATH. Deliberately NOT `/healthz` — the conventional
# startup-probe path and the value a lazy default would fabricate. A distinctive
# path is the only thing that distinguishes "the declaration was carried" from
# "something substituted the obvious string", which is exactly the failure mode
# a `/healthz` fixture is blind to.
comptime _HEALTH_PATH: String = "/internal/ready-for-traffic"
# The confusable SIBLING — `supervisor_child_health_path` (field 9). It is
# supervisor->child INSIDE the container over loopback; this file's subject is
# placement-service->app from OUTSIDE across the ingress. Given a DIFFERENT
# value throughout so a carry that went through the wrong one is visible in the
# VALUE, not only in the wire tags.
comptime _SUPERVISOR_CHILD_PATH: String = "/supervisor-only-liveness"


# =============================================================================
# FIXTURES — ONE spec builder, so a bundle that DECLARES an allocation differs
#            from one that does not by exactly those two fields and nothing else.
# =============================================================================
def _spec(var health_check_path: Optional[String]) raises -> AppSpec:
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
        # THE CONFUSABLE SIBLING (field 9) IS NON-EMPTY AND DIFFERENT
        # THROUGHOUT THIS FILE, ON PURPOSE. `supervisor_child_health_path` is the
        # only other health path on this message, and it means something else at
        # another altitude: supervisor -> child, INSIDE the container, over
        # loopback, by a sidecar that is already running. Setting it to a
        # DISTINCT value means any assertion this file makes about a health path
        # can only be satisfied by field 40 — an implementation that read field 9
        # instead would carry the wrong string and be caught in the VALUE.
        String(_SUPERVISOR_CHILD_PATH),  # supervisor_child_health_path
        Int32(0),  # supervisor_child_health_port
        String(""),  # supervisor_cpu
        String(""),  # supervisor_memory
        String(""),  # web_slug
        String(""),  # web_domain
        List[String](),  # web_additional_domains
        List[String](),  # web_api_path_prefixes
        String(""),  # web_api_service_logical_id
        InboundNeed(0),  # inbound
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
        None,  # network_egress
        None,  # mail_transport
        List[DatastoreCollection](),  # datastore_collections
        List[CloudVariant](),  # cloud_variants
        NameScope(NameScope.NAME_SCOPE_UNSPECIFIED),  # name_scope
        None,  # cpu (field 38) — not this file's subject
        None,  # memory (field 39) — not this file's subject
        # THE SUBJECT (field 40).
        health_check_path^,
    )


def _bundle(var spec: AppSpec) raises -> AppBundle:
    var waves = List[Wave]()
    return AppBundle(
        AppKind(AppKind.APP_KIND_API),
        String(_SERVICE),
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


def _compose(var health_check_path: Optional[String]) raises -> FullManifest:
    return compose_api(
        _bundle(_spec(health_check_path^)), String("env-a")
    )


def _the_compute_spec(m: FullManifest) raises -> ServerlessComputeSpec:
    """The ONE `RESOURCE_KIND_SERVERLESS_COMPUTE` node's spec.

    ⛔ IT REFUSES ZERO AND IT REFUSES TWO. An empty search result would make
    every assertion in this file vacuous — the exact failure class this repo has
    found eight times — and two nodes would mean the assertions are about
    whichever one came first."""
    var found = List[ServerlessComputeSpec]()
    for i in range(len(m.nodes)):
        if (
            m.nodes[i].kind.value
            == ResourceKind.RESOURCE_KIND_SERVERLESS_COMPUTE
        ):
            if not m.nodes[i].serverless_compute:
                raise Error(
                    "a SERVERLESS_COMPUTE node carries no ServerlessComputeSpec"
                )
            found.append(m.nodes[i].serverless_compute.value().copy())
    if len(found) != 1:
        raise Error(
            String("expected EXACTLY ONE ServerlessCompute node, found ")
            + String(len(found))
            + String(
                " — a zero would make every assertion in this file vacuous."
            )
        )
    return found[0].copy()



# =============================================================================
# §1 — THE CARRY, and the two things this is NOT.
# =============================================================================
def test_declared_healthcheck_reaches_the_compute_node() raises:
    """A bundle that DECLARES a healthcheck endpoint composes a
    ServerlessCompute node carrying EXACTLY that path, verbatim."""
    var m = _compose(Optional[String](String(_HEALTH_PATH)))
    var cs = _the_compute_spec(m)
    assert_true(
        Bool(cs.health_check_path),
        (
            "the node MUST carry the declared healthcheck path — an UNSET one"
            " here means the declaration reached nothing, and the placement service"
            " goes back to marking a service ACTIVE because the CLOUD accepted"
            " the create, which is a fact about the service resource and never"
            " about the app"
        ),
    )
    assert_equal(
        cs.health_check_path.value(),
        String(_HEALTH_PATH),
        "the declared path is carried VERBATIM",
    )
    # AND NOT VIA THE SUPERVISOR. Field 9 is the confusable sibling and this
    # fixture gives it a DIFFERENT non-empty value, so a carry that had read it
    # instead would be visible right here as the wrong string.
    assert_true(Bool(cs.supervisor), "the served node carries a supervisor")
    assert_equal(
        cs.supervisor.value().child_health_path,
        String(_SUPERVISOR_CHILD_PATH),
        (
            "the supervisor's OWN child health path is untouched — the app's"
            " placement-facing declaration did not leak onto the sidecar's"
            " loopback probe, and the two are not the same statement"
        ),
    )
    assert_true(
        cs.health_check_path.value()
        != cs.supervisor.value().child_health_path,
        (
            "the two paths are DIFFERENT in this fixture on purpose: an"
            " implementation that read field 9 into field 14 would satisfy the"
            " presence assertion above and be caught only here"
        ),
    )
    print("  test_declared_healthcheck_reaches_the_compute_node: PASS")


# =============================================================================
# §2 — ABSENT STAYS ABSENT (never defaulted to /healthz).
# =============================================================================
def test_absent_healthcheck_is_carried_absent_never_defaulted() raises:
    """A bundle that declares NO healthcheck composes an UNSET field.

    THIS IS THE NO-HEALTHCHECK POLICY, AND IT IS A DECISION, NOT AN OMISSION.
    UNSET means the resource is `NOT_GATED`: it is adopted on cloud existence,
    and the placement service's verdict SAYS `NOT_GATED` rather than claiming a
    health PASS nobody observed. Both alternatives are worse — defaulting a path
    makes the placement service give up on an app that never asked to be probed
    there, while refusing to activate an app with no declaration would take
    every app without one dark."""
    var m = _compose(None)
    var cs = _the_compute_spec(m)
    assert_false(
        Bool(cs.health_check_path),
        (
            "an undeclared healthcheck MUST compose UNSET — not '', and above"
            " all not a fabricated '/healthz'. A substituted path is an"
            " endpoint the app never offered, and probing it yields a GIVE-UP"
            " verdict against an app that is working perfectly."
        ),
    )
    # The supervisor's own path is STILL carried — proving the UNSET above is
    # about field 40 and not about the whole supervisor merge having gone dark.
    assert_true(Bool(cs.supervisor), "the served node still carries a supervisor")
    assert_equal(
        cs.supervisor.value().child_health_path,
        String(_SUPERVISOR_CHILD_PATH),
        (
            "the sidecar's own probe is unaffected by the app declaring no"
            " placement-facing healthcheck — this is what proves §2's UNSET is about"
            " field 40 and not a collapsed composition"
        ),
    )
    print("  test_absent_healthcheck_is_carried_absent_never_defaulted: PASS")


# =============================================================================
# §3 — THE AUTHORED-EMPTY REFUSAL, BY NAME, AT COMPOSE.
# =============================================================================
def test_authored_empty_healthcheck_is_refused_by_name() raises:
    """`health_check_path: ""` is REFUSED at compose, and the message names the
    field and the service.

    This is the absent-vs-empty seam. A plain `string` would spell "the bundle
    said nothing" and "the bundle asked us to probe the empty path" with the SAME
    BYTES, and this refusal could then not exist. Refusing at COMPOSE is the last
    point at which the fault is still attributable to the thing that caused it
    — and compose runs before any cloud call, so `kci <app> plan` shows it."""
    var raised = False
    var msg = String("")
    try:
        var m = _compose(Optional[String](String("")))
        _ = m^
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        (
            "an authored EMPTY health_check_path MUST be refused — carrying it"
            " through would ask the placement service to probe the empty path, and"
            " silently dropping it would turn a bundle the composer refuses"
            " into one it accepts"
        ),
    )
    assert_true(
        String("health_check_path") in msg,
        "the refusal NAMES the field: " + msg,
    )
    assert_true(
        String(_SERVICE) in msg,
        "the refusal NAMES the service the bundle authored: " + msg,
    )
    print("  test_authored_empty_healthcheck_is_refused_by_name: PASS")


# =============================================================================
# §4 — THE WIRE TAGS. ⛔ A ROUND TRIP IS BLIND TO A FIELD-NUMBER SWAP.
# =============================================================================
def _contains(hay: List[UInt8], needle: List[UInt8]) -> Bool:
    if len(needle) == 0 or len(needle) > len(hay):
        return False
    for i in range(len(hay) - len(needle) + 1):
        var ok = True
        for j in range(len(needle)):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _bytes_of(var s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_field_numbers_are_pinned_on_the_wire() raises:
    """A SWAP OF TWO SAME-TYPED FIELD NUMBERS REGENERATES BOTH THE ENCODER
    AND THE DECODER, SO encode->decode IS AN IDENTITY EITHER WAY. Every other
    section of this file would still pass under a swap. This one reads the
    literal varint TAG bytes.

    AppSpec field 40, wire type 2: (40 << 3) | 2 = 322 -> varint 0xC2 0x02.
    ServerlessComputeSpec field 14, wire type 2: (14 << 3) | 2 = 114 -> 0x72.

    A proto field number is FOREVER, and the placement side builds against
    these."""
    var spec = _spec(Optional[String](String(_HEALTH_PATH)))
    var wire = encode_proto[AppSpec](spec)

    var payload = _bytes_of(String(_HEALTH_PATH))
    var n = len(payload)

    # tag 0xC2 0x02, then the length varint (the path is < 128 bytes so one
    # byte), then the bytes.
    var want = List[UInt8]()
    want.append(UInt8(0xC2))
    want.append(UInt8(0x02))
    want.append(UInt8(n))
    for i in range(n):
        want.append(payload[i])
    assert_true(
        _contains(wire, want),
        (
            "AppSpec.health_check_path MUST be encoded under field 40 (tag"
            " 0xC2 0x02). A round trip cannot see a field-number swap; this can."
        ),
    )

    # ⛔ AND IT MUST NOT APPEAR UNDER A NEIGHBOUR'S TAG. 38 -> 0xB2 0x02,
    # 39 -> 0xBA 0x02: the two fields a swap would most plausibly hit.
    for neighbour_lo in [UInt8(0xB2), UInt8(0xBA)]:
        var bad = List[UInt8]()
        bad.append(neighbour_lo)
        bad.append(UInt8(0x02))
        bad.append(UInt8(n))
        for i in range(n):
            bad.append(payload[i])
        assert_false(
            _contains(wire, bad),
            (
                "the health path MUST NOT be written under cpu (38) or memory"
                " (39) — that is exactly what a field-number swap looks like on"
                " the wire, and nothing else in this file can see it"
            ),
        )

    # The node side: field 14 -> single-byte tag 0x72.
    var m = _compose(Optional[String](String(_HEALTH_PATH)))
    var node_wire = encode_proto[ServerlessComputeSpec](_the_compute_spec(m))
    var node_want = List[UInt8]()
    node_want.append(UInt8(0x72))
    node_want.append(UInt8(n))
    for i in range(n):
        node_want.append(payload[i])
    assert_true(
        _contains(node_wire, node_want),
        (
            "ServerlessComputeSpec.health_check_path MUST be encoded under"
            " field 14 (tag 0x72)"
        ),
    )
    # ... and not under cpu (12 -> 0x62) or memory (13 -> 0x6A).
    for bad_tag in [UInt8(0x62), UInt8(0x6A)]:
        var nbad = List[UInt8]()
        nbad.append(bad_tag)
        nbad.append(UInt8(n))
        for i in range(n):
            nbad.append(payload[i])
        assert_false(
            _contains(node_wire, nbad),
            "the node's health path MUST NOT be written under cpu/memory",
        )
    print("  test_field_numbers_are_pinned_on_the_wire: PASS")


# =============================================================================
# §5 — UNSET WRITES NO BYTES (the additive-safety property).
# =============================================================================
def test_unset_health_check_path_writes_no_bytes() raises:
    """EVERY COMPOSED CONTENT ADDRESS DEPENDS ON THIS. The generated encoder
    writes every PLAIN scalar unconditionally, so a bare `string` would append a
    zero-length field to EVERY ServerlessCompute node and move every composed
    manifest's content address (the break `network_ingress` (9) is
    presence-typed to avoid). A presence-typed `optional string` writes nothing
    when unset — so a bundle that declares no healthcheck composes
    byte-identically to one that omits the field.

    AND THIS IS ASSERTED AS EXACT BYTE ARITHMETIC, NOT AS "THE TAG BYTE IS
    ABSENT", BECAUSE THE LATTER IS A FALSE-POSITIVE MACHINE. The node's field-14
    tag is the single byte 0x72 — which is ASCII `'r'` — so a substring search
    for it matches the `r` in every image digest, service name and path in the
    message, and fails for reasons unrelated to its subject. The length
    DIFFERENCE between the present and absent encodings is exact, is immune to
    payload coincidences, and says something STRONGER — that the declaration
    adds EXACTLY its own bytes and moves nothing else."""
    var payload_n = len(_bytes_of(String(_HEALTH_PATH)))

    # ---- AppSpec (field 40): a 2-byte tag + a 1-byte length varint (the path is
    # < 128 bytes) + the payload. Nothing else may move.
    var present = encode_proto[AppSpec](
        _spec(Optional[String](String(_HEALTH_PATH)))
    )
    var absent = encode_proto[AppSpec](_spec(None))
    assert_equal(
        len(present) - len(absent),
        2 + 1 + payload_n,
        (
            "the declaration must add EXACTLY its own bytes (tag 0xC2 0x02 +"
            " length + payload) and an UNSET one must add NONE — anything else"
            " means a zero-length field is being written for every bundle in"
            " the fleet, which moves every composed manifest's content address"
        ),
    )

    # ---- The composed node (field 14): a 1-byte tag + length + payload.
    var node_present = encode_proto[ServerlessComputeSpec](
        _the_compute_spec(_compose(Optional[String](String(_HEALTH_PATH))))
    )
    var node_absent = encode_proto[ServerlessComputeSpec](
        _the_compute_spec(_compose(None))
    )
    assert_equal(
        len(node_present) - len(node_absent),
        1 + 1 + payload_n,
        (
            "the node's health_check_path must add EXACTLY tag 0x72 + length +"
            " payload when present, and NOTHING when absent"
        ),
    )

    # ---- And the round trip: the three states stay three.
    var back_absent = decode_proto[AppSpec](encode_proto[AppSpec](_spec(None)))
    assert_false(
        Bool(back_absent.health_check_path),
        "absent round-trips as ABSENT, never as Some(\"\")",
    )
    var back_present = decode_proto[AppSpec](
        encode_proto[AppSpec](_spec(Optional[String](String(_HEALTH_PATH))))
    )
    assert_true(Bool(back_present.health_check_path))
    assert_equal(
        back_present.health_check_path.value(), String(_HEALTH_PATH)
    )
    # AN AUTHORED EMPTY ROUND-TRIPS AS PRESENT-AND-EMPTY, NOT AS ABSENT. That
    # is what makes §3's refusal reachable at all: a decode that collapsed
    # Some("") to None would silently turn a bundle the composer REFUSES into
    # one it accepts — the quiet direction.
    var back_empty = decode_proto[AppSpec](
        encode_proto[AppSpec](_spec(Optional[String](String(""))))
    )
    assert_true(
        Bool(back_empty.health_check_path),
        (
            "an AUTHORED EMPTY must survive the wire as PRESENT-and-empty —"
            " collapsing it to absent would make the compose refusal"
            " unreachable forever"
        ),
    )
    assert_equal(back_empty.health_check_path.value(), String(""))
    print("  test_unset_health_check_path_writes_no_bytes: PASS")


def main() raises:
    test_declared_healthcheck_reaches_the_compute_node()
    test_absent_healthcheck_is_carried_absent_never_defaulted()
    test_authored_empty_healthcheck_is_refused_by_name()
    test_field_numbers_are_pinned_on_the_wire()
    test_unset_health_check_path_writes_no_bytes()
    print("test_app_declares_its_healthcheck: 5/5 PASS")
