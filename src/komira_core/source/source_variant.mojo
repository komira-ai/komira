# =============================================================================
# SourceVariant — a closed union being replaced by `ScanBinding`.
# =============================================================================
#
# ⚠ READ THIS BEFORE ADDING AN ARM. Do NOT add a tenth concrete arm: build a
# `ScanBinding` in your own package and pass it to
# `SourceVariant.from_binding(...)`. A concrete arm here for a source defined
# above the engine (e.g. a broker) would force komira_core to depend on that
# source's object-store and HTTP stack, INVERTING THE BUILD DAG.
#
# THE HYBRID STATE:
#
#   BINDING-BACKED (payload in `_binding`, a `ScanBinding`):
#       tags 4/5/6  arrow uncompressed / lz4_frame / zstd  -> ONE kind
#                   `komira.arrow.ipc` + a `codec` param
#       tag 7       orc  -> kind `komira.orc`
#       tag 8       avro -> kind `komira.avro` (ROW)
#       tag 3       csv  -> kind `komira.csv`  (ROW)
#       tag 2       json -> kind `komira.json` (ROW)
#       tag 9       BINDING — any kind core has never heard of
#   CONCRETE ARMS (payload in a concrete-source Optional):
#       tags 0/1    parquet / in_memory
#
# `tag` is the LEGACY discriminant. Its VALUES are stable, so no caller that
# reads `tag` depends on which world an arm is in. `_tag_is_binding_backed(tag)`
# is the single place that says which world an arm is in; when it is true for
# every tag, `tag` can be deleted and `ScanBinding.kind_id` is the only
# discriminant left.
#
# ---------------------------------------------------------------------------
# The concrete arms:
# ---------------------------------------------------------------------------
#
#   - Direct-payload storage (NOT `Optional[OwnedPointer[T]]`, which Mojo
#     rejects for cyclic-type reasons). Each arm is `Optional[T]` for
#     concrete Movable+Copyable T.
#
#   - Inactive arm is `Optional[T] = None` (NOT a pre-constructed
#     `empty_default()`, which would pay an Arc allocation per Scan node).
#     Only the active arm holds a value; the inactive arm carries no payload
#     + costs nothing.
#
#   - copy() / fingerprint() / schema() / estimate_rows() dispatch on the
#     tag byte; the inactive arm stays None and is never touched in
#     dispatch.
#
# Precedent: the `WhenCaseData` tagged-union in `komira_core/plan/expr.mojo`
# (direct-payload storage in a Movable+Copyable variant). `Expr.copy()` is
# the canonical fall-through tag-dispatch pattern this file mirrors.
#
# Cross-engine analogs:
#   - DuckDB: `BoundTableRef` polymorphic source.
#   - DataFusion: `TableSource` enum.
#
# The answer to the union's growing size is not a smaller box per arm — it
# is that the arms stop being types. Each binding-backed arm REMOVES an
# Optional field rather than boxing it; the three arrow Optionals are
# replaced by one shared `_binding`.
# =============================================================================

from std.memory import ArcPointer

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import ArrowType, Field, Schema, SchemaBuilder
from komira_core.arrow.schema_identity import schema_identity_hash
from komira_core.collections.slab import Slab
from komira_core.plan.expr import Expr
from komira_core.source.parquet_source import ParquetSource
from komira_core.source.in_memory_source import InMemorySource
from komira_core.source.json_source import JsonSource
from komira_core.source.csv_source import (
    CsvSource,
    CSV_DEFAULT_DELIMITER,
    CSV_DEFAULT_HAS_HEADER,
)
from komira_core.source.arrow_source import ArrowSource
from komira_core.source.orc_source import OrcSource
from komira_core.source.avro_source import AvroSource
from komira_core.source.pushdown_gate import PushdownGate
from komira_core.source.scan_binding import (
    ScanBinding,
    scan_kind_id,
    SCAN_KIND_NAME_ARROW_IPC,
    SCAN_KIND_NAME_AVRO,
    SCAN_KIND_NAME_CSV,
    SCAN_KIND_NAME_IN_MEMORY,
    SCAN_KIND_NAME_JSON,
    SCAN_KIND_NAME_ORC,
    SCAN_ORIENTATION_COLUMNAR,
    SCAN_ORIENTATION_ROW,
    SCAN_STRUCTURAL_ID_UNRESOLVED,
    SNAPSHOT_NONE,
    SNAPSHOT_PINNED,
)
from komira_core.source.scan_identity_audit import ScanIdentityCorpus
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams


comptime SOURCE_VARIANT_PARQUET: UInt8 = 0
comptime SOURCE_VARIANT_IN_MEMORY: UInt8 = 1
# JSON / JSONL file source. Tag ID 2.
#
# BINDING-BACKED. The payload is a `ScanBinding` of kind `komira.json`, which
# declares `SCAN_ORIENTATION_ROW`. JSONL is a row-major on-wire format: both
# production builders take ROW from the kind, `row_streaming_dispatch` routes
# THIS TAG to the JSONL direct row reader, `lower_untyped_row_streaming` reads
# the arm as a ROW source, and the typed conformer
# `JsonlSource[FS].orientation = ROW()` agrees. No plan-execution path reads a
# JSON scan columnar.
#
# ⚠ THE ORIENTATION IS NOT A FREE CHOICE. Declaring COLUMNAR makes
# `_require_orientation_agreement` RAISE on both live callers; dropping their
# argument instead routes a row-major JSONL file at the column executor.
#
# The TAG VALUE is stable, so `row_streaming_dispatch
# ._row_source_variant_for_dispatch` — which picks the JSONL vs CSV direct
# reader by this byte — reads it unchanged.
comptime SOURCE_VARIANT_JSON: UInt8 = 2
# CSV file source. Tag ID 3.
#
# BINDING-BACKED. The payload is a `ScanBinding` of kind `komira.csv`, which
# declares `SCAN_ORIENTATION_ROW`. Orientation is intrinsic to the source
# FORMAT, and CSV is a ROW source: the `LogicalPlan.scan(path, SOURCE_CSV,
# ...)` factory threads `SOURCE_KIND_ROW`; both row-streaming path walkers read
# this arm as a ROW source; and the typed conformer
# `komira_parquet.csv_typed_source.CsvSource[FS].orientation = ROW()` agrees.
#
# `ScanData.__init__` derives CSV's `source_type` and path from the binding,
# so a CSV scan is never labelled SOURCE_PARQUET with an empty path.
comptime SOURCE_VARIANT_CSV: UInt8 = 3
# Arrow IPC (3 tag IDs 4-6).
#
# BINDING-BACKED. These three tags do not name an `Optional[ArrowSource]` arm.
# Their PAYLOAD IS A `ScanBinding` in `_binding`, of kind `komira.arrow.ipc`,
# distinguished by a `codec` param — so the three arms are ONE kind plus one
# param.
#
# The tag VALUES are stable: what each tag says is "this arm is
# binding-backed, and its codec is spelled this way".
comptime SOURCE_VARIANT_ARROW_UNCOMPRESSED: UInt8 = 4
comptime SOURCE_VARIANT_ARROW_LZ4_FRAME: UInt8 = 5
comptime SOURCE_VARIANT_ARROW_ZSTD: UInt8 = 6
# ORC file source. Tag ID 7.
#
# BINDING-BACKED. The payload is a `ScanBinding` in `_binding`, of kind
# `komira.orc` — a genuinely different kind from arrow, slotted in with no
# core edit.
#
# Per-codec dispatch (None/Zlib/Snappy/Lzo/Lz4/Zstd) happens inside the ORC
# decoder at decode time, NOT here — one OrcSource carrier handles every codec
# (mirrors ParquetSource's 4-codec collapse, NOT the 3-arm Arrow IPC tags).
# That is why `_orc_binding`'s params are just `path` + `projection.N`: there is
# no codec for a param to discriminate. Arrow needs a `codec` param precisely
# because it has three TAGS; ORC needs none.
comptime SOURCE_VARIANT_ORC: UInt8 = 7
# Avro row-native READ. Tag ID 8.
#
# BINDING-BACKED. The payload is a `ScanBinding` of kind `komira.avro`, which
# declares `SCAN_ORIENTATION_ROW`. The orientation lives in the KIND, not in the
# callers: the two production call sites pass no `source_kind` and get ROW from
# the binding. (`ScanData.__init__`'s ladder auto-promotes for SOURCE_CSV /
# SOURCE_NDJSON only, so without the declaration an Avro scan built without an
# explicit argument would come out COLUMNAR and be routed at the column
# executor.)
#
# The row-streaming producer dispatch picks the Avro direct row reader by this
# TAG. Per-codec dispatch (null/snappy/...)
# happens INSIDE the OCF reader at decode time, NOT here — one AvroSource
# carrier handles every codec (mirrors OrcSource's collapse), which is why
# `_avro_binding`'s params are just `path`: there is no codec for a param to
# discriminate.
comptime SOURCE_VARIANT_AVRO: UInt8 = 8
# =============================================================================
# THE OPEN ARM. Tag ID 9.
# =============================================================================
#
# A `ScanBinding` for a kind THIS PACKAGE HAS NEVER HEARD OF. This is the seam
# the binding design exists to open: an upper package builds pure data
# (kind_id, name, params, schema, stats, fingerprint, snapshot token, pushdown
# gate) and roots a plan at it, with NO edit here and no concrete source type
# named in core.
#
# The legacy tags above are what the union was. This one is what it becomes:
# when every arm is binding-backed, the tag byte can be deleted and
# `ScanBinding.kind_id` is the only discriminant left.
comptime SOURCE_VARIANT_BINDING: UInt8 = 9


# Codec param values for the three arrow arms. These strings are LOAD-BEARING:
# `kind_name()` renders `arrow[<codec>]`, the stable name of each arm.
comptime ARROW_CODEC_UNCOMPRESSED: String = "uncompressed"
comptime ARROW_CODEC_LZ4_FRAME: String = "lz4_frame"
comptime ARROW_CODEC_ZSTD: String = "zstd"


