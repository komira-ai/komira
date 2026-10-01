# =============================================================================
# kci_deploy_compose/tests/test_app_declares_its_compute_allocation.mojo
#   WITHOUT A DECLARED ALLOCATION A SERVED APP CANNOT BE BILLED AT ALL.
# =============================================================================
#
# WHY. Billing multiplies a usage INTERVAL by an ALLOCATION. `AppSpec`'s other
# cpu/memory are `supervisor_cpu` (11) / `supervisor_memory` (12), which are the
# SIDECAR's, and `AppSpec.compute` (5) is a `ComputeIntent` ENUM
# (serverless|serverful), a SHAPE SELECTOR and not a quantity. So without the
# app's own declaration there is no second operand and a served app is
# unbillable by construction.
#
# WHAT THIS FILE PINS. `AppSpec.cpu` (38) / `AppSpec.memory` (39) — the app's
# OWN declaration (an app DECLARES its allocation rather than inheriting one
# from the compute shape) — and the carry through `compose_api` onto
# `ServerlessComputeSpec.cpu` (12) / `.memory` (13), the spec of the one node a
# bill is drawn against.
#
# SECTIONS, each answering "what wrong value would still make this pass?":
#   §1 THE CARRY — a bundle declaring "1000m"/"512Mi" composes a
#      ServerlessCompute node carrying EXACTLY those strings. Asserts the two are
#      not swapped by giving them shapes only one field can plausibly hold.
#   §2 ABSENT STAYS ABSENT — a bundle declaring NOTHING composes an UNSET
#      cpu/memory. NOT "", NOT "0m", NOT a fabricated default: a silent zero is
#      an un-billed customer and is byte-identical to an idle one, and a default
#      here would make the read side's loud refusal unreachable.
#   §3 THE AUTHORED-EMPTY REFUSAL — `cpu: ""` / `memory: ""` are REFUSED BY NAME
#      at compose, which is the absent-vs-empty seam: refuse at the last point
#      the fault is still attributable to the thing that caused it. compose runs
#      before any cloud call, so `kci <app> plan` shows it.
#   §4 INDEPENDENT, NOT PAIRED — one may be declared without the other, because
#      the placement side tests and refuses each separately and compose must not
#      invent a pairing rule the write side does not have.
#   §5 THE FIELD NUMBERS ARE PINNED ON THE WIRE, NOT BY ROUND-TRIP. A round trip
#      cannot see a SWAP of two same-typed field numbers (encode and decode move
#      together), so this section asserts the literal varint TAG bytes: AppSpec
#      38 -> 0xB2 0x02, 39 -> 0xBA 0x02; ServerlessComputeSpec 12 -> 0x62, 13 ->
#      0x6A. A proto field number is FOREVER, and other components build against
#      these two numbers.
#   §6 UNSET WRITES NO BYTES — the additive-safety property. A presence-typed
#      `optional string` must emit nothing when absent, or every composed
#      ServerlessCompute node gains bytes and every manifest content address
#      moves.
#
# Pure struct construction + pure functions — no store, no cloud, no
# UnsafePointer, no wildcard origin.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_serde import encode_proto, decode_proto

from kci_deploy_compose.compose_api import compose_api

