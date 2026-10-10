# =============================================================================
# tests/test_cov_in_memory_stores.mojo
#   The offline conformers' refusal and fault arms: InMemoryConditionalStore,
#   DelimiterFaithfulConditionalStore and SharedInMemorySlowCasStore.
# =============================================================================
#
# What each case catches:
#   * InMemory / DelimiterFaithful: a create over an existing key, an
#     If-Match on an absent key or with a stale etag that WRITES instead of
#     raising a 412 (and leaves the stored bytes changed); head / list / range
#     reads that return the wrong size, key or window; a root listing that
#     drops keys; a delimiter listing that repeats a common prefix.
#   * DelimiterFaithful lock: a verb that does not wait for a held lock
#     (a reader thread started while the lock is held must see the write
#     made under it, never a torn state).
#   * SlowCas: a poll with nothing in flight that raises or reports READY
#     instead of an ERR; a take before READY that hands out a value; the
#     transport-fault knobs not raising; an If-Match CAS that ignores the
#     etag.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.types import WritePrecondition


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _s(b: List[UInt8]) -> String:
    return String(StringSlice(unsafe_from_utf8=Span(b)))


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


# ---- InMemoryConditionalStore ----------------------------------------------


def _im_err(s: InMemoryConditionalStore, k: String, p: WritePrecondition) -> String:
    try:
        _ = s.conditional_put(Path.parse(k), _b("NEW"), p)
        return String("")
    except e:
        return String(e)


def test_in_memory_store() raises:
    var s = InMemoryConditionalStore()
    var k = Path.parse(String("d/k"))
    var m1 = s.put(k, _b("hello world"))
    _ = s.put(Path.parse(String("d/j")), _b("j"))
    _ = s.put(Path.parse(String("e/x")), _b("x"))
    # head: size + etag of the stored entry.
    var h = s.head(k)
    assert_equal(h.location, String("d/k"))
    assert_equal(h.size, Int64(11))
    assert_equal(h.etag, m1.etag)
    var missing = False
    try:
        _ = s.head(Path.parse(String("d/none")))
    except e:
        missing = String(e).find("not_found") >= 0
    assert_true(missing, "head of an absent key did not raise not_found")
    # list: only keys under the prefix (the prefix shorter than a key, a key
    # shorter than the prefix, and a same-length non-match).
    var lr = s.list_with_delimiter(Path.parse(String("d/")))
    assert_equal(len(lr.objects), 2)
    assert_equal(lr.objects[0].location, String("d/k"))
    assert_equal(lr.objects[0].size, Int64(11))
    assert_equal(lr.objects[0].etag, m1.etag)
    assert_equal(lr.objects[1].location, String("d/j"))
    assert_equal(len(s.list_with_delimiter(Path.parse(String("d/k/longer/x"))).objects), 0)
    assert_equal(len(s.list_with_delimiter(Path.parse(String(""))).objects), 3)
    assert_equal(s.coalesce_policy().max_concurrency, 8)
    # The three 412 arms: none of them may write.
    var c = _im_err(s, String("d/k"), WritePrecondition.if_none_match_star())
    assert_true(c.find("key already exists") >= 0, c)
    var a = _im_err(s, String("d/absent"), WritePrecondition.if_match(String("1")))
    assert_true(a.find("If-Match on absent key") >= 0, a)
    var st = _im_err(s, String("d/k"), WritePrecondition.if_match(String("nope")))
    assert_true(st.find("If-Match etag mismatch") >= 0, st)
    assert_equal(_s(s.get(k)), String("hello world"))
    var absent_written = False
    try:
        _ = s.get(Path.parse(String("d/absent")))
        absent_written = True
    except:
        pass
    assert_false(absent_written, "a refused If-Match created the key")
    # compare_and_swap honours the etag.
    var m2 = s.compare_and_swap(k, _b("0123456789"), m1.etag)
    assert_true(m2.etag != m1.etag)
    assert_equal(_s(s.get(k)), String("0123456789"))
    # get_range: window, empty length, out of range, absent key.
    assert_equal(_s(s.get_range(k, Int64(3), Int64(4))), String("3456"))
    assert_equal(len(s.get_range(k, Int64(3), Int64(0))), 0)
    var oob = False
    try:
        _ = s.get_range(k, Int64(7), Int64(4))
    except e:
        oob = String(e).find("out-of-range") >= 0
    assert_true(oob, "a range past the end was served")
    var neg = False
    try:
        _ = s.get_range(k, Int64(-1), Int64(2))
    except e:
        neg = String(e).find("out-of-range") >= 0
    assert_true(neg, "a negative start was served")
    var nf = False
    try:
        _ = s.get_range(Path.parse(String("zz")), Int64(0), Int64(1))
    except e:
        nf = String(e).find("not_found") >= 0
    assert_true(nf, "a range of an absent key did not raise not_found")


