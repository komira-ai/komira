# S3Fs keeps up to its in-flight bound of requests in flight, and never more.
#
# Over S3Fs, with a fake S3 whose every ranged GET and UploadPart takes
# _DELAY_MS: a prefetch of _RANGES ranges too far apart to coalesce, with
# `prefetch_max_inflight` K, takes at least ceil(_RANGES / K) delays (more
# than K requests at once would finish sooner), and every one of its requests
# is in flight together with K - 1 others and never with more (the fake
# counts, below); with `prefetch_max_inflight` 0 (every range) and S3Config's
# `max_inflight` 2, likewise with K = 2; a write of _PARTS parts with
# `upload_max_inflight` K likewise.
#
# HOW THE FAKE COUNTS. While a timed run is armed with its bound K (`_arm`),
# each slow request adds itself to a process-wide in-flight count
# (komira_counters' GlobalCounterTable: the fakes are reached from a thin
# connector factory and keep no state of their own, but a name-keyed global
# is the process's, not theirs), waits until K are in flight (or
# _GATHER_GUARD_MS pass, once per run), holds _DELAY_MS, and leaves. It
# records whether it saw K in flight and any moment it saw more. "K at a time"
# is then a count, not a duration: a wall-clock ceiling such as "under 5
# delays" also charges the CPU time of building, signing and summing 5 MiB
# parts, which under coverage instrumentation alone was 7 s and failed a
# runner that kept its bound. The floor of ceil(n / K) delays stays: CPU time
# can only lengthen a run, never shorten it.
# Every request of a prefetch carries the handle's ETag, whichever worker's
# store sends it: under `ver/` the fake answers a ranged GET by its
# precondition (If-Match "v1": version 1; none, past offset 0: version 2,
# other letters; another ETag: 412), so a request sent without it reads
# bytes of version 2. The fake holds no state: a connector
# factory is a thin function, so the stores S3Fs builds for its concurrent
# requests each dial a fake of their own, and none could see what another
# was sent. Its object is virtual (byte i is 'a' + i % 26), and it answers
# an UploadPart with an ETag that encodes the part number, the body's length
# and the sum of its bytes, so CompleteMultipartUpload checks, from the ETags
# alone, that it lists parts 1.._PARTS in order, each with the bytes the test
# wrote; any other completion is answered 400 InvalidPart.
#
# Then run_bounded_inflight itself, over a fake store that counts requests in
# flight (below): the peak is exactly the bound, never more; fewer jobs than
# the bound run all at once; a bound of 1 runs in order on the calling
# thread; a failed job is raised as it is and stops new jobs. And twelve
# file systems made, used on several threads and dropped, one after another.
from std.ffi import external_call
from std.memory import ArcPointer
from std.memory import Pointer
from std.testing import assert_equal, assert_raises, assert_true
from std.time import perf_counter_ns

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_atomic_alias import AtomicI64
from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_counters.global_counter import GlobalCounterTable
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    StreamIo,
    TRANSPORT_KIND_KERNEL_TCP,
)
from komira_http_core.transport.scripted import ScriptedStream
from komira_fs.file_system import WriteMode
from komira_objectstore_s3 import (
    AddressingStyle,
    InflightJobs,
    S3Config,
    S3Fs,
    S3FsOptions,
    inflight_workers,
    run_bounded_inflight,
)
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _SIZE = 16 * 1024 * 1024
comptime _SPACING = 1_200_000  # past the 1 MiB coalescing gap
comptime _RANGES = 8
comptime _DELAY_MS = 200
comptime _PART = 5 * 1024 * 1024
comptime _PARTS = 6
comptime _LAST = 1000  # the last part's bytes
comptime _GATHER_GUARD_MS = 30_000
"""How long an armed request waits for its bound's worth of requests to be in
flight before it stops waiting (and the run is recorded as never having
reached it). Paid once per run, and only by a runner that does not keep its
bound in flight; a runner that does reaches K as soon as its K threads have
built their requests."""

# The fake's counters (see the header). Slots of `_Counts`:
comptime _Counts = GlobalCounterTable["komira_objectstore_s3_test_inflight_fake", 6]
comptime _ARMED_K = 0  # the bound a timed run expects; 0: not counting
comptime _IN_FLIGHT = 1  # armed requests inside the fake now
comptime _SERVED = 2  # armed requests served
comptime _REACHED = 3  # armed requests that saw K in flight
comptime _OVER = 4  # moments an armed request saw more than K in flight
comptime _GAVE_UP = 5  # 1 once a request waited out _GATHER_GUARD_MS


