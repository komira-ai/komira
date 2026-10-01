# =============================================================================
# broker_scan_binding — a PLAN SOURCE, defined OUTSIDE `komira_core`.
# =============================================================================
#
# A broker source is a plan source even though it lives outside komira_core.
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
# ---------------------------------------------------------------------------
#
# A broker source cannot be an arm of the closed `SourceVariant` union in
# komira_core: that would force `komira_core -> komira_broker ->
# {objectstore, ...}`, inverting the build DAG. And `MessageBrokerConsumer` is
# Movable-only (see consumer_source), so it cannot be the Copyable value a
# plan carries. The clean resolution is a Copyable backend HANDLE (a cheap
# identity token the plan builder copies, the heavy network substrate
# constructed at execute time).
#
# That handle is `ScanBinding`, and this file builds one. `komira_broker`
# depends on `komira_core`; `komira_core` does not and never needs to depend
# on `komira_broker`. The DAG is not inverted, and the plan can be rooted at a
# broker scan.
#
# Core ships knowing nothing about a broker — `ScanKindRegistry()` returns
# False for this kind until THIS package registers it.
# `tests/test_out_of_core_scan_source.mojo` asserts exactly that, and asserts
# the plan-level behaviour that follows.
#
# ---------------------------------------------------------------------------
# WHAT IT DOES *NOT* COVER
# ---------------------------------------------------------------------------
#
# A plan can be BUILT, TYPED, PUSHDOWN-QUERIED, EXPLAINED, CLONED, CACHE-KEYED
# and RESOLVED against a registry owned by this package. EXECUTING it
# end-to-end (pulling morsels) needs a morsel resolver for the kind in
# `komira_morsel`; without one, `MessageBrokerConsumer` drains eagerly and
# roots the DataFrame at an `InMemorySource`.
#
# ---------------------------------------------------------------------------
# WHY THE SNAPSHOT POLICY IS `LIVE` — the interesting half
# ---------------------------------------------------------------------------
#
# A broker offset moves. Baking it into the plan's identity is safe and
# thrashy: every produce changes every query's cache key, so the plan cache
# never hits (this is what the search source does
# with `generation`). Baking the VALUE while dropping it from identity is
# cheap and unsafe — a cached plan replayed later reads an offset the retention
# window has already reclaimed.
#
# `SNAPSHOT_LIVE` is neither: the token is EXCLUDED from identity (so the cache
# hits across produces) and RE-RESOLVED at execution start (so it is never
# stale). `BrokerScanResolver` below is the re-resolution, and it lives here
# because the high-watermark is a broker concept core cannot spell.
# =============================================================================

from komira_core.arrow.schema import Schema
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_ORIENTATION_COLUMNAR,
    SNAPSHOT_LIVE,
)
from komira_core.source.scan_identity_audit import ScanIdentityCorpus
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams, param_hash_string
from komira_core.source.scan_resolver import ScanResolver


comptime BROKER_SCAN_KIND_NAME: String = "komira.broker.consume"
"""Reverse-DNS kind name. NO CENTRAL TABLE ALLOCATES THIS — `kind_id` is its
FNV-1a/32 hash, which is exactly why claiming a kind costs no core edit."""

comptime BROKER_PARAM_TOPIC: String = "topic"
comptime BROKER_PARAM_PARTITION: String = "partition"
comptime BROKER_PARAM_START_OFFSET: String = "start_offset"


def broker_scan_kind_id() -> UInt32:
    return scan_kind_id(String(BROKER_SCAN_KIND_NAME))


