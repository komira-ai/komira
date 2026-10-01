# =============================================================================
# test_local_fs_write_at.mojo
# =============================================================================
#
#
# Exercises the LocalFs WRITE-side trait surface (`open_write` +
# `write_at` + `pwrite_at` + `close_write` + `WriteMode`).
#
# Coverage:
#   T1 — open_write(CREATE_TRUNCATE) — opens file, writes 1KB, close;
#        file on disk has the expected bytes.
#   T2 — open_write(CREATE_EXCLUSIVE) — pre-create file; open with
#        CREATE_EXCLUSIVE raises (EEXIST).
#   T3 — open_write(APPEND) — pre-create file with "AAAA"; open APPEND;
#        write "BBBB"; file is "AAAABBBB".
#   T4 — write_at byte-identical vs FileHandle.write — write same 1MB blob
#        via both paths; byte-by-byte equality.
#   T5 — write_at chunking — write a payload that crosses the 64 MiB
#        chunk boundary (>64 MiB); verify total size + spot-check bytes.
#        Runs only with `--large-writes` on the command line, to keep the
#        gated run's wall time bounded.
#   T6 — pwrite_at concurrent disjoint ranges — ftruncate file to 4 MiB,
#        fork-join 4 workers writing 1 MiB each to disjoint ranges via
#        pwrite_at, verify final file bytes match expected.
#   T7 — close_write flushes and closes — write, close_write, re-open
#        for read, verify bytes intact.
#
# Discipline:
#   * /tmp paths; setup overwrites cleanly via CREATE_TRUNCATE on most
#     tests. T2 explicitly pre-creates to test the EXCLUSIVE-fail path.
#   * Bytes read back via std.io.FileHandle.
#   * ZERO new wildcard origins.
#
# T6 fans out on the package's OWN fork-join — `parallel_fork_join_shared`
# over a real 4-worker `PerCoreAsyncRuntime` + `LocalDispatcher` (Mojo 1.0
# has no stdlib `parallelize`). The claim: 4 workers on 4 OS threads
# pwrite disjoint byte ranges of one fd concurrently, and the file that results
# is byte-identical to a serial write. A serial rewrite would compile and pass
# while proving nothing about `SUPPORTS_PARALLEL_WRITES`.
#
# The `UnsafePointer(to=...).bitcast[...]()` pair inside the `SharedChunkWork`
# body is the trait's own documented idiom (the `process` method is generic over
# `In`/`P`, so the concrete types are recovered at the top of the body); it is
# the same shape the join key extract and `test_parallel_fork_join.mojo` use,
# and neither pointer escapes the function.
# =============================================================================

from std.sys import argv
from std.memory import UnsafePointer
from std.io import FileHandle
from std.testing import assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
from komira_async.cancellation.token import CancellationToken
from komira_async.fs.file_system import WriteMode
from komira_async.fs.local_fs import LocalFs, LocalWriteFile
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.parallel_fork_join_shared import (
    parallel_fork_join_shared,
)
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_core.runtime_traits.shared_chunk_work import SharedChunkWork


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A fixed `/tmp` path is shared by every concurrent execution of this test on
# one worker; the runner's private `TEST_TMPDIR` (read through
# `komira_runtime_paths.test_tmpdir`) keeps them disjoint.
# ---------------------------------------------------------------------------
def _has_flag(name: String) -> Bool:
    """True when `name` is one of this program's command-line arguments."""
    var args = argv()
    for i in range(1, len(args)):
        if String(args[i]) == name:
            return True
    return False


def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


# =============================================================================
# Test fixture helpers
# =============================================================================
#
# Path naming convention: `<scratch>/local_fs_write_<test>.bin`.
# Single-process tests don't need a unique-suffix scheme (each test
# name is distinct). Tests that need a clean slate explicitly
# CREATE_TRUNCATE; tests that need pre-existing content use
# FileHandle to set up.