from full_manifest_rpc.full_manifest import (
    FullManifest,
    ResourceKind,
    ServerlessComputeSpec,
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


comptime _SERVICE: String = "alloc-app"
# The two DECLARED quantities. Deliberately shapes only ONE field can plausibly
# hold: "1000m" is a CPU millicore quantity and "512Mi" is a memory mebibyte
# quantity, so a swap anywhere on the path is visible in the VALUE and not only
# in the wire tags §5 pins.
comptime _CPU: String = "1000m"
comptime _MEMORY: String = "512Mi"


# =============================================================================
# FIXTURES — ONE spec builder, so a bundle that DECLARES an allocation differs
#            from one that does not by exactly those two fields and nothing else.
# =============================================================================
def _spec(
    var cpu: Optional[String], var memory: Optional[String]
) raises -> AppSpec:
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
        # THE SIDECAR'S OWN cpu/memory (fields 11-12) STAY EMPTY THROUGHOUT
        # THIS FILE, ON PURPOSE. They are the confusable pair: they are the only
        # other cpu/memory on this message and they belong to the supervisor
        # container, not to the app. Leaving them empty means every non-empty
        # allocation this file observes can only have come from fields 38-39.
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
        # THE SUBJECT (fields 38-39).
        cpu^,
        memory^,
        # THE APP'S HEALTHCHECK ENDPOINT (field 40) — ABSENT: the resource is
        # NOT_GATED and the presence-typed `optional string` writes NO bytes.
        None,  # health_check_path (field 40)
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


def _compose(
    var cpu: Optional[String], var memory: Optional[String]
) raises -> FullManifest:
    return compose_api(_bundle(_spec(cpu^, memory^)), String("env-a"))


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
# §1 — THE CARRY.
# =============================================================================
def test_declared_allocation_reaches_the_compute_node() raises:
    """A bundle that DECLARES cpu/memory composes a ServerlessCompute node
    carrying EXACTLY those strings, verbatim and unconverted."""
    var m = _compose(
        Optional[String](String(_CPU)), Optional[String](String(_MEMORY))
    )
    var cs = _the_compute_spec(m)
    assert_true(
        Bool(cs.cpu),
        (
            "the node MUST carry the declared cpu — an UNSET one here means the"
            " declaration reached nothing and the app is unbillable"
        ),
    )
    assert_true(Bool(cs.memory), "the node MUST carry the declared memory")
    assert_equal(cs.cpu.value(), String(_CPU), "cpu carried VERBATIM")
    assert_equal(cs.memory.value(), String(_MEMORY), "memory carried VERBATIM")
    # AND NOT VIA THE SIDECAR. The supervisor's own cpu/memory are the
    # confusable pair; this fixture leaves them empty, so assert they STAYED
    # empty — a carry that had gone through `_supervisor_spec` instead would
    # satisfy nothing above but WOULD show up here.
    assert_true(Bool(cs.supervisor), "the served node carries a supervisor")
    assert_equal(
        cs.supervisor.value().cpu,
        String(""),
        "the APP's allocation did NOT leak onto the SIDECAR's cpu",
    )
    assert_equal(
        cs.supervisor.value().memory,
        String(""),
        "the APP's allocation did NOT leak onto the SIDECAR's memory",
    )
    print("  test_declared_allocation_reaches_the_compute_node: PASS")


# =============================================================================
# §2 — ABSENT STAYS ABSENT (never defaulted).
# =============================================================================
def test_absent_allocation_is_carried_absent_never_defaulted() raises:
    """A bundle that declares NO allocation composes an UNSET cpu/memory.

    THIS IS THE ASSERTION THAT KEEPS THE BILL HONEST. A substituted "0m"/""
    would be an amount the customer never asked for, and — worse — it would make
    billing's refusal of absence unreachable, so an unbilled app would look like
    an idle one forever."""
    var m = _compose(None, None)
    var cs = _the_compute_spec(m)
    assert_false(
        Bool(cs.cpu),
        (
            "an undeclared cpu MUST compose UNSET — not '', not '0m', not a"
            " default. A silent zero is an un-billed customer and is"
            " byte-identical to an idle one."
        ),
    )
    assert_false(Bool(cs.memory), "an undeclared memory MUST compose UNSET")
    print("  test_absent_allocation_is_carried_absent_never_defaulted: PASS")


# =============================================================================
# §3 — THE AUTHORED-EMPTY REFUSAL.
# =============================================================================
def test_authored_empty_cpu_is_refused_by_name() raises:
    """`cpu: ""` is REFUSED at compose, naming the service and the field.

    An omission and an authored-empty quantity are DIFFERENT facts; only the
    first is representable downstream (a durable allocation column is NULLable
    precisely so "" never becomes a number on a bill). The refusal happens here
    because compose is the last point at which the fault is still attributable
    to the bundle that caused it."""
    var raised = False
    var msg = String("")
    try:
        var m = _compose(Optional[String](String("")), None)
        _ = _the_compute_spec(m)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, 'compose MUST REFUSE an authored `cpu: ""`')
    assert_true(
        msg.find(String("cpu")) >= 0,
        "the refusal must NAME the field: " + msg,
    )
    assert_true(
        msg.find(String(_SERVICE)) >= 0,
        "the refusal must NAME the service: " + msg,
    )
    print("  test_authored_empty_cpu_is_refused_by_name: PASS")


