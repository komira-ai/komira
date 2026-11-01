# =============================================================================
# test_log_native_indexing_l0.mojo
#   The log transpose seam and drained-logs-searchable end to end.
# =============================================================================
#
# WHAT THIS SUITE PROVES:
#   1. THE SEAM. `drain_to_views` decodes a LOG record into an OWNED
#      `LogRecordView` whose `message` is BYTE-IDENTICAL to the text-drain
#      path's interpolated message (the inverted TEXT that gets indexed equals
#      the human-rendered line's message). The arena is copied before the seam:
#      the views survive `reset_arena`.
#   2. THE TRANSPOSE AND WIDENING. `log_views_to_record_batch` builds the typed
#      multi-column batch; corr_id (UInt64), flags (UInt16) and site_id (UInt32)
#      are widened to Int64 so they LAND in the SearchSink fast fields (UInt*
#      columns are silently skipped otherwise).
#   3. SCHEMA INVARIANCE. The log-index schema is FROZEN and scoped to the index:
#      identical across drain windows and workers, and dynamic args do not
#      change it. A reader may therefore inspect the first split's fast fields
#      once.
#   4. THE shard_id WRITER-ROLE AXIS. `make_shard_id(role=...)` keeps a drain
#      worker's ring index and a search server's thread index in DISJOINT
#      sub-lineages (no collision on the same node and pid).
#   5. DRAINED LOGS ARE SEARCHABLE END TO END. transpose -> SearchSink -> split
#      bytes -> SearchCore: full-text BM25 on `message` (the inverted field), a
#      filter on a columnar-only NUMERIC field (corr_id) and a sort on a
#      columnar DATE field (timestamp). Plus the metastore publish round trip
#      (the drain worker writes its OWN drain-role sub-lineage; the cross-shard
#      read enumerates it; a srv-role shard does not collide).
#
# Indexing is not wired into the hot drain here: this is the seam, the end to
# end behaviour and the schema. Inline millisecond-scale indexing on the
# nanosecond-scale drain core would exhaust memory, which is why the index is
# built off the drain path.
#
# No UnsafePointer in any signature; the views carry owned Strings (the engine
# copied the arena), and the RecordBatch columns are List-owned via the public
# factories.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr, BIN_GE, BIN_LE, BIN_AND
from komira_plan_expr.scalar_value import ScalarValue

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import drain_to_lines, drain_to_views
from komira_log import LogRecordView
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR, level_name
from komira_log.log_arg import ArgI64, ArgStr, ArgF64, Field

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_index_schema,
    log_views_to_record_batch,
    build_log_index_plan,
)

from komira_search.sink import SearchSink
from komira_search.source import (
    QueryIR,
    SearchCore,
    SORT_ASC,
    MISSING_LAST,
)
from komira_search.analyzer import AnalyzerConfig

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
)
from komira_search_catalog import (
    SplitSummary,
    make_split_summary,
    make_shard_id,
    shard_manifest_prefix,
    SearchMetastore,
    list_live_splits_across_shards,
)


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------


def _fixed_anchor() -> CalibrationAnchor:
    # tick_hz=1e9 (1 tick == 1 ns).
    var wall0_ns = UInt64(1_788_220_800) * UInt64(1_000_000_000)
    return CalibrationAnchor(
        tick0=UInt64(0), wall0_ns=wall0_ns, tick_hz=UInt64(1_000_000_000)
    )


def _dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["query finished in {} ms", "komira_engine"]()
    d.register["scanned {} rows", "komira_engine"]()
    d.register["opened file {}", "komira_parquet"]()
    d.register["retry {} reason {}", "komira_agent"]()
    d.register["request {} status {}", "komira_http"]()
    return d^


def _uuid(seed: UInt8) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


# =============================================================================
# CASE 1 — the POD seam: message BYTE-IDENTICAL to the text-drain path.
# Two rings carry the SAME emits; one drains to lines, one to views; the
# view's `message` equals the text line's message portion (suffix after the
# "LEVEL [module] " prefix). Proves the inverted TEXT == the rendered message.
# =============================================================================


def _line_message(line: String) -> String:
    """Extract the message portion of a rendered text line: everything AFTER the
    "<ts> LEVEL [module] " prefix (the part interpolate() produced)."""
    # The layout is: "<ts> LEVEL [module] <message> [ <field>...]". We find the
    # "] " after the module and take the remainder (the message + any fields).
    var idx = line.find(String("] "))
    if idx < 0:
        return line
    var b = line.as_bytes()
    var out = String("")
    for i in range(idx + 2, len(b)):
        out += chr(Int(b[i]))
    return out^