def _arm(k: Int, n: Int) raises:
    """Count the next run's `n` slow requests against the bound `k`. `n` must
    be a multiple of `k`: a last round of fewer than `k` would wait out
    _GATHER_GUARD_MS and read as a runner that does not keep its bound."""
    assert_true(k > 0 and n % k == 0, String(n) + " requests are not whole rounds of " + String(k))
    _Counts.reset()
    _Counts.add(_ARMED_K, k)


def _disarm() raises:
    _Counts.reset_slot(_ARMED_K)


def _slow_request() raises:
    """The delay of a slow request; counted while a run is armed."""
    var k = _Counts.read(_ARMED_K)
    if k <= 0:
        _ = external_call["usleep", Int32](UInt32(_DELAY_MS * 1000))
        return
    _Counts.incr(_IN_FLIGHT)
    var reached = False
    var waited_ms = 0
    while True:
        var now = _Counts.read(_IN_FLIGHT)
        if now > k:
            _Counts.incr(_OVER)
        if now >= k:
            reached = True
            break
        if _Counts.read(_GAVE_UP) > 0:
            break
        if waited_ms >= _GATHER_GUARD_MS:
            _Counts.add(_GAVE_UP, 1)
            break
        _ = external_call["usleep", Int32](UInt32(1000))
        waited_ms += 1
    if reached:
        _Counts.incr(_REACHED)
    _ = external_call["usleep", Int32](UInt32(_DELAY_MS * 1000))
    if _Counts.read(_IN_FLIGHT) > k:
        _Counts.incr(_OVER)
    _Counts.add(_IN_FLIGHT, -1)
    _Counts.incr(_SERVED)


def _check_counts(what: String, k: Int, n: Int) raises:
    """Every one of the `n` requests of the run just timed was in flight
    together with `k - 1` others, and none ever saw more than `k`."""
    _disarm()
    assert_equal(_Counts.read(_SERVED), n, what + ": requests the fake served while armed")
    assert_equal(
        _Counts.read(_OVER),
        0,
        what + ": more than " + String(k) + " were in flight",
    )
    assert_equal(
        _Counts.read(_REACHED),
        n,
        what
        + ": of "
        + String(n)
        + " requests, only "
        + String(_Counts.read(_REACHED))
        + " were in flight with "
        + String(k - 1)
        + " others: they were not sent "
        + String(k)
        + " at a time",
    )


def _byte_at(i: Int) -> UInt8:
    return UInt8(0x61 + i % 26)


def _v2_byte_at(i: Int) -> UInt8:
    return UInt8(0x41 + i % 26)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _sub(s: String, i: Int, j: Int) -> String:
    return String(s[byte=i:j])


def _pattern_at(i: Int) -> UInt8:
    return UInt8((i * 7 + 3) % 251)


def _part_len(number: Int) -> Int:
    return _LAST if number == _PARTS else _PART


def _part_etag(number: Int, length: Int, sum: Int) -> String:
    return String('"p') + String(number) + "-" + String(length) + "-" + String(sum) + '"'


def _expected_etag(number: Int) -> String:
    var length = _part_len(number)
    var sum = 0
    var base = (number - 1) * _PART
    for i in range(length):
        sum += Int(_pattern_at(base + i))
    return _part_etag(number, length, sum)


def _ok(headers: String, body: String) -> List[UInt8]:
    var out = _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Length: ")
        + String(body.byte_length())
        + "\r\nConnection: close\r\n"
        + headers
        + "\r\n"
        + body
    )
    return out^


def _invalid(why: String) -> List[UInt8]:
    var body = String("<Error><Code>InvalidPart</Code><Message>") + why + "</Message></Error>"
    return _bytes(
        String("HTTP/1.1 400 Bad Request\r\nContent-Length: ")
        + String(body.byte_length())
        + "\r\nConnection: close\r\nContent-Type: application/xml\r\n\r\n"
        + body
    )


def _precondition_failed() -> List[UInt8]:
    var body = String("<Error><Code>PreconditionFailed</Code><Message>no</Message></Error>")
    return _bytes(
        String("HTTP/1.1 412 Precondition Failed\r\nContent-Length: ")
        + String(body.byte_length())
        + "\r\nConnection: close\r\nContent-Type: application/xml\r\n\r\n"
        + body
    )


