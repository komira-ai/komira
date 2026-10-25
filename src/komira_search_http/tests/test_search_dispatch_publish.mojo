# =============================================================================
# test_search_dispatch_publish.mojo: how `_bulk` writes a split, and how it fails
# =============================================================================
#
# The store under the dispatcher is `_RecStore`: the shared in-memory store with
# a log of every write verb and path, and switches that make a `put`, a
# catalog write or a split read fail.
#
#   * order: the split object is `put` BEFORE the first catalog write of the
#     request. A dispatcher that published first would log a catalog write
#     ahead of the `put` and fail the test.
#   * a `put` that fails: the response is 500, no catalog write was tried, the
#     index stays empty.
#   * a catalog write that fails: the response is 500, the split object exists
#     but nothing references it, the index stays empty.
#   * a split read that fails during `_search`: 500, and the store's own text
#     is not sent to the client.
#   * split keys: the key embeds discriminant, install-time epoch and sequence,
#     so a dispatcher started again with a later epoch (a restart, whose
#     sequence begins at 1 again) and a second worker of one process each get
#     keys of their own, and a dispatcher built with the default epoch reads
#     the wall clock.
#   * an L0 split (the cheap drain format) in the catalog is searched by the
#     L0 reader, alone and mixed with a split `_bulk` wrote.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse

from komira_log_index import L0SegmentBuilder

from komira_objectstore import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_search_catalog import (
    SearchMetastore,
    make_split_summary,
    shard_manifest_prefix,
)
from komira_search_http import SearchHttpConfig, SearchHttpDispatcher

comptime _Rt = BlockingRuntime[NoopSink]
comptime Inner = SharedInMemoryConditionalStore


struct _RecStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """The in-memory store plus an ordered log of its write verbs
    (`put <path>`, `cas <path>`) and failure switches."""

    var _inner: Inner
    var _log: ArcPointer[List[String]]
    var _fail_put: Bool
    var _fail_cas: Bool
    var _fail_split_get: Bool

    def __init__(
        out self,
        var inner: Inner,
        var log: ArcPointer[List[String]],
        fail_put: Bool = False,
        fail_cas: Bool = False,
        fail_split_get: Bool = False,
    ):
        self._inner = inner^
        self._log = log^
        self._fail_put = fail_put
        self._fail_cas = fail_cas
        self._fail_split_get = fail_split_get

    def clone(self) -> Self:
        return Self(
            self._inner.clone(),
            self._log.copy(),
            self._fail_put,
            self._fail_cas,
            self._fail_split_get,
        )

    def _note(self, verb: String, path: Path):
        self._log[].append(verb + String(" ") + path.raw())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._note(String("cas"), path)
        if self._fail_cas:
            raise Error("injected catalog write failure SECRET-DETAIL")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._note(String("cas"), path)
        if self._fail_cas:
            raise Error("injected catalog write failure SECRET-DETAIL")
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._note(String("put"), path)
        if self._fail_put:
            raise Error("injected put failure SECRET-DETAIL")
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if self._fail_split_get and path.raw().endswith(".split"):
            raise Error("injected split read failure SECRET-DETAIL")
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text(r: HttpResponse) -> String:
    return String(unsafe_from_utf8=Span(r.body))


def _post(
    mut d: SearchHttpDispatcher[_RecStore], path: String, body: String
) raises -> HttpResponse:
    var reactor = _new_reactor()
    var req = HttpRequest(HttpMethod.post(), path.copy())
    req.body = _bytes(body)
    return d.dispatch[_Rt](reactor, req^)


def _dispatcher(
    inner: Inner,
    log: ArcPointer[List[String]],
    worker: Int = 0,
    epoch_us: Int64 = Int64(1000),
    text_field: String = "body",
    fail_put: Bool = False,
    fail_cas: Bool = False,
    fail_split_get: Bool = False,
) raises -> SearchHttpDispatcher[_RecStore]:
    return SearchHttpDispatcher[_RecStore](
        SearchHttpConfig(
            String("catalog"), String("data"), text_field.copy(), String("n")
        ),
        _RecStore(inner.clone(), log.copy(), fail_put, fail_cas, fail_split_get),
        worker,
        epoch_us,
    )


def _two_docs() -> String:
    return String(
        '{"index":{}}\n{"body":"the quick brown fox"}\n'
        '{"index":{}}\n{"body":"a lazy dog sleeps"}\n'
    )


def _search_fox() -> String:
    return String('{"query":{"match":{"body":"fox"}}}')


def _events(log: ArcPointer[List[String]]) -> List[String]:
    return log[].copy()


