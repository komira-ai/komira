# =============================================================================
# test_log_native_indexing_l1.mojo
#   The cheap unsorted-posting L0 builder, the L0 SPLIT_VERSION=1 additive-footer
#   format, and the small run-to-completion build task.
# =============================================================================
#
# This suite is the correctness gate for the L0 builder:
#
#   1. ROUND TRIP. The L0 split parses through SplitView.parse (which rejects
#      any version other than 1): the L0 split IS a SPLIT_VERSION=1 additive-
#      footer container with an EMPTY term dictionary and EMPTY postings region,
#      a POPULATED doc store and fast-field region (THFF), and the L0 posting
#      blob in the `l0_posting` footer slot. The format discriminator is
#      SplitView.has_l0_posting() (not a front magic).
#
#   2. POSTING QUERY == ORACLE. The round-tripped L0 posting (deserialized from
#      the parsed split's l0_posting region) returns the CORRECT, COMPLETE set of
#      matching doc-ids for term queries (selective, common, multi and absent),
#      checked against an independent in-test brute-force oracle (tokenize every
#      doc's message, membership-test the query term).
#
#   3. THFF BYTE-IDENTICAL. The L0 split's fast-field (THFF) region is
#      BYTE-IDENTICAL to what the OPTIMIZED writer (SearchSink) produces for the
#      same batch, so a compaction merge's typed fast-field carry-forward finds
#      every field. The doc-store region is likewise byte-identical (same
#      DocStoreBuilder).
#
#   4. RUN-TO-COMPLETION TASK END TO END. The small L0BuildTask (the
#      SpawnableTask a worker runs type-erased) builds and publishes the L0
#      split into the CAS-sharded role="drain" sub-lineage; the published split
#      round-trips through SplitView.parse and its L0 posting query returns the
#      right matches. No thread is involved (the task is driven inline here, as
#      the spawner would).
#
# No UnsafePointer in any signature. The posting, doc-store and fast-field
# builders use plain List storage; the views are owned function-local Lists.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import drain_to_views
from komira_log import LogRecordView
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR
from komira_log.log_arg import ArgI64, ArgStr, Field

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_index_schema,
    log_views_to_record_batch,
    L0SegmentBuilder,
    L0PostingIndex,
    L0BuildTask,
)

from komira_search.analyzer import AnalyzerConfig, analyze_text
from komira_search.split import SplitView
from komira_search.sink import SearchSink

from komira_objectstore import (
    SharedInMemoryConditionalStore,
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.path import Path
from komira_search_catalog import (
    make_shard_id,
    shard_manifest_prefix,
    SearchMetastore,
    list_live_splits_across_shards,
)


# -----------------------------------------------------------------------------
# Fixtures (an OTLP-style 5-site corpus).
# -----------------------------------------------------------------------------


def _fixed_anchor() -> CalibrationAnchor:
    var wall0_ns = UInt64(1_788_220_800) * UInt64(1_000_000_000)
    return CalibrationAnchor(
        tick0=UInt64(0), wall0_ns=wall0_ns, tick_hz=UInt64(1_000_000_000)
    )


def _dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["request {} method {} status {}", "komira_http"]()
    d.register["query finished in {} ms scanned {} rows", "komira_engine"]()
    d.register["opened file {} size {} bytes", "komira_parquet"]()
    d.register["retry {} reason {}", "komira_agent"]()
    d.register["connection {} from {} closed", "komira_broker"]()
    return d^


def _fill_ring(mut r: LogRecordRing, n: Int):
    """Emit `n` records cycling the 5 sites (mixed levels + args)."""
    for i in range(n):
        var m = i % 5
        var c = UInt64(1000 + i)
        if m == 0:
            _ = emit_record["request {} method {} status {}", "komira_http"](
                r, LEVEL_INFO, c, ArgStr(String("/v1/query")), ArgStr(String("POST")), ArgI64(200)
            )
        elif m == 1:
            _ = emit_record[
                "query finished in {} ms scanned {} rows", "komira_engine"
            ](r, LEVEL_INFO, c, ArgI64(42), ArgI64(6001215))
        elif m == 2:
            _ = emit_record["opened file {} size {} bytes", "komira_parquet"](
                r, LEVEL_WARN, c, ArgStr(String("lineitem.parquet")), ArgI64(298000000)
            )
        elif m == 3:
            _ = emit_record["retry {} reason {}", "komira_agent"](
                r, LEVEL_ERROR, c, ArgI64(3), ArgStr(String("connection timeout to upstream"))
            )
        else:
            _ = emit_record["connection {} from {} closed", "komira_broker"](
                r, LEVEL_INFO, c, ArgI64(7), ArgStr(String("10.0.0.42"))
            )


def _drain_corpus(n: Int) raises -> List[LogRecordView]:
    var dict = _dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=n + 8, overflow_policy=OVERFLOW_BLOCK)
    _fill_ring(ring, n)
    return drain_to_views(ring, dict, anchor)