def broker_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan a broker scan without knowing what a
    broker is: a pushdown gate, an orientation, a snapshot policy, and the
    params that must be present.

    THE GATE. A broker can absorb `offset >= lo AND offset < hi` and equality
    on a partition key — the conjunctive-comparison family — but it carries no
    column STATISTICS, so the stat-friendly requirement is relaxed. That is one
    bit of an existing vocabulary, not a new mode and not a callback: the whole
    reason `PushdownGate` is bits is that a plan node holding a fn-ptr would
    stop being serializable.
    """
    var req = List[String]()
    req.append(String(BROKER_PARAM_TOPIC))
    req.append(String(BROKER_PARAM_PARTITION))
    return ScanKindDescriptor(
        kind_name=String(BROKER_SCAN_KIND_NAME),
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        snapshot_policy=SNAPSHOT_LIVE,
        required_params=req^,
    )


def broker_scan_binding(
    var topic: String,
    partition: Int64,
    start_offset: Int64,
    var schema: Schema,
) -> ScanBinding:
    """Build the plan-side identity token for a broker consume scan.

    Carries NO `ConsumeCore`, no `Storage`, no network handle — which is the
    whole reason it can be `Copyable` and live in an IR. `consumer_source.mojo`
    calls the absence of exactly this "THE COPYABLE WALL": `ConsumeCore` is
    Movable-only because it owns a network-backed store, so a `SourceLike`
    conformance would have forced a `copy()` that duplicates a live network
    handle on every plan-cache copy.

    IDENTITY excludes the offset — that is what `SNAPSHOT_LIVE` means. Two
    queries over the same (topic, partition) share a cache key across produces;
    freshness comes from `BrokerScanResolver.resolve_snapshot` at execution
    start, not from churning the key.
    """
    var params = ScanParams()
    params.put_i64(String(BROKER_PARAM_PARTITION), partition)
    params.put_i64(String(BROKER_PARAM_START_OFFSET), start_offset)
    params.put_str(String(BROKER_PARAM_TOPIC), String(topic))

    # A CONTENT-derived identity, stable across processes. Note what it does
    # NOT use: a process-global monotonic counter. `InMemorySource._identity`
    # is one, and it is the reason that arm cannot serialize even with the Arc
    # removed.
    var fp = param_hash_string(topic, UInt64(broker_scan_kind_id()))
    fp = (fp ^ UInt64(partition)) * UInt64(1099511628211)

    return ScanBinding(
        kind_id=broker_scan_kind_id(),
        kind_name=String(BROKER_SCAN_KIND_NAME),
        name=topic^,
        params=params^,
        schema=schema^,
        fingerprint=fp,
        structural_id=fp,
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        snapshot_policy=SNAPSHOT_LIVE,
        # ⚠ ZERO, ALWAYS, in a plan. A LIVE token is written to a
        # PER-EXECUTION copy and never back into a cached plan, so a non-zero
        # LIVE token found in a cached plan is a detectable bug.
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def broker_scan_identity_corpus(var schema: Schema) -> ScanIdentityCorpus:
    """This kind's statement of what makes two of its scans different.

    ⚠ THE CORPUS LIVES IN THE KIND'S OWN PACKAGE, WHICH IS THE POINT. The audit
    that consumes it is core-resident and knows nothing about brokers; it asks
    every registered kind the same question and checks the answer mechanically.
    That is the same layering this whole file is about, applied to the gate.

    `broker_scan_binding`'s `fingerprint` folds (topic, partition) and NOT
    `start_offset` — deliberately, because a broker offset moves and
    `SNAPSHOT_LIVE` means the token is excluded from identity. The `offset`
    entry is here anyway: the audit's rule R2 only constrains pairs the KIND's
    own fold separates, so this entry places no demand — but the plan-text rule
    in `tests/test_scan_identity_coverage.mojo` does check it, and that is
    the check that catches the second instance of this class (a
    supplied `structural_id` omitting `start_offset`).
    """
    var c = ScanIdentityCorpus(broker_scan_descriptor())
    c.add(
        String("baseline"),
        broker_scan_binding(
            String("orders"), Int64(3), Int64(1000), schema.copy()
        ),
    )
    c.add(
        String("topic"),
        broker_scan_binding(
            String("events"), Int64(3), Int64(1000), schema.copy()
        ),
    )
    c.add(
        String("partition"),
        broker_scan_binding(
            String("orders"), Int64(4), Int64(1000), schema.copy()
        ),
    )
    c.add(
        String("start_offset"),
        broker_scan_binding(String("orders"), Int64(3), Int64(2000), schema^),
    )
    return c^


@fieldwise_init
struct BrokerScanResolver(ScanResolver, Movable, Deinitable):
    """Execution-time resolution for `komira.broker.consume`, TIER 1.

    Lives here, not in core, because a high-watermark is a broker concept. Core
    calls `resolve_snapshot` through the `ScanResolver` trait and never learns
    what it resolved.

    THE OWNERSHIP RULE applies to this type: it must outlive every
    execution that resolves against it, and `epoch` is what makes a violation a
    named error instead of a dangling read. This stand-in models the
    high-watermark as a value; the real conformer reads it from `ConsumeCore`.
    """

    var _epoch: UInt64
    var _high_watermark: UInt64

    def epoch(self) -> UInt64:
        return self._epoch

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return kind_id == broker_scan_kind_id() and handle >= 0

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """Re-read the CURRENT high-watermark for this (topic, partition).

        Called once per scan leaf per EXECUTION on the driver thread — never
        per morsel (the engine operator and runtime packages contain zero
        payload reads). So there is
        no lock and no atomic on this path.
        """
        if binding.kind_id != broker_scan_kind_id():
            raise Error(
                String("BrokerScanResolver: refusing to resolve foreign kind '")
                + binding.kind_name
                + String("'")
            )
        return self._high_watermark
