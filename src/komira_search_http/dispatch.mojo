# =============================================================================
# dispatch.mojo: the search HTTP dispatcher
# =============================================================================
#
# `SearchHttpDispatcher[Storage]` is a `RequestDispatcher` with two routes over
# the Arrow-native search engine:
#
#   POST /<index>/_bulk     index NDJSON documents as one new split
#   POST /<index>/_search   search the live splits of the index
#
# GENERIC OVER THE STORE. `Storage` is any `CloneableConditionalWriteStore`
# from `komira_objectstore`: the in-memory store in tests, a cloud store in a
# deployment. The dispatcher names no cloud client and holds no credential; the
# program that mounts it builds the store and hands it over. Split objects and
# the catalog share that one store.
#
# STATE. The dispatcher owns the validated config, the store handle, the id of
# its catalog sub-lineage and the split-uuid counter. The catalog handle
# (`SearchMetastore`) is built per `_bulk` request on a clone of the store, so a
# sub-lineage that has been retired does not poison the dispatcher.
#
# PUBLISH ORDER. A split is written with `storage.put` FIRST and appended to the
# catalog with `SearchMetastore.publish` SECOND; the append is the point at
# which the split becomes searchable. A crash or an error between the two leaves
# an unreferenced object (harmless, a retention sweep deletes it), never a
# catalog entry that names a missing object.
#
# NEVER RAISES OUT. Every failure becomes an OpenSearch-style error envelope: a
# malformed request is 400, a body over the limit 413, an unknown path 404, a
# wrong verb 405, an index with more splits than the config allows 503, and a
# failure of the store 500 (with a fixed reason: the store's message is not
# echoed to the client).
#
# No pointer type appears in any signature.
# =============================================================================

from std.builtin.swap import swap

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_clock import now_unix_us

from komira_collections.slab import Slab

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher

from komira_log_index import search_l0_split

from komira_objectstore import CasManifestStore, Path, RetryPolicy
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_search.fast_fields import FastFieldReader
from komira_search.merge import (
    merge_agg_results,
    merge_search_results,
    shard_size_for,
)
from komira_search.sink import SearchSink
from komira_search.source import (
    AggResults,
    SORT_FIELD_DOC,
    SORT_MODE_DOC,
    SORT_MODE_SCORE,
    SearchCore,
    SearchResult,
)
from komira_search.split import SplitView

from komira_search_catalog import (
    SearchMetastore,
    SplitSummary,
    generation_across_shards,
    list_live_splits_across_shards,
    make_shard_id,
    make_split_summary,
    shard_manifest_prefix,
)

from .bulk import BulkItem, ndjson_bulk_to_docbatch
from .config import SOURCE_FIELD, SearchHttpConfig
from .envelopes import (
    bulk_response_envelope_items,
    empty_hits_envelope,
    error_envelope,
    hitbatch_to_hits_envelope,
)
from .request_path import (
    body_too_large,
    count_ndjson_lines,
    unsupported_query_param,
    is_valid_index_name,
    split_path,
    strip_query,
)
from .response import json_response, ok_json
from .search_gates import (
    gate_aggs_against_fastfields,
    gate_filter_against_fastfields,
    gate_sort_against_fastfields,
)
from .search_query import (
    parse_track_total_hits,
    search_json_to_queryir,
    sort_is_by_score,
)
from .split_ids import make_split_uuid


comptime _FAULT_NONE = 0
comptime _FAULT_STORE = 1
comptime _FAULT_TOO_MANY_SPLITS = 2


def _split_short_id(summary: SplitSummary) -> String:
    """The split's whole 16-byte uuid in hex: the stable per-split part of the
    cross-split `_id` `<split-uuid>_<doc_id>`. All 16 bytes are needed; two
    splits minted in one run share the leading time bytes."""
    comptime HEX = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        var b = Int(summary.split_uuid[i])
        out += HEX[byte = (b >> 4) & 0xF]
        out += HEX[byte = b & 0xF]
    return out^


