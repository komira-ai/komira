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
# WHERE EXECUTION LIVES
# ---------------------------------------------------------------------------
#
# A plan can be BUILT, TYPED, PUSHDOWN-QUERIED, EXPLAINED, CLONED, CACHE-KEYED
# and RESOLVED against a registry owned by this package. Execution is tier 2
# (`ScanMorselResolver`, `komira_scan_resolver`): the broker's conformer is
# `BrokerScanRuntime` in `broker_scan_kind.mojo`, which resolves the LIVE token
# and drains the partitions the binding names. No eager drain into an
# in-memory source is provided; a topic is read through the plan.
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
# stale). `BrokerScanRuntime.resolve_snapshot` (`broker_scan_kind.mojo`) is
# the re-resolution, and it lives in this package because the high-watermark
# is a broker concept core cannot spell.
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
from komira_core.source.scan_params import (
    ScanParams,
    param_hash_string,
    PARAM_I64,
    PARAM_STR,
)


comptime BROKER_SCAN_KIND_NAME: String = "komira.broker.topic"
"""Reverse-DNS kind name. NO CENTRAL TABLE ALLOCATES THIS —
`kind_id` is its FNV-1a/32 hash, which is exactly why claiming a kind costs no
core edit. Distinct from the exchange kinds (`komira.exchange.write`/`.read`)."""

comptime BROKER_PARAM_TOPIC: String = "topic"
comptime BROKER_PARAM_PARTITIONS: String = "partitions"
"""MULTI-VALUED: the canonical comma-joined, ascending, de-duplicated partition
ids (`"0,3,7"`). One scan over N partitions — not N plans, not a UNION — and every output row carries `BROKER_PARTITION_COLUMN`."""
comptime BROKER_PARAM_START_OFFSET: String = "start_offset"
"""The first offset to read, for every partition that `start_offsets` does not
override. Default 0. NOT in the fingerprint (a broker offset moves)."""
comptime BROKER_PARAM_START_OFFSETS: String = "start_offsets"
"""Optional per-partition start offsets, comma-joined and ALIGNED with the
canonical `partitions` list (a Kafka Fetch names one offset per partition).
NOT in the fingerprint."""
comptime BROKER_PARAM_ISOLATION: String = "isolation"
"""`read_committed` (bounded by the last stable offset, aborted transactions
removed) or `read_uncommitted` (bounded by the high-watermark; Kafka's
default). Stored ONLY when it is `read_committed`, so the default spelling and
the omitted one are ONE binding. IN the fingerprint: it changes the rows."""
comptime BROKER_PARAM_MAX_BYTES: String = "max_bytes"
"""The byte budget for the whole scan, `-1`/absent = none.
NOT in the fingerprint — a budget changes how much of the same relation one
execution returns, not which relation it is. KIP-74 applies (see
`broker_scan_kind.mojo`)."""
comptime BROKER_PARAM_PARTITION_MAX_BYTES: String = "partition_max_bytes"
"""The byte budget per partition, `-1`/absent = none. NOT in the fingerprint."""

comptime BROKER_ISOLATION_READ_COMMITTED: String = "read_committed"
comptime BROKER_ISOLATION_READ_UNCOMMITTED: String = "read_uncommitted"

comptime BROKER_PARTITION_COLUMN: String = "__partition"
"""The INT64 column every broker scan appends to the topic's own schema: which
partition a row came from. A binding built by the kind (`build_binding`)
declares it as its LAST field."""

comptime BROKER_SCAN_UNKNOWN_PARAM: StaticString = "BROKER_SCAN_UNKNOWN_PARAM"
"""NAMED ERROR — a param key this kind does not define. Refused rather than
ignored: a typo in `partition_max_bytes` would otherwise silently drop the
budget."""
comptime BROKER_SCAN_BAD_PARAM: StaticString = "BROKER_SCAN_BAD_PARAM"
"""NAMED ERROR — a param with the wrong type or an unparsable value."""


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
    # Only `topic`: `partitions` defaults to every partition of the topic
    # (`BrokerScanRuntime.build_binding`), so a binding naming only the topic
    # needs nothing else. Every binding the kind BUILDS carries both.
    var req = List[String]()
    req.append(String(BROKER_PARAM_TOPIC))
    return ScanKindDescriptor(
        kind_name=String(BROKER_SCAN_KIND_NAME),
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        snapshot_policy=SNAPSHOT_LIVE,
        required_params=req^,
    )


# =============================================================================
# The partition list: parse / canonicalize / render.
# =============================================================================


