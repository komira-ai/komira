# =============================================================================
# ScanBinding — PURE DATA identity for a scan's source.
# =============================================================================
#
# WHAT THIS REPLACES AND WHY. `SourceVariant` (source_variant.mojo) is a CLOSED
# 9-arm tagged union owned by the BOTTOM package, referenced as a field on
# `ScanData`. Because it is closed and it is at the bottom, it destroys two
# properties the sink side keeps:
#
#   LAYERING — all 7 `SourceLike` conformers must live inside
#   the core packages, so nothing above the engine can be a source. Adding
#   a broker arm would force the core packages to depend on the broker and its
#   object-store and HTTP stack, INVERTING THE BUILD DAG. Sinks, a trait
#   PARAMETER, can be defined in any package. One field is the whole
#   difference.
#
#   SERIALIZABILITY — `InMemorySource` holds `ArcPointer[Slab[RecordBatch]]`,
#   i.e. LIVE HEAP DATA inside the IR. A plan is therefore not a description of
#   work, it is a container of the data: it cannot be written to disk, sent to
#   another process, or cached across runs.
#
# The fix is a Copyable backend HANDLE on the plan: a cheap identity token the
# plan builder copies, with the heavy substrate constructed at execute time.
#
# PRECEDENT — the same seam exists for filesystems.
# `komira_plan_expr/fs_descriptor_pod.mojo` is a pure identity POD on the
# plan node naming its source, whose live counterpart (the file system its
# scheme names) is constructed above core at execute time.
# `partition_pred_pod.mojo` is a second instance. ScanBinding is that same seam
# applied to SOURCES.
#
# PERFORMANCE IS NOT THE POINT:
#   * `Schema.copy()` dominates a plan clone; the Arc refcount bump is a
#     rounding error. CHEAP PLAN CLONES ARE NOT A BENEFIT OF THIS DESIGN —
#     `ScanBinding` keeps `Schema` by value and inherits the same floor.
#   * The seam costs nothing measurable per scan.
#   * Resolution is once per scan leaf per EXECUTION, on the driver thread —
#     never per morsel. So the resolver needs no lock and no atomic.
#   The benefits are layering + serializability.
#
# THE COST, NAMED. This is a genuine safety trade-off on one axis: `ArcPointer`
# in the IR is a COMPILE-TIME keep-alive; `handle: Int` is not. The ownership
# rule and the epoch check in `scan_resolver.mojo` are the price.
#
# POINTER DISCIPLINE: every field is a value —
# UInt8 / UInt32 / Int / UInt64 / String / List / Schema / Optional[TableStats].
# NO OwnedPointer, NO ArcPointer, NO UnsafePointer, NO wildcard origin, NO
# fn-ptr. That is not a style preference: it is the definition of the type.
# =============================================================================

from komira_arrow.schema import Schema
from komira_arrow.schema_identity import schema_identity_hash
from komira_plan_expr.expr import Expr
from komira_plan_stats.table_stats import TableStats
from komira_scan_source.pushdown_gate import (
    PushdownGate,
    gate_allows,
)
from komira_scan_source.scan_params import (
    ScanParams,
    param_hash_combine,
    param_hash_string,
)


# -----------------------------------------------------------------------------
# Snapshot policy — decides whether `snapshot_token` participates in IDENTITY.
# This one byte is the entire mechanism of the identity/freshness split.
# -----------------------------------------------------------------------------
comptime SNAPSHOT_NONE: UInt8 = 0
"""Content is immutable for the process lifetime. Token unused (0)."""

comptime SNAPSHOT_PINNED: UInt8 = 1
"""The token IS identity — a parquet `_mtime_ns`. Folded into
`identity_hash`; resolved once, at plan build."""

comptime SNAPSHOT_LIVE: UInt8 = 2
"""The token is NOT identity — a broker offset, a search generation. EXCLUDED
from `identity_hash` (so the plan cache hits across publishes) and re-resolved
at EXECUTION start via `ScanResolver.resolve_snapshot` (so it is never stale).

A search source that folds its `generation` into `fingerprint()` is safe but
thrashy — every publish changes every query's identity. The naive fix (drop it
from identity, bake the value) is UNSAFE and fails hard, not quietly: a
metastore that sizes its reaper grace window against MAX QUERY DURATION, not
plan-cache lifetime, would 404 a replayed cached plan's baked token on a
reaped object."""