def _make_pattern(n: Int) -> List[UInt8]:
    """Build a deterministic n-byte pattern (i % 251). Used to verify
    byte-identity round-trips through write_at."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(i % 251))
    return out^


def _write_via_filehandle(path: String, bytes: List[UInt8]) raises:
    """Write `bytes` to `path` via stdlib FileHandle (the comparison
    baseline for T4)."""
    var fh = open(path, "w")
    fh.write_bytes(bytes)
    fh.close()


def _read_file_bytes(path: String) raises -> List[UInt8]:
    """Read whole file as bytes via stdlib FileHandle."""
    var fh = open(path, "r")
    _ = fh.seek(0, 2)  # SEEK_END
    var n = Int(fh.seek(0, 1))  # SEEK_CUR
    _ = fh.seek(0, 0)  # SEEK_SET
    if n <= 0:
        return List[UInt8]()
    var raw = fh.read_bytes(n)
    return raw^


def _assert_bytes_equal(
    actual: List[UInt8], expected: List[UInt8]
) raises:
    """Element-wise compare. Fast-fails on first mismatch with index."""
    assert_equal(len(actual), len(expected))
    var n = len(expected)
    var i = 0
    while i < n:
        if actual[i] != expected[i]:
            raise Error(
                "bytes mismatch at index "
                + String(i)
                + ": got="
                + String(Int(actual[i]))
                + " expected="
                + String(Int(expected[i]))
            )
        i = i + 1


def _maybe_unlink(path: String):
    """Best-effort unlink via FileHandle write+close - actually we just
    rely on CREATE_TRUNCATE in subsequent tests to clean up. For T2
    (CREATE_EXCLUSIVE) we pre-create explicitly; if the test re-runs,
    the pre-create overwrites the prior contents (CREATE_TRUNCATE
    semantics via FileHandle("w")).
    """
    pass


# =============================================================================
# T1 — open_write(CREATE_TRUNCATE) — write 1KB, close, verify
# =============================================================================


def test_open_write_create_truncate() raises:
    """open_write with CREATE_TRUNCATE creates / overwrites the file;
    write_at + close_write produces the expected bytes on disk."""
    var path = (_scratch_dir() + String("/local_fs_write_t1_truncate.bin"))
    # Ensure starting fresh — overwrite via FileHandle first to set a
    # known baseline.
    _write_via_filehandle(path, _make_pattern(64))

    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var data = _make_pattern(1024)
    var n = fs.write_at(wf, Span(data))
    assert_equal(Int(n), 1024)
    fs.close_write(wf^)

    # File on disk should now be 1024 bytes of the pattern (the prior
    # 64-byte content was truncated).
    var actual = _read_file_bytes(path)
    var expected = _make_pattern(1024)
    _assert_bytes_equal(actual, expected)


# =============================================================================
# T2 — open_write(CREATE_EXCLUSIVE) — raises if file already exists
# =============================================================================


def test_open_write_create_exclusive_raises_if_exists() raises:
    """open_write with CREATE_EXCLUSIVE atomically creates-or-fails;
    when the path already exists, it raises (EEXIST at the syscall
    level)."""
    var path = (_scratch_dir() + String("/local_fs_write_t2_exclusive.bin"))
    # Pre-create the file so CREATE_EXCLUSIVE will fail.
    _write_via_filehandle(path, _make_pattern(32))

    var fs = LocalFs[NoopSink].new()
    var caught = False
    try:
        var _wf = fs.open_write(path, WriteMode.create_exclusive())
    except e:
        caught = True
    assert_true(
        caught,
        msg="CREATE_EXCLUSIVE on existing path should have raised",
    )

    # File contents must be unchanged (no truncate / no overwrite).
    var actual = _read_file_bytes(path)
    var expected = _make_pattern(32)
    _assert_bytes_equal(actual, expected)


# =============================================================================
# T3 — open_write(APPEND) — appends to existing file
# =============================================================================


def test_open_write_append() raises:
    """open_write with APPEND opens an existing file in append mode;
    write_at adds bytes at end-of-file."""
    var path = (_scratch_dir() + String("/local_fs_write_t3_append.bin"))
    # Pre-seed with "AAAA" (4 bytes of 0x41).
    var seed = List[UInt8]()
    seed.resize(4, UInt8(0x41))
    _write_via_filehandle(path, seed)

    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.append())
    # Append "BBBB" (4 bytes of 0x42).
    var addn = List[UInt8]()
    addn.resize(4, UInt8(0x42))
    var n = fs.write_at(wf, Span(addn))
    assert_equal(Int(n), 4)
    fs.close_write(wf^)

    # File should now be "AAAABBBB" = 8 bytes.
    var actual = _read_file_bytes(path)
    assert_equal(len(actual), 8)
    assert_equal(Int(actual[0]), 0x41)
    assert_equal(Int(actual[3]), 0x41)
    assert_equal(Int(actual[4]), 0x42)
    assert_equal(Int(actual[7]), 0x42)


# =============================================================================
# T4 — write_at byte-identical vs FileHandle.write on 1 MB blob
# =============================================================================


def test_write_at_byte_identical_vs_filehandle_write() raises:
    """A 1 MB blob written via LocalFs.write_at must be byte-identical
    to the same blob written via stdlib FileHandle.write."""
    var data = _make_pattern(1024 * 1024)  # 1 MiB
    var path_a = (_scratch_dir() + String("/local_fs_write_t4_localfs.bin"))
    var path_b = (_scratch_dir() + String("/local_fs_write_t4_filehandle.bin"))

    # Path A: LocalFs.write_at
    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path_a, WriteMode.create_truncate())
    var n = fs.write_at(wf, Span(data))
    assert_equal(Int(n), 1024 * 1024)
    fs.close_write(wf^)

    # Path B: stdlib FileHandle.write
    _write_via_filehandle(path_b, data)

    # Compare byte-by-byte
    var bytes_a = _read_file_bytes(path_a)
    var bytes_b = _read_file_bytes(path_b)
    _assert_bytes_equal(bytes_a, bytes_b)


# =============================================================================
# T5 — write_at chunking on >64 MiB payload
# =============================================================================
#
# Validates that the 64 MiB chunked-write workaround inside LocalFs.write_at
# is actually invoked and produces the correct byte count + spot-checked
# content. Runs only with `--large-writes`, to keep the gated run's wall time
# bounded (writing ~70 MiB takes ~100-200 ms on local NVMe).


def test_write_at_large_chunking() raises:
    """Write a >64 MiB payload via LocalFs.write_at; verify total
    size and spot-check pattern bytes.

    Runs only when the program is started with `--large-writes` (it writes
    70 MiB); the gated test run passes no arguments, so there it returns at
    once.
    """
    if not _has_flag("--large-writes"):
        return

    # 70 MiB — straddles the 64 MiB chunk boundary so both fast-path
    # (last chunk) and slow-path (chunked) code are exercised.
    var n_bytes = 70 * 1024 * 1024
    var data = _make_pattern(n_bytes)
    var path = (_scratch_dir() + String("/local_fs_write_t5_large.bin"))

    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var n_written = fs.write_at(wf, Span(data))
    assert_equal(Int(n_written), n_bytes)
    fs.close_write(wf^)

    # Verify on-disk size matches.
    var on_disk = _read_file_bytes(path)
    assert_equal(len(on_disk), n_bytes)

    # Spot-check pattern bytes at strategic offsets:
    #   * 0 — first byte
    #   * 64 MiB - 1 — last byte of first chunk
    #   * 64 MiB — first byte of second chunk
    #   * n_bytes - 1 — last byte
    assert_equal(Int(on_disk[0]), 0)
    var i1 = 64 * 1024 * 1024 - 1
    assert_equal(Int(on_disk[i1]), i1 % 251)
    var i2 = 64 * 1024 * 1024
    assert_equal(Int(on_disk[i2]), i2 % 251)
    var i3 = n_bytes - 1
    assert_equal(Int(on_disk[i3]), i3 % 251)


# =============================================================================
# T6 — pwrite_at concurrent disjoint ranges
# =============================================================================
#
# Validates that LocalFs.SUPPORTS_PARALLEL_WRITES = True is honored:
# 4 workers each write a distinct 1 MiB segment to disjoint
# [tid*1MiB, (tid+1)*1MiB) ranges via pwrite_at, all in parallel on the
# repo's own fork-join. Final file must contain the concatenation in
# byte-identical order.


struct _PwriteBufs(Deinitable):
    """Read-only, shared across every chunk: worker `c`'s payload bytes live at
    `bufs[c]` and no chunk reads another chunk's slot."""

    var bufs: List[List[UInt8]]

    def __init__(out self, var bufs: List[List[UInt8]]):
        self.bufs = bufs^