def broker_join_i64(values: List[Int64]) -> String:
    """`[0, 3, 7]` -> `"0,3,7"`. The one spelling a list param has."""
    var out = String("")
    for i in range(len(values)):
        if i > 0:
            out += String(",")
        out += String(values[i])
    return out^


def broker_parse_i64_list(text: String, what: String) raises -> List[Int64]:
    """`"0,3,7"` -> `[0, 3, 7]`, in the order written. Refuses an empty
    element or a non-integer, naming `what`."""
    var out = List[Int64]()
    if text == String(""):
        return out^
    var parts = text.split(",")
    for i in range(len(parts)):
        var t = String(String(parts[i]).strip())
        if t == String(""):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": '")
                + what
                + String("' has an empty element in '")
                + text
                + String("'")
            )
        try:
            out.append(Int64(atol(t)))
        except:
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": '")
                + what
                + String("' element '")
                + t
                + String("' is not an integer")
            )
    return out^


def broker_canonical_partitions(partitions: List[Int64]) raises -> List[Int64]:
    """Ascending and de-duplicated, so `"3,0"` and `"0,3,3"` are ONE binding.
    Refuses a negative id and an empty list."""
    if len(partitions) == 0:
        raise Error(
            String(BROKER_SCAN_BAD_PARAM)
            + String(": '")
            + String(BROKER_PARAM_PARTITIONS)
            + String("' names no partition")
        )
    var out = List[Int64]()
    for i in range(len(partitions)):
        var p = partitions[i]
        if p < Int64(0):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": partition ")
                + String(p)
                + String(" is negative")
            )
        var pos = len(out)
        var dup = False
        for j in range(len(out)):
            if out[j] == p:
                dup = True
                break
            if out[j] > p:
                pos = j
                break
        if dup:
            continue
        out.insert(pos, p)
    return out^


# =============================================================================
# The binding.
# =============================================================================


def _broker_fingerprint(
    topic: String, partitions: List[Int64], read_committed: Bool
) -> UInt64:
    """A CONTENT-derived identity, stable across processes. Folds (topic, every
    partition, isolation) and NOTHING the kind leaves live: not a start offset,
    not a byte budget, not the snapshot token.

    Note what it does NOT use: a process-global monotonic counter.
    `InMemorySource._identity` is one, and it is the reason that arm cannot
    serialize even with the Arc removed.

    For one partition under the default isolation this is byte-identical to the
    pre-multi-partition fold (`(fp ^ partition) * prime`), so a single-partition
    binding kept its `bsid`.
    """
    var fp = param_hash_string(topic, UInt64(broker_scan_kind_id()))
    for i in range(len(partitions)):
        fp = (fp ^ UInt64(partitions[i])) * UInt64(1099511628211)
    if read_committed:
        fp = param_hash_string(String(BROKER_ISOLATION_READ_COMMITTED), fp)
    return fp


def _broker_binding_from_canonical(
    var topic: String,
    var params: ScanParams,
    var schema: Schema,
    fingerprint: UInt64,
) -> ScanBinding:
    return ScanBinding(
        kind_id=broker_scan_kind_id(),
        kind_name=String(BROKER_SCAN_KIND_NAME),
        name=topic^,
        params=params^,
        schema=schema^,
        fingerprint=fingerprint,
        structural_id=fingerprint,
        gate=PushdownGate.conjunctive_comparison(require_stat_friendly_col=False),
        snapshot_policy=SNAPSHOT_LIVE,
        # ⚠ ZERO, ALWAYS, in a plan. A LIVE token is written to a
        # PER-EXECUTION copy and never back into a cached plan, so a non-zero
        # LIVE token found in a cached plan is a detectable bug.
        snapshot_token=UInt64(0),
        orientation=SCAN_ORIENTATION_COLUMNAR,
    )


def broker_scan_binding(
    var topic: String,
    partition: Int64,
    start_offset: Int64,
    var schema: Schema,
) -> ScanBinding:
    """A single-partition broker scan binding over a CALLER-DECLARED `schema`
    (taken as the whole relation; nothing is appended). The plan-level
    convenience the identity tests pin; an EXECUTABLE binding comes from
    `BrokerScanRuntime.build_binding`, which reads the topic's schema and
    appends `BROKER_PARTITION_COLUMN`.

    Carries NO `ConsumeCore`, no `Storage`, no network handle — which is the
    whole reason it can be `Copyable` and live in an IR. `consumer_source.mojo`
    calls the absence of exactly this "THE COPYABLE WALL": `ConsumeCore` is
    Movable-only because it owns a network-backed store, so a `SourceLike`
    conformance would have forced a `copy()` that duplicates a live network
    handle on every plan-cache copy.

    IDENTITY excludes the offset — that is what `SNAPSHOT_LIVE` means. Two
    queries over the same (topic, partition) share a cache key across produces;
    freshness comes from `BrokerScanRuntime.resolve_snapshot` at execution
    start, not from churning the key.
    """
    var parts = List[Int64]()
    parts.append(partition)
    var params = ScanParams()
    params.put_str(String(BROKER_PARAM_PARTITIONS), broker_join_i64(parts))
    params.put_i64(String(BROKER_PARAM_START_OFFSET), start_offset)
    params.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    var fp = _broker_fingerprint(topic, parts, False)
    return _broker_binding_from_canonical(topic^, params^, schema^, fp)