def _trim_trailing_slash(s: String) -> String:
    var pb = s.as_bytes()
    var n = len(pb)
    if n > 0 and pb[n - 1] == UInt8(47):  # '/'
        n -= 1
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(pb[i])
    # SAFETY: a prefix of a String's bytes that drops a trailing ASCII '/' is
    # still UTF-8.
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


struct SearchHttpDispatcher[Storage: CloneableConditionalWriteStore](
    Movable, RequestDispatcher, Deinitable
):
    """The OpenSearch-compatible search routes over a store `Storage`.

    Routes `POST /<index>/_bulk` and `POST /<index>/_search`. See the module
    header for the publish order and the error mapping."""

    var _cfg: SearchHttpConfig
    var _store: Self.Storage
    # This dispatcher's catalog sub-lineage id `<node_id>-<pid>-<worker_idx>`,
    # minted once. The dispatcher is the sole writer of that sub-lineage.
    var _shard_id: String
    var _worker_disc: UInt8
    # The wall clock, in microseconds, read once at construction (the
    # install-time epoch mixed into every split uuid).
    var _epoch_us: UInt64
    # The sequence of the last split uuid minted; the next is this plus one.
    var _split_seq: Int64
    # How the request in flight failed, set by the handler just before it
    # raises and read by `_map_error`; reset at the start of every request.
    # A kind and a fixed operation name, not a prefix of the message, tell a
    # store fault from a request error, so no message text can pose as one.
    var _fault: Int
    var _fault_what: String

    def __init__(
        out self,
        var cfg: SearchHttpConfig,
        var store: Self.Storage,
        worker_idx: Int = 0,
        epoch_us: Int64 = Int64(-1),
    ) raises:
        """Take the config and the store. `worker_idx` (0 to 255) tells apart
        the dispatchers of one process: it is the uuid discriminant byte and
        part of the sub-lineage id; it must be unique among the dispatchers of
        one process that share a store, because two with the same index and
        epoch mint the same split keys and the second `put` overwrites the
        first. `epoch_us` is the install time mixed into
        every split uuid; a negative value (the default) reads the wall clock
        now, pass a value only to pin it. Raises when `worker_idx` is outside
        0 to 255."""
        if worker_idx < 0 or worker_idx > 255:
            raise Error(
                "SearchHttpDispatcher: worker_idx must be between 0 and 255"
            )
        self._shard_id = make_shard_id(cfg.node_id, worker_idx)
        self._worker_disc = UInt8(worker_idx)
        if epoch_us < Int64(0):
            self._epoch_us = UInt64(now_unix_us())
        else:
            self._epoch_us = UInt64(epoch_us)
        self._split_seq = Int64(0)
        self._fault = _FAULT_NONE
        self._fault_what = String("")
        self._cfg = cfg^
        self._store = store^

    def _store_fault(mut self, what: String, e: Error) -> Error:
        """Record that the store (or an object it holds) failed while `what`,
        and return the error to raise. The client is told `what` only."""
        self._fault = _FAULT_STORE
        self._fault_what = what.copy()
        return Error(what + String(": ") + String(e))

    def shard_id(self) -> String:
        """The id of this dispatcher's catalog sub-lineage."""
        return self._shard_id

    def _index_meta_prefix(self, index: String) -> String:
        """`<meta_root>/<index>/meta`: the parent of the sub-lineages."""
        return _trim_trailing_slash(self._cfg.meta_root) + "/" + index + "/meta"

    def _next_split_uuid(mut self) -> InlineArray[UInt8, 16]:
        self._split_seq += Int64(1)
        return make_split_uuid(
            self._worker_disc, self._epoch_us, self._split_seq
        )

    def _new_write_metastore(
        self, index: String
    ) raises -> SearchMetastore[Self.Storage]:
        """A catalog handle bound to this dispatcher's sub-lineage of `index`.
        The dispatcher is the sole writer there, so a publish wins its first
        compare-and-swap."""
        var lineage_prefix = shard_manifest_prefix(
            self._index_meta_prefix(index), self._shard_id
        )
        var manifest = CasManifestStore[Self.Storage](
            self._store.clone(), lineage_prefix^, RetryPolicy.default()
        )
        return SearchMetastore[Self.Storage](manifest^, index.copy())

    # =========================================================================
    # The RequestDispatcher surface.
    # =========================================================================
    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Route a parsed request. Any other path is 404, a known path under
        another verb 405, a bad index name 400, a body over the limit 413. The
        handlers' failures are mapped to envelopes here, so nothing raises out.
        """
        self._fault = _FAULT_NONE
        var segs = split_path(strip_query(req.path))
        var is_bulk = len(segs) == 2 and segs[1] == String("_bulk")
        var is_search = len(segs) == 2 and segs[1] == String("_search")
        if not is_bulk and not is_search:
            return self._error_response(
                String("not_found"),
                String(
                    "no handler for the requested path (POST /<index>/_bulk"
                    " and POST /<index>/_search are served)"
                ),
                404,
            )
        if not (req.method == HttpMethod.post()):
            var verb = String("_bulk") if is_bulk else String("_search")
            var r = self._error_response(
                String("method_not_allowed"),
                String("POST is required for /<index>/") + verb,
                405,
            )
            r.headers[String("allow")] = String("POST")
            return r^
        if unsupported_query_param(req.path):
            return self._error_response(
                String("illegal_argument_exception"),
                String(
                    "a query-string parameter other than refresh, pretty,"
                    " human and error_trace is not supported; send it in the"
                    " request body"
                ),
                400,
            )
        if body_too_large(len(req.body), self._cfg.max_body_bytes):
            return self._error_response(
                String("content_too_long_exception"),
                String("the request body is longer than ")
                + String(self._cfg.max_body_bytes)
                + String(" bytes"),
                413,
            )
        if is_bulk and count_ndjson_lines(req.body) > self._cfg.max_bulk_lines:
            return self._error_response(
                String("content_too_long_exception"),
                String("the _bulk body has more than ")
                + String(self._cfg.max_bulk_lines)
                + String(" lines"),
                413,
            )
        var index = segs[0].copy()
        if not is_valid_index_name(index):
            return self._error_response(
                String("invalid_index_name_exception"),
                String(
                    "an index name is 1 to 255 bytes of a-z, 0-9, '.', '_' and"
                    " '-', and starts with a letter or digit"
                ),
                400,
            )
        try:
            if is_bulk:
                return self._handle_bulk(index, req.body)
            return self._handle_search(index, req.body)
        except e:
            return self._map_error(String(e))

    # -------------------------------------------------------------------------
    # The _bulk handler.
    # -------------------------------------------------------------------------
    def _handle_bulk(
        mut self, index: String, body: List[UInt8]
    ) raises -> HttpResponse:
        """Parse the NDJSON body, build one split of the good documents, write
        the split object, then publish its summary. The response lists every
        item in wire order (201 or 400); a bad item fails alone. A dangling
        action line with no source raises (a 400)."""
        var text_field = self._cfg.text_field.copy()
        var parsed = ndjson_bulk_to_docbatch(Span(body), text_field)
        var count = parsed.count

        if len(parsed.items) == 0:
            return ok_json(
                bulk_response_envelope_items(index, List[BulkItem](), False)
            )

        var items = parsed.items.copy()
        var any_error = parsed.any_error

        # Every item failed: answer 200 with errors:true and publish nothing.
        if count == 0:
            return ok_json(bulk_response_envelope_items(index, items, any_error))

        var docbatch = parsed.take_docbatch()
        var split_uuid = self._next_split_uuid()

        # The sink's first argument is a name it only stores; the object key is
        # built from the prefix, the index and the uuid.
        var sink = SearchSink(
            String(""),
            self._cfg.key_prefix.copy(),
            index.copy(),
            text_field.copy(),
            split_uuid.copy(),
            String(SOURCE_FIELD),
        )
        sink.init_sink(docbatch.schema)
        sink.accept_batch(docbatch^)
        sink.finish()
        var split_bytes = sink.take_split_bytes()
        var object_key = sink.object_key()

        var summary = make_split_summary(
            split_uuid.copy(),
            Int64(count),
            Int64(len(split_bytes)),
            Int64(0),
            Int64(count - 1),
            index.copy(),
            text_field.copy(),
            object_key.copy(),
        )

        # (1) the split object FIRST: if the process dies or the next step
        # fails, the object is unreferenced and harmless.
        try:
            _ = self._store.put(Path.parse(object_key), split_bytes)
        except e:
            raise self._store_fault(String("writing the split object"), e)
        # (2) the catalog append SECOND: from here on the split is searchable.
        try:
            var metastore = self._new_write_metastore(index)
            _ = metastore.publish(summary^)
        except e:
            raise self._store_fault(String("publishing the split"), e)

        return ok_json(bulk_response_envelope_items(index, items, any_error))

    # -------------------------------------------------------------------------
    # The _search handler.
    # -------------------------------------------------------------------------
    def _read_split(mut self, summary: SplitSummary) raises -> List[UInt8]:
        try:
            return self._store.get(Path.parse(summary.object_key))
        except e:
            raise self._store_fault(String("reading a split object"), e)

    def _parse_split(mut self, var bytes: List[UInt8]) raises -> SplitView:
        try:
            return SplitView.parse(bytes^)
        except e:
            raise self._store_fault(String("reading a split object"), e)

    def _open_core(mut self, var view: SplitView) raises -> SearchCore:
        try:
            return SearchCore.from_view(view^)
        except e:
            raise self._store_fault(String("opening a split object"), e)

    def _handle_search(
        mut self, index: String, body: List[UInt8]
    ) raises -> HttpResponse:
        """Parse the request, resolve the live splits, gate the filter, sort
        and aggregations against the first split's fast fields, search every
        split, merge, and render the hits envelope. An index with no live
        split answers like an empty one."""
        # The body is parsed before the store is touched, so a malformed
        # request costs no store round trip. The generation is stamped below.
        var query = search_json_to_queryir(
            Span(body), Int64(0), self._cfg.text_field
        )
        var track_total = parse_track_total_hits(Span(body))
        var sorted_by_score = sort_is_by_score(query)

        var meta_prefix = self._index_meta_prefix(index)
        var splits: List[SplitSummary]
        try:
            query.generation = generation_across_shards(
                self._store, meta_prefix, index
            )
            splits = list_live_splits_across_shards(
                self._store, meta_prefix, index
            )
        except e:
            raise self._store_fault(String("reading the catalog"), e)

        var n_splits = len(splits)
        if n_splits == 0:
            return ok_json(
                empty_hits_envelope(index, AggResults(), query.has_aggs())
            )
        if n_splits > self._cfg.max_splits_per_search:
            self._fault = _FAULT_TOO_MANY_SPLITS
            raise Error(
                String("the index has ")
                + String(n_splits)
                + String(" live splits; at most ")
                + String(self._cfg.max_splits_per_search)
                + String(" are searched at once")
            )

        var has_aggs = query.has_aggs()
        var needs_sort_gate = (
            not sorted_by_score and query.sort_field != SORT_FIELD_DOC
        )

        var base_from = query.from_offset
        var base_size = query.top_k
        var base_mode = SORT_MODE_SCORE
        if query.sort_field == SORT_FIELD_DOC:
            base_mode = SORT_MODE_DOC

        # The first split's bytes are read up front: the gates run on its fast
        # fields (the fast-field set is the same in every split of an index).
        # Each later split is read when its turn comes and freed after its
        # search, so one request holds one split's bytes at a time.
        var first_bytes = self._read_split(splits[0])
        if query.has_filter() or needs_sort_gate or has_aggs:
            var gate_view = self._parse_split(first_bytes.copy())
            var gate_reader = FastFieldReader(gate_view)
            if query.has_filter():
                query = gate_filter_against_fastfields(query^, gate_reader)
            query = gate_sort_against_fastfields(query^, gate_reader)
            if has_aggs:
                query = gate_aggs_against_fastfields(query^, gate_reader)

        # Every split is over-fetched to from+size and the merge applies the
        # single global skip. Per-terms bucket sizes are widened so a term that
        # is globally significant is not dropped before the merge. The shared
        # filter is never written through; this is a copy.
        var leaf_query = query.copy()
        leaf_query.from_offset = 0
        leaf_query.top_k = base_from + base_size
        if has_aggs:
            leaf_query.rewrite_terms_bucket_sizes(shard_size_for(base_size))

        var results = Slab[SearchResult].create(n_splits)
        var split_short_ids = List[String]()
        for i in range(n_splits):
            split_short_ids.append(_split_short_id(splits[i]))
            var split_bytes = List[UInt8]()
            if i == 0:
                swap(first_bytes, split_bytes)
            else:
                split_bytes = self._read_split(splits[i])
            # Each split's own footer picks its reader: a split with an L0
            # posting slot (the cheap drain format) is probed by
            # `search_l0_split`, any other by `SearchCore`. Both return the
            # same result shape, so a mixed set merges.
            # A split that does not parse is a damaged object (500). An error
            # from the search itself is not wrapped: the query was gated, and
            # the engine also refuses a request that does not fit the split.
            var split_view = self._parse_split(split_bytes^)
            if split_view.has_l0_posting():
                results.append(search_l0_split(split_view, leaf_query))
            else:
                var core = self._open_core(split_view^)
                results.append(core.search(leaf_query))

        var merged_aggs = AggResults()
        if has_aggs:
            merged_aggs = merge_agg_results(results, query.aggs_ref())
        var merged = merge_search_results(
            results^,
            base_from,
            base_size,
            base_mode,
            query.sort_order,
            query.missing_order,
        )

        # With several splits a hit's `_id` is `<split-uuid>_<doc_id>`, since
        # doc ids restart at 0 in every split; with one it is the bare doc id.
        var client_ids = List[String]()
        if n_splits > 1:
            ref page_ids = merged.hit_split_index
            var page_n = merged.result.batch.num_rows()
            for row in range(page_n):
                var doc_id = Int64(
                    merged.result.batch.column_at(1)
                    .as_primitive[DType.int64]()
                    .get(row)
                )
                client_ids.append(
                    split_short_ids[page_ids[row]]
                    + String("_")
                    + String(doc_id)
                )

        var resp = hitbatch_to_hits_envelope(
            merged.result.batch,
            index,
            client_ids,
            merged.result.total_matches,
            track_total,
            sorted_by_score,
            merged_aggs^,
            has_aggs,
            n_splits,  # shards_total
            n_splits,  # shards_successful: all or nothing
            0,  # shards_failed
        )
        return ok_json(resp^)

    # -------------------------------------------------------------------------
    # Error mapping.
    # -------------------------------------------------------------------------
    def _error_response(
        self, error_type: String, reason: String, status: Int
    ) -> HttpResponse:
        """Build a JSON error response. `error_envelope` only raises on a
        non-object tree, so the fallback is unreachable; it keeps this call
        non-raising."""
        try:
            var body = error_envelope(error_type, reason, status)
            return json_response(body^, Int32(status))
        except:
            return json_response(
                String(
                    '{"error":{"type":"internal_error","reason":"envelope'
                    ' build failed"},"status":500}'
                ),
                Int32(500),
            )

    def _map_error(self, msg: String) -> HttpResponse:
        """A store fault is 500 with a fixed reason (the store's own message is
        not sent), a refused split count 503, anything else (a parse, gate or
        engine refusal of the request) 400."""
        if self._fault == _FAULT_STORE:
            return self._error_response(
                String("internal_error"),
                String("the search store failed while ") + self._fault_what,
                500,
            )
        if self._fault == _FAULT_TOO_MANY_SPLITS:
            return self._error_response(
                String("search_unavailable_exception"), msg, 503
            )
        return self._error_response(String("parse_exception"), msg, 400)