# =============================================================================
# The legacy `SOURCE_*` value each BINDING-BACKED arm keeps answering.
# =============================================================================
#
# ⚠ THESE ARE `plan/logical_plan.mojo`'s `SOURCE_ARROW` (7), `SOURCE_ORC` (5),
# `SOURCE_AVRO` (6), `SOURCE_CSV` (1), `SOURCE_JSON` (4) AND
# `SOURCE_IN_MEMORY` (3), SPELLED AS NUMBERS. `logical_plan.mojo` imports THIS
# file, so importing the plan layer back would be a cycle — the same constraint
# that makes `scan_binding.mojo` re-declare `SCAN_ORIENTATION_*` rather than
# import `SOURCE_KIND_*`. The equality is pinned by tests, which can import
# both.
#
# They live here rather than on `ScanBinding` because they are LEGACY-ARM facts,
# not properties of the kind concept: a kind from an upper package has no legacy
# enum value and leaves the field at `SCAN_LEGACY_SOURCE_TYPE_NONE`. They go
# away with this file.
comptime LEGACY_SOURCE_TYPE_ARROW: UInt8 = 7
comptime LEGACY_SOURCE_TYPE_ORC: UInt8 = 5
comptime LEGACY_SOURCE_TYPE_AVRO: UInt8 = 6
comptime LEGACY_SOURCE_TYPE_CSV: UInt8 = 1
# `SOURCE_JSON` (4), NOT `SOURCE_NDJSON` (2). Both name the same on-wire format;
# they differ in DECODE PATH, and `ScanData.__init__`'s JSON arm derives
# SOURCE_JSON. Declaring the same value keeps every `source_type` reader
# answering the same value while the orientation comes from the binding.
comptime LEGACY_SOURCE_TYPE_JSON: UInt8 = 4
# `SOURCE_IN_MEMORY` (3). Declared beside the in-memory identity, so the value
# an in-memory binding must keep answering is written down in the same place
# its identity is.
comptime LEGACY_SOURCE_TYPE_IN_MEMORY: UInt8 = 3


def _orc_binding(var orc: OrcSource) -> ScanBinding:
    """Build the `komira.orc` binding for an `OrcSource`.

    ⚠ THE FINGERPRINT IS TAKEN FROM THE CONCRETE SOURCE, NOT RECOMPUTED — the
    same contract `_arrow_binding` documents above: recomputing it would move
    every plan-cache key.

    THE PARAMS ARE EXACTLY WHAT THE KIND HAS, AND NOTHING MORE:

      * `path`         — the file on disk.
      * `projection.N` — one I64 per OUTPUT column index, in CALLER ORDER.
        `read_orc_bytes_projected` has an order-sensitive output-column
        that order without inventing a codec. An empty projection means "all
        columns" and emits no key at all.
        key at all.

    WHAT IS DELIBERATELY *NOT* A PARAM:
      * The CODEC. Per-codec dispatch (None/Zlib/Snappy/Lzo/Lz4/Zstd) happens
        INSIDE the ORC decoder at decode time, never in the variant. One
        carrier handles every codec, so there is nothing for a codec param to
        discriminate. That is the OPPOSITE of arrow, where three TAGS exist per
        codec and collapse into one param.
      * `estimated_rows`. `OrcSource.estimate_rows()` returns -1
        unconditionally, and `ScanBinding.estimate_rows()` already answers -1
        when the param is absent. Adding it would be inventing a param the kind
        does not have.
      * The MTIME — it is the `snapshot_token`, see below.

    SNAPSHOT_PINNED, NOT NONE. `_mtime_ns` is folded into `OrcSource`'s identity
    (stale-cache invalidation), and "the token IS identity — a file mtime" is
    the exact definition of `SNAPSHOT_PINNED` (scan_binding.mojo). Declaring it
    means core's DERIVED `identity_hash()` covers the mtime too, not just the
    kind-supplied `fingerprint` — a kind-supplied identity can omit an input
    (a broker binding folding only (topic, partition) would miss
    `start_offset`), and the derived fold is what covers it. Every identity
    input `OrcSource` has is reachable from BOTH folds.
    """
    var fp = orc.fingerprint()
    var params = ScanParams()
    params.put_str(String("path"), String(orc.path))
    for i in range(len(orc.projection)):
        params.put_i64(
            String("projection.") + String(i), Int64(orc.projection[i])
        )
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_ORC)),
        kind_name=String(SCAN_KIND_NAME_ORC),
        name=String(orc.path),
        params=params^,
        schema=orc.schema(),
        # `structural_id == fingerprint` for every file source — only IN_MEMORY
        # differs (see `structural_id()` below).
        fingerprint=fp,
        structural_id=fp,
        # `OrcSource.supports_filter_pushdown` returned False for EVERY
        # predicate: ORC's stride-stats / bloom pruning happens inside the
        # decoder and is not surfaced through SourceLike. GATE_REJECT_ALL is
        # that behaviour, declared instead of implemented.
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_PINNED,
        # `_mtime_ns` read directly: same-package underscore-field access.
        # No public accessor is added to a struct slated for deletion.
        snapshot_token=orc._mtime_ns,
        orientation=SCAN_ORIENTATION_COLUMNAR,
        legacy_source_type=LEGACY_SOURCE_TYPE_ORC,
    )


def orc_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.orc` scan.

    Every kind needs a descriptor: an unregistered kind is one
    `ScanKindRegistry.validate` cannot run on and the identity audit (which
    iterates the registry) cannot see — and an unchecked kind is how an mtime
    hole ships.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_ORC),
        # ORC's stride-stats / bloom pruning happens inside the decoder and is
        # not surfaced through `SourceLike`; see `_orc_binding`.
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        # PINNED: the file mtime IS this kind's identity. `ScanKindRegistry
        # .validate` compares this against the binding's policy, so a descriptor
        # and a builder that disagree is a named error.
        snapshot_policy=SNAPSHOT_PINNED,
    )


def orc_scan_identity_corpus() -> ScanIdentityCorpus:
    """The ORC kind's statement of what makes two of its scans different.

    ONE ENTRY PER INPUT `OrcSource.fingerprint()` FOLDS. It
    folds exactly three things — the `path`, `_mtime_ns`, and the `projection`
    vector — and the projection fold is ORDER-SENSITIVE, so it takes TWO entries
    to cover: a different ORDER and a different LENGTH. A corpus that varied
    only the length would pass while `[0,2]` vs `[2,0]` collided, which is the
    pair `read_orc_bytes_projected`'s output-column contract actually
    distinguishes.

    ⚠ DO NOT DELETE AN ENTRY TO MAKE A FUTURE CHANGE PASS. The audit runs ALL
    PAIRS over whatever is here, so removing an entry is removing the check, and
    the entry IS the contract.
    """
    var c = ScanIdentityCorpus(orc_scan_descriptor())
    c.add(String("baseline"), _orc_binding(_orc_corpus_source(String("/t/a.orc"), UInt64(0))))
    c.add(String("path"), _orc_binding(_orc_corpus_source(String("/t/b.orc"), UInt64(0))))
    c.add(
        String("mtime"),
        _orc_binding(_orc_corpus_source(String("/t/a.orc"), UInt64(1700000000))),
    )
    c.add(
        String("projection"),
        _orc_binding(_orc_corpus_source(String("/t/a.orc"), UInt64(0), 0, 2)),
    )
    c.add(
        String("projection_order"),
        _orc_binding(_orc_corpus_source(String("/t/a.orc"), UInt64(0), 2, 0)),
    )
    return c^


def _orc_corpus_source(
    var path: String, mtime_ns: UInt64, *proj: Int
) -> OrcSource:
    """Corpus fixture only. The SCHEMA is deliberately empty: `schema` is not an
    input `OrcSource.fingerprint()` folds, and a corpus that varied something
    the fingerprint cannot see would be testing core against itself."""
    var projection = List[Int]()
    for i in range(len(proj)):
        projection.append(proj[i])
    return OrcSource(path^, Schema(), projection^, mtime_ns=mtime_ns)


def _avro_binding(var avro: AvroSource) -> ScanBinding:
    """Build the `komira.avro` binding for an `AvroSource`.

    ⚠ THE FINGERPRINT IS TAKEN FROM THE CONCRETE SOURCE, NOT RECOMPUTED — the
    same contract `_orc_binding` and `_arrow_binding` document.

    ⚠ `orientation = SCAN_ORIENTATION_ROW`. Avro OCF is row-oriented on disk
    and its reader decodes each record's fields DIRECTLY into a `RowBlock`, so
    the scan belongs to the row execution hierarchy. The ladder in
    `ScanData.__init__` auto-promotes for CSV / NDJSON only, so without this
    declaration an Avro scan built without an explicit `source_kind` would come
    out COLUMNAR. The declaration decides: the two production call sites
    (`engine_context.read_avro_row_streaming`, `AvroReader.build_scan_plan`)
    pass NOTHING and get ROW from the kind.

    THE PARAMS ARE EXACTLY WHAT THE KIND HAS, AND NOTHING MORE — just `path`.
    `AvroSource` carries a path, a caller-supplied schema and an mtime, and it
    is the closest sibling of `JsonSource`: no projection vector, no codec, no
    row estimate. Specifically NOT params:

      * The CODEC. Per-codec dispatch (null / deflate / snappy / zstd) happens
        INSIDE the OCF reader at decode time — one `AvroSource` carrier handles
        every codec, so there is nothing for a codec param to discriminate.
        Arrow needed a `codec` param only because it had three TAGS.
      * `estimated_rows`. `AvroSource.estimate_rows()` returns -1
        unconditionally (a real count needs a full block scan), and
        `ScanBinding.estimate_rows()` already answers -1 for an absent param.
      * The SCHEMA — it is the `schema` FIELD, and it is deliberately not folded
        into `AvroSource.fingerprint()` either (the OCF header's schema is a
        function of the file the path already names).
      * The MTIME — it is the `snapshot_token`, see below.

    SNAPSHOT_PINNED, NOT NONE. `_mtime_ns` is folded into `AvroSource`'s identity
    (stale-cache invalidation) and "the token IS identity — a file mtime" is
    the definition of `SNAPSHOT_PINNED`. Declaring it is what makes core's
    DERIVED `identity_hash()` cover the mtime; leaving it at `SNAPSHOT_NONE`
    would let two scans of one path at different mtimes collide in the
    plan-compile cache.
    """
    var fp = avro.fingerprint()
    var params = ScanParams()
    params.put_str(String("path"), String(avro.path))
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_AVRO)),
        kind_name=String(SCAN_KIND_NAME_AVRO),
        name=String(avro.path),
        params=params^,
        schema=avro.schema(),
        # `structural_id == fingerprint` for every file source — only IN_MEMORY
        # differs (see `structural_id()` below).
        fingerprint=fp,
        structural_id=fp,
        # `AvroSource.supports_filter_pushdown` returned False for EVERY
        # predicate (Avro has no equivalent of a
        # parquet row-group zonemap). GATE_REJECT_ALL is that behaviour,
        # declared instead of implemented.
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_PINNED,
        # `_mtime_ns` read directly: same-package underscore-field access.
        # No public accessor is added to a struct slated for deletion.
        snapshot_token=avro._mtime_ns,
        orientation=SCAN_ORIENTATION_ROW,
        legacy_source_type=LEGACY_SOURCE_TYPE_AVRO,
    )