def _messages_of(views: List[LogRecordView]) -> List[String]:
    var out = List[String]()
    for i in range(len(views)):
        out.append(views[i].message)
    return out^


# -----------------------------------------------------------------------------
# The independent brute-force ORACLE:
# tokenize every doc's message, return the slots whose message contains the
# (analyzed) query term. The L0 posting must reproduce this EXACTLY.
# -----------------------------------------------------------------------------


def _oracle_matches(
    config: AnalyzerConfig, messages: List[String], term: String
) raises -> List[Int]:
    var qa = analyze_text(term, config)
    var out = List[Int]()
    if qa.len() == 0:
        return out^
    var qterm = qa.tokens[0].term
    for slot in range(len(messages)):
        var af = analyze_text(messages[slot], config)
        for ti in range(af.len()):
            if af.tokens[ti].term == qterm:
                out.append(slot)
                break
    return out^


def _lists_equal(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# -----------------------------------------------------------------------------
# Build helpers: an L0 split (cheap posting) and the OPTIMIZED split (SearchSink)
# over the SAME batch.
# -----------------------------------------------------------------------------


def _build_l0_split(views: List[LogRecordView]) raises -> List[UInt8]:
    var schema = log_index_schema()
    var batch = log_views_to_record_batch(views)
    var seg = L0SegmentBuilder(schema^)
    seg.add_batch(batch^)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(7))
    return seg.serialize_split_bytes(LOG_INDEX_TEXT_FIELD, uuid)


def _build_optimized_split(views: List[LogRecordView]) raises -> List[UInt8]:
    var schema = log_index_schema()
    var batch = log_views_to_record_batch(views)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(7))
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String("logs"),
        LOG_INDEX_TEXT_FIELD,
        uuid,
        LOG_INDEX_SOURCE_FIELD,
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


# =============================================================================
# CASE 1 — the L0 split is a SPLIT_VERSION=1 additive-footer container that
# ROUND-TRIPS through SplitView.parse, with the L0 discriminator + empty
# inverted regions + populated docstore/THFF.
# =============================================================================


def test_01_l0_split_roundtrips_through_parse() raises:
    var views = _drain_corpus(40)
    assert_equal(len(views), 40, "1: 40 views drained")
    var bytes = _build_l0_split(views)

    # The hard gate: SplitView.parse ACCEPTS the L0 split (it is v1).
    var view = SplitView.parse(bytes^)

    # The FORMAT DISCRIMINATOR: an L0 split carries the l0_posting slot.
    assert_true(view.has_l0_posting(), "1: L0 split has the l0_posting slot")
    assert_true(view.l0_posting_len() > 0, "1: l0_posting region non-empty")

    # An L0 split has EMPTY term-dict + EMPTY postings (the optimized regions the
    # old reader expects, present but zero-length).
    assert_equal(view.postings_len(), 0, "1: empty postings region (L0)")

    # POPULATED docstore + THFF (the searchable-on-land payload + fast-fields).
    assert_true(view.docstore_len() > 0, "1: populated docstore region")
    assert_true(view.has_fastfields(), "1: populated THFF region")

    # Footer metadata is intact.
    assert_equal(view.doc_count(), 40, "1: doc_count == 40")
    assert_equal(view.field_name(), LOG_INDEX_TEXT_FIELD, "1: text field name")
    assert_equal(view.min_doc_id(), 0, "1: min_doc_id 0")
    assert_equal(view.max_doc_id(), 39, "1: max_doc_id 39")