comptime SCAN_HANDLE_UNBOUND: Int = -1
comptime SCAN_EPOCH_NONE: UInt64 = 0

comptime SCAN_STRUCTURAL_ID_UNRESOLVED: UInt64 = 0
"""A `structural_id` that has DELIBERATELY NOT BEEN COMPUTED.

⚠ NOT A DEFAULT AND NOT "UNKNOWN". A binding carrying this value is a
RESOLUTION TOKEN — a `(kind_id, handle, epoch)` good for reaching a payload —
and is NOT a plan identity. It may never reach a rendered plan, a
`structural_hash()`, or a plan-cache key, because a shared 0 makes two scans
over DIFFERENT content agree on the one field that separates them.

WHY IT EXISTS. `inmem_scan_binding` supplies `structural_id =
InMemorySource.structural_id()`, a CONTENT hash that is O(total batch bytes)
and memoized PER SOURCE INSTANCE. Computing it on a freshly-built source is
therefore a full fold of the payload, and scan dedup binds a dedup'd FACT
TABLE on the driver, once per group, on every query with a duplicated or
session-cache-hit scan. That cost is a real share of driver cycles on such
queries, and no value assertion anywhere can see it, because the rows are
identical either way.

THE ONE PRODUCER is `inmem_scan_binding(ims, fold_content_identity=False)`, and
the one consumer is `optimizer_scan_dedup._bind_dedup_batch`, whose stamped
node is rebuilt WITHOUT its binding by `_inline_one_registry_scan` before the
plan is rendered or hashed.

⚠ A CHANGE THAT CARRIES A DEDUP HANDLE FORWARD ONTO THE FINISHED PLAN MUST
SUPPLY A REAL `structural_id` FIRST. It cannot simply stop stripping the
binding: that would put this 0 into `bsid=` for every dedup'd scan.
"""


# -----------------------------------------------------------------------------
# Orientation — a DECLARED property of the kind.
# -----------------------------------------------------------------------------
# Deliberately re-declared here rather than imported from the plan layer:
# `ScanBinding` must not depend on `logical_plan_variants`, which depends on
# it. The values are pinned equal to `SOURCE_KIND_COLUMNAR` /
# `SOURCE_KIND_ROW` and a test asserts that equality, so the ladder inside
# `ScanData.__init__` can be deleted arm-by-arm without a mapping table.
comptime SCAN_ORIENTATION_COLUMNAR: UInt8 = 0
comptime SCAN_ORIENTATION_ROW: UInt8 = 1


# -----------------------------------------------------------------------------
# The legacy `source_type` a binding-backed arm must keep answering — DECLARED DATA.
# -----------------------------------------------------------------------------
# This exists for exactly one reason: to keep `ScanData.__init__`'s derivation
# ladder from growing an arm per kind. Making the value DECLARED (like
# `orientation` is) collapses the branch to one assignment, so the next kind
# costs ZERO core lines.
#
# ⚠ THE VALUE IS A `SOURCE_*` CONSTANT FROM `plan/logical_plan.mojo`, SPELLED AS
# A NUMBER. `logical_plan.mojo` imports `source_variant.mojo`, which imports
# this file, so importing the plan layer back is a cycle. Same constraint, same
# answer, as `SCAN_ORIENTATION_*` above: the arm declares the number and a test
# pins it equal to the named constant.
#
# ⚠ THIS FIELD IS SCAFFOLDING. It carries the LEGACY enum while `SourceVariant`
# exists; when `SourceVariant` is deleted, `source_type` and this field go with
# it and `kind_id` is the only discriminant left. A kind from an upper package
# has no legacy enum value and leaves it at the sentinel — which is why the
# sentinel, not a real `SOURCE_*` value, is the default.
comptime SCAN_LEGACY_SOURCE_TYPE_NONE: UInt8 = 255
"""No legacy `SOURCE_*` enum value exists for this kind — the derivation
yields `SOURCE_BINDING`, i.e. "consult `kind_id`". 255 cannot collide: the
plan layer's constants are 0..8."""


# =============================================================================
# kind_id — a HASHED NAME, not a hand-assigned tag.
# =============================================================================


