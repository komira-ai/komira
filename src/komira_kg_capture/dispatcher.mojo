# =============================================================================
# dispatcher -- the capture server's request handler.
# =============================================================================
#
# `CaptureDispatcher` is a `komira_http_server` `RequestDispatcher` over one
# snapshot store. Its routes:
#
#   GET  /health             open; answers 200 without touching the store.
#   POST /capture            the body is one raw record. `?surface=<tag>` names
#                            the adapter registered under that tag, which parses
#                            and lowers the record to episodes; each is ingested
#                            (`ingest_episode_into`). `?partition=<id>` names the
#                            partition, else the default. A tag nobody registered
#                            is refused (422) and no adapter runs.
#   POST /ingest-structured  known entities and edges as JSON (see
#                            `structured`); ingested with no extraction.
#   POST /query              the subgraph around what a text matches in one
#                            partition, optionally with a model's answer (see
#                            `query_spec`, `query_build`, `query_synthesis`).
#   POST /query-federated    the same over a list of partitions, merged and
#                            ranked together.
#   (anything else)          a `CaptureRoutes` conformer the host gave the
#                            server, over the loaded working set.
#
# EVERY ROUTE BUT /health NEEDS `Authorization: Bearer <token>`, the token the
# host gave the server. The check is the first thing done after health, so an
# unauthenticated request learns nothing: not which routes exist, not whether a
# tag is registered. Then the body size is checked against the configured limit.
#
# TIME. The server's clock is an argument. It is read once per request that
# writes or reaches a host route, and the reading is the ingest time of every
# episode the request writes (the adapters' own `ts` is replaced: ingest time is
# the server's), the default event time of a structured body that names none, and
# the time a compaction fold marks retired chunks with.
#
# THE GRAPH. The merged working set is kept warm between requests
# (`WarmMergedCache`): a write takes it, ingests into it in place, folds the
# delta chain when it has reached `compact_after_deltas`, and puts it back keyed
# at the new head. A write that fails part way drops the set, so the next request
# merges the stored state again. The server is the single writer of its store
# handle; another writer's delta is picked up on the next request.
#
# ERRORS never carry the text of a lower-level error: a failure of the adapter,
# the ingest or a host route is a fixed message, so nothing about the store, a
# path or a model endpoint leaves the process. A malformed body is described
# because the description is about the caller's own bytes.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_json import JsonValue
from komira_kg import (
    Embedder,
    EpisodeInput,
    IngestConfig,
    LlmClient,
    SnapshotWorkingSet,
    StructuredEpisode,
    WarmMergedCache,
    ingest_episode_into,
    ingest_structured_into,
    maybe_compact_chain,
)
from komira_kg_format import CompactionPolicy, KgQueryResult, KgSnapshotStore
from komira_kg_sources import AdapterRegistry
from komira_objectstore.store import CloneableConditionalWriteStore

from .clock import CaptureClock
from .http_util import (
    bearer_matches,
    check_label,
    check_token,
    error_response,
    json_response,
    query_value,
)
from .query_build import build_query_result
from .query_config import QueryConfig
from .query_spec import QuerySpec, parse_query_request
from .query_synthesis import synthesize_answer
from .routes import CaptureRoutes
from .structured import StructuredRequest, parse_structured_request

comptime ROUTE_HEALTH: String = "/health"
comptime ROUTE_CAPTURE: String = "/capture"
comptime ROUTE_INGEST_STRUCTURED: String = "/ingest-structured"
comptime ROUTE_QUERY: String = "/query"
comptime ROUTE_QUERY_FEDERATED: String = "/query-federated"


struct CaptureConfig(Copyable, Movable):
    """What the host decides about one capture server. Nothing has a default.

    Fields:
        token: The bearer token every route but health requires.
        default_partition: The partition a request that names none writes to.
        max_body_bytes: The largest request body accepted; a larger one is
            refused with 413 before it is read.
        compact_after_deltas: Fold the delta chain into a new base once it holds
            this many deltas (at least 1).
        ingest: The knobs of one ingest.
    """

    var token: String
    var default_partition: String
    var max_body_bytes: Int
    var compact_after_deltas: Int
    var ingest: IngestConfig

    def __init__(
        out self,
        var token: String,
        var default_partition: String,
        max_body_bytes: Int,
        compact_after_deltas: Int,
        var ingest: IngestConfig,
    ) raises:
        """A checked configuration.

        Raises:
            If the token is empty, over 4096 bytes or not visible ASCII; the
            default partition is empty, over 256 bytes or holds a control byte;
            the body limit or the fold threshold is below 1; or the ingest knobs
            are refused by `IngestConfig.check`.
        """
        check_token(token)
        check_label("default_partition", default_partition)
        if max_body_bytes < 1:
            raise Error("max_body_bytes must be at least 1")
        if compact_after_deltas < 1:
            raise Error("compact_after_deltas must be at least 1")
        ingest.check()
        self.token = token^
        self.default_partition = default_partition^
        self.max_body_bytes = max_body_bytes
        self.compact_after_deltas = compact_after_deltas
        self.ingest = ingest^


