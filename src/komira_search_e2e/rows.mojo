# =============================================================================
# komira_search_e2e/rows.mojo
#   The two sides every query comparison has: the rows the
#   `komira.search.index` scan returns when drained over a catalog, and the
#   rows `SearchCore` returns for split bytes held in memory (the baseline).
# =============================================================================
#
# A row is rendered `<_score>|<_id>|<_source>`, so two sides are equal only if
# every hit has the same score bits, the same split-local id and the same
# source bytes, in the same order.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_scan_source.scan_binding import ScanBinding
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.scan_resolver import resolve_for_execution

from komira_scan_resolver.drain_scan import drain_scan
from komira_scan_resolver.scan_source_resolver import ScanRequest

from komira_search.source import QueryIR, SearchCore

from komira_search_scan.search_scan_kind import (
    SEARCH_RESOLVED_GENERATION,
    SearchIndexCatalog,
    SearchScanResolver,
)

from komira_search_e2e.corpus import TEXT_FIELD, text_analyzer


def hit_row(batch: RecordBatch, r: Int) raises -> String:
    """Row `r` of a hit batch (`_score`, `_id`, `_source`) as one string."""
    var sc = Float64(batch.column_at(0).as_primitive[DType.float64]().get(r))
    var id = Int64(batch.column_at(1).as_primitive[DType.int64]().get(r))
    var src = batch.column_at(2).as_string().get(r)
    return String(sc) + String("|") + String(id) + String("|") + String(src)


def hit_source(batch: RecordBatch, r: Int) raises -> String:
    return String(batch.column_at(2).as_string().get(r))


@fieldwise_init
struct ScanRows(Copyable, Movable, Deinitable):
    """What one drained scan returned: its rows, their `_source` cells and the
    generation the execution resolved."""

    var rows: List[String]
    var sources: List[String]
    var generation: Int64


def resolve_scan[
    C: SearchIndexCatalog
](rt: SearchScanResolver[C], index: String, query: String) raises -> ScanBinding:
    """Bind a LIVE `komira.search.index` scan of `index` for `query` (empty is
    the no-query scan) and resolve it for execution: the binding carries the
    generation the catalog reported now. Drain it later with `drain_rows` to
    stand for a query that is still running when the catalog changes."""
    var p = ScanParams()
    p.put_str(String("index"), index)
    p.put_str(String("field"), String(TEXT_FIELD))
    if query.byte_length() > 0:
        p.put_str(String("query"), query)
    var binding = rt.build_binding(p)
    return resolve_for_execution(rt, binding)


def drain_rows[
    C: SearchIndexCatalog
](rt: SearchScanResolver[C], resolved: ScanBinding) raises -> ScanRows:
    """Plan, open and read every split of a scan `resolve_scan` resolved."""
    var opened = drain_scan(rt, ScanRequest(resolved.copy()))
    var rows = List[String]()
    var sources = List[String]()
    for bi in range(len(opened.batches[])):
        ref b = opened.batches[][bi]
        for r in range(b.num_rows()):
            rows.append(hit_row(b, r))
            sources.append(hit_source(b, r))
    return ScanRows(
        rows^,
        sources^,
        opened.resolved.get_i64(String(SEARCH_RESOLVED_GENERATION)),
    )


def scan_rows[
    C: SearchIndexCatalog
](rt: SearchScanResolver[C], index: String, query: String) raises -> ScanRows:
    """`resolve_scan` then `drain_rows`: one query, start to end."""
    return drain_rows(rt, resolve_scan(rt, index, query))


def _core_batch(split: List[UInt8], query: String) raises -> RecordBatch:
    var core = SearchCore(split.copy())
    var q = QueryIR(
        String(TEXT_FIELD),
        query,
        core.doc_count(),
        text_analyzer(),
        match_all=(query.byte_length() == 0),
    )
    var res = core.search(q^)
    return res.take_batch()


def core_rows(split: List[UInt8], query: String) raises -> List[String]:
    """What `SearchCore.search` returns for `split` when asked for every match:
    the baseline for one split."""
    var batch = _core_batch(split, query)
    var out = List[String]()
    for r in range(batch.num_rows()):
        out.append(hit_row(batch, r))
    return out^


def core_sources(split: List[UInt8], query: String) raises -> List[String]:
    """The `_source` of every document `SearchCore` matches in `split`."""
    var batch = _core_batch(split, query)
    var out = List[String]()
    for r in range(batch.num_rows()):
        out.append(hit_source(batch, r))
    return out^


def baseline_rows(splits: List[List[UInt8]], query: String) raises -> List[String]:
    """`core_rows` of every split in order, concatenated: what the scan must
    return over the same splits."""
    var out = List[String]()
    for s in range(len(splits)):
        var rows = core_rows(splits[s], query)
        for i in range(len(rows)):
            out.append(rows[i])
    return out^


def sorted_strings(var xs: List[String]) -> List[String]:
    """`xs` in ascending byte order (insertion sort; the lists are short)."""
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j] < xs[j - 1]:
            var t = xs[j].copy()
            xs[j] = xs[j - 1].copy()
            xs[j - 1] = t^
            j -= 1
    return xs^