def _emit_seam_records(mut r: LogRecordRing):
    """Emit the same three records the seam-equality case asserts on."""
    _ = emit_record["query finished in {} ms", "komira_engine"](
        r, LEVEL_INFO, UInt64(7), ArgI64(42)
    )
    _ = emit_record["scanned {} rows", "komira_engine"](
        r, LEVEL_INFO, UInt64(0), ArgI64(6001215)
    )
    _ = emit_record["opened file {}", "komira_parquet"](
        r, LEVEL_WARN, UInt64(0), ArgStr(String("lineitem.parquet"))
    )


def test_01_seam_message_byte_identical() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()

    var ring_lines = LogRecordRing(capacity=64, overflow_policy=OVERFLOW_BLOCK)
    var ring_views = LogRecordRing(capacity=64, overflow_policy=OVERFLOW_BLOCK)

    # Emit the SAME records into both rings (corr_id controllable per call).
    _emit_seam_records(ring_lines)
    _emit_seam_records(ring_views)

    var lines = drain_to_lines(ring_lines, dict, anchor)
    var views = drain_to_views(ring_views, dict, anchor)
    assert_equal(len(lines), 3, "1: 3 lines")
    assert_equal(len(views), 3, "1: 3 views")

    for i in range(3):
        # The view message == the text line's message portion (byte-identical
        # interpolate output). This is the load-bearing seam invariant.
        assert_equal(
            views[i].message,
            _line_message(lines[i]),
            "1: view message == text line message #" + String(i),
        )
    # The interpolated content is exactly what we expect.
    assert_equal(views[0].message, String("query finished in 42 ms"))
    assert_equal(views[1].message, String("scanned 6001215 rows"))
    assert_equal(views[2].message, String("opened file lineitem.parquet"))


# =============================================================================
# CASE 2 — the scalars survive the seam (arena copy). corr_id / level /
# module are carried OWNED on the view; the values match what was emitted, and
# remain valid after the ring's arena reset (drain_to_views calls reset_arena).
# =============================================================================


def test_02_seam_scalars_owned() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)

    _ = emit_record["request {} status {}", "komira_http"](
        ring, LEVEL_INFO, UInt64(0xCAFEBABE), ArgStr(String("/v1/q")), ArgI64(200)
    )
    var views = drain_to_views(ring, dict, anchor)
    assert_equal(len(views), 1, "2: one view")
    ref v = views[0]
    assert_equal(v.corr_id, UInt64(0xCAFEBABE), "2: corr_id carried")
    assert_equal(Int(v.level), Int(LEVEL_INFO), "2: level carried")
    assert_equal(v.module, String("komira_http"), "2: module resolved")
    assert_equal(
        v.message, String("request /v1/q status 200"), "2: message owned"
    )
    # The arena was reset by drain_to_views; the owned String is still valid.
    assert_true(v.message.byte_length() > 0, "2: message survives reset_arena")


# =============================================================================
# CASE 3 — the transpose and widening. The batch carries the typed columns;
# corr_id/flags/site_id land as Int64 (would silently SKIP at SearchSink as
# UInt*). The frozen schema column inventory is exactly the 8 columns.
# =============================================================================