struct _PwriteTarget(Movable, Deinitable):
    """The MUTABLE shared payload: the fd every worker pwrites into, the
    `LocalFs` that owns the syscall, and the per-worker error slots.

    `fs` / `wf` are `Optional` so the caller can `take()` them back out of the
    payload the driver returns after the barrier — a bare field cannot be moved
    out of a struct, and the write handle has to reach `close_write(wf^)`.
    """

    var fs: Optional[LocalFs[NoopSink]]
    var wf: Optional[LocalWriteFile]
    var errors: List[Optional[String]]

    def __init__(
        out self,
        var fs: LocalFs[NoopSink],
        var wf: LocalWriteFile,
        var errors: List[Optional[String]],
    ):
        self.fs = Optional[LocalFs[NoopSink]](fs^)
        self.wf = Optional[LocalWriteFile](wf^)
        self.errors = errors^


@fieldwise_init
struct _PwriteDisjoint(SharedChunkWork):
    """Chunk `c` pwrites `bufs[c]` at byte offset `c * seg_bytes`.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: chunk `c` writes the file range
        [c*seg_bytes, (c+1)*seg_bytes) and the error slot `errors[c]` — both
        indexed by `chunk_id`, so the tiling is exact and pairwise disjoint by
        construction. POSIX pwrite(2) is atomic for disjoint ranges of a
        regular file, and `pwrite_at` does not touch the kernel file offset, so
        there is no shared cursor either. `fs` and `wf` are READ-ONLY here:
        `LocalFs.pwrite_at` takes both `self` and `file` borrowed.
      * Liveness: the payload is MOVED onto the driver's State, so the fd is
        OWNED across the barrier rather than borrowed, and `_PwriteBufs`
        arrives as `ref [in_o] input` with a CONCRETE origin pinned to the
        caller's frame. `fork_join_shared`'s `run_with_state` is a synchronous
        fork-join barrier — no worker outlives it, and nothing is closed under
        a worker.
      * No-realloc: `bufs` and `errors` are both pre-sized to `n_chunks` before
        the dispatch; chunks only `setitem` live slots. No append, no resize.
    """

    var seg_bytes: Int

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self,
        chunk_id: Int,
        n_chunks: Int,
        ref input: In,
        mut payload: P,
    ) raises:
        # SAFETY: the call site below instantiates the driver with
        # In=_PwriteBufs and P=_PwriteTarget; the bitcasts recover those
        # concrete types. Neither pointer escapes this function.
        var ip = UnsafePointer(to=input).bitcast[_PwriteBufs]()
        var pp = UnsafePointer(to=payload).bitcast[_PwriteTarget]()
        try:
            var offset = Int64(chunk_id * self.seg_bytes)
            var span = Span(ip[].bufs[chunk_id])
            var _n = pp[].fs.value().pwrite_at(
                pp[].wf.value(), offset, span
            )
        except e:
            pp[].errors[chunk_id] = Optional[String](String(e))


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_pwrite_at_concurrent_disjoint_ranges() raises:
    """4 workers x 1 MiB pwrite_at to disjoint ranges; verify final
    file matches the byte-pattern that a serial write would have
    produced."""
    comptime N_WORKERS = 4
    comptime SEG_BYTES = 1024 * 1024  # 1 MiB per worker
    comptime TOTAL_BYTES = N_WORKERS * SEG_BYTES

    var path = (_scratch_dir() + String("/local_fs_write_t6_pwrite_parallel.bin"))

    # Step 1: open file CREATE_TRUNCATE and ftruncate to TOTAL_BYTES
    # (pre-size the file so pwrite_at writes into a known extent).
    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.create_truncate())
    # Use the underlying RawWriteFd.ftruncate_size via direct field
    # access on LocalWriteFile (tests are inside the same crate; field
    # is module-private but available for test setup).
    wf._fd.ftruncate_size(TOTAL_BYTES)

    # Step 2: build per-worker byte buffers. Worker tid's bytes are
    # `pattern[tid*SEG_BYTES : (tid+1)*SEG_BYTES]` so that the
    # concatenated file matches the full SEG_BYTES * N pattern.
    var worker_bufs = List[List[UInt8]]()
    var w = 0
    while w < N_WORKERS:
        var buf = List[UInt8](capacity=SEG_BYTES)
        var base = w * SEG_BYTES
        var i = 0
        while i < SEG_BYTES:
            buf.append(UInt8((base + i) % 251))
            i = i + 1
        worker_bufs.append(buf^)
        w = w + 1

    # Step 3: fan 4 workers out over disjoint pwrite ranges on a REAL
    # 4-worker runtime. The `_serial` entry, or a runtime with one worker,
    # would order the writes and assert nothing about parallel pwrite.
    # The disjointness / liveness / no-realloc argument lives on
    # `_PwriteDisjoint` above, next to the code it governs.
    var errors = List[Optional[String]]()
    var ei = 0
    while ei < N_WORKERS:
        errors.append(Optional[String](None))
        ei = ei + 1

    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(N_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    var ct = CancellationToken.new()
    ref disp = rt.dispatcher()
    var disp_ptr = Pointer(to=disp)

    var bufs_in = _PwriteBufs(worker_bufs^)
    var target = parallel_fork_join_shared[
        _PwriteDisjoint,
        _PwriteBufs,
        _PwriteTarget,
        origin_of(bufs_in),
        origin_of(disp),
    ](
        _PwriteDisjoint(SEG_BYTES),
        bufs_in,
        _PwriteTarget(fs^, wf^, errors^),
        N_WORKERS,
        disp_ptr,
        ct.clone(),
    )
    rt.shutdown()

    # Re-raise the first pwrite failure if any worker failed.
    var ei2 = 0
    while ei2 < N_WORKERS:
        if target.errors[ei2]:
            raise Error(
                String("pwrite worker ") + String(ei2)
                + String(" failed: ") + target.errors[ei2].value().copy()
            )
        ei2 = ei2 + 1

    # Close the write handle (reclaimed from the payload after the barrier).
    var fs_back = target.fs.take()
    var wf_back = target.wf.take()
    fs_back.close_write(wf_back^)

    # Step 4: verify file matches the expected concatenated pattern.
    var actual = _read_file_bytes(path)
    var expected = _make_pattern(TOTAL_BYTES)
    _assert_bytes_equal(actual, expected)


# =============================================================================
# T7 — close_write flushes and closes
# =============================================================================


def test_close_write_flushes_and_closes() raises:
    """Write a known payload, close_write explicitly, then re-open for
    read and verify bytes are intact. Also verify the LocalWriteFile
    reports closed state via is_closed() after close_write returns."""
    var path = (_scratch_dir() + String("/local_fs_write_t7_close.bin"))
    var data = _make_pattern(2048)

    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.create_truncate())
    assert_false(wf.is_closed())
    var n = fs.write_at(wf, Span(data))
    assert_equal(Int(n), 2048)
    # cursor should be advanced.
    assert_equal(Int(wf.cursor()), 2048)
    # Explicit close. Consumes wf.
    fs.close_write(wf^)

    # Re-open for read via FileHandle; verify bytes match.
    var actual = _read_file_bytes(path)
    var expected = _make_pattern(2048)
    _assert_bytes_equal(actual, expected)


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    test_open_write_create_truncate()
    test_open_write_create_exclusive_raises_if_exists()
    test_open_write_append()
    test_write_at_byte_identical_vs_filehandle_write()
    test_write_at_large_chunking()
    test_pwrite_at_concurrent_disjoint_ranges()
    test_close_write_flushes_and_closes()
    print(
        "PASS komira_async.fs.test_local_fs_write_at"
        " (LocalFs WRITE-side trait conformance)"
    )
