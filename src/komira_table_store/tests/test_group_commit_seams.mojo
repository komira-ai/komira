# =============================================================================
# src/komira_table_store/tests/test_group_commit_seams.mojo
#   The group-commit seams the coalescing spine drives, called directly: the
#   head reader, the codec's head decode and size estimate, the shared OCC
#   scan's in-flight-chunk refusal, and the appender's error classifier.
# =============================================================================
#
# What each test proves:
#   * the head reader stages the authoritative head (chunk_seq, next_offset)
#     as two little-endian i64 at start, its poll is READY, a second take_read
#     with nothing staged is refused, and the stage-blob stubs are READY/no-op.
#   * classify_read_error: each torn/truncated/retryable wording is TORN, a
#     status=412 / precondition is CONFLICT, anything else FATAL.
#   * decode_head: an absent head is (-1, 0); a body shorter than 16 bytes is
#     refused; every byte of both fields is read (values with all bytes set).
#   * estimate_bytes sums key + row + 9 per write.
#   * encode_group_batch: a member whose OCC window reaches a chunk that is not
#     there raises the RETRYABLE-tagged in-flight error naming the seq.
#   * classify_append_error: status=412 / precondition / If-None-Match are a lost
#     slot, anything else an error, including an "If-Match" error (the
#     appender's create-CAS is If-None-Match, so it agrees with the async
#     commit classifier `_is_lost_slot_412` on every row; komira-ai/komira#1402)
#     and an I/O error whose only 412 is in a path (komira-ai/komira#1275).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.coalescing_window import (
    APPEND_ERR,
    APPEND_LOST_SLOT,
    READ_ERR_CONFLICT,
    READ_ERR_FATAL,
    READ_ERR_TORN,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import CasReadResult

from komira_table_store.table_store_codec import TS_OP_PUT, WriteOp
from komira_table_store.table_store import (
    TableStore,
    _is_lost_slot_412,
    is_commit_retryable,
)
from komira_table_store.group_commit import (
    TableStoreExactSlotAppender,
    TableStoreGroupCommitCodec,
    TableStoreGroupCommitItem,
    TableStoreHeadReader,
    encode_group_batch,
)


comptime _Store = SharedInMemorySlowCasStore


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _le64(v: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))
    return out^


def _get_le64(b: List[UInt8], off: Int) -> Int64:
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(b[off + i])) << UInt64(8 * i)
    return Int64(u)


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _wal(backing: SharedInMemoryConditionalStore, prefix: String) -> CasManifestStore[_Store]:
    var slow = SharedInMemorySlowCasStore(inner=backing.clone(), slow_ticks=0)
    return CasManifestStore[_Store](
        store=slow^, prefix=prefix, retry=RetryPolicy.fast_test()
    )


def test_head_reader_stages_and_refuses_empty_take() raises:
    print("[gc-seams] head reader: staged head, READY poll, empty take refused")
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()
    # Two committed chunks, so the head is (1, next_offset 3).
    var ts = TableStore[_Store].open(_wal(backing, "gc/seams"))
    var t0 = ts.begin()
    t0.insert(_b("a"), _b("1"))
    t0.insert(_b("b"), _b("2"))
    _ = ts.commit(t0^)
    var t1 = ts.begin()
    t1.insert(_b("c"), _b("3"))
    _ = ts.commit(t1^)

    var reader = TableStoreHeadReader[_Store](_wal(backing, "gc/seams"))
    assert_true(reader.read_head_start[NoopSink](reactor).is_ready(), "start READY")
    assert_true(reader.read_head_poll[NoopSink](reactor).is_ready(), "poll READY")
    var rr = reader.take_read()
    assert_false(rr.absent, "a staged head is present")
    assert_equal(len(rr.body), 16, "two i64 fields")
    assert_equal(_get_le64(rr.body, 0), Int64(1), "chunk_seq")
    assert_equal(_get_le64(rr.body, 8), Int64(3), "next_offset")
    var refused = String("")
    try:
        _ = reader.take_read()
    except e:
        refused = String(e)
    assert_true(
        refused.find("TableStoreHeadReader.take_read: no staged head") >= 0,
        "a second take_read is refused: " + refused,
    )
    assert_true(
        reader.stage_blob_start[NoopSink](String("k"), _b("x"), reactor).is_ready(),
        "stage_blob_start READY",
    )
    assert_true(
        reader.stage_blob_poll[NoopSink](reactor).is_ready(), "stage_blob_poll READY"
    )
    reader.stage_blob_take()


def test_classify_read_error() raises:
    print("[gc-seams] classify_read_error: TORN / CONFLICT / FATAL")
    var backing = SharedInMemoryConditionalStore()
    var reader = TableStoreHeadReader[_Store](_wal(backing, "gc/cls"))
    var torn = List[String]()
    torn.append(String("chunk torn mid-write"))
    torn.append(String("truncated i64"))
    torn.append(String("transient, retryable"))
    torn.append(String("TS_COMMIT_RETRYABLE: x"))
    for i in range(len(torn)):
        assert_equal(
            Int(reader.classify_read_error(torn[i])), Int(READ_ERR_TORN), torn[i]
        )
    assert_equal(
        Int(
            reader.classify_read_error(
                String("StoreError[PRECONDITION] PutObject s3://b/k status=412")
            )
        ),
        Int(READ_ERR_CONFLICT),
    )
    assert_equal(
        Int(reader.classify_read_error(String("precondition failed"))),
        Int(READ_ERR_CONFLICT),
    )
    assert_equal(
        Int(reader.classify_read_error(String("access denied"))), Int(READ_ERR_FATAL)
    )