def test_03_transpose_schema_and_fm1() raises:
    var schema = log_index_schema()
    assert_equal(schema.num_columns(), 8, "3: 8 columns")
    assert_equal(schema.field_name(0), LOG_INDEX_TEXT_FIELD, "3: col0 message")
    assert_equal(schema.field_name(1), LOG_INDEX_SOURCE_FIELD, "3: col1 _source")
    assert_equal(schema.field_name(2), String("timestamp"), "3: col2 timestamp")
    assert_equal(schema.field_name(3), String("level"), "3: col3 level")
    assert_equal(schema.field_name(4), String("module"), "3: col4 module")
    assert_equal(schema.field_name(5), String("corr_id"), "3: col5 corr_id")
    assert_equal(schema.field_name(6), String("flags"), "3: col6 flags")
    assert_equal(schema.field_name(7), String("site_id"), "3: col7 site_id")
    # corr_id/flags/site_id are Int64 (NOT UInt*) so they are readable.
    assert_true(
        schema.field_at(5).arrow_type == ArrowType.INT64, "3: corr_id INT64"
    )
    assert_true(
        schema.field_at(6).arrow_type == ArrowType.INT64, "3: flags INT64"
    )
    assert_true(
        schema.field_at(7).arrow_type == ArrowType.INT64, "3: site_id INT64"
    )
    # timestamp is a temporal (DATE-class) i64-storage type.
    assert_true(
        schema.field_at(2).arrow_type.is_temporal(), "3: timestamp temporal"
    )

    # Build a couple of views and transpose: row count + a column round-trip.
    var dict = _dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _ = emit_record["retry {} reason {}", "komira_agent"](
        ring, LEVEL_ERROR, UInt64(11), ArgI64(3), ArgStr(String("timeout"))
    )
    _ = emit_record["query finished in {} ms", "komira_engine"](
        ring, LEVEL_INFO, UInt64(22), ArgI64(99)
    )
    var views = drain_to_views(ring, dict, anchor)
    var batch = log_views_to_record_batch(views)
    assert_equal(batch.num_rows(), 2, "3: batch 2 rows")
    assert_equal(batch.num_columns(), 8, "3: batch 8 cols")


# =============================================================================
# CASE 4 — schema invariance. The frozen schema is identical across
# multiple independent transpose calls (different drain windows), and dynamic
# args (the trailing Field key/values) do NOT add columns — they fold into
# _source. This is what lets a reader inspect only the first split.
# =============================================================================


def _schema_fingerprint(s: Schema) raises -> String:
    var fp = String("")
    for c in range(s.num_columns()):
        fp += s.field_name(c) + ":" + String(s.field_at(c).arrow_type.type_id) + "|"
    return fp^


def test_04_schema_invariance() raises:
    var dict = _dict()
    var anchor = _fixed_anchor()

    # Window A: no dynamic args.
    var ring_a = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _ = emit_record["query finished in {} ms", "komira_engine"](
        ring_a, LEVEL_INFO, UInt64(1), ArgI64(10)
    )
    var plan_a = build_log_index_plan(drain_to_views(ring_a, dict, anchor))

    # Window B: WITH dynamic Field args (free-form key/value pairs). The schema
    # MUST be identical (the args fold into _source, NOT new columns).
    var ring_b = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    _ = emit_record["retry {} reason {}", "komira_agent"](
        ring_b,
        LEVEL_WARN,
        UInt64(2),
        ArgI64(5),
        ArgStr(String("net")),
        Field("region", ArgStr(String("us-east-1"))),
        Field("attempt", ArgI64(5)),
    )
    var plan_b = build_log_index_plan(drain_to_views(ring_b, dict, anchor))

    assert_equal(
        _schema_fingerprint(plan_a.schema),
        _schema_fingerprint(plan_b.schema),
        "4: schema invariant across windows",
    )
    # Both schemas equal the canonical frozen schema.
    assert_equal(
        _schema_fingerprint(plan_a.schema),
        _schema_fingerprint(log_index_schema()),
        "4: window A == canonical frozen schema",
    )
    # The dynamic-arg window still has exactly 8 columns (no schema mutation).
    assert_equal(plan_b.schema.num_columns(), 8, "4: dynamic args add 0 columns")


# =============================================================================
# CASE 5 — shard_id WRITER-ROLE axis. A drain-role shard and a srv-role
# shard with the SAME (node, pid, worker_idx) do NOT collide. A role="" shard
# preserves the legacy `<node>-<pid>-<worker>` shape (byte-compat).
# =============================================================================


def test_05_shard_id_role_axis() raises:
    var node = String("nodeA")
    # Same (node, worker) — DISJOINT roles must not collide.
    var drain0 = make_shard_id(node, 0, String("drain"))
    var srv0 = make_shard_id(node, 0, String("srv"))
    assert_true(drain0 != srv0, "5: drain0 != srv0 (role disambiguates)")
    # Within a role, distinct workers are distinct.
    var drain1 = make_shard_id(node, 1, String("drain"))
    assert_true(drain0 != drain1, "5: drain0 != drain1")
    # role="" preserves the legacy shape == the 2-arg default.
    var legacy = make_shard_id(node, 0)
    var legacy_explicit = make_shard_id(node, 0, String(""))
    assert_equal(legacy, legacy_explicit, "5: role='' == 2-arg default")
    # The legacy id is distinct from a roled id at the same (node, worker).
    assert_true(legacy != drain0, "5: legacy != drain0")
    # A roled id carries the role prefix on the worker segment.
    assert_true(drain0.find(String("drain0")) >= 0, "5: drain id carries role")