def _xml_text(s: String, tag: String, start: Int) -> String:
    var open_tag = String("<") + tag + ">"
    var a = s.find(open_tag, start)
    if a < 0:
        return String("")
    a += open_tag.byte_length()
    var b = s.find(String("</") + tag + ">", a)
    return _sub(s, a, b).replace("&quot;", '"').replace("&#34;", '"')


def _complete(body: String) -> List[UInt8]:
    var listed = body.split("<Part>")
    if len(listed) - 1 != _PARTS:
        return _invalid(String("listed ") + String(len(listed) - 1) + " parts")
    for i in range(1, len(listed)):
        var entry = String(listed[i])
        var number = _xml_text(entry, "PartNumber", 0)
        var etag = _xml_text(entry, "ETag", 0)
        if number != String(i) or etag != _expected_etag(i):
            return _invalid(String("part ") + String(i) + " listed as " + number + " " + etag)
    return _ok(
        "Content-Type: application/xml\r\n",
        '<CompleteMultipartUploadResult><ETag>"done"</ETag></CompleteMultipartUploadResult>',
    )


def _serve(written: List[UInt8]) raises -> List[UInt8]:
    """A ranged GET of the virtual object `v/big`, or a multipart upload
    verb; ranged GETs and parts are answered after the delay."""
    var n = len(written)
    var end = -1
    for i in range(n - 3):
        if written[i] == 13 and written[i + 1] == 10 and written[i + 2] == 13 and written[i + 3] == 10:
            end = i
            break
    if end < 0:
        raise Error("the fake S3 read no complete request head")
    var head = String(unsafe_from_utf8=Span(written)[0:end])
    var lines = head.split("\r\n")
    var request_line = String(lines[0]).split(" ")
    var method = String(request_line[0])
    var target = String(request_line[1])
    if method == "POST" and target.find("uploads") >= 0 and target.find("uploadId=") < 0:
        return _ok(
            "Content-Type: application/xml\r\n",
            "<InitiateMultipartUploadResult><UploadId>up-0</UploadId></InitiateMultipartUploadResult>",
        )
    # Objects under `fast/` are answered without the delay.
    var slow = target.find("/fast/") < 0
    if method == "PUT" and target.find("uploadId=up-0") >= 0:
        if slow:
            _slow_request()
        var at = target.find("partNumber=")
        var stop = at + 11
        while stop < target.byte_length() and target.as_bytes()[stop] >= 48 and target.as_bytes()[stop] <= 57:
            stop += 1
        var number = Int(_sub(target, at + 11, stop))
        var sum = 0
        for i in range(end + 4, n):
            sum += Int(written[i])
        return _ok(String("ETag: ") + _part_etag(number, n - end - 4, sum) + "\r\n", "")
    if method == "POST" and target.find("uploadId=up-0") >= 0:
        return _complete(String(unsafe_from_utf8=Span(written)[end + 4 : n]))
    var range_ = String("")
    var if_match = String("")
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon > 0 and _sub(line, 0, colon).lower() == "range":
            range_ = String(_sub(line, colon + 1, line.byte_length()).strip())
        if colon > 0 and _sub(line, 0, colon).lower() == "if-match":
            if_match = String(_sub(line, colon + 1, line.byte_length()).strip())
    if range_.byte_length() == 0:
        raise Error("the fake S3 answers ranged GETs only")
    if slow:
        _slow_request()
    var spec = _sub(range_, 6, range_.byte_length())
    var dash = spec.find("-")
    var first = Int(_sub(spec, 0, dash))
    var last = min(Int(_sub(spec, dash + 1, spec.byte_length())), _SIZE - 1)
    # An object under `ver/` answers by its request's precondition (the
    # test of every request carrying the handle's ETag, below).
    var version = 1
    if target.find("/ver/") >= 0:
        if if_match.byte_length() > 0 and if_match != '"v1"':
            return _precondition_failed()
        if if_match.byte_length() == 0 and first > 0:
            version = 2
    var body = List[UInt8](capacity=last - first + 1)
    for i in range(first, last + 1):
        body.append(_byte_at(i) if version == 1 else _v2_byte_at(i))
    var out = _bytes(
        String("HTTP/1.1 206 Partial Content\r\nContent-Length: ")
        + String(len(body))
        + "\r\nConnection: close\r\nETag: \"v"
        + String(version)
        + "\"\r\nContent-Range: bytes "
        + String(first)
        + "-"
        + String(last)
        + "/"
        + String(_SIZE)
        + "\r\n\r\n"
    )
    out.extend(Span(body))
    return out^