# ---- DelimiterFaithfulConditionalStore -------------------------------------


def _df_err(
    s: DelimiterFaithfulConditionalStore, k: String, p: WritePrecondition
) -> String:
    try:
        _ = s.conditional_put(Path.parse(k), _b("NEW"), p)
        return String("")
    except e:
        return String(e)


def test_delimiter_faithful_store() raises:
    var s = DelimiterFaithfulConditionalStore()
    var k = Path.parse(String("p/k"))
    var m1 = s.put(k, _b("abcdef"))
    # Two keys under the same sub-directory roll up into ONE common prefix.
    _ = s.put(Path.parse(String("p/sub/1")), _b("1"))
    _ = s.put(Path.parse(String("p/sub/2")), _b("2"))
    _ = s.put(Path.parse(String("p/other/3")), _b("3"))
    var lr = s.list_with_delimiter(Path.parse(String("p/")))
    assert_equal(len(lr.objects), 1)
    assert_equal(lr.objects[0].location, String("p/k"))
    assert_equal(len(lr.common_prefixes), 2)
    assert_equal(lr.common_prefixes[0], String("p/sub/"))
    assert_equal(lr.common_prefixes[1], String("p/other/"))
    # The root listing rolls everything up under `p/`.
    var root = s.list_with_delimiter(Path.parse(String("")))
    assert_equal(len(root.objects), 0)
    assert_equal(len(root.common_prefixes), 1)
    assert_equal(root.common_prefixes[0], String("p/"))
    assert_equal(s.coalesce_policy().max_concurrency, 8)
    # The three 412 arms leave the bytes as they were; the lock is released
    # after each (the next verb would spin forever otherwise).
    var c = _df_err(s, String("p/k"), WritePrecondition.if_none_match_star())
    assert_true(c.find("key already exists") >= 0, c)
    var a = _df_err(s, String("p/nope"), WritePrecondition.if_match(String("1")))
    assert_true(a.find("If-Match on absent key") >= 0, a)
    var st = _df_err(s, String("p/k"), WritePrecondition.if_match(String("x")))
    assert_true(st.find("If-Match etag mismatch") >= 0, st)
    assert_equal(_s(s.get(k)), String("abcdef"))
    var m2 = s.compare_and_swap(k, _b("ABCDEF"), m1.etag)
    assert_true(m2.etag != m1.etag)
    assert_equal(_s(s.get_range(k, Int64(1), Int64(3))), String("BCD"))
    assert_equal(len(s.get_range(k, Int64(1), Int64(0))), 0)
    var oob = False
    try:
        _ = s.get_range(k, Int64(4), Int64(3))
    except e:
        oob = String(e).find("out-of-range") >= 0
    assert_true(oob, "a range past the end was served")
    var nf = False
    try:
        _ = s.get_range(Path.parse(String("p/zz")), Int64(0), Int64(1))
    except e:
        nf = String(e).find("not_found") >= 0
    assert_true(nf, "a range of an absent key did not raise not_found")
    # And the store is still usable: every arm above released the lock.
    _ = s.put(Path.parse(String("p/after")), _b("ok"))
    assert_equal(_s(s.get(Path.parse(String("p/after")))), String("ok"))