# =============================================================================
# CASE 6 — THE DRAINED-LOGS-SEARCHABLE e2e. transpose -> SearchSink -> split ->
# SearchCore: full-text BM25 on `message`, filter on the columnar NUMERIC
# corr_id, sort on the columnar DATE timestamp. Proves the whole mechanism.
# =============================================================================


def _drive_log_sink(var batch: RecordBatch, var schema: Schema) raises -> List[UInt8]:
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("logs"),
        LOG_INDEX_TEXT_FIELD,  # message is the inverted TEXT field
        _uuid(1),
        LOG_INDEX_SOURCE_FIELD,  # _source designated column
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _build_searchable_split() raises -> List[UInt8]:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=64, overflow_policy=OVERFLOW_BLOCK)

    # 5 log records. The message words drive BM25; corr_id is the numeric filter
    # key; the timestamp (raw ticks) is the DATE sort key. We use distinct corr
    # ids and ascending raw ticks (so the timestamp sort is deterministic — the
    # ring is SPSC FIFO, so emit order == drain order == ascending ticks).
    _ = emit_record["request {} status {}", "komira_http"](
        ring, LEVEL_INFO, UInt64(100), ArgStr(String("login")), ArgI64(200)
    )
    _ = emit_record["request {} status {}", "komira_http"](
        ring, LEVEL_ERROR, UInt64(200), ArgStr(String("login")), ArgI64(500)
    )
    _ = emit_record["query finished in {} ms", "komira_engine"](
        ring, LEVEL_INFO, UInt64(300), ArgI64(42)
    )
    _ = emit_record["retry {} reason {}", "komira_agent"](
        ring, LEVEL_WARN, UInt64(400), ArgI64(3), ArgStr(String("login"))
    )
    _ = emit_record["request {} status {}", "komira_http"](
        ring, LEVEL_INFO, UInt64(500), ArgStr(String("logout")), ArgI64(200)
    )

    var views = drain_to_views(ring, dict, anchor)
    var batch = log_views_to_record_batch(views)
    var schema = log_index_schema()
    return _drive_log_sink(batch^, schema^)


def _ids(batch: RecordBatch) raises -> List[Int]:
    # The HitBatch _id column is col 1 (Int64). Read it as ints.
    var out = List[Int]()
    for r in range(batch.num_rows()):
        out.append(Int(batch.column_at(1).as_primitive[DType.int64]().get(r)))
    return out^


def test_06_drained_logs_searchable_fulltext() raises:
    var bytes = _build_searchable_split()
    var core = SearchCore(bytes^)

    # Full-text BM25 on `message`: "login" appears in 3 docs (the two requests +
    # the retry reason). The query matches them.
    var q = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        String("login"),
        10,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
    )
    var res = core.search(q)
    assert_equal(res.total_matches, 3, "6: 'login' matches 3 docs (full-text)")
    # A word in only one doc.
    var q2 = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        String("logout"),
        10,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
    )
    var res2 = core.search(q2)
    assert_equal(res2.total_matches, 1, "6: 'logout' matches 1 doc")


def test_07_drained_logs_columnar_filter() raises:
    var bytes = _build_searchable_split()
    var core = SearchCore(bytes^)

    # Columnar-only filter on the NUMERIC corr_id fast-field (widened i64).
    # "login" matches docs with corr_id in {100, 200, 400}. Filter corr_id >= 200
    # AND <= 400 -> {200, 400} (the error request + the retry).
    var pred = Expr.binary(
        BIN_GE,
        Expr.col_ref(String("corr_id")),
        Expr.literal(ScalarValue.from_int64(Int64(200))),
    )
    var pred2 = Expr.binary(
        BIN_LE,
        Expr.col_ref(String("corr_id")),
        Expr.literal(ScalarValue.from_int64(Int64(400))),
    )
    # The right-leaning conjunction the shim builds: corr_id>=200 AND corr_id<=400.
    var conj = Expr.binary(BIN_AND, pred^, pred2^)
    var q = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        String("login"),
        10,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
        Optional[Expr](conj^),
    )
    var res = core.search(q)
    assert_equal(
        res.total_matches, 2, "7: login AND 200<=corr_id<=400 -> 2 docs"
    )