def _first_index(events: List[String], infix: String, prefix: String = "") -> Int:
    for i in range(len(events)):
        if events[i].find(infix) >= 0 and events[i].startswith(prefix):
            return i
    return -1


def _split_keys(inner: Inner) raises -> List[String]:
    var out = List[String]()
    var listed = inner.list_with_delimiter(Path.parse("data/"))
    for i in range(len(listed.objects)):
        out.append(listed.objects[i].location.copy())
    return out^


def test_split_is_put_before_the_catalog_is_written() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var d = _dispatcher(inner, log)
    var r = _post(d, String("/docs/_bulk"), _two_docs())
    assert_equal(r.status, Int32(200))
    var ev = _events(log)
    var put_at = _first_index(ev, String(".split"), String("put "))
    var meta_at = _first_index(ev, String("catalog/docs/meta/"))
    assert_true(put_at >= 0, "the split object was put")
    assert_true(meta_at >= 0, "the catalog was written")
    assert_true(put_at < meta_at, "the put comes before the first catalog write")
    # One split put, and nothing but that put before the catalog.
    var puts = 0
    for i in range(len(ev)):
        if ev[i].startswith("put ") and ev[i].find(".split") >= 0:
            puts += 1
    assert_equal(puts, 1)
    assert_equal(put_at, 0)
    # The catalog write lands in this dispatcher's own sub-lineage.
    assert_true(
        ev[meta_at].find("catalog/docs/meta/_lineage/" + d.shard_id()) >= 0
    )
    assert_true(ev[put_at].find("data/docs/splits/") >= 0)


def test_failed_put_publishes_nothing() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var d = _dispatcher(inner, log, fail_put=True)
    var r = _post(d, String("/docs/_bulk"), _two_docs())
    assert_equal(r.status, Int32(500))
    var t = _text(r)
    assert_true(t.find('"type":"internal_error"') >= 0)
    assert_true(t.find("writing the split object") >= 0)
    assert_false(t.find("SECRET-DETAIL") >= 0, "the store's text stays server-side")
    var ev = _events(log)
    assert_equal(_first_index(ev, String("catalog/")), -1)
    assert_equal(len(_split_keys(inner)), 0)
    # A reader sees an empty index.
    var reader = _dispatcher(inner, log)
    r = _post(reader, String("/docs/_search"), _search_fox())
    assert_equal(r.status, Int32(200))
    assert_true(_text(r).find('"total":{"value":0') >= 0)


def test_failed_publish_leaves_only_an_unreferenced_object() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var d = _dispatcher(inner, log, fail_cas=True)
    var r = _post(d, String("/docs/_bulk"), _two_docs())
    assert_equal(r.status, Int32(500))
    var t = _text(r)
    assert_true(t.find("publishing the split") >= 0)
    assert_false(t.find("SECRET-DETAIL") >= 0)
    var ev = _events(log)
    assert_true(_first_index(ev, String(".split"), String("put ")) >= 0)
    # The object is there, no catalog chunk is.
    var keys = _split_keys(inner)
    assert_equal(len(keys), 1)
    assert_true(keys[0].endswith(".split"))
    # Nothing references it: the index answers empty.
    var reader = _dispatcher(inner, log)
    r = _post(reader, String("/docs/_search"), _search_fox())
    assert_equal(r.status, Int32(200))
    assert_true(_text(r).find('"total":{"value":0') >= 0)


def test_failed_split_read_is_500_without_the_store_text() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var w = _dispatcher(inner, log)
    _ = _post(w, String("/docs/_bulk"), _two_docs())
    var d = _dispatcher(inner, log, 1, 2000, fail_split_get=True)
    var r = _post(d, String("/docs/_search"), _search_fox())
    assert_equal(r.status, Int32(500))
    var t = _text(r)
    assert_true(t.find('"type":"internal_error"') >= 0)
    assert_true(t.find("reading a split object") >= 0)
    assert_false(t.find("SECRET-DETAIL") >= 0)
    # A request error stays a 400 on the same dispatcher.
    r = _post(d, String("/docs/_search"), String("{bad"))
    assert_equal(r.status, Int32(400))


def test_first_split_key_is_discriminant_epoch_sequence() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var d = _dispatcher(inner, log, 0, Int64(1000))
    _ = _post(d, String("/docs/_bulk"), _two_docs())
    _ = _post(d, String("/docs/_bulk"), _two_docs())
    var keys = _split_keys(inner)
    assert_equal(len(keys), 2)
    # worker 0, epoch 1000 us (0xe8 0x03), sequence 1 and 2
    assert_equal(
        keys[0], String("data/docs/splits/00e80300000000000100000000000000.split")
    )
    assert_equal(
        keys[1], String("data/docs/splits/00e80300000000000200000000000000.split")
    )