def broker_topic_binding(params: ScanParams, var schema: Schema) raises -> ScanBinding:
    """The general binding constructor over a caller's `params`: validates
    every key, canonicalizes the partition list and the isolation spelling,
    and folds the identity. `schema` is taken as the whole relation.

    Every key must be one this kind defines (`BROKER_SCAN_UNKNOWN_PARAM`
    otherwise); `topic` and `partitions` are required. The returned binding's
    LIVE token is 0 whatever the caller supplied — a token never rides in
    params, and `ScanBinding`'s own token starts at 0.
    """
    for i in range(params.num_params()):
        var k = params.key_at(i)
        if not (
            k == String(BROKER_PARAM_TOPIC)
            or k == String(BROKER_PARAM_PARTITIONS)
            or k == String(BROKER_PARAM_START_OFFSET)
            or k == String(BROKER_PARAM_START_OFFSETS)
            or k == String(BROKER_PARAM_ISOLATION)
            or k == String(BROKER_PARAM_MAX_BYTES)
            or k == String(BROKER_PARAM_PARTITION_MAX_BYTES)
        ):
            raise Error(
                String(BROKER_SCAN_UNKNOWN_PARAM)
                + String(": ")
                + String(BROKER_SCAN_KIND_NAME)
                + String(" defines no param '")
                + k
                + String("'")
            )
    _require_tag(params, String(BROKER_PARAM_TOPIC), PARAM_STR)
    _require_tag(params, String(BROKER_PARAM_PARTITIONS), PARAM_STR)
    var topic = params.get_str(String(BROKER_PARAM_TOPIC))
    if topic == String(""):
        raise Error(
            String(BROKER_SCAN_BAD_PARAM) + String(": 'topic' is empty")
        )
    var parts = broker_canonical_partitions(
        broker_parse_i64_list(
            params.get_str(String(BROKER_PARAM_PARTITIONS)),
            String(BROKER_PARAM_PARTITIONS),
        )
    )
    var out = ScanParams()
    out.put_str(String(BROKER_PARAM_TOPIC), String(topic))
    out.put_str(String(BROKER_PARAM_PARTITIONS), broker_join_i64(parts))

    if params.has(String(BROKER_PARAM_START_OFFSET)):
        _require_tag(params, String(BROKER_PARAM_START_OFFSET), PARAM_I64)
        out.put_i64(
            String(BROKER_PARAM_START_OFFSET),
            params.get_i64(String(BROKER_PARAM_START_OFFSET)),
        )
    if params.has(String(BROKER_PARAM_START_OFFSETS)):
        _require_tag(params, String(BROKER_PARAM_START_OFFSETS), PARAM_STR)
        # Aligned with the partition list AS WRITTEN, re-ordered here with it.
        var written = broker_parse_i64_list(
            params.get_str(String(BROKER_PARAM_PARTITIONS)),
            String(BROKER_PARAM_PARTITIONS),
        )
        var offs = broker_parse_i64_list(
            params.get_str(String(BROKER_PARAM_START_OFFSETS)),
            String(BROKER_PARAM_START_OFFSETS),
        )
        if len(offs) != len(written):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": 'start_offsets' has ")
                + String(len(offs))
                + String(" elements for ")
                + String(len(written))
                + String(" partitions")
            )
        var canon_offs = List[Int64]()
        for i in range(len(parts)):
            var found = False
            var v = Int64(0)
            for j in range(len(written)):
                if written[j] == parts[i]:
                    if found and offs[j] != v:
                        raise Error(
                            String(BROKER_SCAN_BAD_PARAM)
                            + String(": partition ")
                            + String(parts[i])
                            + String(" is named twice with different start offsets")
                        )
                    found = True
                    v = offs[j]
            canon_offs.append(v)
        out.put_str(String(BROKER_PARAM_START_OFFSETS), broker_join_i64(canon_offs))

    var read_committed = False
    if params.has(String(BROKER_PARAM_ISOLATION)):
        _require_tag(params, String(BROKER_PARAM_ISOLATION), PARAM_STR)
        var iso = params.get_str(String(BROKER_PARAM_ISOLATION))
        if iso == String(BROKER_ISOLATION_READ_COMMITTED):
            read_committed = True
            out.put_str(String(BROKER_PARAM_ISOLATION), String(iso))
        elif iso != String(BROKER_ISOLATION_READ_UNCOMMITTED):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": 'isolation' must be '")
                + String(BROKER_ISOLATION_READ_COMMITTED)
                + String("' or '")
                + String(BROKER_ISOLATION_READ_UNCOMMITTED)
                + String("', got '")
                + iso
                + String("'")
            )
    if params.has(String(BROKER_PARAM_MAX_BYTES)):
        _require_tag(params, String(BROKER_PARAM_MAX_BYTES), PARAM_I64)
        out.put_i64(
            String(BROKER_PARAM_MAX_BYTES),
            params.get_i64(String(BROKER_PARAM_MAX_BYTES)),
        )
    if params.has(String(BROKER_PARAM_PARTITION_MAX_BYTES)):
        _require_tag(params, String(BROKER_PARAM_PARTITION_MAX_BYTES), PARAM_I64)
        out.put_i64(
            String(BROKER_PARAM_PARTITION_MAX_BYTES),
            params.get_i64(String(BROKER_PARAM_PARTITION_MAX_BYTES)),
        )
    var fp = _broker_fingerprint(topic, parts, read_committed)
    return _broker_binding_from_canonical(topic^, out^, schema^, fp)