def avro_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.avro` scan.

    Every kind needs a descriptor — an unregistered kind is a kind
    `ScanKindRegistry.validate` cannot check and the identity audit cannot see.

    ⚠ THE `orientation` HERE IS NOT DECORATION. `ScanKindRegistry.validate`
    RAISES when a binding's orientation differs from its descriptor's, so this
    ROW and `_avro_binding`'s ROW are checked against each other.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_AVRO),
        # Avro has no decode-time pruning surfaced through `SourceLike`; a
        # predicate stays as a `Filter` above the scan, applied row-native.
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_ROW,
        # PINNED: the file mtime IS this kind's identity.
        snapshot_policy=SNAPSHOT_PINNED,
    )


def avro_scan_identity_corpus() -> ScanIdentityCorpus:
    """The AVRO kind's statement of what makes two of its scans different.

    ONE ENTRY PER INPUT `AvroSource.fingerprint()` FOLDS. It
    folds exactly two things — the `path` (its LENGTH and its BYTES, which one
    entry covers, since no two paths of different length share their bytes) and
    `_mtime_ns`. There is no projection and no codec to vary: unlike ORC, this
    kind has no third input, and inventing a corpus entry for something the
    fingerprint cannot see would be testing core against itself.

    ⚠ DO NOT DELETE AN ENTRY TO MAKE A FUTURE CHANGE PASS. The audit runs ALL
    PAIRS over whatever is here, so removing an entry is removing the check, and
    the entry IS the contract.
    """
    var c = ScanIdentityCorpus(avro_scan_descriptor())
    c.add(String("baseline"), _avro_binding(_avro_corpus_source(String("/t/a.avro"), UInt64(0))))
    c.add(String("path"), _avro_binding(_avro_corpus_source(String("/t/b.avro"), UInt64(0))))
    c.add(
        String("mtime"),
        _avro_binding(_avro_corpus_source(String("/t/a.avro"), UInt64(1700000000))),
    )
    return c^


def _avro_corpus_source(var path: String, mtime_ns: UInt64) -> AvroSource:
    """Corpus fixture only. The SCHEMA is deliberately empty: `schema` is not an
    input `AvroSource.fingerprint()` folds, and a corpus that varied something
    the fingerprint cannot see would be testing core against itself."""
    return AvroSource(path^, Schema(), mtime_ns=mtime_ns)


def _csv_binding(var csv: CsvSource) -> ScanBinding:
    """Build the `komira.csv` binding for a `CsvSource`.

    ⚠ THE FINGERPRINT IS TAKEN FROM THE CONCRETE SOURCE, NOT RECOMPUTED — the
    same contract `_avro_binding` / `_orc_binding` / `_arrow_binding`
    document.

    ⚠ `orientation = SCAN_ORIENTATION_ROW`. Orientation is intrinsic to the
    source format and CSV is a ROW source: the `LogicalPlan.scan(path,
    SOURCE_CSV, ...)` factory threads ROW, both row-streaming path walkers
    read this arm as ROW, and the typed conformer
    `csv_typed_source.CsvSource[FS].orientation = ROW()` agrees. The
    declaration decides.

    THE PARAMS ARE EXACTLY WHAT THE KIND HAS, AND NOTHING MORE:

      * `path`            — the file on disk.
      * `quote_style_tag` — 0/1/2 == Rfc4180/Excel/Posix. ⚠ THIS PARAM IS
        LOAD-BEARING. It selects WHICH COMPTIME-MONOMORPHIZED SCANNER decodes
        the bytes (the CSV parallel reader cascades on it), so two scans of one
        path under different dialects parse it into DIFFERENT VALUES.
        `CsvSource` folds it into its fingerprint for exactly that reason, and
        the plan TEXT must carry it or the two share a plan-compile cache key.
        Same shape as arrow's `codec`.
      * `delimiter`      — the field-separator byte, as an i64.
      * `has_header`     — 1/0. The same hole one field over: schema inference
        reads both, so `read_csv('f', delim='|')` and `read_csv('f')` produce
        two DIFFERENT schemas and must not share a plan-compile cache key.
        `has_header` is the sharper: it decides whether row 0 is DATA, so a
        cache hit across it would return a different ROW COUNT, not merely
        different types. Both are also folded into `CsvSource.fingerprint()`,
        which is what makes them visible to the identity AUDIT and not only to
        the plan text — the audit's R2 compares `fingerprint`, so a param the
        fold cannot see is a corpus entry that cannot be added.

    WHAT IS DELIBERATELY *NOT* A PARAM:
      * `estimated_rows`. `CsvSource.estimate_rows()` returns -1 unconditionally
        (a real count needs a full file scan), and `ScanBinding.estimate_rows()`
        already answers -1 for an absent param.
      * The SCHEMA — it is the `schema` FIELD, and it is deliberately not folded
        into `CsvSource.fingerprint()` either: a freshly-constructed `CsvSource`
        carries an EMPTY schema that the chassis fills during scan, so folding it
        would make identity depend on WHEN you asked.
      * The MTIME — it is the `snapshot_token`, see below.

    SNAPSHOT_PINNED, NOT NONE. `_mtime_ns` is folded into `CsvSource`'s identity
    (stale-cache invalidation) and "the token IS identity — a file mtime" is
    the definition of `SNAPSHOT_PINNED`. Same fix as ORC's and AVRO's.
    """
    var fp = csv.fingerprint()
    var params = ScanParams()
    params.put_str(String("path"), String(csv.path))
    params.put_i64(String("quote_style_tag"), Int64(csv.quote_style_tag))
    params.put_i64(String("delimiter"), Int64(csv.delimiter))
    params.put_i64(
        String("has_header"), Int64(1) if csv.has_header else Int64(0)
    )
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_CSV)),
        kind_name=String(SCAN_KIND_NAME_CSV),
        name=String(csv.path),
        params=params^,
        schema=csv.schema(),
        # `structural_id == fingerprint` for every file source — only IN_MEMORY
        # differs (see `structural_id()` below).
        fingerprint=fp,
        structural_id=fp,
        # `CsvSource.supports_filter_pushdown` returned False for EVERY
        # predicate (CSV has no equivalent of parquet's
        # row-group zonemap pruning). GATE_REJECT_ALL is that behaviour,
        # declared instead of implemented.
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_PINNED,
        # `_mtime_ns` read directly: same-package underscore-field access.
        # No public accessor is added to a struct slated for deletion.
        snapshot_token=csv._mtime_ns,
        orientation=SCAN_ORIENTATION_ROW,
        legacy_source_type=LEGACY_SOURCE_TYPE_CSV,
    )


def csv_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.csv` scan.

    Every kind needs a descriptor — an unregistered kind is a kind
    `ScanKindRegistry.validate` cannot check and the identity audit cannot see.

    ⚠ THE `orientation` HERE IS NOT DECORATION. `ScanKindRegistry.validate`
    RAISES when a binding's orientation differs from its descriptor's, so this
    ROW and `_csv_binding`'s ROW are checked against each other. Registering
    kinds of both orientations keeps that comparison multi-valued rather than
    a check that cannot fail.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_CSV),
        # CSV has no decode-time pruning surfaced through `SourceLike`; a
        # predicate stays as a `Filter` above the scan.
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_ROW,
        # PINNED: the file mtime IS this kind's identity.
        snapshot_policy=SNAPSHOT_PINNED,
    )


def csv_scan_identity_corpus() -> ScanIdentityCorpus:
    """The CSV kind's statement of what makes two of its scans different.

    ONE ENTRY PER INPUT `CsvSource.fingerprint()` FOLDS. `csv_source.mojo`'s
    ctor folds exactly five things — the `path` (its LENGTH and its BYTES,
    which one entry covers, since no two paths of different length share their
    bytes), `_mtime_ns`, `quote_style_tag`, `delimiter` and `has_header`. The
    schema is NOT folded, so there is no schema entry: a corpus that varied
    something the fingerprint cannot see would be testing core against itself.

    ⚠ A PARAM AND ITS FOLD TERM TRAVEL TOGETHER. The audit's R2 compares
    `fingerprint`, so a `delimiter` entry over an unchanged fold would collide
    with `baseline` and the audit would go RED naming the pair.

    ⚠ THE `quote_style` ENTRY COVERS THE SHARPEST CASE — two scans with
    GENUINELY DIFFERENT DECODERS that must not share a plan-compile cache key.
    Deleting it would delete the check.

    ⚠ DO NOT DELETE AN ENTRY TO MAKE A FUTURE CHANGE PASS. The audit runs ALL
    PAIRS over whatever is here, so removing an entry is removing the check, and
    the entry IS the contract.
    """
    var c = ScanIdentityCorpus(csv_scan_descriptor())
    c.add(String("baseline"), _csv_binding(_csv_corpus_source(String("/t/a.csv"), UInt64(0), 0)))
    c.add(String("path"), _csv_binding(_csv_corpus_source(String("/t/b.csv"), UInt64(0), 0)))
    c.add(
        String("mtime"),
        _csv_binding(_csv_corpus_source(String("/t/a.csv"), UInt64(1700000000), 0)),
    )
    c.add(
        String("quote_style"),
        _csv_binding(_csv_corpus_source(String("/t/a.csv"), UInt64(0), 2)),
    )
    c.add(
        String("delimiter"),
        _csv_binding(
            _csv_corpus_source(
                String("/t/a.csv"), UInt64(0), 0, delimiter=UInt8(ord("|"))
            )
        ),
    )
    c.add(
        String("has_header"),
        _csv_binding(
            _csv_corpus_source(
                String("/t/a.csv"), UInt64(0), 0, has_header=False
            )
        ),
    )
    return c^