def test_restart_and_second_worker_mint_new_keys() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var first = _dispatcher(inner, log, 0, Int64(1000))
    _ = _post(first, String("/docs/_bulk"), _two_docs())
    # The process restarts: a new dispatcher, sequence 1 again, later epoch.
    var restarted = _dispatcher(inner, log, 0, Int64(2_000_000))
    _ = _post(restarted, String("/docs/_bulk"), _two_docs())
    # A second worker of the restarted process, same epoch, sequence 1.
    var worker = _dispatcher(inner, log, 1, Int64(2_000_000))
    _ = _post(worker, String("/docs/_bulk"), _two_docs())
    var keys = _split_keys(inner)
    assert_equal(len(keys), 3)
    assert_true(keys[0] != keys[1])
    assert_true(keys[0] != keys[2])
    assert_true(keys[1] != keys[2])
    # All three splits are live and none overwrote another.
    var r = _post(worker, String("/docs/_search"), _search_fox())
    assert_true(_text(r).find('"total":{"value":3') >= 0)
    assert_true(_text(r).find('"_shards":{"total":3') >= 0)


def test_default_epoch_reads_the_wall_clock() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var d = _dispatcher(inner, log, 0, Int64(-1))
    _ = _post(d, String("/docs/_bulk"), _two_docs())
    var keys = _split_keys(inner)
    assert_equal(len(keys), 1)
    var key = keys[0].copy()
    # data/docs/splits/ = 17 bytes; bytes 1..7 of the uuid are hex digits 2..15
    var hex = String(key[byte = 17 : 49])
    var epoch_hex = String(hex[byte = 2 : 16])
    assert_true(epoch_hex != String("00000000000000"))
    assert_equal(String(hex[byte = 16 : 18]), String("01"))


def _l0_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("message"), ArrowType.STRING, False))
    sb.add_field(Field(String("_source"), ArrowType.STRING, False))
    return sb.build()


def _publish_l0_split(inner: Inner, messages: List[String]) raises:
    var sources = List[String]()
    for i in range(len(messages)):
        sources.append(String('{"message":"') + messages[i] + String('"}'))
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(messages)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    var batch = rb.build(_l0_schema())
    var seg = L0SegmentBuilder(_l0_schema())
    seg.add_batch(batch^)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(7))
    var bytes = seg.serialize_split_bytes(String("message"), uuid)
    var key = String("data/logs/splits/07070707070707070707070707070707.split")
    _ = inner.put(Path.parse(key), bytes)
    var manifest = CasManifestStore[Inner](
        inner.clone(),
        shard_manifest_prefix(String("catalog/logs/meta"), String("ext-1-0")),
        RetryPolicy.default(),
    )
    var meta = SearchMetastore[Inner](manifest^, String("logs"))
    _ = meta.publish(
        make_split_summary(
            uuid.copy(),
            Int64(len(messages)),
            Int64(len(bytes)),
            Int64(0),
            Int64(len(messages) - 1),
            String("logs"),
            String("message"),
            key,
        )
    )


def test_l0_split_is_searched_alone_and_mixed() raises:
    var inner = Inner()
    var log = ArcPointer[List[String]](List[String]())
    var msgs = List[String]()
    msgs.append(String("alpha beta gamma"))
    msgs.append(String("delta epsilon"))
    msgs.append(String("alpha again"))
    _publish_l0_split(inner, msgs)
    var d = _dispatcher(inner, log, 0, Int64(1000), String("message"))
    var q = String('{"query":{"match":{"message":"alpha"}}}')
    var r = _post(d, String("/logs/_search"), q)
    assert_equal(r.status, Int32(200))
    var t = _text(r)
    assert_true(t.find('"total":{"value":2,"relation":"eq"}') >= 0)
    assert_true(t.find("alpha beta gamma") >= 0)
    assert_true(t.find("alpha again") >= 0)
    assert_false(t.find("delta") >= 0)
    # An L0 split next to a split the dispatcher wrote: both are searched and
    # merged, the ids are namespaced.
    r = _post(
        d,
        String("/logs/_bulk"),
        String('{"index":{}}\n{"message":"alpha from bulk"}\n'),
    )
    assert_equal(r.status, Int32(200))
    r = _post(d, String("/logs/_search"), q)
    t = _text(r)
    assert_true(t.find('"total":{"value":3,"relation":"eq"}') >= 0)
    assert_true(t.find('"_shards":{"total":2,"successful":2') >= 0)
    assert_true(t.find("alpha from bulk") >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
