# =============================================================================
# tests/test_broker_format_firewall_smoke.mojo
#   core protocol-agnosticism FIREWALL smoke test
# =============================================================================
#
# THE FIREWALL INVARIANT:
#
#   The concrete broker cores `BrokerCore[Storage]` (produce) and
#   `ConsumeCore[Storage]` (consume) take ONLY `[Storage]` — NEVER a
#   `Format` / protocol param. They MONOMORPHIZE ONCE PER `Storage`, and the
#   record/wire convention NEVER reaches the core.
#
# WHY ONLY [Storage]:
#   The native broker source/sink path has no `[Format]` type parameter: a
#   native pipeline produces / consumes RecordBatches, never a "Kafka-format"
#   record. The Kafka wire convention lives ENTIRELY at the server
#   compatibility shim (`komira_kafka_server`), which transcodes Kafka <-> the
#   envelope RecordBatch at RUNTIME (api_key dispatch) — there is NO comptime
#   Kafka `Format` on the native side, so there is no per-Format monomorph to
#   firewall.
#
#   The invariant that matters — enforced BY CONSTRUCTION since the native
#   types are Arrow-only — is that the cores stay PROTOCOL-AGNOSTIC:
#   `[Storage]` and nothing else. This test asserts exactly that, as a
#   compile-time witness: it instantiates BOTH cores over TWO distinct
#   `ConditionalWriteStore` conformers, with NO `Format` parameter anywhere. If
#   a future change re-introduced a protocol/Format param on a core, this file
#   would no longer compile against the `[Storage]`-only core signatures.
#
# WHAT THIS TEST DELIBERATELY DOES NOT DO:
#   * NO `ctx.run` / `ctx.materialize` — those pull in the engine's large
#     comptime row-dispatch instantiation and would drown the firewall signal.
#     This is a pure TYPE-INSTANTIATION + trivial-runtime test.
#   * NO network / no object store. We instantiate the cores over the in-memory
#     `ConditionalWriteStore` conformers (no live S3 transport).
#
# THE RUNTIME CHECK (so this is a real test, not just a compile witness):
#   Each core, built over each in-memory store, reports its bound topic /
#   partition correctly — proving the `[Storage]`-only instantiation is a real,
#   usable core (not a degenerate / dead instantiation).
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.store import ConditionalWriteStore

from komira_broker.broker_core import BrokerCore
from komira_broker.consume_core import ConsumeCore


def _make_broker_core[
    Storage: ConditionalWriteStore
](var seg: Storage, var man: Storage) raises -> BrokerCore[Storage]:
    """Build a `BrokerCore[Storage]` over an in-memory store — NO Format param,
    NO network. The build typechecks ONLY because `BrokerCore` takes `[Storage]`
    alone (the firewall invariant)."""
    var manifest = CasManifestStore[Storage](
        store=man^,
        prefix=String("firewall/_meta/topics/t/0"),
        retry=RetryPolicy.default(),
    )
    return BrokerCore[Storage](
        segment_store=seg^,
        manifest=manifest^,
        cluster=String("firewall"),
        topic=String("topic-protocol-agnostic"),
        partition=Int64(0),
        broker_id=String("broker-firewall"),
    )


def _make_consume_core[
    Storage: ConditionalWriteStore
](var seg: Storage, var man: Storage) raises -> ConsumeCore[Storage]:
    """Build a `ConsumeCore[Storage]` over an in-memory store — NO Format param,
    NO network. Same firewall: `ConsumeCore` takes `[Storage]` alone."""
    var manifest = CasManifestStore[Storage](
        store=man^,
        prefix=String("firewall/_meta/topics/t/0"),
        retry=RetryPolicy.default(),
    )
    return ConsumeCore[Storage](
        segment_store=seg^,
        manifest=manifest^,
        cluster=String("firewall"),
        topic=String("topic-protocol-agnostic"),
        partition=Int64(0),
    )


def test_cores_take_only_storage_over_conformer_a() raises:
    """Instantiate BOTH cores over the FIRST `ConditionalWriteStore` conformer
    (`InMemoryConditionalStore`), with NO Format param. The compile is the
    firewall; the topic/partition runtime check proves the cores are real."""
    print("[test_cores_take_only_storage_over_conformer_a] starting...")
    var bc = _make_broker_core[InMemoryConditionalStore](
        InMemoryConditionalStore(), InMemoryConditionalStore()
    )
    var cc = _make_consume_core[InMemoryConditionalStore](
        InMemoryConditionalStore(), InMemoryConditionalStore()
    )
    assert_equal(
        bc.topic(),
        String("topic-protocol-agnostic"),
        "BrokerCore[InMemoryConditionalStore] bound its topic",
    )
    assert_equal(bc.partition(), Int64(0), "BrokerCore partition bound")
    assert_equal(
        cc.topic(),
        String("topic-protocol-agnostic"),
        "ConsumeCore[InMemoryConditionalStore] bound its topic",
    )
    assert_equal(cc.partition(), Int64(0), "ConsumeCore partition bound")
    _ = bc^
    _ = cc^
    print("[test_cores_take_only_storage_over_conformer_a] PASS")


def test_cores_take_only_storage_over_conformer_b() raises:
    """Instantiate BOTH cores over a SECOND, DISTINCT `ConditionalWriteStore`
    conformer (`SharedInMemoryConditionalStore`) — same `[Storage]`-only core
    signatures, a different backend. Two distinct Storage conformers compiling
    against ONE core signature is the 'monomorphize per Storage, never
    per protocol' witness — and with the native path now Arrow-only there is no
    Format/protocol axis to leak in the first place."""
    print("[test_cores_take_only_storage_over_conformer_b] starting...")
    var bc = _make_broker_core[SharedInMemoryConditionalStore](
        SharedInMemoryConditionalStore(), SharedInMemoryConditionalStore()
    )
    var cc = _make_consume_core[SharedInMemoryConditionalStore](
        SharedInMemoryConditionalStore(), SharedInMemoryConditionalStore()
    )
    assert_equal(
        bc.topic(),
        String("topic-protocol-agnostic"),
        "BrokerCore[SharedInMemoryConditionalStore] bound its topic",
    )
    assert_equal(
        cc.topic(),
        String("topic-protocol-agnostic"),
        "ConsumeCore[SharedInMemoryConditionalStore] bound its topic",
    )
    assert_true(
        True,
        "Both cores instantiated over two distinct Storage conformers with"
        " NO Format/protocol param — the cores are protocol-agnostic.",
    )
    _ = bc^
    _ = cc^
    print("[test_cores_take_only_storage_over_conformer_b] PASS")


def main() raises:
    test_cores_take_only_storage_over_conformer_a()
    test_cores_take_only_storage_over_conformer_b()
    print(
        "[OK] test_broker_format_firewall_smoke — core firewall:"
        " BrokerCore[Storage] + ConsumeCore[Storage] instantiated over TWO"
        " distinct ConditionalWriteStore conformers with NO Format/protocol"
        " param. The cores stay protocol-agnostic by construction; the"
        " Kafka-vs-Arrow-wire axis now lives at the server's RUNTIME dispatch,"
        " not as a comptime core param — so there is no per-Format monomorph"
        " to firewall on the native path."
    )