def _csv_corpus_source(
    var path: String,
    mtime_ns: UInt64,
    quote_style_tag: Int,
    delimiter: UInt8 = CSV_DEFAULT_DELIMITER,
    has_header: Bool = CSV_DEFAULT_HAS_HEADER,
) -> CsvSource:
    """Corpus fixture only. The SCHEMA is deliberately empty: `schema` is not an
    input `CsvSource.fingerprint()` folds, and a corpus that varied something the
    fingerprint cannot see would be testing core against itself."""
    return CsvSource(
        path^,
        Schema(),
        mtime_ns=mtime_ns,
        quote_style_tag=quote_style_tag,
        delimiter=delimiter,
        has_header=has_header,
    )


def _json_binding(var json: JsonSource) -> ScanBinding:
    """Build the `komira.json` binding for a `JsonSource`.

    ⚠ THE FINGERPRINT IS TAKEN FROM THE CONCRETE SOURCE, NOT RECOMPUTED — the
    same contract `_csv_binding` / `_avro_binding` / `_orc_binding` /
    `_arrow_binding` document.

    ⚠ `orientation = SCAN_ORIENTATION_ROW`. JSONL is a row-major on-wire
    format. The columnar materializer
    (`komira_json.columnar_materializer.materialize_jsonl_to_batch`) is a
    direct byte-level API: `lower_untyped.mojo`, `pipeline_compiler.mojo` and
    the optimizer passes hold no `SOURCE_JSON` / `SOURCE_VARIANT_JSON`
    references, and the one `EngineContext` caller of the materializer,
    `_decode_jsonl_path_to_batch`, re-roots at an `InMemorySource` because a
    JSON scan is not executed columnar.

    ⚠ THE CHOICE IS FORCED, NOT PREFERRED. Three sites build
    `SourceVariant(JsonSource(...))`: `read_jsonl_row_streaming` and
    `JsonlReader.build_scan_plan` (which take ROW from the kind), and the
    legacy `LogicalPlan.scan(path, SOURCE_NDJSON, ...)` factory. Declaring
    COLUMNAR makes `_require_orientation_agreement` RAISE on both live callers,
    and dropping their argument instead routes a row-major JSONL file at the
    column executor.

    THE PARAMS ARE EXACTLY WHAT THE KIND HAS, AND NOTHING MORE — just `path`.
    `JsonSource` is `AvroSource`'s closest sibling (identical fold, identical
    field set) and takes the identical param set. Specifically NOT params:

      * `estimated_rows`. `JsonSource.estimate_rows()` returns -1
        unconditionally (a real count needs a full structural-index scan), and
        `ScanBinding.estimate_rows()` already answers -1 for an absent param.
      * The SCHEMA — it is the `schema` FIELD. JSON has no embedded footer
        schema so the caller supplies it, and it is deliberately NOT folded into
        `JsonSource.fingerprint()`: folding it would make identity depend on
        which schema a caller happened to ask for over the same bytes.
      * The MTIME — it is the `snapshot_token`, see below.

    SNAPSHOT_PINNED, NOT NONE. `_mtime_ns` is folded into `JsonSource`'s identity
    (stale-cache invalidation) and "the token IS identity — a file mtime" is
    the definition of `SNAPSHOT_PINNED`. Same fix as ORC / AVRO / CSV: two
    mtimes of one JSON file do not share a plan-compile cache key.
    """
    var fp = json.fingerprint()
    var params = ScanParams()
    params.put_str(String("path"), String(json.path))
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_JSON)),
        kind_name=String(SCAN_KIND_NAME_JSON),
        name=String(json.path),
        params=params^,
        schema=json.schema(),
        # `structural_id == fingerprint` for every file source — only IN_MEMORY
        # differs (see `structural_id()` below).
        fingerprint=fp,
        structural_id=fp,
        # `JsonSource.supports_filter_pushdown` returned False for EVERY
        # predicate (JSON has no equivalent of
        # Parquet's row-group zonemap pruning; a predicate stays a `Filter`
        # above the scan). GATE_REJECT_ALL is that behaviour, declared instead
        # of implemented.
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_PINNED,
        # `_mtime_ns` read directly: same-package underscore-field access.
        # No public accessor is added to a struct slated for deletion.
        snapshot_token=json._mtime_ns,
        orientation=SCAN_ORIENTATION_ROW,
        legacy_source_type=LEGACY_SOURCE_TYPE_JSON,
    )


def json_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.json` scan.

    Every kind needs a descriptor — an unregistered kind is a kind
    `ScanKindRegistry.validate` cannot check and the identity audit cannot see.

    ⚠ THE `orientation` HERE IS NOT DECORATION. `ScanKindRegistry.validate`
    RAISES when a binding's orientation differs from its descriptor's, so this
    ROW and `_json_binding`'s ROW are checked against each other.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_JSON),
        # JSON has no decode-time pruning surfaced through `SourceLike`; a
        # predicate stays as a `Filter` above the scan.
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_ROW,
        # PINNED: the file mtime IS this kind's identity.
        snapshot_policy=SNAPSHOT_PINNED,
    )


def json_scan_identity_corpus() -> ScanIdentityCorpus:
    """The JSON kind's statement of what makes two of its scans different.

    ONE ENTRY PER INPUT `JsonSource.fingerprint()` FOLDS. `json_source.mojo`
    folds exactly two things — the `path` (its LENGTH and its BYTES,
    which one entry covers, since no two paths of different length share their
    bytes) and `_mtime_ns`. The SCHEMA is not folded, so there is no schema
    entry: a corpus that varied something the fingerprint cannot see would be
    testing core against itself.

    ⚠ THE `mtime` ENTRY is the one a plan-text-only fold would miss: two mtimes
    of one path with EQUAL `structural_hash`. Deleting the entry would delete
    the check.

    ⚠ DO NOT DELETE AN ENTRY TO MAKE A FUTURE CHANGE PASS. The audit runs ALL
    PAIRS over whatever is here, so removing an entry is removing the check, and
    the entry IS the contract.
    """
    var c = ScanIdentityCorpus(json_scan_descriptor())
    c.add(String("baseline"), _json_binding(_json_corpus_source(String("/t/a.json"), UInt64(0))))
    c.add(String("path"), _json_binding(_json_corpus_source(String("/t/b.json"), UInt64(0))))
    c.add(
        String("mtime"),
        _json_binding(_json_corpus_source(String("/t/a.json"), UInt64(1700000000))),
    )
    return c^


def _json_corpus_source(var path: String, mtime_ns: UInt64) -> JsonSource:
    """Corpus fixture only. The SCHEMA is deliberately empty: `schema` is not an
    input `JsonSource.fingerprint()` folds, and a corpus that varied something
    the fingerprint cannot see would be testing core against itself."""
    return JsonSource(path^, Schema(), mtime_ns=mtime_ns)


def _arrow_binding(var arrow: ArrowSource, var codec: String) -> ScanBinding:
    """Build the `komira.arrow.ipc` binding for an `ArrowSource`.

    ⚠ THE FINGERPRINT IS TAKEN FROM THE CONCRETE SOURCE, NOT RECOMPUTED. A
    binding-backed arm's fingerprint must stay EQUAL TO THE CONCRETE SOURCE'S
    VALUE, not merely stay distinct — otherwise every plan-cache key changes
    and every cached plan silently recompiles. That is a perf cliff with
    nothing going red.

    ⚠ SNAPSHOT_PINNED, NOT NONE. `ArrowSource.fingerprint()` folds `_mtime_ns`
    (`arrow_source.mojo`). Declared `SNAPSHOT_NONE`, the mtime would reach the
    kind's OWN identity and nothing else: not `params`, not the snapshot token,
    therefore not core's derived `identity_hash()`, and therefore not the plan
    TEXT that `structural_hash()` folds — two arrow scans of ONE path at
    DIFFERENT mtimes would collide in the plan-compile cache, a silent wrong
    answer.

    "The token IS identity — a file mtime" is `SNAPSHOT_PINNED`'s definition
    verbatim, and it is the same conclusion as for ORC. The rejected
    alternative — dropping `_mtime_ns` from `ArrowSource.fingerprint()` — fails
    twice over: it would CHANGE the arrow fingerprint VALUE, and it would
    delete the stale-cache-invalidation contract, so a file rewritten at the
    same path would silently reuse the old plan. Pinning is the fix; unpinning
    is the same bug in another spelling.

    THE GATE THAT HOLDS THIS: `scan_identity_audit.mojo` asserts, for every
    REGISTERED kind, that `fingerprint(a) != fingerprint(b)` implies
    `identity_hash(a) != identity_hash(b)`.
    """
    var fp = arrow.fingerprint()
    var params = ScanParams()
    params.put_str(String("path"), String(arrow.path))
    params.put_str(String("codec"), codec^)
    params.put_i64(String("estimated_rows"), Int64(arrow.estimate_rows()))
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_ARROW_IPC)),
        kind_name=String(SCAN_KIND_NAME_ARROW_IPC),
        name=String(arrow.path),
        params=params^,
        schema=arrow.schema(),
        # `structural_id == fingerprint` for every file source — only IN_MEMORY
        # differs (see `structural_id()` below).
        fingerprint=fp,
        structural_id=fp,
        # Arrow IPC has no decode-time pruning, so `ArrowSource
        # .supports_filter_pushdown` returned False for EVERY predicate.
        # GATE_REJECT_ALL is that behaviour, declared instead of implemented.
        gate=PushdownGate.reject_all(),
        snapshot_policy=SNAPSHOT_PINNED,
        # `_mtime_ns` read directly: same-package underscore-field access.
        # No public accessor is added to a struct slated for deletion.
        snapshot_token=arrow._mtime_ns,
        orientation=SCAN_ORIENTATION_COLUMNAR,
        # The legacy type is DECLARED instead of tested for by tag in
        # `ScanData.__init__`: one assignment there, and the next
        # binding-backed arm costs zero core lines.
        legacy_source_type=LEGACY_SOURCE_TYPE_ARROW,
    )