# ---- DelimiterFaithful lock: a verb waits for a held lock -------------------


def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    # SAFETY: `Optional[UnsafePointer]` is layout-compatible with the bare
    # pointer; `None` is the NULL bit pattern. Never dereferenced: it is the
    # C NULL passed to pthread_create / pthread_join.
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


struct _ReaderArg(Movable, Deinitable):
    var store: DelimiterFaithfulConditionalStore

    def __init__(out self, var store: DelimiterFaithfulConditionalStore):
        self.store = store^



# FFI-BOUNDARY: the pthread_create / pthread_join FFI of the lock-wait case.
# `_reader_entry` is the C thread entry, so its argument and result are
# spelled with MutUntrackedOrigin, as are the C NULLs passed for the
# attributes and the join result (tests/pointer_lint_ffi.tsv lists this
# file). Ownership: `test_delimiter_faithful_lock_waits` allocates the
# `_ReaderArg` and hands it to the thread, whose OwnedPointer frees it; the
# entry returns NULL, which pthread_join discards.
def _reader_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY: `arg` is the heap `_ReaderArg*` written by `_spawn_reader`;
    # the OwnedPointer frees it at scope exit.
    var owned = OwnedPointer[_ReaderArg](
        unsafe_from_raw_pointer=arg.bitcast[_ReaderArg]()
    )
    try:
        # Spins while the main thread holds the lock; then reads the value
        # written under it and records what it saw.
        var seen = owned[].store.get(Path.parse(String("lock/k")))
        _ = owned[].store.put(Path.parse(String("lock/seen")), seen^)
    except e:
        print("reader raised: " + String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def test_delimiter_faithful_lock_waits() raises:
    var s = DelimiterFaithfulConditionalStore()
    _ = s.put(Path.parse(String("lock/k")), _b("old"))
    # Hold the store's lock, start a reader, give it time to reach the spin.
    s._acquire()
    var raw = alloc[_ReaderArg](1)
    UnsafePointer(to=raw[]).unsafe_write(_ReaderArg(s.clone()))
    var tid = Int64(0)
    var rc = external_call["pthread_create", Int32](
        UnsafePointer(to=tid).bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _reader_entry,
        raw.bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
    )
    if rc != 0:
        s._release()
        raise Error("pthread_create failed")
    _ = external_call["usleep", Int32](UInt32(50_000))
    # Still under the lock: nothing has been recorded, then write "new" with
    # the lock still held (as a verb would) and release it.
    var p = Path.parse(String("lock/k"))
    var idx = s._find(p.raw())
    assert_true(idx >= 0)
    s._map[].entries[idx].bytes = _b("new")
    assert_equal(s._find(String("lock/seen")), -1)
    s._release()
    _ = external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )
    assert_equal(_s(s.get(Path.parse(String("lock/seen")))), String("new"))


# ---- SharedInMemorySlowCasStore --------------------------------------------