comptime _KIND_FNV32_OFFSET: UInt32 = 2166136261
comptime _KIND_FNV32_PRIME: UInt32 = 16777619


def scan_kind_id(name: String) -> UInt32:
    """FNV-1a 32-bit hash of a reverse-DNS kind name.

    ⚠ WHY NOT A TAG BYTE. Hand-assigned ids (`SCAN_KIND_PARQUET: UInt8 = 2`)
    need a central allocation table, and a central allocation table in
    the core packages is the closed union again in another spelling — every new
    kind would edit core just to claim a number.

    A hashed name needs no table (no core edit to claim an id) and is stable
    ACROSS PROCESSES, so it survives serialization — which
    `InMemorySource._identity` (a process-global monotonic counter) cannot.
    Collisions are remote but not impossible; `ScanKindRegistry.register`
    rejects a second registration of the same id under a different name, so a
    collision is a loud startup failure, never a silent mis-dispatch.
    """
    var h = _KIND_FNV32_OFFSET
    var b = name.as_bytes()
    for i in range(len(b)):
        h = h ^ UInt32(b[i])
        h = h * _KIND_FNV32_PRIME
    return h


# The kinds this package itself owns. A kind owned by an UPPER package computes
# its own id from its own name and never appears here — that is the point.
comptime SCAN_KIND_NAME_ARROW_IPC: String = "komira.arrow.ipc"
comptime SCAN_KIND_NAME_ORC: String = "komira.orc"
comptime SCAN_KIND_NAME_AVRO: String = "komira.avro"
"""A `SCAN_ORIENTATION_ROW` kind: Avro OCF is row-oriented on disk."""
comptime SCAN_KIND_NAME_CSV: String = "komira.csv"
"""A `SCAN_ORIENTATION_ROW` kind. Orientation is INTRINSIC to the source FORMAT
and CSV is a ROW source: the `LogicalPlan.scan(path, SOURCE_CSV, ...)` factory
threads `SOURCE_KIND_ROW`, both row-streaming path walkers read the CSV arm as
a ROW source, and the typed conformer
`komira_parquet.csv_typed_source.CsvSource[FS].orientation = ROW()` agrees."""
comptime SCAN_KIND_NAME_JSON: String = "komira.json"
"""A `SCAN_ORIENTATION_ROW` kind. JSONL is a ROW-major on-wire format:
`read_jsonl_row_streaming` and `JsonlReader.build_scan_plan` both build ROW
scans, `row_streaming_dispatch` routes this arm's TAG to the JSONL direct ROW
reader, and the typed conformer `jsonl_typed_source.JsonlSource[FS].orientation
= ROW()` agrees. No plan-execution path reads a JSON scan columnar.

⚠ THE DECLARATION IS NOT A FREE CHOICE. Declaring COLUMNAR would make
`_require_orientation_agreement` RAISE on both live callers, and dropping their
argument instead would route a row-major file at the column executor."""
comptime SCAN_KIND_NAME_IN_MEMORY: String = "komira.in_memory"
"""THE KIND WHOSE `fingerprint` AND `structural_id` ARE DIFFERENT VALUES, and
the divergence is forced rather than chosen for taste.

For arrow / ORC / AVRO / CSV / JSON the two fields are the same number, because
a file kind's whole identity (path + mtime) is something CORE CAN SEE — it goes
in `params` and the PINNED snapshot token, so `identity_hash()` separates every
pair the kind separates and audit rule R2 is satisfiable. IN_MEMORY is the kind
`structural_id` exists for: two `from_record_batch` sources with one name and
one schema differ ONLY in their BYTES, and no fold core can perform sees a
byte.

So this kind supplies:

    structural_id = InMemorySource.structural_id()   the CONTENT hash
    fingerprint   = schema_identity_hash(schema)     the CORE-VISIBLE identity

and it may not supply the content hash for BOTH: the audit over a bytes-only
corpus raises R2. The only way to satisfy R2 with a content-derived
`fingerprint` is to make `identity_hash()` content-sensitive (a `params` entry
or a PINNED token), and `identity_hash()` reaches `bid=`, which
`placeholder_inmem_id` deliberately does NOT placeholder — so the CHEAP key
would stop being content-blind. The content identity reaches the plan-compile
cache key through `bsid=`, which is audited by R5 — the rule written for
exactly this kind."""