def arrow_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.arrow.ipc` scan.

    Every kind needs a descriptor: without one, `ScanKindRegistry.validate` —
    the check that a binding agrees with what its kind DECLARES — cannot run
    on its bindings, and the identity audit (which iterates the registry)
    cannot see it. An unregistered kind is an unchecked kind.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_ARROW_IPC),
        # Arrow IPC has no decode-time pruning; see `_arrow_binding`.
        gate=PushdownGate.reject_all(),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        # PINNED: the file mtime IS this kind's identity. `ScanKindRegistry
        # .validate` compares this against the binding's policy, so a descriptor
        # and a builder that disagree is a named error.
        snapshot_policy=SNAPSHOT_PINNED,
    )


def arrow_scan_identity_corpus() -> ScanIdentityCorpus:
    """The arrow kind's statement of what makes two of its scans different.

    ONE ENTRY PER INPUT `ArrowSource.fingerprint()` FOLDS, plus the params that
    core carries. `arrow_source.mojo` folds exactly two things — the `path`
    and `_mtime_ns` — and `_arrow_binding` adds `codec` and `estimated_rows`.

    ⚠ THE `mtime` ENTRY IS THE POINT OF THIS CORPUS: `ArrowSource.fingerprint()`
    folds `_mtime_ns`, and a binding declaring `SNAPSHOT_NONE` would hide it
    from core's derived `identity_hash()`. Do not remove the entry to make a
    future change pass — the entry IS the contract.
    """
    var c = ScanIdentityCorpus(arrow_scan_descriptor())
    c.add(
        String("baseline"),
        _arrow_binding(
            ArrowSource(String("/t/a.arrow"), Schema(), mtime_ns=UInt64(0)),
            String(ARROW_CODEC_UNCOMPRESSED),
        ),
    )
    c.add(
        String("path"),
        _arrow_binding(
            ArrowSource(String("/t/b.arrow"), Schema(), mtime_ns=UInt64(0)),
            String(ARROW_CODEC_UNCOMPRESSED),
        ),
    )
    c.add(
        String("mtime"),
        _arrow_binding(
            ArrowSource(String("/t/a.arrow"), Schema(), mtime_ns=UInt64(1700000000)),
            String(ARROW_CODEC_UNCOMPRESSED),
        ),
    )
    c.add(
        String("codec"),
        _arrow_binding(
            ArrowSource(String("/t/a.arrow"), Schema(), mtime_ns=UInt64(0)),
            String(ARROW_CODEC_ZSTD),
        ),
    )
    c.add(
        String("estimated_rows"),
        _arrow_binding(
            ArrowSource(
                String("/t/a.arrow"), Schema(), mtime_ns=UInt64(0), estimated_rows=99
            ),
            String(ARROW_CODEC_UNCOMPRESSED),
        ),
    )
    return c^


# =============================================================================
# IN_MEMORY — the content identity.
# =============================================================================
#
# The payload still rides the concrete arm; nothing below routes a payload.
# What lives here is an identity for this kind that is a FUNCTION OF THE DATA
# rather than of when the source was constructed.
#
# WHY THAT MATTERS. `InMemorySource._identity` is
# `_mix64(komira_next_inmem_source_id())` — a process-global monotonic counter
# implemented C-side. Serialize a plan carrying it, read it back in a second
# process, and the id either collides with an unrelated table or fails to
# match the same one. `scan_binding.mojo:scan_kind_id` states the requirement
# ("stable ACROSS PROCESSES, so it survives serialization"); audit rule R9 is
# that sentence made mechanical.


def inmem_scan_binding(
    ims: InMemorySource, fold_content_identity: Bool = True
) raises -> ScanBinding:
    """Build the `komira.in_memory` binding for an `InMemorySource`.

    ⚠ THIS BINDING BUILDER'S `fingerprint` AND `structural_id` ARE DIFFERENT
    NUMBERS. Every file kind passes one value to both, because for a FILE
    source the whole identity (path + mtime) is something CORE CAN SEE.

        structural_id = ims.structural_id()              CONTENT
        fingerprint   = schema_identity_hash(schema)     WHAT CORE CAN SEE

    `structural_id` — the content hash. `InMemorySource.structural_id()` folds
    the structural schema text (field names + types + nullability) and every
    batch's `RecordBatch.content_hash` (raw buffer bytes + per-column
    structural metadata), and folds NEITHER the per-ctor `_identity` NOR the
    debug `name`. It is the value `plan_display` emits as `inmem_id=` for the
    concrete arm, so it is not a new number entering the plan-compile cache
    key — it is the SAME number carried as `bsid=`, which is why
    `INMEM_ID_PLACEHOLDER` is deliberately one token for both carriers.

    `fingerprint` — ⚠ NOT the content hash, and NOT the counter either. Audit
    rule R2 demands `fingerprint(a) != fingerprint(b) => identity_hash(a) !=
    identity_hash(b)`, and `identity_hash()` folds kind_id, kind_name, name,
    params, schema, gate, orientation (+ the token iff PINNED) — not one of
    which can see a byte. So a content-derived `fingerprint` makes R2 fire on
    every bytes-only pair.

    AND THE OBVIOUS FIX IS THE ONE THAT MUST NOT BE TAKEN. R2's own FIX line
    says "carry the differing input in `params`, or declare it as the
    `snapshot_token` under SNAPSHOT_PINNED" — both of which make
    `identity_hash()` content-sensitive. `identity_hash()` reaches `bid=`, and
    `plan_display` deliberately does NOT placeholder `bid=` (the arrow `codec`
    / `estimated_rows` pairs are separated by `bid=` alone). So the CHEAP key
    would stop being content-blind the moment this tag becomes
    binding-backed. The content identity reaches the plan-compile cache key
    through `bsid=` — the carrier audit rule R5 (SUPPLIED REACH +
    ATTRIBUTION) exists for.

    So the pair of fields is the kind's FULL statement, and each half has its
    own auditor: R2 over `fingerprint`, R5 over `structural_id`.

    ⚠ `InMemorySource.fingerprint()` IS NOT TOUCHED, and must not be: its
    PER-CTOR UNIQUENESS is the allocator-reuse contract, and a content hash
    would make two sources over identical bytes fingerprint EQUAL. The counter
    stays the ALLOCATOR-REUSE identity and is not asked to be a plan identity,
    which its own docstring already says it is not.

    NO PARAMS. Deliberate: with an empty map, `identity_hash()` is a pure
    function of (kind, name, schema, gate, orientation), i.e. exactly "what
    core can see". `estimated_rows` — the param arrow carries — is NOT added
    here: a row count is a property of the CONTENT, so folding it would make
    `bid=` (and therefore the cheap key) partially content-sensitive. A kind
    that wants a row hint at execution time reads it off the resolved
    payload, which is O(1) and exact.

    `name` mirrors what `ScanData.__init__` derives for the concrete arm — the
    optional debug label, or the synthetic `__in_memory__` — so the rendered
    `path=` does not move when the arm becomes binding-backed.

    ⚠ `fold_content_identity=False` MAKES THIS A RESOLUTION TOKEN, NOT AN
    IDENTITY. `ims.structural_id()` is a CONTENT hash — O(total batch bytes),
    memoized per source INSTANCE — so calling it on a freshly-built source
    folds the whole payload. `optimizer_scan_dedup._bind_dedup_batch` binds a
    dedup'd FACT TABLE, on the driver, once per group, on every query with a
    duplicated or session-cache-hit scan; folding there is a real share of
    driver cycles — invisibly, because the rows are identical either way.

    The opt-out is a PARAMETER rather than a second builder so the other nine
    fields cannot drift between the two forms; a copied builder is how
    identity defects start. Read `SCAN_STRUCTURAL_ID_UNRESOLVED`'s docstring
    before using it: a binding carrying it may never reach a plan render, a
    `structural_hash()` or a cache key.
    """
    var params = ScanParams()
    return ScanBinding(
        kind_id=scan_kind_id(String(SCAN_KIND_NAME_IN_MEMORY)),
        kind_name=String(SCAN_KIND_NAME_IN_MEMORY),
        name=(
            String(ims.name.value()) if ims.name else String("__in_memory__")
        ),
        params=params^,
        schema=ims.schema(),
        fingerprint=schema_identity_hash(ims.schema()),
        structural_id=(
            ims.structural_id()
            if fold_content_identity
            else SCAN_STRUCTURAL_ID_UNRESOLVED
        ),
        # THE ONLY `GATE_ACCEPT_ALL` KIND (seven arms REJECT_ALL, parquet
        # SHAPED, in_memory ACCEPT_ALL). `True` means: "folding a predicate
        # into `Scan.filter` is OUTCOME-PRESERVING — the pushed and un-pushed
        # plans agree, on rows OR on refusal". See
        # `InMemorySource.supports_filter_pushdown`.
        gate=PushdownGate.accept_all(),
        # SNAPSHOT_NONE is this kind's definition verbatim — "content is
        # immutable for the process lifetime". `InMemorySource.data` is written
        # once in `__init__` and never mutated (the premise `_StructuralIdMemo`
        # already rests on). There is no mtime to pin and no generation to
        # re-resolve, so neither PINNED nor LIVE has anything to carry.
        snapshot_policy=SNAPSHOT_NONE,
        orientation=SCAN_ORIENTATION_COLUMNAR,
        legacy_source_type=LEGACY_SOURCE_TYPE_IN_MEMORY,
    )


def inmem_scan_descriptor() -> ScanKindDescriptor:
    """What the OPTIMIZER needs to plan an `komira.in_memory` scan.

    Registered before any payload moves, so this kind's identity is under
    audit from the start — an unregistered kind is an unchecked kind.
    """
    return ScanKindDescriptor(
        kind_name=String(SCAN_KIND_NAME_IN_MEMORY),
        gate=PushdownGate.accept_all(),
        orientation=SCAN_ORIENTATION_COLUMNAR,
        snapshot_policy=SNAPSHOT_NONE,
    )