def test_08_drained_logs_columnar_sort() raises:
    var bytes = _build_searchable_split()
    var core = SearchCore(bytes^)

    # Sort the full-text "login" hits by the columnar timestamp (DATE) ASC. The
    # ring is SPSC FIFO so emit order == ascending raw ticks == ascending wall ns.
    # The matched docs are 0 (corr 100), 1 (corr 200), 3 (corr 400); ASC by
    # timestamp keeps that doc-id order.
    var q = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        String("login"),
        10,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
        None,
        String("timestamp"),  # sort_field
        SORT_ASC,
        MISSING_LAST,
    )
    var res = core.search(q)
    assert_equal(res.total_matches, 3, "8: 3 login hits sorted")
    var ids = _ids(res.batch)
    assert_equal(len(ids), 3, "8: 3 ids returned")
    # ASC timestamp -> the earliest-emitted doc first.
    assert_true(ids[0] < ids[1], "8: timestamp ASC -> ascending doc order #0")
    assert_true(ids[1] < ids[2], "8: timestamp ASC -> ascending doc order #1")


# =============================================================================
# CASE 9 — the metastore publish round-trip. The
# drain-worker publishes its OWN drain-role sub-lineage; a fresh cross-shard read
# enumerates it; a srv-role shard on the SAME (node, pid, worker) is a DISTINCT
# sub-lineage (no collision). Uses the in-memory CAS store.
# =============================================================================


def _shard_meta(
    store: SharedInMemoryConditionalStore, meta_root: String, shard_id: String
) raises -> SearchMetastore[SharedInMemoryConditionalStore]:
    var lineage = shard_manifest_prefix(meta_root, shard_id)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    return SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )


def test_09_drain_publish_role_no_collision() raises:
    var bytes = _build_searchable_split()
    # We just need the byte length + doc count for the summary; the searchability
    # was proved in 6-8. Build a real split-derived summary.
    var doc_count = Int64(5)
    var byte_size = Int64(len(bytes))

    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")

    # The DRAIN writer publishes into its drain-role sub-lineage.
    var drain_shard = make_shard_id(String("node"), 0, String("drain"))
    var drain_meta = _shard_meta(store, meta_root, drain_shard)
    var drain_summary = make_split_summary(
        _uuid(1),
        doc_count,
        byte_size,
        Int64(0),
        doc_count - 1,
        String("logs"),
        LOG_INDEX_TEXT_FIELD,
        String("index/logs/splits/drain.split"),
    )
    var r = drain_meta.publish(drain_summary^)
    # Sole writer of its sub-lineage -> first-try win (no 412-storm).
    assert_equal(r.attempts, 1, "9: drain shard append wins first try")

    # A SEARCH-SERVER writer on the SAME (node, pid, worker_idx) is a DISTINCT
    # sub-lineage (the role axis). Publishing there does NOT touch the drain
    # shard's _HEAD.
    var srv_shard = make_shard_id(String("node"), 0, String("srv"))
    assert_true(
        drain_shard != srv_shard, "9: drain and srv shards distinct"
    )
    var srv_meta = _shard_meta(store, meta_root, srv_shard)
    var srv_summary = make_split_summary(
        _uuid(50),
        Int64(2),
        Int64(123),
        Int64(0),
        Int64(1),
        String("logs"),
        LOG_INDEX_TEXT_FIELD,
        String("index/logs/splits/srv.split"),
    )
    var rs = srv_meta.publish(srv_summary^)
    assert_equal(rs.attempts, 1, "9: srv shard append wins first try (disjoint)")

    # A fresh cross-shard read enumerates BOTH sub-lineages — the drain split is
    # searchable on publish.
    var live = list_live_splits_across_shards(store, meta_root, String("logs"))
    assert_equal(len(live), 2, "9: cross-shard read sees drain + srv splits")


def main() raises:
    var suite = TestSuite()
    suite.test[test_01_seam_message_byte_identical]()
    suite.test[test_02_seam_scalars_owned]()
    suite.test[test_03_transpose_schema_and_fm1]()
    suite.test[test_04_schema_invariance]()
    suite.test[test_05_shard_id_role_axis]()
    suite.test[test_06_drained_logs_searchable_fulltext]()
    suite.test[test_07_drained_logs_columnar_filter]()
    suite.test[test_08_drained_logs_columnar_sort]()
    suite.test[test_09_drain_publish_role_no_collision]()
    suite^.run()
