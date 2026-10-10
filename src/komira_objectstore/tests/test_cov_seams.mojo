# =============================================================================
# tests/test_cov_seams.mojo
#   The small seams of komira_objectstore that no other test of this package
#   reaches: the presign TTL bounds and percent-encoder, the RequestCore
#   skeleton, the store-readiness predicate, the latency-injecting store,
#   the shared in-memory store's counters, and the value types' refusals.
# =============================================================================
#
# Each case names the defect it catches:
#   * presign: a TTL bound off by one (0 or 3601 accepted, 1 or 3600
#     refused); a byte >= 0x80 kept or encoded per code point; lowercase hex;
#     `/` encoded in a path or kept in a query value.
#   * readiness: an empty listing read as "not ready", or an error leaking
#     out of the predicate instead of becoming False.
#   * latency store: a verb that skips its delegate, or a body fetch that
#     does not sleep its RTT.
#   * shared store: a counter that counts the wrong verb; get_range reading
#     the wrong window; compare_and_swap not checking the etag.
#   * types: GetRange.bounded / RangeSet.append accepting negative input.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_objectstore.cas_backoff_probe import (
    CAS_BACKOFF_PROBE_MAX_ATTEMPT,
    cas_backoff_counts,
    record_cas_backoff,
    reset_cas_backoff_counts,
)
from komira_objectstore.coalesce import plan_coalesce
from komira_objectstore.objectstore_uri import (
    SCHEME_ABFS,
    SCHEME_AZ,
    SCHEME_FILE,
    SCHEME_GS,
    SCHEME_S3,
    Scheme,
)
from komira_objectstore.path import Path
from komira_objectstore.presign import (
    PRESIGN_MAX_TTL_SECONDS,
    PresignedHeader,
    PresignedUrl,
    check_presign_ttl,
    presign_percent_encode,
)
from komira_objectstore.request_core import RequestCore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_latency_store import (
    SharedInMemoryLatencyStore,
)
from komira_objectstore.store import ObjectStore, ObjectStoreHttpStub
from komira_objectstore.store_readiness import object_store_reachable
from komira_objectstore.sublineage_shard_keys import shard_manifest_prefix
from komira_objectstore.types import (
    CoalescePolicy,
    GetOptions,
    GetRange,
    ListResult,
    ObjectMeta,
    RANGE_FETCH_STATUS_ERROR,
    RANGE_FETCH_STATUS_OK,
    RangeFetchResult,
    RangeSet,
    WritePrecondition,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _err_of_ttl(ttl: Int) -> String:
    try:
        check_presign_ttl(ttl)
        return String("")
    except e:
        return String(e)


# ---- presign -------------------------------------------------------------


def test_presign_ttl_bounds() raises:
    # The two edges are accepted, one past each edge is refused.
    assert_equal(_err_of_ttl(1), String(""))
    assert_equal(_err_of_ttl(PRESIGN_MAX_TTL_SECONDS), String(""))
    var low = _err_of_ttl(0)
    assert_true(low.find("TTL of 0s") >= 0, low)
    assert_true(low.find("already dead") >= 0, low)
    var high = _err_of_ttl(PRESIGN_MAX_TTL_SECONDS + 1)
    assert_true(high.find("TTL of 3601s") >= 0, high)
    assert_true(high.find("caps presigned capabilities at 3600s") >= 0, high)
    assert_true(_err_of_ttl(-5).find("TTL of -5s") >= 0)


def test_presign_percent_encode() raises:
    # Every unreserved class is kept; `/` is kept only for a path.
    assert_equal(
        presign_percent_encode(String("AZaz09-._~/x"), False),
        String("AZaz09-._~/x"),
    )
    assert_equal(
        presign_percent_encode(String("a/b"), True), String("a%2Fb")
    )
    # One escape per UTF-8 octet, uppercase hex: digits and letters both.
    assert_equal(presign_percent_encode(String("é"), True), String("%C3%A9"))
    assert_equal(
        presign_percent_encode(String(" +=?"), False), String("%20%2B%3D%3F")
    )
    # The bytes just outside each unreserved range: @ [ ` { and 0x7F.
    assert_equal(
        presign_percent_encode(String("@[`{\x7f:"), True),
        String("%40%5B%60%7B%7F%3A"),
    )
    assert_equal(presign_percent_encode(String(""), True), String(""))


def test_presigned_url_value() raises:
    var hs = List[PresignedHeader]()
    hs.append(PresignedHeader(String("x-ms-blob-type"), String("BlockBlob")))
    var u = PresignedUrl(
        String("https://h.test/k"), String("PUT"), Int64(42), hs^
    )
    assert_equal(u.url, String("https://h.test/k"))
    assert_equal(u.method, String("PUT"))
    assert_equal(u.expires_unix_seconds, Int64(42))
    assert_equal(len(u.required_headers), 1)
    assert_equal(u.required_headers[0].name, String("x-ms-blob-type"))
    assert_equal(u.required_headers[0].value, String("BlockBlob"))


# ---- RequestCore ---------------------------------------------------------


struct _SizeStub(ObjectStoreHttpStub, Movable, Deinitable):
    var size: Int64

    def __init__(out self, size: Int64):
        self.size = size

    def head_url(mut self, url: String) raises -> Int64:
        if url.byte_length() == 0:
            raise Error("stub: empty url")
        return self.size


def test_request_core_default_policy() raises:
    var core = RequestCore[_SizeStub].with_default_policy(_SizeStub(Int64(7)))
    var d = CoalescePolicy.default()
    assert_equal(core.coalesce_policy.max_gap_bytes, d.max_gap_bytes)
    assert_equal(core.coalesce_policy.max_request_bytes, d.max_request_bytes)
    assert_equal(core.coalesce_policy.max_concurrency, d.max_concurrency)
    assert_equal(d.max_gap_bytes, Int64(1024 * 1024))
    assert_equal(d.max_request_bytes, Int64(8 * 1024 * 1024))
    assert_equal(d.max_concurrency, 8)
    assert_equal(core.http.head_url(String("u")), Int64(7))


# ---- store readiness -----------------------------------------------------


struct _UnreachableStore(ObjectStore, Movable, Deinitable):
    var lists: Int

    def __init__(out self):
        self.lists = 0

    def head(self, path: Path) raises -> ObjectMeta:
        raise Error("unreachable: head")

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        raise Error("PERMISSION_DENIED (403) prefix=" + prefix.raw())

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()


def test_store_readiness() raises:
    # An empty bucket is READY (the probe prefix holds nothing).
    var empty = SharedInMemoryConditionalStore()
    assert_true(object_store_reachable(empty))
    # A listing that raises is NOT READY, and the error does not escape.
    assert_false(object_store_reachable(_UnreachableStore()))
    # Exactly one LIST round-trip per probe.
    assert_equal(empty.n_list(), Int64(1))


# ---- latency store -------------------------------------------------------


def test_latency_store_delegates() raises:
    var s = SharedInMemoryLatencyStore()
    var p = Path.parse(String("a/k"))
    var m = s.put(p, _bytes(String("hello")))
    assert_equal(s.head(p).etag, m.etag)
    assert_equal(s.head(p).size, Int64(5))
    var m2 = s.compare_and_swap(p, _bytes(String("world!")), m.etag)
    assert_true(m2.etag != m.etag)
    var stale = False
    try:
        _ = s.compare_and_swap(p, _bytes(String("x")), m.etag)
    except e:
        stale = String(e).find("precondition") >= 0
    assert_true(stale, "stale CAS through the latency store accepted")
    _ = s.conditional_put(
        Path.parse(String("a/n")), _bytes(String("n")),
        WritePrecondition.if_none_match_star(),
    )
    var lr = s.list_with_delimiter(Path.parse(String("a/")))
    assert_equal(len(lr.objects), 2)
    assert_equal(s.coalesce_policy().max_concurrency, 8)
    # A clone shares the map: a write through one is read through the other.
    var c = s.clone()
    assert_equal(len(c.get(p)), 6)
    assert_equal(len(c.get_range(p, Int64(1), Int64(3))), 3)
    assert_equal(c.get_range(p, Int64(1), Int64(3))[0], UInt8(ord("o")))
    c.delete(p)
    var gone = False
    try:
        _ = s.get(p)
    except e:
        gone = String(e).find("not_found") >= 0
    assert_true(gone, "delete through a clone not seen by the original")
    assert_true(s.inner_ref().n_get() >= Int64(2))


def test_latency_store_sleeps_rtt() raises:
    var fast = SharedInMemoryLatencyStore()
    var p = Path.parse(String("k"))
    _ = fast.put(p, _bytes(String("abcd")))
    # The same map, a 20 ms RTT: every body fetch takes at least that long.
    var slow = fast.with_rtt(0.02)
    var t0 = perf_counter_ns()
    _ = slow.get(p)
    var t1 = perf_counter_ns()
    _ = slow.get_range(p, Int64(0), Int64(2))
    var t2 = perf_counter_ns()
    assert_true(t1 - t0 >= 20_000_000, "get did not sleep its RTT")
    assert_true(t2 - t1 >= 20_000_000, "get_range did not sleep its RTT")
    # The two-argument init carries a supplied inner map and RTT.
    var again = SharedInMemoryLatencyStore(
        inner=fast.inner_ref().clone(), rtt_seconds=0.0
    )
    assert_equal(len(again.get(p)), 4)


# ---- shared in-memory store counters --------------------------------------


def test_shared_store_counters() raises:
    var s = SharedInMemoryConditionalStore()
    var p = Path.parse(String("x/_lineage/s1/k"))
    var m = s.put(p, _bytes(String("0123456789")))
    _ = s.compare_and_swap(p, _bytes(String("abcdefghij")), m.etag)
    var bad = False
    try:
        _ = s.compare_and_swap(p, _bytes(String("z")), m.etag)
    except e:
        bad = String(e).find("etag mismatch") >= 0
    assert_true(bad, "compare_and_swap accepted a stale etag")
    # 3 puts tallied (the refused one too), with every byte offered.
    assert_equal(s.n_put(), Int64(3))
    assert_equal(s.b_put(), Int64(21))
    var r = s.get_range(p, Int64(2), Int64(3))
    assert_equal(len(r), 3)
    assert_equal(r[0], UInt8(ord("c")))
    assert_equal(r[2], UInt8(ord("e")))
    assert_equal(len(s.get_range(p, Int64(0), Int64(0))), 0)
    var oob = False
    try:
        _ = s.get_range(p, Int64(8), Int64(3))
    except e:
        oob = String(e).find("out-of-range") >= 0
    assert_true(oob, "get_range past the end accepted")
    var nf = False
    try:
        _ = s.get_range(Path.parse(String("x/none")), Int64(0), Int64(1))
    except e:
        nf = String(e).find("get_range: not_found") >= 0
    assert_true(nf, "get_range of an absent key did not raise not_found")
    assert_equal(s.n_get_range(), Int64(3))
    _ = s.get(p)
    assert_equal(s.b_get(), Int64(13))
    # One lineage LIST and one root LIST (an empty prefix matches every key).
    _ = s.list_with_delimiter(Path.parse(String("x/_lineage/")))
    var all = s.list_with_delimiter(Path.parse(String("")))
    assert_equal(len(all.objects), 1)
    assert_equal(s.n_list(), Int64(2))
    assert_equal(s.n_list_lineage(), Int64(1))


# ---- value types and planner refusals ---------------------------------------


def test_value_type_refusals() raises:
    var neg = String("")
    try:
        _ = GetRange.bounded(Int64(-1), Int64(4))
    except e:
        neg = String(e)
    assert_equal(neg, String("GetRange.bounded: negative start/end"))
    var neg_end = String("")
    try:
        _ = GetRange.bounded(Int64(0), Int64(-4))
    except e:
        neg_end = String(e)
    assert_equal(neg_end, String("GetRange.bounded: negative start/end"))
    var inv = String("")
    try:
        _ = GetRange.bounded(Int64(5), Int64(4))
    except e:
        inv = String(e)
    assert_equal(inv, String("GetRange.bounded: start > end"))
    # start == end is the empty-but-valid range.
    assert_equal(GetRange.bounded(Int64(4), Int64(4)).bounded_end(), Int64(4))
    var rs = RangeSet.empty()
    var off = String("")
    try:
        rs.append(GetRange.bounded(Int64(0), Int64(1)), -1)
    except e:
        off = String(e)
    assert_equal(off, String("RangeSet.append: dst_offset < 0"))
    assert_equal(rs.num_ranges(), 0)
    rs.append(GetRange.bounded(Int64(0), Int64(1)), 0)
    assert_equal(rs.num_ranges(), 1)


def test_plan_refuses_unknown_tag() raises:
    var rs = RangeSet.empty()
    rs.append(GetRange(UInt8(9), Int64(0), Int64(4)), 0)
    var msg = String("")
    try:
        _ = plan_coalesce(rs, CoalescePolicy.default(), Int64(100))
    except e:
        msg = String(e)
    assert_equal(msg, String("plan_coalesce: unknown GetRange tag"))


def test_value_type_defaults() raises:
    var r = RangeFetchResult.with_capacity(3)
    assert_equal(r.num_ranges(), 3)
    assert_equal(r.status_at(2), RANGE_FETCH_STATUS_OK)
    assert_equal(r.fetched_bytes_at(1), Int64(0))
    r.record(1, RANGE_FETCH_STATUS_ERROR, Int64(9))
    assert_equal(r.status_at(1), RANGE_FETCH_STATUS_ERROR)
    assert_equal(r.fetched_bytes_at(1), Int64(9))
    assert_equal(r.status_at(0), RANGE_FETCH_STATUS_OK)
    assert_equal(r.fetched_bytes_at(2), Int64(0))
    var g = GetOptions.default()
    assert_equal(g.if_match, String(""))
    assert_equal(g.if_none_match, String(""))
    assert_equal(g.if_modified_since_unix_ms, Int64(-1))
    assert_equal(g.if_unmodified_since_unix_ms, Int64(-1))
    assert_equal(g.version, String(""))
    assert_false(Bool(g.range))
    var w = WritePrecondition.if_none_match(String("e1"))
    assert_true(w.is_if_none_match())
    assert_true(w.is_create())
    assert_false(w.is_if_match())
    assert_equal(w.etag, String("e1"))
    var lr = ListResult.empty()
    assert_equal(len(lr.objects), 0)
    assert_equal(len(lr.common_prefixes), 0)


def test_path_prefix_mismatch() raises:
    # Shorter than the prefix: no match.
    assert_false(
        Path.parse(String("a")).prefix_matches(Path.parse(String("a/b")))
    )
    # Same length, one byte differs: no match (last byte and first byte).
    assert_false(
        Path.parse(String("ab")).prefix_matches(Path.parse(String("ac")))
    )
    assert_false(
        Path.parse(String("xb/c")).prefix_matches(Path.parse(String("ab")))
    )
    assert_true(
        Path.parse(String("ab/c")).prefix_matches(Path.parse(String("ab")))
    )


# ---- backoff probe --------------------------------------------------------


def test_backoff_probe_edges() raises:
    reset_cas_backoff_counts()
    # Attempt 0 counts in slot 1; a draw above its bound and a negative draw
    # both count as over-upper; a draw at the bound does not.
    record_cas_backoff(0, Int64(10), Int64(11), Int64(11))
    record_cas_backoff(1, Int64(10), Int64(-1), Int64(0))
    record_cas_backoff(2, Int64(10), Int64(10), Int64(10))
    record_cas_backoff(CAS_BACKOFF_PROBE_MAX_ATTEMPT + 5, Int64(7), Int64(0), Int64(0))
    var c = cas_backoff_counts()
    assert_equal(c.draws_at[0], 2)
    assert_equal(c.upper_sum_at[0], 20)
    assert_equal(c.draws_at[1], 1)
    assert_equal(c.draws_at[CAS_BACKOFF_PROBE_MAX_ATTEMPT - 1], 1)
    assert_equal(c.upper_sum_at[CAS_BACKOFF_PROBE_MAX_ATTEMPT - 1], 7)
    assert_equal(c.draws_over_upper, 2)
    assert_equal(c.drawn_us, 20)
    assert_equal(c.slept_us, 21)
    assert_equal(c.draws(), 4)
    reset_cas_backoff_counts()



def test_names_and_prefixes() raises:
    assert_equal(Scheme(SCHEME_S3).name(), String("s3"))
    assert_equal(Scheme(SCHEME_GS).name(), String("gs"))
    assert_equal(Scheme(SCHEME_AZ).name(), String("az"))
    assert_equal(Scheme(SCHEME_ABFS).name(), String("abfs"))
    assert_equal(Scheme(SCHEME_FILE).name(), String("file"))
    assert_equal(Scheme(UInt8(99)).name(), String("unknown"))
    assert_true(Scheme(SCHEME_GS) == Scheme(SCHEME_GS))
    assert_false(Scheme(SCHEME_GS) == Scheme(SCHEME_AZ))
    assert_equal(Path.parse(String("/a//b/")).__str__(), String("a/b/"))
    assert_equal(
        shard_manifest_prefix(String("idx/meta"), String("w1")),
        String("idx/meta/_lineage/w1"),
    )

def main() raises:
    test_presign_ttl_bounds()
    test_presign_percent_encode()
    test_presigned_url_value()
    test_request_core_default_policy()
    test_store_readiness()
    test_latency_store_delegates()
    test_latency_store_sleeps_rtt()
    test_shared_store_counters()
    test_value_type_refusals()
    test_plan_refuses_unknown_tag()
    test_value_type_defaults()
    test_path_prefix_mismatch()
    test_backoff_probe_edges()
    test_names_and_prefixes()
    print("[test_cov_seams] PASS")
