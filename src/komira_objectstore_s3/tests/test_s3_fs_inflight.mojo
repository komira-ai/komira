# S3Fs keeps up to its in-flight bound of requests in flight, and never more.
#
# Over S3Fs, with a fake S3 whose every ranged GET and UploadPart takes
# _DELAY_MS: a prefetch of _RANGES ranges too far apart to coalesce, with
# `prefetch_max_inflight` K, takes at least ceil(_RANGES / K) delays (more
# than K requests at once would finish sooner) and well under _RANGES delays
# (one request at a time takes that long); a write of _PARTS parts with
# `upload_max_inflight` K likewise. The fake holds no state: a connector
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


def _byte_at(i: Int) -> UInt8:
    return UInt8(0x61 + i % 26)


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
            _ = external_call["usleep", Int32](UInt32(_DELAY_MS * 1000))
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
    for i in range(1, len(lines)):
        var line = String(lines[i])
        var colon = line.find(":")
        if colon > 0 and _sub(line, 0, colon).lower() == "range":
            range_ = String(_sub(line, colon + 1, line.byte_length()).strip())
    if range_.byte_length() == 0:
        raise Error("the fake S3 answers ranged GETs only")
    if slow:
        _ = external_call["usleep", Int32](UInt32(_DELAY_MS * 1000))
    var spec = _sub(range_, 6, range_.byte_length())
    var dash = spec.find("-")
    var first = Int(_sub(spec, 0, dash))
    var last = min(Int(_sub(spec, dash + 1, spec.byte_length())), _SIZE - 1)
    var body = List[UInt8](capacity=last - first + 1)
    for i in range(first, last + 1):
        body.append(_byte_at(i))
    var out = _bytes(
        String("HTTP/1.1 206 Partial Content\r\nContent-Length: ")
        + String(len(body))
        + "\r\nConnection: close\r\nETag: \"v1\"\r\nContent-Range: bytes "
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


def _fs(prefetch_max_inflight: Int, upload_max_inflight: Int = 1) raises -> _Fs:
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


def _timed_prefetch_ms(bound: Int) raises -> Int:
    """Milliseconds of a prefetch of the far ranges on a handle a first
    prefetch has already read through (so the stores are built and the
    handle's version is known), with the bytes checked."""
    var fs = _fs(bound)
    var f = fs.open("v/big")
    _check(fs.read_ranges_prefetched(f, _far_ranges()))
    var start = perf_counter_ns()
    var out = fs.read_ranges_prefetched(f, _far_ranges())
    var ms = Int((perf_counter_ns() - start) // 1_000_000)
    _check(out)
    return ms


def test_a_prefetch_keeps_its_bound_in_flight() raises:
    # K = 4: two rounds of four requests.
    var ms = _timed_prefetch_ms(4)
    assert_true(
        ms >= 2 * _DELAY_MS,
        String("8 requests under a bound of 4 took ") + String(ms) + " ms: more than 4 were in flight",
    )
    assert_true(
        ms < 6 * _DELAY_MS,
        String("8 requests under a bound of 4 took ") + String(ms) + " ms: they were not sent 4 at a time",
    )


def test_a_bound_of_one_is_one_at_a_time() raises:
    var ms = _timed_prefetch_ms(1)
    assert_true(
        ms >= _RANGES * _DELAY_MS,
        String("8 requests under a bound of 1 took ") + String(ms) + " ms: more than 1 was in flight",
    )


def _timed_write_ms(bound: Int) raises -> Int:
    """Milliseconds of a write of the _PARTS parts (one write_at and the
    close), the completion checked by the fake."""
    var fs = _fs(1, bound)
    var total = (_PARTS - 1) * _PART + _LAST
    var data = List[UInt8](capacity=total)
    for i in range(total):
        data.append(_pattern_at(i))
    var w = fs.open_write("w/big", WriteMode.create_truncate())
    var start = perf_counter_ns()
    assert_equal(fs.write_at(w, Span(data)), Int64(total))
    fs.close_write(w^)
    return Int((perf_counter_ns() - start) // 1_000_000)


def test_a_write_keeps_its_bound_in_flight() raises:
    # K = 3: parts 1-3 together once three are held, then 4-6 at close.
    var ms = _timed_write_ms(3)
    assert_true(
        ms >= 2 * _DELAY_MS,
        String("6 parts under a bound of 3 took ") + String(ms) + " ms: more than 3 were in flight",
    )
    assert_true(
        ms < 5 * _DELAY_MS,
        String("6 parts under a bound of 3 took ") + String(ms) + " ms: they were not sent 3 at a time",
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
    test_file_systems_made_and_dropped_over_and_over()
    print("OK")