def _inmem_corpus_batch(
    var field_name: String, num_rows: Int, seed: Int
) raises -> RecordBatch:
    """Corpus fixture only. One INT64 column, values `seed + i`, so `seed`
    varies BYTES at a fixed shape and `num_rows` varies the shape."""
    var sb = SchemaBuilder()
    sb.add_field(Field(field_name^, ArrowType.INT64, nullable=False))
    var vals = List[Int64]()
    for i in range(num_rows):
        vals.append(Int64(seed + i))
    return RecordBatch.from_columns_1(
        sb.build(), PrimitiveArray[DType.int64].from_list(vals)
    )


def _inmem_corpus_source(
    var field_name: String,
    num_rows: Int,
    seed: Int,
    num_batches: Int = 1,
    var name: Optional[String] = None,
) raises -> InMemorySource:
    var sl = Slab[RecordBatch].create(num_batches)
    for b in range(num_batches):
        sl.append(_inmem_corpus_batch(String(field_name), num_rows, seed + b))
    _ = field_name^
    return InMemorySource.from_record_batches(sl^, name^)


def inmem_scan_identity_corpus() raises -> ScanIdentityCorpus:
    """The in-memory kind's statement of what makes two of its scans different.

    ⚠ THIS CORPUS IS SHAPED BY WHICH FIELD AUDITS WHICH HALF, which is the
    thing that is new about this kind. `InMemorySource.structural_id()` folds
    FOUR inputs — batch COUNT, schema TEXT, per-batch ROW COUNT and column
    BYTES — and exactly one of them (schema) is visible to core's derived
    `identity_hash()`. So:

      * `schema`   varies an input BOTH folds  -> audited by R2 (fingerprint
                   differs, identity_hash must differ) AND by R5.
      * `name`     varies an input ONLY core folds -> audited by R2's converse
                   direction, which is deliberately not checked, and by R4.
      * `bytes`    |
      * `rows`     |  vary inputs ONLY the KIND folds -> `fingerprint` is EQUAL
      * `nbatches` |  to baseline by construction, so R2's premise never holds
                   and these three are audited by **R5** (SUPPLIED REACH +
                   ATTRIBUTION): each one's `structural_id` must appear in its
                   own rendered plan text and must be the WITNESS separating it
                   from the others.

    That split is the whole reason `structural_id` exists as a second field,
    and `scan_identity_audit.mojo`'s R5 header names this kind as the case it
    is for. A reader tempted to "fix" R2 for the bytes entries by folding the
    content hash into `params` should read `inmem_scan_binding`'s docstring
    first — that fix breaks the cheap key.

    ⚠ DO NOT DELETE AN ENTRY TO MAKE A FUTURE CHANGE PASS. The audit runs ALL
    PAIRS over whatever is here; removing an entry removes the check.
    """
    var c = ScanIdentityCorpus(inmem_scan_descriptor())
    c.add(
        String("baseline"),
        inmem_scan_binding(_inmem_corpus_source(String("c0"), 8, 0)),
    )
    # Varies the ONE identity input both folds see.
    c.add(
        String("schema"),
        inmem_scan_binding(_inmem_corpus_source(String("c1"), 8, 0)),
    )
    # Varies only what CORE sees — the debug label that becomes `path=`.
    c.add(
        String("name"),
        inmem_scan_binding(
            _inmem_corpus_source(
                String("c0"), 8, 0, name=Optional(String("t"))
            )
        ),
    )
    # The three below are the reason this kind needs `structural_id` at all:
    # same name, same schema, DIFFERENT DATA. Nothing core can compute
    # separates them; only the content hash does.
    c.add(
        String("bytes"),
        inmem_scan_binding(_inmem_corpus_source(String("c0"), 8, 999)),
    )
    c.add(
        String("rows"),
        inmem_scan_binding(_inmem_corpus_source(String("c0"), 9, 0)),
    )
    c.add(
        String("nbatches"),
        inmem_scan_binding(
            _inmem_corpus_source(String("c0"), 8, 0, num_batches=2)
        ),
    )
    return c^


@always_inline
def _tag_is_binding_backed(tag: UInt8) -> Bool:
    """True iff this tag's payload lives in `_binding` rather than in a
    concrete-source arm. When it is true for every tag, the union can be
    deleted."""
    return (
        tag == SOURCE_VARIANT_ARROW_UNCOMPRESSED
        or tag == SOURCE_VARIANT_ARROW_LZ4_FRAME
        or tag == SOURCE_VARIANT_ARROW_ZSTD
        or tag == SOURCE_VARIANT_ORC
        or tag == SOURCE_VARIANT_AVRO
        or tag == SOURCE_VARIANT_CSV
        or tag == SOURCE_VARIANT_JSON
        or tag == SOURCE_VARIANT_BINDING
    )


comptime _MAX_LEGACY_TAG: Int = 10
"""One past `SOURCE_VARIANT_BINDING`. The legacy tag space is closed; this
bound exists so `core_scan_identity_corpora` can walk it."""


def core_scan_identity_corpora() raises -> List[ScanIdentityCorpus]:
    """Every core-owned scan kind that is BINDING-BACKED, with its corpus.

    ⚠ THE LIST IS DERIVED FROM `_tag_is_binding_backed`, NOT HAND-WRITTEN — and
    that is the whole design of this function.

    The audit in `scan_identity_audit.mojo` is registry-driven, so it covers any
    The audit in `scan_identity_audit.mojo` is registry-driven, so it covers any
    kind that is REGISTERED. The residual hole is a binding-backed kind that is
    never registered. So this walks the legacy tag space and asks the union
    ITSELF which tags are binding-backed; a tag that is binding-backed with no
    arm below RAISES, naming the tag. Making an arm binding-backed without
    auditing it is therefore a HARD FAILURE at the next test run, not an
    omission nobody sees.

    ONE CORPUS PER KIND, NOT PER TAG. The three arrow tags are three spellings
    of one kind (`komira.arrow.ipc` + a `codec` param), so two of them fall
    through to the shared arm.
    """
    var out = List[ScanIdentityCorpus]()
    # ⚠ ONE ENTRY IS NOT DERIVED FROM THE TAG WALK, AND IT IS ON PURPOSE.
    # `komira.in_memory` has its IDENTITY but its payload still rides the
    # concrete arm, so `SOURCE_VARIANT_IN_MEMORY` is not binding-backed and the
    # walk below will not reach it. Auditing it here puts the identity this
    # kind will carry under R0-R10 BEFORE the arm becomes binding-backed. When
    # it does, the arm moves into the walk below and this line is deleted — a
    # `_tag_is_binding_backed(SOURCE_VARIANT_IN_MEMORY)` that is true with this
    # line still here would append the corpus TWICE, which R0's
    # one-corpus-per-kind clause turns into a named failure rather than a
    # silent double-count.
    if not _tag_is_binding_backed(SOURCE_VARIANT_IN_MEMORY):
        out.append(inmem_scan_identity_corpus())
    for t in range(0, _MAX_LEGACY_TAG):
        var tag = UInt8(t)
        if not _tag_is_binding_backed(tag):
            continue
        if tag == SOURCE_VARIANT_ARROW_UNCOMPRESSED:
            out.append(arrow_scan_identity_corpus())
        elif tag == SOURCE_VARIANT_ORC:
            out.append(orc_scan_identity_corpus())
        elif tag == SOURCE_VARIANT_AVRO:
            out.append(avro_scan_identity_corpus())
        elif tag == SOURCE_VARIANT_CSV:
            out.append(csv_scan_identity_corpus())
        elif tag == SOURCE_VARIANT_JSON:
            out.append(json_scan_identity_corpus())
        elif tag == SOURCE_VARIANT_ARROW_LZ4_FRAME or tag == SOURCE_VARIANT_ARROW_ZSTD:
            # Same KIND as tag 4 — one corpus already covers it, and `codec` is
            # one of that corpus's entries.
            continue
        elif tag == SOURCE_VARIANT_BINDING:
            # The OPEN arm. It names no core-owned kind: whatever binding
            # arrives through it was built and audited by the package that owns
            # the kind (`broker_scan_identity_corpus`, and its successors).
            continue
        else:
            raise Error(
                String("core_scan_identity_corpora: legacy tag ")
                + String(t)
                + String(" is BINDING-BACKED but declares no identity corpus.")
                + String(" You migrated an arm onto `ScanBinding` without")
                + String(" saying what makes two of its scans different, so")
                + String(" nothing checks that core's derived identity_hash()")
                + String(" covers what the kind's own fingerprint() folds —")
                + String(" the defect class in `scan_identity_audit.mojo`,")
                + String(" which has fired four times. Add a")
                + String(" `<kind>_scan_identity_corpus()` beside the kind's")
                + String(" `_<kind>_binding()` and an arm here.")
            )
    return out^