def test_authored_empty_memory_is_refused_by_name() raises:
    """`memory: ""` is refused for the reason `cpu: ""` is — and it is asserted
    SEPARATELY, because a guard written for one of a pair and not the other is
    a half-fix."""
    var raised = False
    var msg = String("")
    try:
        var m = _compose(None, Optional[String](String("")))
        _ = _the_compute_spec(m)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, 'compose MUST REFUSE an authored `memory: ""`')
    assert_true(
        msg.find(String("memory")) >= 0,
        "the refusal must NAME the field: " + msg,
    )
    assert_true(
        msg.find(String(_SERVICE)) >= 0,
        "the refusal must NAME the service: " + msg,
    )
    print("  test_authored_empty_memory_is_refused_by_name: PASS")


# =============================================================================
# §4 — INDEPENDENT, NOT PAIRED.
# =============================================================================
def test_the_two_are_independent() raises:
    """A cpu may be declared without a memory and vice versa.

    The placement side reads the two with separate presence tests and refuses
    each on its own, so compose must NOT invent a pairing rule the write side
    does not have."""
    var m1 = _compose(Optional[String](String(_CPU)), None)
    var c1 = _the_compute_spec(m1)
    assert_true(Bool(c1.cpu), "cpu-only: cpu carried")
    assert_equal(c1.cpu.value(), String(_CPU), "cpu-only: the right value")
    assert_false(Bool(c1.memory), "cpu-only: memory stays UNSET, not ''")

    var m2 = _compose(None, Optional[String](String(_MEMORY)))
    var c2 = _the_compute_spec(m2)
    assert_true(Bool(c2.memory), "memory-only: memory carried")
    assert_equal(
        c2.memory.value(), String(_MEMORY), "memory-only: the right value"
    )
    assert_false(Bool(c2.cpu), "memory-only: cpu stays UNSET, not ''")
    print("  test_the_two_are_independent: PASS")


# =============================================================================
# §5 — THE FIELD NUMBERS, PINNED ON THE WIRE.
# =============================================================================
def _find_tag_value(
    wire: List[UInt8], tag: List[UInt8], want: String
) raises -> Bool:
    """Whether `wire` holds `tag` immediately followed by a length-delimited
    `want`. The tag is the raw varint of `(field_number << 3) | 2`.

    THIS IS WHAT A ROUND TRIP CANNOT DO. Two same-typed fields whose NUMBERS
    are swapped in the .proto re-generate BOTH the encoder and the decoder, so
    encode->decode is an identity either way and a swap is invisible to it. Only
    the literal tag bytes distinguish them, and other components build against
    these two numbers."""
    var n = len(wire)
    var tl = len(tag)
    var wl = want.byte_length()
    var wb = want.as_bytes()
    for i in range(n):
        var ok = True
        for j in range(tl):
            if i + j >= n or wire[i + j] != tag[j]:
                ok = False
                break
        if not ok:
            continue
        # the length prefix, then the bytes
        if i + tl >= n:
            continue
        if Int(wire[i + tl]) != wl:
            continue
        var matched = True
        for j in range(wl):
            if i + tl + 1 + j >= n or wire[i + tl + 1 + j] != wb[j]:
                matched = False
                break
        if matched:
            return True
    return False


def _tag(b0: Int, b1: Int = -1) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(b0))
    if b1 >= 0:
        out.append(UInt8(b1))
    return out^


def test_appspec_field_numbers_are_38_and_39() raises:
    """`AppSpec.cpu` is field 38 and `AppSpec.memory` is field 39, asserted from
    the WIRE. 38 -> (38<<3)|2 == 306 -> varint 0xB2 0x02; 39 -> 314 -> 0xBA
    0x02."""
    var spec = _spec(
        Optional[String](String(_CPU)), Optional[String](String(_MEMORY))
    )
    var wire = encode_proto[AppSpec](spec)
    assert_true(
        _find_tag_value(wire, _tag(0xB2, 0x02), String(_CPU)),
        "AppSpec.cpu MUST be field 38 (tag 0xB2 0x02)",
    )
    assert_true(
        _find_tag_value(wire, _tag(0xBA, 0x02), String(_MEMORY)),
        "AppSpec.memory MUST be field 39 (tag 0xBA 0x02)",
    )
    # the SWAP falsifier: neither value may appear under the OTHER's tag.
    assert_false(
        _find_tag_value(wire, _tag(0xB2, 0x02), String(_MEMORY)),
        "the memory quantity must NOT be on field 38 (the numbers are swapped)",
    )
    assert_false(
        _find_tag_value(wire, _tag(0xBA, 0x02), String(_CPU)),
        "the cpu quantity must NOT be on field 39 (the numbers are swapped)",
    )
    # and the decode agrees with the tags (so the generated reader is consistent
    # with the number the wire pins, not merely with itself).
    var back = decode_proto[AppSpec](wire^)
    assert_true(Bool(back.cpu), "AppSpec.cpu survives the round trip")
    assert_equal(back.cpu.value(), String(_CPU), "decoded cpu")
    assert_equal(back.memory.value(), String(_MEMORY), "decoded memory")
    print("  test_appspec_field_numbers_are_38_and_39: PASS")