# =============================================================================
# CASE 2 — the round-tripped L0 posting query returns CORRECT + COMPLETE results
# vs the independent oracle (selective / common / multi-site / absent terms).
# =============================================================================


def test_02_l0_posting_query_matches_oracle() raises:
    var views = _drain_corpus(60)
    var messages = _messages_of(views)
    var bytes = _build_l0_split(views)
    var view = SplitView.parse(bytes^)
    assert_true(view.has_l0_posting(), "2: l0_posting present")

    # Deserialize the L0 posting from the PARSED split's region (the read path).
    var l0 = L0PostingIndex.deserialize(view.l0_posting_region())
    assert_equal(l0.num_docs(), 60, "2: posting num_docs == 60")

    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)

    # selective (m==2 site ~20%), common (m==0), multi (m==1), absent.
    var terms = [
        String("lineitem.parquet"),
        String("request"),
        String("scanned"),
        String("connection"),  # appears in BOTH m==3 (text) and m==4 (template)
        String("nonesuchzzz"),
    ]
    for qi in range(len(terms)):
        ref qt = terms[qi]
        var oracle = _oracle_matches(config, messages, qt)
        var got = l0.query_term(qt, config)
        assert_true(
            _lists_equal(got, oracle),
            String("2: L0 posting == oracle for term '") + qt + "' (got "
            + String(len(got)) + " want " + String(len(oracle)) + ")",
        )

    # The absent term returns empty (membership negative).
    var absent = l0.query_term(String("nonesuchzzz"), config)
    assert_equal(len(absent), 0, "2: absent term -> no matches")


# =============================================================================
# CASE 3 — the L0 split's THFF + docstore regions are BYTE-IDENTICAL to the
# OPTIMIZED writer (SearchSink) for the SAME batch (the invariant that
# lets a compaction merge carry fast fields forward and re-derive _source).
# =============================================================================


def _region_bytes_equal(
    a: Span[UInt8, _], b: Span[UInt8, _]
) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _region_diff(a: Span[UInt8, _], b: Span[UInt8, _]) -> String:
    """A failure message that NAMES the difference. A bare 'not byte-identical'
    tells the next person nothing about whether the regions differ in LENGTH
    (a column-set / classification divergence) or in CONTENT at some offset (a
    value-encoding divergence), which are completely different bugs."""
    if len(a) != len(b):
        return (
            String("length differs: l0=") + String(len(a))
            + " optimized=" + String(len(b))
        )
    for i in range(len(a)):
        if a[i] != b[i]:
            return (
                String("first byte difference at offset ") + String(i)
                + " of " + String(len(a)) + ": l0=" + String(Int(a[i]))
                + " optimized=" + String(Int(b[i]))
            )
    return String("identical")