struct _Stream(IoStream, Movable, Deinitable):
    var _written: List[UInt8]
    var _answer: ScriptedStream
    var _answered: Bool

    def __init__(out self):
        self._written = List[UInt8]()
        self._answer = ScriptedStream()
        self._answered = False

    def try_read[
        RT: Runtime, o: Origin[mut=True],
    ](mut self, mut reactor: Reactor[RT.Sink], dst: Span[UInt8, o]) raises -> StreamIo:
        if not self._answered:
            self._answered = True
            self._answer = ScriptedStream.from_read_script(_serve(self._written))
        return self._answer.try_read[RT, o](reactor, dst)

    def try_write[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], src: Span[UInt8, _]
    ) raises -> StreamIo:
        self._written.extend(src)
        return StreamIo.ready(Int64(len(src)))

    def unread(mut self, src: Span[UInt8, _]) raises:
        self._answer.unread(src)

    def close(var self):
        pass

    def negotiated_protocol(self) -> UInt8:
        return NEGOTIATED_HTTP_1_1

    def fd(self) -> Int32:
        return Int32(-1)


struct _Connector(Connector, Movable, Deinitable):
    comptime Stream = _Stream

    def __init__(out self):
        pass

    def connect[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], ip_be: UInt32, port: UInt16
    ) raises -> _Stream:
        _ = ip_be
        _ = port
        return _Stream()

    def transport_kind(self) -> UInt8:
        return TRANSPORT_KIND_KERNEL_TCP

    def is_tls(self) -> Bool:
        return False

    def set_dial_host(mut self, var host: String):
        _ = host^


comptime _Fs = S3Fs[_Connector, StaticCredsSource, FixedClock]


def _mk() raises -> _Connector:
    return _Connector()


def _fs(
    prefetch_max_inflight: Int, upload_max_inflight: Int = 1, max_inflight: Int = 64
) raises -> _Fs:
    return _Fs.built(
        "lake",
        S3Config(
            "us-east-1",
            endpoint="http://127.0.0.1:9000",
            addressing=AddressingStyle.path(),
            retry=RetryPolicy(
                Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
                max_attempts=3,
                deadline_ms=Int64(60_000),
            ),
            max_inflight=max_inflight,
        ),
        _mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        FixedClock(1790000000),
        S3FsOptions(
            prefetch_max_inflight=prefetch_max_inflight,
            upload_part_bytes=_PART,
            upload_max_inflight=upload_max_inflight,
        ),
    )


def _far_ranges() -> List[Tuple[Int64, Int64]]:
    var ranges = List[Tuple[Int64, Int64]]()
    for i in range(_RANGES):
        ranges.append((Int64(i * _SPACING), Int64(5)))
    return ranges^


def _check(got: Slab[SharedAlignedBuffer[HeapRegion]]) raises:
    for i in range(_RANGES):
        var view = got[i].view_range_ro(0, got[i].len()).into_span()
        assert_equal(len(view), 5)
        for b in range(5):
            assert_equal(view[b], _byte_at(i * _SPACING + b))