struct SourceVariant(Movable, Copyable, Deinitable):
    """Tagged-union over concrete SourceLike implementors.

    Invariant: exactly one arm is Some, matching the tag byte. For a
    binding-backed tag that arm is `_binding` (shared by every binding-backed
    tag and by the open `SOURCE_VARIANT_BINDING` arm); for the concrete tags
    it is that tag's concrete-source Optional. `_tag_is_binding_backed(tag)`
    decides which.

    NOTE: SourceVariant does NOT implement the SourceLike trait directly
    (Mojo cannot dispatch trait methods across a tagged-union
    without devirtualization). Consumers call the local accessor methods
    `schema()` / `estimate_rows()` / `fingerprint()` which do the tag
    dispatch internally — ergonomically equivalent at the call site.
    """

    var tag: UInt8
    var _parquet: Optional[ParquetSource]
    var _in_memory: Optional[InMemorySource]
    # The BINDING-BACKED payload. One field serves every binding-backed arm
    # AND every kind core has never heard of, because a binding is data rather
    # than a type. `ArrowSource` is only a construction convenience — it is
    # not reachable from a plan node.
    var _binding: Optional[ScanBinding]

    def __init__(out self, var parquet: ParquetSource):
        """Construct a SourceVariant holding a ParquetSource (active arm)."""
        self.tag = SOURCE_VARIANT_PARQUET
        self._parquet = Optional(parquet^)
        self._in_memory = None
        self._binding = None

    def __init__(out self, var in_memory: InMemorySource):
        """Construct a SourceVariant holding an InMemorySource (active arm)."""
        self.tag = SOURCE_VARIANT_IN_MEMORY
        self._parquet = None
        self._in_memory = Optional(in_memory^)
        self._binding = None

    def __init__(out self, var json: JsonSource):
        """Builds a `komira.json` binding (tag `SOURCE_VARIANT_JSON`).

        The kind declares ROW: JSONL is a row-major on-wire format.
        `EngineContext.read_jsonl_row_streaming` and
        `JsonlReader.build_scan_plan` build this arm and take ROW from the
        kind; `row_streaming_dispatch._read_row_source_to_row_block` routes
        `SOURCE_VARIANT_JSON` to `read_jsonl_path_to_row_block`, the JSONL
        direct ROW reader; `lower_untyped_row_streaming._row_source_path`
        reads this arm as a SOURCE_KIND_ROW scan's source; and the typed
        conformer `jsonl_typed_source.JsonlSource[FS].orientation =
        PlanOrientation.ROW()` agrees. No plan-execution path reads a JSON
        scan columnar.
        """
        self.tag = SOURCE_VARIANT_JSON
        self._parquet = None
        self._in_memory = None
        self._binding = Optional(_json_binding(json^))

    def __init__(out self, var csv: CsvSource):
        """Builds a `komira.csv` binding (tag `SOURCE_VARIANT_CSV`,
        `kind_name() == "csv"`).

        The kind declares ROW: orientation is intrinsic to the source format.
          1. `LogicalPlan.scan(path, SOURCE_CSV, ...)` — the factory behind
             `ctx.read_csv` — threads `kind = SOURCE_KIND_ROW`.
          2. Both row-streaming path walkers read this arm as a ROW source
             (`lower_untyped_row_streaming._row_source_path`,
             `row_streaming_dispatch._row_source_path_for_dispatch`).
          3. The typed conformer `komira_parquet.csv_typed_source`
             declares `CsvSource.orientation = ROW()`.
        """
        self.tag = SOURCE_VARIANT_CSV
        self._parquet = None
        self._in_memory = None
        self._binding = Optional(_csv_binding(csv^))

    def __init__(out self, var orc: OrcSource):
        """Builds a `komira.orc` binding (tag `SOURCE_VARIANT_ORC`).

        The ORC arm is `SOURCE_KIND_COLUMNAR` — the ORC chassis decodes the
        file into a single RecordBatch; per-codec dispatch
        (None/Zlib/Snappy/Lzo/Lz4/Zstd) happens INSIDE the decoder.
        Per-stripe streaming morsels are a possible refinement.

        The legacy source type is DECLARED data on the binding
        (`legacy_source_type`, sentinel `SCAN_LEGACY_SOURCE_TYPE_NONE`), exactly
        as `orientation` is, so `ScanData.__init__` derives it with one
        assignment rather than a tag-keyed test per kind. That is what lets a
        new kind — including one from an upper package that core has never
        heard of — cost ZERO lines in `ScanData.__init__`. Only `kind_name()`
        keeps a tag arm here, because it maps a tag to the legacy NAME and
        reads no payload.
        """
        self.tag = SOURCE_VARIANT_ORC
        self._parquet = None
        self._in_memory = None
        self._binding = Optional(_orc_binding(orc^))

    def __init__(out self, var avro: AvroSource):
        """Builds a `komira.avro` binding (tag `SOURCE_VARIANT_AVRO`).

        The Avro arm is the genuine ROW source — the row-streaming producer
        dispatch decodes each OCF record DIRECTLY into a RowBlock (no col->row
        bridge), and per-codec dispatch (null/snappy/...) happens INSIDE the
        OCF reader at decode time.

        The ROW orientation exists in exactly one place, the kind: the
        production callers (`engine_context.read_avro_row_streaming`,
        `AvroReader.build_scan_plan`) pass no `source_kind`, and
        `ScanData.__init__`'s auto-promotion covers SOURCE_CSV / SOURCE_NDJSON
        only, so without the declaration an Avro scan would derive COLUMNAR.
        `orientation` is therefore a field whose value actually varies across
        kinds, which is what lets `ScanKindRegistry.validate` fail.
        """
        self.tag = SOURCE_VARIANT_AVRO
        self._parquet = None
        self._in_memory = None
        self._binding = Optional(_avro_binding(avro^))

    # =========================================================================
    # ARROW IPC — binding-backed.
    # =========================================================================
    #
    # The three factories keep one signature each. Instead of stashing an
    # `ArrowSource` in one of three Optionals, they build ONE
    # `komira.arrow.ipc` binding whose `codec` param is the only difference
    # between them. Three union arms are one kind plus one param.

    @staticmethod
    def from_arrow_uncompressed(var arrow: ArrowSource) -> Self:
        """SourceVariant for the `Arrow[Uncompressed]` typed surface."""
        return SourceVariant(
            tag=SOURCE_VARIANT_ARROW_UNCOMPRESSED,
            binding=_arrow_binding(arrow^, String(ARROW_CODEC_UNCOMPRESSED)),
        )

    @staticmethod
    def from_arrow_lz4_frame(var arrow: ArrowSource) -> Self:
        """SourceVariant for the `Arrow[Lz4Frame]` typed surface (per-buffer
        LZ4_FRAME body decompression at decode time)."""
        return SourceVariant(
            tag=SOURCE_VARIANT_ARROW_LZ4_FRAME,
            binding=_arrow_binding(arrow^, String(ARROW_CODEC_LZ4_FRAME)),
        )

    @staticmethod
    def from_arrow_zstd(var arrow: ArrowSource) -> Self:
        """SourceVariant for the `Arrow[Zstd[3]]` typed surface (per-buffer
        ZSTD body decompression at decode time)."""
        return SourceVariant(
            tag=SOURCE_VARIANT_ARROW_ZSTD,
            binding=_arrow_binding(arrow^, String(ARROW_CODEC_ZSTD)),
        )

    @staticmethod
    def from_binding(var binding: ScanBinding) -> Self:
        """THE OPEN ARM. Root a plan at a source kind this package has never
        heard of, with no edit here.

        An upper package (a search source, a broker consumer) that conforms
        the `SourceLike` surface can build a `ScanBinding` in its own package
        and pass it here: a Copyable identity HANDLE on the plan node, with
        the heavy substrate constructed at execute time.
        """
        return SourceVariant(tag=SOURCE_VARIANT_BINDING, binding=binding^)

    def __init__(out self, *, tag: UInt8, var binding: ScanBinding):
        """Internal kw-only ctor for every BINDING-BACKED arm.

        Kw-only because the payload type no longer discriminates: the three
        arrow arms and the open arm all carry a `ScanBinding`, so the tag must
        be stated. The named factories above are the user-facing surface.
        """
        self.tag = tag
        self._parquet = None
        self._in_memory = None
        self._binding = Optional(binding^)

    def binding_ref(self) -> ref [origin_of(self._binding.value())] ScanBinding:
        """The binding behind a binding-backed arm.

        ⚠ Precondition: `is_binding_backed()`. Reading it on a legacy arm is a
        programming error, the same contract every `._parquet.value()` site in
        this file already has.
        """
        return self._binding.value()

    @always_inline
    def is_binding_backed(self) -> Bool:
        """True iff this arm's payload is a `ScanBinding`. When it is every
        arm, `tag` can be deleted."""
        return _tag_is_binding_backed(self.tag)

    # -------------------------------------------------------------------------
    # THE TRANSITIONAL CARRIER — a binding on a concrete (in-memory) arm
    # -------------------------------------------------------------------------
    #
    # ⚠ WHY THIS IS A SECOND PAIR OF ACCESSORS AND NOT A WIDENING OF
    # `is_binding_backed()`. That predicate answers "does this arm's PAYLOAD live
    # in `_binding`" — it is what `copy()`, `fingerprint()`, `schema()`,
    # `plan_display` and `core_scan_identity_corpora` all dispatch on. Making it
    # true for `SOURCE_VARIANT_IN_MEMORY` would flip the whole arm at once:
    # `_binding` is None on this tag, so every one of those readers would take
    # the wrong branch.
    #
    # So a source can carry a handle WITHOUT its arm having moved. The two
    # questions are genuinely different:
    #
    #   is_binding_backed()   — "is the payload gone from the union?"   (arm)
    #   has_carrier_binding() — "does a registry hold this payload too?" (handle)
    #
    # They become the same question when `_in_memory` is deleted, and this
    # pair goes with it.

    @always_inline
    def has_carrier_binding(self) -> Bool:
        """True iff a concrete arm nonetheless carries a `ScanBinding`.

        False for every binding-backed arm (their binding is `_binding`, reached
        by `binding_ref()`), and false for every unbound source — every
        in-memory source built without an `EngineContext` in frame.
        """
        if self.tag == SOURCE_VARIANT_IN_MEMORY:
            return Bool(self._in_memory.value().binding)
        return False

    def carrier_binding_ref(
        self,
    ) -> ref [origin_of(self._in_memory.value().binding.value())] ScanBinding:
        """The carrier binding. ⚠ Precondition: `has_carrier_binding()`."""
        return self._in_memory.value().binding.value()

    # -------------------------------------------------------------------------
    # THE WRITE HALF OF THE CARRIER — the entry-time bind.
    #
    # `has_carrier_binding` / `carrier_binding_ref` READ a handle. A plan node
    # hands out a `SourceVariant`, not an `InMemorySource`, so a pass that walks
    # PLAN NODES — which is the only frame that knows which registry will
    # execute the plan — needs these two to PUT one there.
    # -------------------------------------------------------------------------

    def carrier_payload_arc(self) raises -> ArcPointer[Slab[RecordBatch]]:
        """The in-memory arm's payload, as a REFCOUNT BUMP.

        O(1) in resident bytes — the same handoff shape
        `ScanRegistry.payload_arc` uses and for the same reason: the caller
        hands this straight to `ScanRegistry.bind`, so a deep copy here would
        double resident memory for every in-memory scan in every query.

        ⚠ Precondition: `tag == SOURCE_VARIANT_IN_MEMORY`. Raises rather than
        returning a sentinel — every caller has already tag-dispatched, so a
        miss here is a programming error and not a shape to paper over.
        """
        if self.tag != SOURCE_VARIANT_IN_MEMORY:
            raise Error(
                String("SourceVariant.carrier_payload_arc: tag ")
                + String(Int(self.tag))
                + String(" is not SOURCE_VARIANT_IN_MEMORY")
            )
        return self._in_memory.value().data.copy()

    def carrier_scan_binding(
        self, fold_content_identity: Bool = True
    ) raises -> ScanBinding:
        """The UNSTAMPED `komira.in_memory` binding describing this node's
        carrier — `inmem_scan_binding` over the arm, without the caller having
        to open the arm to get at it.

        ⚠ WHY THIS EXISTS. A bind pass that opened `self._in_memory.value()`
        directly would be a payload-read site OUTSIDE this union — one more
        place that has to know the arm. Keeping the read INTO this file makes
        it ONE dispatch arm that goes to zero with `SourceVariant`.

        `fold_content_identity=False` yields
        `structural_id = SCAN_STRUCTURAL_ID_UNRESOLVED` — a RESOLUTION TOKEN
        and not an identity. See `inmem_scan_binding`'s own docstring for why
        that is sound only for a binding the rebuilt node does not carry.
        """
        if self.tag != SOURCE_VARIANT_IN_MEMORY:
            raise Error(
                String("SourceVariant.carrier_scan_binding: tag ")
                + String(Int(self.tag))
                + String(" is not SOURCE_VARIANT_IN_MEMORY")
            )
        return inmem_scan_binding(
            self._in_memory.value(),
            fold_content_identity=fold_content_identity,
        )

    def attach_carrier_binding(mut self, var binding: ScanBinding) raises:
        """Stamp the in-memory arm with the `(handle, epoch)` its payload was
        bound under — the plan-node-level spelling of
        `InMemorySource.attach_binding`.

        A NAMED METHOD for the reason `attach_binding` is one: "who stamps a
        handle onto a plan node" has to be greppable without knowing which arm
        carries the field.

        ⚠ THE CALLER OWES THE PAIRING. The binding must have been minted by
        binding the Arc `carrier_payload_arc()` hands back — not a copy of the
        batches, and not some other source's payload. `bind_plan_inmem_payloads`
        is the single place that pairing is made, which is why it is one pass
        and not a stamp at each route.
        """
        if self.tag != SOURCE_VARIANT_IN_MEMORY:
            raise Error(
                String("SourceVariant.attach_carrier_binding: tag ")
                + String(Int(self.tag))
                + String(" is not SOURCE_VARIANT_IN_MEMORY")
            )
        self._in_memory.value().attach_binding(binding^)

    def copy(self) -> Self:
        """Tag-dispatch deep clone: copies only the active arm.

        Mirrors `Expr.copy()` and `WhenCaseData.copy()` (expr.mojo) — both walk
        the variant tag, copy the active payload, and let the inactive arm stay
        None. Refcount-bumps the ArcPointer inside InMemorySource (no batch
        byte-copy) and deep-clones the Schema in ParquetSource. A
        binding-backed arm copies pure data — no payload is reachable from it
        at all.

        Unreachable fall-through: the final `return` mirrors `Expr.copy()`'s
        "unknown tag — return placeholder" shape. Construct a
        ParquetSource-arm SourceVariant with an empty path + schema (cheap;
        never reached for valid inputs).
        """
        if self.tag == SOURCE_VARIANT_PARQUET:
            return SourceVariant(self._parquet.value().copy())
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return SourceVariant(self._in_memory.value().copy())
        elif _tag_is_binding_backed(self.tag):
            # ONE branch for every binding-backed arm and for every kind core
            # has never heard of. `ScanBinding.copy()` touches no payload — there
            # is no payload reachable from here. The clone is dominated by
            # `Schema.copy()`.
            return SourceVariant(
                tag=self.tag, binding=self._binding.value().copy()
            )
        # else: unknown tag — return a default-constructed sentinel.
        # In practice this branch is unreachable; matches Expr.copy's
        # fall-through shape rather than calling `abort`.
        return SourceVariant(self._parquet.value().copy())

    # =========================================================================
    # SourceLike-equivalent accessors (NOT trait-method dispatch — tag
    # dispatch is done inline here to avoid trait-object indirection).
    # =========================================================================

    def fingerprint(self) -> UInt64:
        """Stable identity hash — dispatches to the active arm's
        fingerprint(). Stable across `value^` moves and `value.copy()`
        clones (the cache-discrimination contract).
        """
        if self.tag == SOURCE_VARIANT_PARQUET:
            return self._parquet.value().fingerprint()
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return self._in_memory.value().fingerprint()
        elif _tag_is_binding_backed(self.tag):
            # The binding CARRIES the value its concrete source produced — it
            # does not recompute it. A binding-backed arm's fingerprint must
            # stay equal to the concrete source's value, not merely stay
            # distinct, or every plan-cache key moves silently.
            return self._binding.value().fingerprint
        return UInt64(0)  # unreachable

    def structural_id(self) -> UInt64:
        """CONTENT-derived structural identity for the plan `structural_hash`.

        Dispatches by arm:

          * IN_MEMORY → `InMemorySource.structural_id()` (a hash over schema +
            batch bytes). This is what `plan_display` emits for an in-memory
            scan INSTEAD of the per-ctor unique `fingerprint()`, so two
            structurally-identical in-mem plans hash equal (subquery dedup +
            the plan-compile cache fire) while two distinct in-mem tables
            still hash apart (a CSE self-join over them is prevented by
            CONTENT). See `in_memory_source.mojo`.

          * Every file-path source (parquet / csv / ndjson / json / avro, plus
            arrow and orc via their binding, which carries the same value) →
            its `fingerprint()`, which is already its path-based structural
            identity: two scans of the SAME file SHOULD dedup / cross-query
            scan-share. So for them `structural_id() == fingerprint()`.

        ⚠ WHAT THIS METHOD DOES *NOT* GUARANTEE. "For the plan
        `structural_hash`" describes the INTENT, not a mechanism this method
        can enforce: `structural_hash` folds the plan's TEXT RENDER, so a value
        only reaches it if `plan_display._write_plan_node` EMITS it. If you add
        an arm here, add the emission there too, or the value is computed and
        discarded.
        """
        if self.tag == SOURCE_VARIANT_IN_MEMORY:
            return self._in_memory.value().structural_id()
        if _tag_is_binding_backed(self.tag):
            # ⚠ READ THE FIELD, NOT `fingerprint()`. For every file kind the
            # two are equal (arrow and broker both set
            # `structural_id == fingerprint`), but for IN_MEMORY they DIFFER —
            # its CONTENT hash is the reason `structural_id` exists separately
            # from `fingerprint` — and falling through to `fingerprint()` would
            # silently return a per-construction id where a content id was
            # required, re-opening the CSE self-join over two distinct tables.
            return self._binding.value().structural_id
        return self.fingerprint()

    def schema(self) -> Schema:
        """Structural schema of the active source (eager copy, no I/O)."""
        if self.tag == SOURCE_VARIANT_PARQUET:
            return self._parquet.value().schema()
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return self._in_memory.value().schema()
        elif _tag_is_binding_backed(self.tag):
            return self._binding.value().source_schema()
        return Schema()  # unreachable

    def estimate_rows(self) -> Int:
        """Row-count estimate from the active source. -1 means unknown
        (e.g. ParquetSource pre-footer-read)."""
        if self.tag == SOURCE_VARIANT_PARQUET:
            return self._parquet.value().estimate_rows()
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return self._in_memory.value().estimate_rows()
        elif _tag_is_binding_backed(self.tag):
            return self._binding.value().estimate_rows()
        return -1  # unreachable

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Per-predicate pushdown query — dispatches to the active arm's
        `supports_filter_pushdown`.
        ParquetSource accepts zonemap-friendly + partition-col predicates
        (and AND-trees of such), rejecting OR-trees / LIKE / arithmetic /
        agg-window / off-schema cols; InMemorySource accepts everything
        (it applies any predicate as a deferred OP_FILTER). The inactive
        arm is never touched."""
        if self.tag == SOURCE_VARIANT_PARQUET:
            return self._parquet.value().supports_filter_pushdown(predicate)
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return self._in_memory.value().supports_filter_pushdown(predicate)
        elif _tag_is_binding_backed(self.tag):
            # ⚠ NO CONCRETE SOURCE IS REACHED HERE. The answer comes from
            # capability BITS on the binding, evaluated by the core-resident
            # matcher against (gate, schema, extra cols, predicate). That is
            # what keeps the plan node serializable — a fn-ptr field would not.
            return self._binding.value().supports_filter_pushdown(predicate)
        return False  # unreachable

    def kind_name(self) -> String:
        """Debug helper for EXPLAIN output. Returns a stable short tag per
        source-kind ("parquet" / "in_memory" / "json" / "csv" /
        "arrow[<codec>]"), or — for the open arm — the binding's reverse-DNS
        kind name, so EXPLAIN names a kind this build never registered."""
        if self.tag == SOURCE_VARIANT_PARQUET:
            return String("parquet")
        elif self.tag == SOURCE_VARIANT_IN_MEMORY:
            return String("in_memory")
        elif self.tag == SOURCE_VARIANT_JSON:
            return String("json")
        elif self.tag == SOURCE_VARIANT_CSV:
            return String("csv")
        elif (
            self.tag == SOURCE_VARIANT_ARROW_UNCOMPRESSED
            or self.tag == SOURCE_VARIANT_ARROW_LZ4_FRAME
            or self.tag == SOURCE_VARIANT_ARROW_ZSTD
        ):
            # Renders `arrow[<codec>]` — the codec param values ARE the
            # stable arm-name substrings.
            return (
                String("arrow[")
                + self._binding.value().params.get_str(String("codec"))
                + String("]")
            )
        elif self.tag == SOURCE_VARIANT_BINDING:
            # A kind core has never heard of still names itself in EXPLAIN.
            return String(self._binding.value().kind_name)
        elif self.tag == SOURCE_VARIANT_ORC:
            return String("orc")
        elif self.tag == SOURCE_VARIANT_AVRO:
            return String("avro")
        return String("unknown")