def test_03_thff_and_docstore_byte_identical_to_optimized() raises:
    # ONE corpus, drained ONCE, fed to BOTH writers.
    #
    # This used to call `_drain_corpus(50)` SEPARATELY for each writer, on the
    # comment "the corpus is deterministic". IT IS NOT. `emit_record`
    # (komira_log/engine/emit.mojo) stamps every record with
    # `read_raw_ticks()` — a hardware clock read. Two independent drains
    # therefore carry DIFFERENT timestamps, so the timestamp fast-field column
    # lands different bytes in the THFF region while keeping the same width.
    # That is exactly what the failure looked like:
    #
    #     3: THFF region BYTE-IDENTICAL (L0 vs optimized) — first byte
    #     difference at offset 108 of 519: l0=204 optimized=213
    #
    # Same LENGTH (so the column set and classification agreed — no product
    # divergence), differing CONTENT (the clock). The test was measuring corpus
    # determinism, which the corpus does not have and does not claim to have.
    #
    # The invariant is explicitly "byte-identical ... FOR THE SAME BATCH":
    # given ONE batch, the cheap L0 writer and the optimized SearchSink must
    # produce identical THFF + docstore, so the compaction merge's fast-field
    # carry-forward and `_source` re-derive find what they expect. Feeding one
    # corpus to both is what actually tests that.
    #
    # Borrowing `views` twice is safe — `_build_*_split` take it by reference and
    # `log_views_to_record_batch` does not consume it (test_02 already relies on
    # this, calling `_messages_of(views)` before `_build_l0_split(views)`).
    var views = _drain_corpus(50)

    var l0_bytes = _build_l0_split(views)
    var opt_bytes = _build_optimized_split(views)

    var l0_view = SplitView.parse(l0_bytes^)
    var opt_view = SplitView.parse(opt_bytes^)

    # The OPTIMIZED split is NOT an L0 split (the discriminator inverts).
    assert_false(opt_view.has_l0_posting(), "3: optimized split has NO l0_posting")
    assert_true(opt_view.postings_len() > 0, "3: optimized split has postings")
    assert_true(l0_view.has_l0_posting(), "3: L0 split has l0_posting")

    # THFF region byte-identical.
    assert_true(
        l0_view.has_fastfields() and opt_view.has_fastfields(),
        "3: both splits carry a THFF region",
    )
    assert_true(
        _region_bytes_equal(
            l0_view.fastfields_region(), opt_view.fastfields_region()
        ),
        String("3: THFF region BYTE-IDENTICAL (L0 vs optimized) — ")
        + _region_diff(
            l0_view.fastfields_region(), opt_view.fastfields_region()
        ),
    )

    # Doc-store region byte-identical (same DocStoreBuilder, same _source).
    assert_true(
        _region_bytes_equal(
            l0_view.docstore_region(), opt_view.docstore_region()
        ),
        "3: docstore region BYTE-IDENTICAL (L0 vs optimized)",
    )

    # The optimized split parsed fine WITHOUT the l0_posting slot — i.e. the
    # additive-footer extension is backward-compatible (an optimized split still
    # parses, the l0_posting slot just reads absent).
    assert_equal(opt_view.l0_posting_len(), 0, "3: optimized l0_posting absent")
    _ = views  # (the originally-drained corpus, retained for clarity)


# =============================================================================
# CASE 4 — the RUN-TO-COMPLETION L0BuildTask builds + publishes the L0 split into
# the CAS-sharded role="drain" sub-lineage; the published split round-trips +
# its L0 posting query returns the right matches. (Driven inline here — the
# spawner would run run() on a worker; the contract is what the gate asserts.)
# =============================================================================


def _emit_login_records(mut r: LogRecordRing, n: Int):
    for i in range(n):
        _ = emit_record["request {} status {}", "komira_http_login"](
            r, LEVEL_INFO, UInt64(100 + i), ArgStr(String("login")), ArgI64(200)
        )


def _login_dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["request {} status {}", "komira_http_login"]()
    return d^