def test_slow_cas_store_arms() raises:
    var reactor = _new_reactor()
    var s = SharedInMemorySlowCasStore(slow_ticks=0)
    var k = Path.parse(String("slow/k"))
    # A poll with nothing in flight is an ERR, not a raise and not READY.
    var rp = s.read_poll[NoopSink](reactor)
    assert_true(rp.is_error())
    assert_true(rp.err_text().find("no read in flight") >= 0, rp.err_text())
    var pp = s.cas_put_poll[NoopSink](reactor)
    assert_true(pp.is_error())
    assert_true(pp.err_text().find("no put in flight") >= 0, pp.err_text())
    # A take before anything completed raises.
    var rt = String("")
    try:
        _ = s.read_take()
    except e:
        rt = String(e)
    assert_true(rt.find("read not ready") >= 0, rt)
    var pt = String("")
    try:
        _ = s.cas_put_take()
    except e:
        pt = String(e)
    assert_true(pt.find("put not ready") >= 0, pt)
    # Create, then an If-Match CAS: a stale etag is an ERR, the live one wins.
    assert_true(s.cas_put_start[NoopSink](k, _b("v1"), String(""), reactor).is_ready())
    var m1 = s.cas_put_take()
    var stale = s.cas_put_start[NoopSink](k, _b("v2"), String("bogus"), reactor)
    assert_true(stale.is_error())
    assert_true(stale.err_text().find("etag mismatch") >= 0, stale.err_text())
    assert_true(
        s.cas_put_start[NoopSink](k, _b("v3"), m1.etag, reactor).is_ready()
    )
    var m3 = s.cas_put_take()
    assert_true(m3.etag != m1.etag)
    assert_equal(_s(s.get(k)), String("v3"))
    # The parked path with the If-Match arm: 1 tick, then READY on poll.
    s.set_slow_ticks(1)
    var parked = s.cas_put_start[NoopSink](k, _b("v4"), m3.etag, reactor)
    assert_true(parked.is_pending())
    assert_true(s.cas_put_poll[NoopSink](reactor).is_ready())
    assert_equal(_s(s.get(k)), String("v4"))
    _ = s.cas_put_take()
    # The final-tick transport fault raises, and writes nothing.
    s.set_raise_on_poll(True)
    assert_true(
        s.cas_put_start[NoopSink](Path.parse(String("slow/f")), _b("f"), String(""), reactor).is_pending()
    )
    var pf = String("")
    try:
        _ = s.cas_put_poll[NoopSink](reactor)
    except e:
        pf = String(e)
    assert_true(pf.find("cas_put_poll final tick") >= 0, pf)
    var f_absent = False
    try:
        _ = s.get(Path.parse(String("slow/f")))
    except e:
        f_absent = String(e).find("not_found") >= 0
    assert_true(f_absent, "a faulted poll wrote the object")
    # Disarmed again: the same parked shape completes.
    s.set_raise_on_poll(False)
    assert_true(
        s.cas_put_start[NoopSink](Path.parse(String("slow/f")), _b("f"), String(""), reactor).is_pending()
    )
    assert_true(s.cas_put_poll[NoopSink](reactor).is_ready())
    # The start-time transport fault raises.
    var faulty = SharedInMemorySlowCasStore(slow_ticks=0, raise_on_cas_put=True)
    var cf = String("")
    try:
        _ = faulty.cas_put_start[NoopSink](k, _b("x"), String(""), reactor)
    except e:
        cf = String(e)
    assert_true(cf.find("cas_put_start, errno=61") >= 0, cf)
    # Base surface delegates to the shared map.
    _ = s.conditional_put(
        Path.parse(String("slow/c")), _b("c"), WritePrecondition.if_none_match_star()
    )
    assert_equal(s.head(Path.parse(String("slow/c"))).size, Int64(1))
    assert_equal(len(s.list_with_delimiter(Path.parse(String("slow/"))).objects), 3)
    assert_equal(s.coalesce_policy().max_concurrency, 8)
    assert_equal(_s(s.get_range(k, Int64(1), Int64(1))), String("4"))
    var cm = s.head(Path.parse(String("slow/c")))
    _ = s.compare_and_swap(Path.parse(String("slow/c")), _b("cc"), cm.etag)
    assert_equal(_s(s.clone().get(Path.parse(String("slow/c")))), String("cc"))
    s.delete(Path.parse(String("slow/c")))
    assert_equal(len(s.list_with_delimiter(Path.parse(String("slow/"))).objects), 2)


def main() raises:
    test_in_memory_store()
    test_delimiter_faithful_store()
    test_delimiter_faithful_lock_waits()
    test_slow_cas_store_arms()
    print("[test_cov_in_memory_stores] PASS")