def _timed_prefetch_ms(bound: Int, expect_k: Int, max_inflight: Int = 64) raises -> Int:
    """Milliseconds of a prefetch of the far ranges on a handle a first
    prefetch has already read through (so the stores are built and the
    handle's version is known), with the bytes checked and the fake's counts
    checked against `expect_k` in flight; `bound` is `prefetch_max_inflight`
    and `max_inflight` is S3Config's."""
    var fs = _fs(bound, max_inflight=max_inflight)
    var f = fs.open("v/big")
    _check(fs.read_ranges_prefetched(f, _far_ranges()))
    _arm(expect_k, _RANGES)
    var start = perf_counter_ns()
    var out = fs.read_ranges_prefetched(f, _far_ranges())
    var ms = Int((perf_counter_ns() - start) // 1_000_000)
    _check(out)
    _check_counts(
        String(_RANGES) + " requests under a bound of " + String(expect_k), expect_k, _RANGES
    )
    return ms


def test_a_prefetch_keeps_its_bound_in_flight() raises:
    # K = 4: two rounds of four requests.
    var ms = _timed_prefetch_ms(4, 4)
    assert_true(
        ms >= 2 * _DELAY_MS,
        String("8 requests under a bound of 4 took ") + String(ms) + " ms: more than 4 were in flight",
    )


def test_s3_config_max_inflight_caps_the_prefetch() raises:
    # prefetch_max_inflight 0 is every range at once; S3Config's max_inflight
    # of 2 caps it at two: four rounds, ceil(8 / 2) = 4 delays at least.
    var ms = _timed_prefetch_ms(0, 2, max_inflight=2)
    assert_true(
        ms >= 4 * _DELAY_MS,
        String("8 requests under S3Config.max_inflight 2 took ")
        + String(ms)
        + " ms: more than 2 were in flight",
    )


def _check_version_1(got: Slab[SharedAlignedBuffer[HeapRegion]]) raises:
    for i in range(_RANGES):
        var view = got[i].view_range_ro(0, got[i].len()).into_span()
        assert_equal(len(view), 5)
        for b in range(5):
            if view[b] != _byte_at(i * _SPACING + b):
                raise Error(
                    String("range ")
                    + String(i)
                    + " holds bytes of version 2: its request carried no If-Match"
                )


def test_every_request_of_a_prefetch_carries_the_etag() raises:
    # Under `ver/` the fake answers a read carrying If-Match "v1" with
    # version 1, and one carrying none with version 2 past offset 0, so the
    # bytes say which requests carried the handle's ETag. The first request
    # (offset 0) pins the handle to "v1"; the other seven go four at a time,
    # on every worker's store, and each must carry it. Then again on the
    # pinned handle.
    var fs = _fs(4)
    var f = fs.open("ver/big")
    _check_version_1(fs.read_ranges_prefetched(f, _far_ranges()))
    _check_version_1(fs.read_ranges_prefetched(f, _far_ranges()))
    assert_equal(fs.stores_built(), 4)


def test_a_bound_of_one_is_one_at_a_time() raises:
    var ms = _timed_prefetch_ms(1, 1)
    assert_true(
        ms >= _RANGES * _DELAY_MS,
        String("8 requests under a bound of 1 took ") + String(ms) + " ms: more than 1 was in flight",
    )


def _timed_write_ms(bound: Int) raises -> Int:
    """Milliseconds of a write of the _PARTS parts (one write_at and the
    close), the completion checked by the fake and its counts checked against
    `bound` in flight."""
    var fs = _fs(1, bound)
    var total = (_PARTS - 1) * _PART + _LAST
    var data = List[UInt8](capacity=total)
    for i in range(total):
        data.append(_pattern_at(i))
    var w = fs.open_write("w/big", WriteMode.create_truncate())
    _arm(bound, _PARTS)
    var start = perf_counter_ns()
    assert_equal(fs.write_at(w, Span(data)), Int64(total))
    fs.close_write(w^)
    var ms = Int((perf_counter_ns() - start) // 1_000_000)
    _check_counts(
        String(_PARTS) + " parts under a bound of " + String(bound), bound, _PARTS
    )
    return ms


def test_a_write_keeps_its_bound_in_flight() raises:
    # K = 3: parts 1-3 together once three are held, then 4-6 at close.
    var ms = _timed_write_ms(3)
    assert_true(
        ms >= 2 * _DELAY_MS,
        String("6 parts under a bound of 3 took ") + String(ms) + " ms: more than 3 were in flight",
    )


def test_file_systems_made_and_dropped_over_and_over() raises:
    # Each cycle builds a file system, runs a prefetch on 4 threads and a
    # write on 3 (its worker stores built, used and joined), and drops it.
    var total = (_PARTS - 1) * _PART + _LAST
    var data = List[UInt8](capacity=total)
    for i in range(total):
        data.append(_pattern_at(i))
    for _ in range(12):
        var fs = _fs(4, 3)
        var f = fs.open("fast/big")
        _check(fs.read_ranges_prefetched(f, _far_ranges()))
        _check(fs.read_ranges_prefetched(f, _far_ranges()))
        var w = fs.open_write("fast/w", WriteMode.create_truncate())
        _ = fs.write_at(w, Span(data))
        fs.close_write(w^)
        assert_equal(fs.stores_built(), 4)


def test_a_write_bound_of_one_is_one_part_at_a_time() raises:
    var ms = _timed_write_ms(1)
    assert_true(
        ms >= _PARTS * _DELAY_MS,
        String("6 parts under a bound of 1 took ") + String(ms) + " ms: more than 1 was in flight",
    )


# =============================================================================
# run_bounded_inflight, over a fake store that counts its requests in flight.
# =============================================================================
#
# `_FakeStore` is what each job "sends" to: it counts the requests in flight
# (an atomic the jobs share), keeps the highest count it saw, and holds each
# request until either the bound's worth are in flight or 300 ms pass, so a
# runner that keeps the bound in flight reaches it every time and one that
# keeps more is seen at once. Each job records the worker it ran on.


struct _FakeStore[io: MutOrigin, po: MutOrigin, ro: MutOrigin](InflightJobs):
    var in_flight: Pointer[AtomicI64, Self.io]
    var peak: Pointer[AtomicI64, Self.po]
    var ran_on: Pointer[List[Int], Self.ro]
    var wait_for: Int
    var fail_job: Int

    def __init__(
        out self,
        in_flight: Pointer[AtomicI64, Self.io],
        peak: Pointer[AtomicI64, Self.po],
        ran_on: Pointer[List[Int], Self.ro],
        wait_for: Int,
        fail_job: Int = -1,
    ):
        self.in_flight = in_flight
        self.peak = peak
        self.ran_on = ran_on
        self.wait_for = wait_for
        self.fail_job = fail_job

    def run_job(self, worker: Int, job: Int) raises:
        var now = self.in_flight[].fetch_add(1) + 1
        var seen = self.peak[].load()
        while now > seen:
            if self.peak[].compare_exchange(seen, now):
                break
        var waited = 0
        while self.in_flight[].load() < Int64(self.wait_for) and waited < 300:
            _ = external_call["usleep", Int32](UInt32(1000))
            waited += 1
        _ = external_call["usleep", Int32](UInt32(2000))
        _ = self.in_flight[].fetch_sub(1)
        if self.ran_on[][job] != -1:
            raise Error(String("job ") + String(job) + " ran twice")
        self.ran_on[][job] = worker
        if job == self.fail_job:
            raise Error(String("job ") + String(job) + " failed")


def _run(n_jobs: Int, bound: Int, fail_job: Int = -1) raises -> Tuple[Int, List[Int]]:
    """The peak in flight and the worker each job ran on."""
    var in_flight = AtomicI64(0)
    var peak = AtomicI64(0)
    var ran_on = List[Int](length=n_jobs, fill=-1)
    var store = _FakeStore(
        Pointer(to=in_flight),
        Pointer(to=peak),
        Pointer(to=ran_on),
        inflight_workers(n_jobs, bound),
        fail_job,
    )
    run_bounded_inflight(store, n_jobs, bound)
    return (Int(peak.load()), ran_on^)


def test_the_workers() raises:
    assert_equal(inflight_workers(0, 4), 0)
    assert_equal(inflight_workers(20, 4), 4)
    assert_equal(inflight_workers(3, 4), 3)
    assert_equal(inflight_workers(5, 1), 1)
    assert_equal(inflight_workers(5, 0), 1)
    assert_equal(inflight_workers(5, -2), 1)


def test_the_bound_is_kept_in_flight_and_never_passed() raises:
    var got = _run(20, 4)
    assert_equal(got[0], 4, "the peak in flight is not the bound")
    for j in range(20):
        assert_true(got[1][j] >= 0 and got[1][j] < 4, String("job ") + String(j) + " ran on no worker")


def test_fewer_jobs_than_the_bound() raises:
    var got = _run(5, 16)
    assert_equal(got[0], 5)


def test_a_bound_of_one_runs_in_order_on_the_caller() raises:
    var got = _run(6, 1)
    assert_equal(got[0], 1)
    for j in range(6):
        assert_equal(got[1][j], 0)


def test_a_failed_job_is_raised_and_stops_new_jobs() raises:
    var in_flight = AtomicI64(0)
    var peak = AtomicI64(0)
    var ran_on = List[Int](length=40, fill=-1)
    var store = _FakeStore(Pointer(to=in_flight), Pointer(to=peak), Pointer(to=ran_on), 1, 0)
    with assert_raises(contains="job 0 failed"):
        run_bounded_inflight(store, 40, 2)
    var ran = 0
    for j in range(40):
        if ran_on[j] != -1:
            ran += 1
    assert_true(ran < 40, "every job ran after one failed")


def main() raises:
    test_the_bound_is_kept_in_flight_and_never_passed()
    test_fewer_jobs_than_the_bound()
    test_a_bound_of_one_runs_in_order_on_the_caller()
    test_a_failed_job_is_raised_and_stops_new_jobs()
    test_the_workers()
    test_a_write_keeps_its_bound_in_flight()
    test_a_write_bound_of_one_is_one_part_at_a_time()
    test_a_prefetch_keeps_its_bound_in_flight()
    test_a_bound_of_one_is_one_at_a_time()
    test_s3_config_max_inflight_caps_the_prefetch()
    test_every_request_of_a_prefetch_carries_the_etag()
    test_file_systems_made_and_dropped_over_and_over()
    print("OK")