def test_04_rtc_task_builds_publishes_and_is_queryable() raises:
    var store = SharedInMemoryConditionalStore()
    var meta_root = String("index/logs/meta")
    var drain_shard = make_shard_id(String("nodeA"), 0, String("drain"))

    # Build the metastore for the drain sub-lineage (the same wiring a
    # consumer uses).
    var lineage = shard_manifest_prefix(meta_root, drain_shard)
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    var metastore = SearchMetastore[SharedInMemoryConditionalStore](
        manifest^, String("logs")
    )

    # Drain 16 'login' records (a small RtC batch).
    var dict = _login_dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=32, overflow_policy=OVERFLOW_BLOCK)
    _emit_login_records(ring, 16)
    var views = drain_to_views(ring, dict, anchor)
    assert_equal(len(views), 16, "4: 16 login views drained")

    # Build the RtC task (owned views + the publish target) and RUN it inline
    # (the spawner would run this type-erased on a worker; run() is the contract).
    var uuid = InlineArray[UInt8, 16](fill=UInt8(0))
    uuid[0] = UInt8(0)  # worker-disc 0
    uuid[8] = UInt8(1)  # seq 1
    var task = L0BuildTask[SharedInMemoryConditionalStore](
        views^,
        store.clone(),
        metastore^,
        meta_root,
        String("logs"),
        uuid,
    )
    var result = task.run()

    # The task published the split (searchable), no failure, 16 docs.
    assert_true(result.published, "4: RtC task published the L0 split")
    assert_false(result.failed, "4: RtC task did not fail")
    assert_equal(Int(result.docs), 16, "4: 16 docs in the published L0 split")
    assert_true(result.bytes > Int64(0), "4: non-empty split bytes")

    # READ-PATH PROOF: enumerate the published split, parse it, and run the L0
    # posting query for 'login' -> all 16 docs match.
    var live = list_live_splits_across_shards(store, meta_root, String("logs"))
    assert_equal(len(live), 1, "4: one live split published in the drain lineage")
    var key = live[0].object_key
    var bytes = store.get(Path.parse(key))
    var view = SplitView.parse(bytes^)
    assert_true(view.has_l0_posting(), "4: published split is an L0 split")
    assert_equal(view.doc_count(), 16, "4: published doc_count 16")

    var l0 = L0PostingIndex.deserialize(view.l0_posting_region())
    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    var hits = l0.query_term(String("login"), config)
    assert_equal(len(hits), 16, "4: all 16 'login' docs queryable in the L0 split")


# =============================================================================
# CASE 5 — empty / single-doc edge cases. A single-doc segment builds a valid L0
# split; an empty (no-token) message still produces a parseable split.
# =============================================================================


def test_05_single_doc_and_edge_counts() raises:
    # Single doc.
    var views1 = _drain_corpus(1)
    assert_equal(len(views1), 1, "5: 1 view")
    var messages1 = _messages_of(views1)
    var b1 = _build_l0_split(views1)
    var v1 = SplitView.parse(b1^)
    assert_true(v1.has_l0_posting(), "5: single-doc L0 split has l0_posting")
    assert_equal(v1.doc_count(), 1, "5: single-doc count")
    var l1 = L0PostingIndex.deserialize(v1.l0_posting_region())
    assert_equal(l1.num_docs(), 1, "5: posting num_docs 1")
    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    # The single doc is the m==0 'request ... POST ...' site -> 'request' matches.
    var oracle1 = _oracle_matches(config, messages1, String("request"))
    var got1 = l1.query_term(String("request"), config)
    assert_true(_lists_equal(got1, oracle1), "5: single-doc query == oracle")

    # A larger batch: every distinct term in the corpus is queryable + correct.
    var views2 = _drain_corpus(25)
    var messages2 = _messages_of(views2)
    var b2 = _build_l0_split(views2)
    var v2 = SplitView.parse(b2^)
    var l2 = L0PostingIndex.deserialize(v2.l0_posting_region())
    # Cross-check a handful of distinct vocabulary terms vs the oracle.
    var probe = [
        String("method"),
        String("status"),
        String("finished"),
        String("file"),
        String("bytes"),
        String("retry"),
        String("reason"),
        String("closed"),
    ]
    for pi in range(len(probe)):
        ref pt = probe[pi]
        var oracle = _oracle_matches(config, messages2, pt)
        var got = l2.query_term(pt, config)
        assert_true(
            _lists_equal(got, oracle),
            String("5: term '") + pt + "' query == oracle",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_01_l0_split_roundtrips_through_parse]()
    suite.test[test_02_l0_posting_query_matches_oracle]()
    suite.test[test_03_thff_and_docstore_byte_identical_to_optimized]()
    suite.test[test_04_rtc_task_builds_publishes_and_is_queryable]()
    suite.test[test_05_single_doc_and_edge_counts]()
    suite^.run()