def test_compute_node_field_numbers_are_12_and_13() raises:
    """`ServerlessComputeSpec.cpu` is field 12 and `.memory` is field 13, from
    the WIRE. 12 -> (12<<3)|2 == 98 -> 0x62 (one byte); 13 -> 106 -> 0x6A."""
    var m = _compose(
        Optional[String](String(_CPU)), Optional[String](String(_MEMORY))
    )
    var cs = _the_compute_spec(m)
    var wire = encode_proto[ServerlessComputeSpec](cs)
    assert_true(
        _find_tag_value(wire, _tag(0x62), String(_CPU)),
        "ServerlessComputeSpec.cpu MUST be field 12 (tag 0x62)",
    )
    assert_true(
        _find_tag_value(wire, _tag(0x6A), String(_MEMORY)),
        "ServerlessComputeSpec.memory MUST be field 13 (tag 0x6A)",
    )
    assert_false(
        _find_tag_value(wire, _tag(0x62), String(_MEMORY)),
        "the memory quantity must NOT be on field 12 (the numbers are swapped)",
    )
    assert_false(
        _find_tag_value(wire, _tag(0x6A), String(_CPU)),
        "the cpu quantity must NOT be on field 13 (the numbers are swapped)",
    )
    print("  test_compute_node_field_numbers_are_12_and_13: PASS")


# =============================================================================
# §6 — UNSET WRITES NO BYTES (additive safety).
# =============================================================================
def test_an_undeclared_allocation_writes_no_bytes() raises:
    """A node with NO allocation encodes to the SAME bytes it would have before
    these fields existed — i.e. strictly fewer bytes than a declaring one, with
    neither tag present.

    WHY THIS IS NOT COSMETIC. The generated encoder writes every PLAIN scalar
    unconditionally, so a non-presence-typed `string` here would append a
    zero-length field to EVERY ServerlessCompute node and move every composed
    manifest's content address — the same break
    `ServerlessComputeSpec.network_ingress` (9) is presence-typed to avoid."""
    var bare = _the_compute_spec(_compose(None, None))
    var bare_wire = encode_proto[ServerlessComputeSpec](bare)
    assert_false(
        _find_tag_value(bare_wire, _tag(0x62), String("")),
        "an UNSET cpu must write NO field-12 bytes",
    )
    assert_false(
        _find_tag_value(bare_wire, _tag(0x6A), String("")),
        "an UNSET memory must write NO field-13 bytes",
    )
    var full = _the_compute_spec(
        _compose(
            Optional[String](String(_CPU)), Optional[String](String(_MEMORY))
        )
    )
    var full_wire = encode_proto[ServerlessComputeSpec](full)
    assert_true(
        len(full_wire) > len(bare_wire),
        (
            "a DECLARING node must encode to more bytes than a bare one — equal"
            " lengths would mean the declaration reached no wire at all"
        ),
    )
    print("  test_an_undeclared_allocation_writes_no_bytes: PASS")


def main() raises:
    print("test_app_declares_its_compute_allocation:")
    test_declared_allocation_reaches_the_compute_node()
    test_absent_allocation_is_carried_absent_never_defaulted()
    test_authored_empty_cpu_is_refused_by_name()
    test_authored_empty_memory_is_refused_by_name()
    test_the_two_are_independent()
    test_appspec_field_numbers_are_38_and_39()
    test_compute_node_field_numbers_are_12_and_13()
    test_an_undeclared_allocation_writes_no_bytes()
    print("test_app_declares_its_compute_allocation: ALL PASS")