struct _Counts(Movable):
    var entities_before: Int
    var edges_before: Int
    var entities_after: Int
    var edges_after: Int
    var snapshot_id: Int64

    def __init__(
        out self,
        entities_before: Int,
        edges_before: Int,
        entities_after: Int,
        edges_after: Int,
        snapshot_id: Int64,
    ):
        self.entities_before = entities_before
        self.edges_before = edges_before
        self.entities_after = entities_after
        self.edges_after = edges_after
        self.snapshot_id = snapshot_id

    def write_into(self, mut out: JsonValue) raises:
        out.set_member("entities_total", JsonValue.from_i64(Int64(self.entities_after)))
        out.set_member("edges_total", JsonValue.from_i64(Int64(self.edges_after)))
        out.set_member(
            "entities_added",
            JsonValue.from_i64(Int64(self.entities_after - self.entities_before)),
        )
        out.set_member(
            "edges_added",
            JsonValue.from_i64(Int64(self.edges_after - self.edges_before)),
        )
        out.set_member("snapshot_id", JsonValue.from_i64(self.snapshot_id))


def _not_allowed(allow: String) -> HttpResponse:
    var r = error_response(Int32(405), String("method not allowed"))
    r.headers[String("allow")] = allow
    return r^


struct CaptureDispatcher[
    Store: CloneableConditionalWriteStore,
    Llm: LlmClient,
    Emb: Embedder,
    Registry: AdapterRegistry,
    Routes: CaptureRoutes,
    Clock: CaptureClock,
](RequestDispatcher):
    """The capture server over one snapshot store.

    Parameters:
        Store: The object store under the snapshot store.
        Llm: The model client the episode ingest extracts with.
        Emb: The embedder.
        Registry: The adapters, by surface tag.
        Routes: The host's extra routes (`NoRoutes` for none).
        Clock: The time source.
    """

    var _store: KgSnapshotStore[Self.Store]
    var _llm: Self.Llm
    var _emb: Self.Emb
    var _registry: Self.Registry
    var _routes: Self.Routes
    var _clock: Self.Clock
    var _cfg: CaptureConfig
    var _query: QueryConfig
    var _warm: WarmMergedCache[Self.Store]

    def __init__(
        out self,
        var store: KgSnapshotStore[Self.Store],
        var llm: Self.Llm,
        var emb: Self.Emb,
        var registry: Self.Registry,
        var routes: Self.Routes,
        var clock: Self.Clock,
        var config: CaptureConfig,
        var query: QueryConfig = QueryConfig.default(),
    ):
        """A server over `store`. It owns every part it is given. `query` holds
        the synthesis prompt and the limits of the query routes; the default is
        neutral."""
        self._store = store^
        self._llm = llm^
        self._emb = emb^
        self._registry = registry^
        self._routes = routes^
        self._clock = clock^
        self._cfg = config^
        self._query = query^
        self._warm = WarmMergedCache[Self.Store]()

    def store_ref(
        ref self,
    ) -> ref [self._store] KgSnapshotStore[Self.Store]:
        """Borrow the snapshot store, to read what the server has written."""
        return self._store

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        """Answer one request. Never raises: an unexpected failure is a 500 with
        a fixed message. The reactor is not used; the handlers do no async I/O
        of their own.
        """
        try:
            return self._route(req^)
        except:
            return error_response(
                Int32(500), String("the request could not be completed")
            )

    def _route(mut self, var req: HttpRequest) raises -> HttpResponse:
        if req.path == ROUTE_HEALTH:
            if not (req.method == HttpMethod.get()):
                return _not_allowed(String("GET"))
            var ok = JsonValue.empty_object()
            ok.set_member("status", JsonValue.from_string("ok"))
            return json_response(Int32(200), ok^)

        if "authorization" not in req.headers or not bearer_matches(
            req.headers["authorization"], self._cfg.token
        ):
            var denied = error_response(
                Int32(401), String("authentication is required")
            )
            denied.headers[String("www-authenticate")] = String("Bearer")
            return denied^
        if len(req.body) > self._cfg.max_body_bytes:
            return error_response(
                Int32(413),
                String("the request body is over ")
                + String(self._cfg.max_body_bytes)
                + " bytes",
            )

        if req.path == ROUTE_CAPTURE:
            if not (req.method == HttpMethod.post()):
                return _not_allowed(String("POST"))
            return self._capture(req^)
        if req.path == ROUTE_INGEST_STRUCTURED:
            if not (req.method == HttpMethod.post()):
                return _not_allowed(String("POST"))
            return self._structured(req^)
        if req.path == ROUTE_QUERY or req.path == ROUTE_QUERY_FEDERATED:
            if not (req.method == HttpMethod.post()):
                return _not_allowed(String("POST"))
            var federated = req.path == ROUTE_QUERY_FEDERATED
            return self._answer_query(req^, federated)
        if self._routes.handles(req.method, req.path):
            return self._extra(req^)
        return error_response(Int32(404), String("no such route"))

    # --- POST /capture -------------------------------------------------------
    def _capture(mut self, var req: HttpRequest) raises -> HttpResponse:
        var surface: String
        var partition: String
        try:
            surface = query_value(req.query_string, "surface")
            partition = query_value(req.query_string, "partition")
        except:
            return error_response(
                Int32(400), String("the query string is malformed")
            )
        if len(surface.as_bytes()) == 0:
            return error_response(
                Int32(400), String("the 'surface' query parameter is required")
            )
        if len(partition.as_bytes()) == 0:
            partition = self._cfg.default_partition.copy()
        try:
            check_label("partition", partition)
        except e:
            return error_response(Int32(400), String(e))
        if len(req.body) == 0:
            return error_response(
                Int32(400), String("the body must hold one record")
            )

        var raw = List[UInt8]()
        swap(raw, req.body)
        var lowered: Optional[List[EpisodeInput]]
        try:
            lowered = self._registry.lower_raw(surface, raw, partition)
        except:
            return error_response(
                Int32(400),
                String("the adapter for this surface could not read the record"),
            )
        if not lowered:
            return error_response(
                Int32(422),
                String("no adapter is registered for this surface"),
            )
        var episodes = lowered.take()
        if len(episodes) == 0:
            return error_response(
                Int32(422), String("the record lowered to no episodes")
            )

        var now = self._clock.now_ms()
        for i in range(len(episodes)):
            episodes[i].ts = now
        var counts = self._ingest_episodes(episodes, now)

        var out = JsonValue.empty_object()
        out.set_member("surface", JsonValue.from_string(surface))
        out.set_member("partition_id", JsonValue.from_string(partition))
        out.set_member(
            "episodes_ingested", JsonValue.from_i64(Int64(len(episodes)))
        )
        counts.write_into(out)
        return json_response(Int32(200), out^)

    def _ingest_episodes(
        mut self, episodes: List[EpisodeInput], now: Int64
    ) raises -> _Counts:
        var ws = self._warm.take_current(self._store, self._emb.dimension())
        var entities_before = ws.num_entities()
        var edges_before = ws.num_edges()
        for i in range(len(episodes)):
            _ = ingest_episode_into(
                self._store,
                ws,
                episodes[i],
                self._llm,
                self._emb,
                self._cfg.ingest,
            )
        return self._finish(ws^, entities_before, edges_before, now)

    # --- POST /ingest-structured ---------------------------------------------
    def _structured(mut self, var req: HttpRequest) raises -> HttpResponse:
        var body = List[UInt8]()
        swap(body, req.body)
        if len(body) == 0:
            return error_response(
                Int32(400), String("the body must hold a JSON object")
            )
        var parsed: StructuredRequest
        try:
            parsed = parse_structured_request(body)
        except e:
            return error_response(
                Int32(400), String("malformed body: ") + String(e)
            )

        var partition: String
        try:
            partition = query_value(req.query_string, "partition")
        except:
            return error_response(
                Int32(400), String("the query string is malformed")
            )
        if len(partition.as_bytes()) == 0:
            partition = parsed.partition_id.copy()
        if len(partition.as_bytes()) == 0:
            partition = self._cfg.default_partition.copy()
        try:
            check_label("partition", partition)
            check_label("uuid", parsed.uuid)
        except e:
            return error_response(Int32(400), String(e))

        var now = self._clock.now_ms()
        var valid_at = parsed.valid_at.or_else(now)
        var episode = StructuredEpisode(
            parsed.uuid.copy(),
            partition.copy(),
            parsed.take_extraction(),
            now,
            valid_at,
            parsed.note.copy(),
            parsed.source.copy(),
            parsed.facet.copy(),
            parsed.facet_source.copy(),
        )
        var ws = self._warm.take_current(self._store, self._emb.dimension())
        var entities_before = ws.num_entities()
        var edges_before = ws.num_edges()
        _ = ingest_structured_into(
            self._store, ws, episode^, self._llm, self._emb, self._cfg.ingest
        )
        var counts = self._finish(ws^, entities_before, edges_before, now)

        var out = JsonValue.empty_object()
        out.set_member("mode", JsonValue.from_string("structured"))
        out.set_member("partition_id", JsonValue.from_string(partition))
        out.set_member(
            "entities_supplied", JsonValue.from_i64(Int64(parsed.num_entities))
        )
        out.set_member(
            "edges_supplied", JsonValue.from_i64(Int64(parsed.num_edges))
        )
        counts.write_into(out)
        return json_response(Int32(200), out^)

    # --- the shared tail of a write ------------------------------------------
    def _finish(
        mut self,
        var ws: SnapshotWorkingSet,
        entities_before: Int,
        edges_before: Int,
        now: Int64,
    ) raises -> _Counts:
        """Fold the chain if it is long enough, then put the set back keyed at
        the head the write left."""
        var head = self._store.latest_snapshot_id()
        if head >= Int64(0):
            var chain = self._store.resolve_head_chain()
            if chain.num_deltas() >= self._cfg.compact_after_deltas:
                _ = maybe_compact_chain(
                    self._store,
                    CompactionPolicy(
                        self._cfg.compact_after_deltas, Int64(1), Int64(0)
                    ),
                    now,
                )
                head = self._store.latest_snapshot_id()
        var counts = _Counts(
            entities_before,
            edges_before,
            ws.num_entities(),
            ws.num_edges(),
            head,
        )
        self._warm.commit(ws^, head)
        return counts^

    # --- host routes ---------------------------------------------------------
    def _extra(mut self, var req: HttpRequest) raises -> HttpResponse:
        var now = self._clock.now_ms()
        if self._store.latest_snapshot_id() < Int64(0):
            var empty = SnapshotWorkingSet(self._emb.dimension())
            return self._routes.handle(req^, empty, now)
        self._warm.refresh(self._store)
        return self._routes.handle(req^, self._warm.get(), now)

    # --- POST /query and POST /query-federated -------------------------------
    def _answer_query(
        mut self, var req: HttpRequest, federated: Bool
    ) raises -> HttpResponse:
        var spec: QuerySpec
        try:
            spec = parse_query_request(
                req.body,
                req.query_string,
                federated,
                self._cfg.default_partition,
                self._query,
            )
        except e:
            return error_response(
                Int32(400), String("malformed query: ") + String(e)
            )
        if len(spec.text.as_bytes()) > self._query.max_query_bytes:
            return error_response(
                Int32(413),
                String("the query text is over ")
                + String(self._query.max_query_bytes)
                + " bytes",
            )

        var has_model = self._llm.has_synthesis()
        var ask = has_model
        if spec.synthesize:
            ask = spec.synthesize.value()
            if ask and not has_model:
                return error_response(
                    Int32(501), String("this server has no model to answer with")
                )

        var result: KgQueryResult
        if self._store.latest_snapshot_id() < Int64(0):
            var empty = SnapshotWorkingSet(self._emb.dimension())
            result = build_query_result(self._emb, empty, spec, self._query)
        else:
            self._warm.refresh(self._store)
            result = build_query_result(
                self._emb, self._warm.get(), spec, self._query
            )
        if ask:
            try:
                result.set_answer(
                    synthesize_answer(
                        self._llm,
                        result,
                        spec.text,
                        self._query.synthesis_prompt,
                    )
                )
            except:
                return error_response(
                    Int32(502), String("the model could not answer")
                )

        var out = HttpResponse(status=Int32(200))
        out.body.extend(result.serialize().as_bytes())
        out.headers[String("content-type")] = String("application/json")
        out.headers[String("content-length")] = String(len(out.body))
        return out^