def test_codec_decode_head_and_estimate() raises:
    print("[gc-seams] decode_head absent/short/full; estimate_bytes")
    var backing = SharedInMemoryConditionalStore()
    var codec = TableStoreGroupCommitCodec[_Store](_wal(backing, "gc/codec"))
    var absent = codec.decode_head(
        CasReadResult(absent=True, body=List[UInt8](), etag=String(""))
    )
    assert_equal(absent.chunk_seq, Int64(-1), "absent head chunk_seq")
    assert_equal(absent.next_offset, Int64(0), "absent head next_offset")

    var body = _le64(Int64(0x0102030405060708))
    var tail = _le64(Int64(0x7A00_0000_0000_00EE))
    for i in range(8):
        body.append(tail[i])
    var h = codec.decode_head(CasReadResult(absent=False, body=body.copy(), etag=String("")))
    assert_equal(h.chunk_seq, Int64(0x0102030405060708), "chunk_seq bytes")
    assert_equal(h.next_offset, Int64(0x7A00_0000_0000_00EE), "next_offset bytes")

    var short = List[UInt8]()
    for i in range(12):
        short.append(body[i])
    var err = String("")
    try:
        _ = codec.decode_head(CasReadResult(absent=False, body=short^, etag=String("")))
    except e:
        err = String(e)
    assert_true(
        err.find("group_commit: truncated i64 head body") >= 0,
        "a 12-byte head body is refused: " + err,
    )

    var ws = List[WriteOp]()
    var row = List[UInt8]()
    for i in range(300):
        row.append(UInt8(i & 0xFF))
    ws.append(WriteOp(TS_OP_PUT, _b("abc"), row^))
    ws.append(WriteOp(TS_OP_PUT, _b("de"), List[UInt8]()))
    var item = TableStoreGroupCommitItem(Int64(0), ws^)
    assert_equal(codec.estimate_bytes(item), (3 + 300 + 9) + (2 + 0 + 9))


def test_occ_scan_missing_chunk_is_retryable() raises:
    print("[gc-seams] OCC scan over a missing chunk raises RETRYABLE + seq")
    var backing = SharedInMemoryConditionalStore()
    var wal = _wal(backing, "gc/occ")
    var ws = List[WriteOp]()
    ws.append(WriteOp(TS_OP_PUT, _b("k"), _b("v")))
    var members = List[TableStoreGroupCommitItem]()
    members.append(TableStoreGroupCommitItem(Int64(-1), ws^))
    var err = String("")
    try:
        _ = encode_group_batch[_Store](wal, members, Int64(0))
    except e:
        err = String(e)
    assert_true(is_commit_retryable(err), "the in-flight chunk is retryable: " + err)
    assert_true(
        err.find("group_commit OCC scan saw an in-flight chunk at seq 0") >= 0,
        "names the seq: " + err,
    )


def test_classify_append_error() raises:
    print("[gc-seams] classify_append_error: lost slot vs error")
    var backing = SharedInMemoryConditionalStore()
    var app = TableStoreExactSlotAppender[_Store](_wal(backing, "gc/app"))
    var lost = List[String]()
    lost.append(String("StoreError[PRECONDITION] PutObject s3://b/k status=412"))
    lost.append(String("precondition failed"))
    lost.append(String("If-None-Match: *"))
    for i in range(len(lost)):
        assert_equal(
            Int(app.classify_append_error(lost[i])), Int(APPEND_LOST_SLOT), lost[i]
        )
        assert_true(_is_lost_slot_412(lost[i]), "async agrees: " + lost[i])
    var errs = List[String]()
    errs.append(String("connection reset"))
    # The create-CAS is If-None-Match, so an If-Match error is not a lost slot
    # (komira-ai/komira#1402); the async classifier says the same (LOW-2).
    errs.append(String("If-Match mismatch"))
    # An I/O failure whose only 412 is in a path is not a lost slot
    # (komira-ai/komira#1275): the matcher needs `status=412`, not a bare 412.
    errs.append(
        String(
            "LocalFsConditionalStore: atomic rename failed ('/srv/412/k.tmp."
            + "0000000000000412' -> '/srv/412/k', rc=-1)"
        )
    )
    for i in range(len(errs)):
        assert_equal(
            Int(app.classify_append_error(errs[i])), Int(APPEND_ERR), errs[i]
        )
        assert_false(_is_lost_slot_412(errs[i]), "async agrees: " + errs[i])


def main() raises:
    test_head_reader_stages_and_refuses_empty_take()
    test_classify_read_error()
    test_codec_decode_head_and_estimate()
    test_occ_scan_missing_chunk_is_retryable()
    test_classify_append_error()
    print("ALL group-commit seam tests PASSED")