def _require_tag(params: ScanParams, key: String, tag: UInt8) raises:
    var v = params.get(key)
    if not v:
        raise Error(
            String(BROKER_SCAN_BAD_PARAM)
            + String(": required param '")
            + key
            + String("' is missing")
        )
    if v.value().tag != tag:
        raise Error(
            String(BROKER_SCAN_BAD_PARAM)
            + String(": param '")
            + key
            + String("' has the wrong type (")
            + v.value().render()
            + String(")")
        )


def broker_scan_identity_corpus(var schema: Schema) raises -> ScanIdentityCorpus:
    """This kind's statement of what makes two of its scans different.

    ⚠ THE CORPUS LIVES IN THE KIND'S OWN PACKAGE, WHICH IS THE POINT. The audit
    that consumes it is core-resident and knows nothing about brokers; it asks
    every registered kind the same question and checks the answer mechanically.
    That is the same layering this whole file is about, applied to the gate.

    `fingerprint` folds (topic, partitions, isolation) and NOT `start_offset`,
    `max_bytes` or `partition_max_bytes` — deliberately: an offset moves, and a
    byte budget changes how much of one relation an execution returns, not
    which relation it is. Those entries are here anyway: the audit's rule R2
    only constrains pairs the KIND's own fold separates, so they place no
    demand — but the plan-text rule in `tests/test_scan_identity_coverage.mojo`
    does check them, and that is the check that catches the second instance of
    this class (a supplied `structural_id` omitting `start_offset`).
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
        broker_scan_binding(String("orders"), Int64(3), Int64(2000), schema.copy()),
    )
    c.add(
        String("partitions"),
        broker_topic_binding(
            _corpus_params(String("3,4"), String(""), Int64(-1)), schema.copy()
        ),
    )
    c.add(
        String("isolation"),
        broker_topic_binding(
            _corpus_params(
                String("3"), String(BROKER_ISOLATION_READ_COMMITTED), Int64(-1)
            ),
            schema.copy(),
        ),
    )
    c.add(
        String("max_bytes"),
        broker_topic_binding(
            _corpus_params(String("3"), String(""), Int64(1048576)), schema^
        ),
    )
    return c^


def _corpus_params(
    partitions: String, isolation: String, max_bytes: Int64
) -> ScanParams:
    var p = ScanParams()
    p.put_str(String(BROKER_PARAM_TOPIC), String("orders"))
    p.put_str(String(BROKER_PARAM_PARTITIONS), String(partitions))
    p.put_i64(String(BROKER_PARAM_START_OFFSET), Int64(1000))
    if isolation != String(""):
        p.put_str(String(BROKER_PARAM_ISOLATION), String(isolation))
    if max_bytes >= Int64(0):
        p.put_i64(String(BROKER_PARAM_MAX_BYTES), max_bytes)
    return p^