struct ScanBinding(Copyable, Movable, Deinitable):
    """PURE DATA replacement for the `SourceVariant` field on `ScanData`.

    Carries a scan's plan-time IDENTITY and CAPABILITIES. Carries NO live data.
    The payload is reached at EXECUTION time via (`kind_id`, `handle`) into a
    resolver owned by the package that registered `kind_id`.
    """

    var kind_id: UInt32
    """Open source-kind id — `scan_kind_id("komira.arrow.ipc")`."""

    var kind_name: String
    """The reverse-DNS name `kind_id` was hashed from. Carried (not just the
    id) so EXPLAIN can name a kind the reader's build has never registered,
    and so a collision is diagnosable from the plan alone."""

    var name: String
    """Human label for EXPLAIN and registry lookup — a path, a table name."""

    var params: ScanParams
    """The kind's configuration. Opaque to core; see `scan_params.mojo`."""

    var schema: Schema
    var stats: Optional[TableStats]

    var fingerprint: UInt64
    """The kind's own PLAN-DISCRIMINATING identity — the value the audit treats
    as the authority on what makes two of this kind's scans different. Stable
    across `copy()` and `value^`.

    ⚠ THIS IS SUPPLIED BY THE KIND, NOT COMPUTED HERE. For a file kind (arrow,
    ORC, AVRO, CSV, JSON) that value IS the concrete source's `fingerprint()`,
    and it MUST be passed unchanged, or every plan-cache key changes and every
    cached plan silently recompiles — not a correctness break, a silent perf
    cliff. `identity_hash()` below is the fold for kinds that have no concrete
    fingerprint to preserve.

    ⚠ BUT "PASS THE CONCRETE SOURCE'S `fingerprint()`" IS A CONSEQUENCE, NOT THE
    RULE. It is right for a FILE source because there `fingerprint()` IS the
    content identity (path + mtime). **It is WRONG for IN_MEMORY**, and
    following it there is a trap with a silent consequence:

        `InMemorySource.fingerprint()` == `_mix64(<process-global counter>)`

    a PER-CONSTRUCTION token, not a property of the data. Two sources over
    BYTE-IDENTICAL content return different fingerprints, while their
    `structural_id()`, their rendered plan text and
    `LogicalPlan.structural_hash()` are all EQUAL — deliberately, because a
    structural hash must be equal for structurally identical plans (folding
    the counter into it would break subquery dedup and the plan-compile
    cache).

    Supplied here, the counter satisfies audit rule R1 (>= 2 DISTINCT
    fingerprints) for FREE — so R1, whose entire job is "a corpus that asserts
    nothing must FAIL", becomes unfalsifiable for this kind — and then drives R2
    to demand core separate two scans it must not separate. R2's FIX line
    ("carry the differing input in `params`") would make every in-memory plan's
    `factory_hash` per-construction unique.

    THE RULE: pass the identity that is a FUNCTION OF THE DATA.
    `audit_scan_identity_reproducibility` (R9) is the mechanical check — it
    builds the kind's corpus TWICE and requires the two builds to agree, which
    a counter cannot.

    ⚠ AND THE RULE HAS A SECOND CLAUSE: pass the identity that is a function
    of the data **AND THAT CORE CAN SEE**. R2 demands this field be no finer
    than `identity_hash()`, which folds only kind_id, kind_name, name, params,
    schema, gate and orientation (+ the token iff PINNED). For the FILE kinds
    those two clauses pick the same number, because a file kind's whole
    identity is a path and an mtime.

    `komira.in_memory` is the kind whose `fingerprint` and `structural_id` are
    DIFFERENT VALUES:

        structural_id = InMemorySource.structural_id()   the CONTENT hash
        fingerprint   = schema_identity_hash(schema)     what core can see

    Supplying the content hash for BOTH fires R2 on every bytes-only pair, and
    R2's own FIX line (carry it in `params`, or as a PINNED token) makes
    `identity_hash()` content-sensitive — which puts the content hash into
    `bid=`, which `plan_display` deliberately does not placeholder, which ends
    the CHEAP key's content-blindness. The content identity travels as
    `structural_id`, and rule R5 is its auditor."""

    var structural_id: UInt64
    """CONTENT-derived identity, SUPPLIED by the kind. Same byte-identity
    requirement as `fingerprint`.

    ⚠ WHAT IT IS FOR. This field carries the part of identity that CORE CANNOT
    COMPUTE — the case that needs it is IN_MEMORY, where two batches with the
    same name, params and schema differ only in their BYTES, and only
    `InMemorySource` can hash those. For every file-path kind it equals
    `fingerprint`.

    ⚠ IT IS NOT, ON ITS OWN, WHAT `LogicalPlan.structural_hash` FOLDS. The
    render folds this field AND `identity_hash()` AND `render()`, because a
    SUPPLIED value can be incomplete and nothing goes red when it is:
    `broker_scan_binding` supplies a `structural_id` over (topic, partition)
    that omits `start_offset`, so two scans differing only in start_offset
    share this value. Core's derived `identity_hash()` is what covers that;
    this field is what covers content core cannot see. Neither subsumes the
    other, so the render emits both."""

    var snapshot_policy: UInt8
    var snapshot_token: UInt64
    """Meaning governed by `snapshot_policy`. See the SNAPSHOT_* docs."""

    var pushdown_gate: PushdownGate
    """Capability BITS, never a callback — see `pushdown_gate.mojo`."""

    var pushdown_extra_cols: List[String]
    """Column names pushable beyond those in `schema` — parquet's Hive
    partition columns are the in-tree case. Data, not a callback."""

    var orientation: UInt8
    """SCAN_ORIENTATION_COLUMNAR / _ROW. A DECLARED property of the kind, which
    is what lets the `source_type` ladder in `logical_plan_variants.mojo`
    collapse to one assignment. It is AUTHORITATIVE over a caller's
    `source_kind`, and `ScanKindRegistry.validate` compares it against the
    descriptor's.

    ⚠ The registry must keep holding kinds of BOTH orientations: in an
    all-COLUMNAR registry (COLUMNAR is also this parameter's default) no reader
    of this field could produce an answer a default would not, and every
    mechanism that checks it would pass as dead code."""

    var legacy_source_type: UInt8
    """The `SOURCE_*` value a binding-backed legacy arm must keep answering, or
    `SCAN_LEGACY_SOURCE_TYPE_NONE`. Declared, not derived — see the constant's
    docs above for why this is a field and not a tag-keyed branch in
    `ScanData.__init__`.

    ⚠ DELIBERATELY NOT FOLDED INTO `identity_hash()` AND NOT EMITTED BY
    `render()`. It is fully determined by `kind_id`, which IS folded, so folding
    it would add no discrimination — and it would move every existing
    binding's `bid=` value, i.e. exactly the silent plan-cache-key drift that
    must not happen."""

    var handle: Int
    """Registry slot, or SCAN_HANDLE_UNBOUND."""

    var registry_epoch: UInt64
    """The epoch of the registry that minted `handle`. A handle is meaningless
    without it; resolution RAISES on mismatch. This runtime check is what
    replaces the Arc's compile-time keep-alive."""

    def __init__(
        out self,
        kind_id: UInt32,
        var kind_name: String,
        var name: String,
        var params: ScanParams,
        var schema: Schema,
        fingerprint: UInt64,
        structural_id: UInt64,
        var gate: PushdownGate,
        snapshot_policy: UInt8 = SNAPSHOT_NONE,
        snapshot_token: UInt64 = UInt64(0),
        orientation: UInt8 = SCAN_ORIENTATION_COLUMNAR,
        legacy_source_type: UInt8 = SCAN_LEGACY_SOURCE_TYPE_NONE,
        handle: Int = SCAN_HANDLE_UNBOUND,
        registry_epoch: UInt64 = SCAN_EPOCH_NONE,
        var stats: Optional[TableStats] = None,
        var pushdown_extra_cols: List[String] = List[String](),
    ):
        self.kind_id = kind_id
        self.kind_name = kind_name^
        self.name = name^
        self.params = params^
        self.schema = schema^
        self.stats = stats^
        self.fingerprint = fingerprint
        self.structural_id = structural_id
        self.snapshot_policy = snapshot_policy
        self.snapshot_token = snapshot_token
        self.pushdown_gate = gate^
        self.pushdown_extra_cols = pushdown_extra_cols^
        self.orientation = orientation
        self.legacy_source_type = legacy_source_type
        self.handle = handle
        self.registry_epoch = registry_epoch

    def copy(self) -> Self:
        """Deep clone. NO refcount traffic — the payload is not reachable from
        here at all. Cost is dominated by `Schema.copy()`."""
        var stats_copy: Optional[TableStats] = None
        if self.stats:
            stats_copy = Optional(self.stats.value().copy())
        return Self(
            kind_id=self.kind_id,
            kind_name=String(self.kind_name),
            name=String(self.name),
            params=self.params.copy(),
            schema=self.schema.copy(),
            fingerprint=self.fingerprint,
            structural_id=self.structural_id,
            gate=self.pushdown_gate.copy(),
            snapshot_policy=self.snapshot_policy,
            snapshot_token=self.snapshot_token,
            orientation=self.orientation,
            legacy_source_type=self.legacy_source_type,
            handle=self.handle,
            registry_epoch=self.registry_epoch,
            stats=stats_copy^,
            pushdown_extra_cols=self.pushdown_extra_cols.copy(),
        )

    # =========================================================================
    # SourceLike-equivalent surface, answered from DATA.
    # =========================================================================

    def source_schema(self) -> Schema:
        """Structural schema (eager copy, no I/O). Named `source_schema` rather
        than `schema` because `schema` is a FIELD — a source's schema is data
        here, which is the whole idea."""
        return self.schema.copy()

    def estimate_rows(self) -> Int:
        """Row-count hint. -1 means unknown, matching `SourceLike`."""
        var v = self.params.get(String("estimated_rows"))
        if v:
            return Int(v.value().as_i64())
        return -1

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Plan-time pushdown answer, computed by the core-resident matcher
        against (gate, schema, extra cols, predicate). NO concrete source is
        reachable from here."""
        return gate_allows(
            self.pushdown_gate,
            self.schema,
            self.pushdown_extra_cols,
            predicate,
        )

    def identity_hash(self) -> UInt64:
        """FORWARD-LOOKING identity fold, for kinds with no legacy fingerprint
        to preserve. Includes `snapshot_token` IFF policy == PINNED — that one
        conditional is the whole of the identity/freshness split."""
        var h = param_hash_combine(UInt64(0xCBF29CE484222325), UInt64(self.kind_id))
        h = param_hash_string(self.kind_name, h)
        h = param_hash_string(self.name, h)
        h = self.params.hash_into(h)
        h = param_hash_combine(h, schema_identity_hash(self.schema))
        h = self.pushdown_gate.hash_into(h)
        h = param_hash_combine(h, UInt64(self.orientation))
        if self.snapshot_policy == SNAPSHOT_PINNED:
            h = param_hash_combine(h, self.snapshot_token)
        return h

    def render(self) -> String:
        """EXPLAIN rendering. Works for a kind this build never registered —
        which is why `params` is a readable map and not an opaque blob."""
        var out = String(self.kind_name)
        out += String("(")
        out += self.name
        if self.params.num_params() > 0:
            out += String(", ")
            out += self.params.render()
        out += String(")")
        return out^

    def is_bound(self) -> Bool:
        return self.handle != SCAN_HANDLE_UNBOUND

    def with_handle(self, handle: Int, registry_epoch: UInt64) -> Self:
        """Return a copy bound to a registry slot. Returns a NEW value rather
        than mutating: a binding inside a cached plan must never acquire a
        handle from an execution that ran after the plan was cached."""
        var out = self.copy()
        out.handle = handle
        out.registry_epoch = registry_epoch
        return out^

    def with_snapshot_token(self, token: UInt64) -> Self:
        """Return a per-execution copy carrying a freshly resolved LIVE token.

        ⚠ THE INVARIANT: a SNAPSHOT_LIVE token may never be
        written back into a cached plan. `resolve_snapshot` hands its result
        here, and the result is a per-execution value. A cached plan holds
        `snapshot_token == 0` for every LIVE binding, and a non-zero LIVE token
        in a cached plan is a detectable bug.
        """
        var out = self.copy()
        out.snapshot_token = token
        return out^
