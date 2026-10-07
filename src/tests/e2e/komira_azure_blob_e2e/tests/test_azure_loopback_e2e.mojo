# =============================================================================
# test_azure_loopback_e2e.mojo -- AzureFs over a real socket, against a fake
# Blob service that checks every signature itself
# =============================================================================
#
# `AzureFs[KernelTcpConnector]` (and `AzureClient` directly) with path-style
# (emulator) addressing, the Azurite development account and its published
# key, against `FakeBlobService` on 127.0.0.1:0 stepped by a real
# `komira_http_server` on a second thread. Nothing is scripted: every request
# is serialized by `HttpClient`, crosses the kernel's loopback, is parsed by
# the server, and is answered from the fake's blobs.
#
# The fake recomputes each request's Shared Key string-to-sign from what
# arrived on the wire, with its own canonicalizer (shared_key_oracle.mojo),
# and answers 403 AuthenticationFailed on a mismatch. So every test below that
# expects data also proves the signer and the service agree on the request
# AzureStore sent: its x-ms-* headers, its Range, its path-style resource
# and its query parameters (List Blobs, the percent-encoded marker included).
#
# Tests, and the defect each catches:
#   test_reads_over_loopback -- read_at (first bytes, a middle range, the
#     last byte), a range past EOF that the service answers short (AzureFs
#     refuses it as a short read), file_size (HEAD), read_footer (HEAD, then
#     the tail range), read_ranges_prefetched, AzureClient.head_blob and
#     get_blob_range, and a blob whose name holds `&` (percent-encoded on the
#     wire path, which the signature covers); the server's log pins each
#     path and Range header on the wire.
#     Catches: a wrong Range (an off-by-one in end_inclusive), a body copied
#     wrong, Content-Length / ETag not read from HEAD, any signing drift.
#     An end off by one is caught two ways: the ranges inside the blob
#     (0+16, 500+37, 10..19) come back one byte long; the ranges that end
#     at the last byte (999+1, the footer, prefetched 996+4) do not, because
#     the fake clamps a range past the end, so for those only the wire log
#     ("the requests on the wire") goes red.
#   test_listing_pages_over_loopback -- list (recursive, four pages of two),
#     list_dir_shallow under a prefix (three pages, delimiter folds, the
#     directory's own marker blob skipped) and at the container root, is_dir
#     (a prefix, a nested prefix, a blob, nothing). The log pins how many
#     List Blobs requests were made and that each later page carried the
#     previous NextMarker, percent-encoded. Catches: pagination stopping early
#     or looping, a marker not encoded or not signed decoded (the second
#     page is refused 403), a fold read as a file, prefix normalization.
#   test_errors_over_loopback -- a missing blob on HEAD and on GET (404, read
#     as NOT_FOUND; the GET carries azure_code=BlobNotFound), a range starting
#     at EOF (416, read as MALFORMED), a missing container (404
#     ContainerNotFound, NOT_FOUND). Catches: the status taxonomy mis-mapped.
#   test_wrong_key_is_refused -- the same account with another key: HEAD,
#     GET and List Blobs are each refused 403 AuthenticationFailed, read as
#     PERMISSION_DENIED. Proves the fake's check can fail (a check that
#     accepts anything would pass every test above) and catches a
#     403 mapped to anything else.
#
# Not asserted: the ContainerName of a List Blobs result. azure_xml cannot
# read XML attributes, so it is always empty today (komira issue #356); the
# fake sends it, and a test should assert it once that is fixed.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_azure_blob import AzureClient, AzureConfig, AzureFs
from komira_azure_blob.azure import (
    AZURE_ERR_MALFORMED,
    AZURE_ERR_NOT_FOUND,
    AZURE_ERR_PERMISSION_DENIED,
    azure_store_error_kind_from_message,
)
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_encoding import base64_encode
from komira_fs.shallow_dir_entry import ShallowDirEntry
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_azure_blob_e2e import (
    AZURITE_ACCOUNT,
    AZURITE_KEY_B64,
    BlobServeLoop,
    ClientLeg,
    FakeBlobService,
    serve_while,
)


comptime _Fs = AzureFs[KernelTcpConnector]
comptime _CONTAINER = "lake"
comptime _EVENTS = "data/events.bin"
comptime _EVENTS_SIZE = 1000
comptime _PAGE_SIZE = 2

comptime _SCENARIO_READS = 1
comptime _SCENARIO_LISTING = 2
comptime _SCENARIO_ERRORS = 3
comptime _SCENARIO_WRONG_KEY = 4


def _pattern(i: Int) -> UInt8:
    return UInt8((i * 7 + 3) % 251)


def _blob(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(_pattern(i))
    return out^


def _fixture() -> FakeBlobService:
    var s = FakeBlobService(
        String(AZURITE_ACCOUNT), String(AZURITE_KEY_B64), String(_CONTAINER),
        _PAGE_SIZE,
    )
    s.put(String(_EVENTS), _blob(_EVENTS_SIZE))
    s.put(String("data/"), List[UInt8]())  # a directory marker blob
    s.put(String("data/notes&more.txt"), _blob(5))
    s.put(String("data/year=2025/part-0.parquet"), _blob(16))
    s.put(String("data/year=2025/part-1.parquet"), _blob(17))
    s.put(String("data/year=2026/month=01/part-0.parquet"), _blob(18))
    s.put(String("data/year=2026/part-0.parquet"), _blob(19))
    s.put(String("data/zzz.bin"), _blob(20))
    s.put(String("data.parquet"), _blob(21))
    s.put(String("other/readme.txt"), _blob(22))
    return s^


def _client(port: UInt16, key_b64: String) raises -> AzureClient[KernelTcpConnector]:
    return AzureClient[KernelTcpConnector](
        account=String(AZURITE_ACCOUNT),
        key_b64=key_b64,
        connector=KernelTcpConnector.new(),
        call_connector=KernelTcpConnector.new(),
        config=AzureConfig.azurite(
            String(AZURITE_ACCOUNT), String("127.0.0.1"), port
        ),
    )


def _no_factory() raises -> AzureClient[KernelTcpConnector]:
    """`AzureFs`'s clone factory. These tests never clone (a thin function
    cannot carry the port the server picked at run time)."""
    raise Error("the loopback tests do not clone an AzureFs")


def _wrong_key() -> String:
    var k = List[UInt8]()
    for _ in range(64):
        k.append(UInt8(0x5A))
    return base64_encode(k)


def _expect_bytes(
    buf: SharedAlignedBuffer[HeapRegion], offset: Int, length: Int, what: String
) raises:
    assert_equal(buf.len(), length, what + ": length")
    for i in range(length):
        if buf.read_u8_at(i) != _pattern(offset + i):
            raise Error(what + ": byte " + String(i) + " differs")


def _error_of_file_size(fs: _Fs, path: String) -> String:
    try:
        _ = fs.file_size(path)
    except e:
        return String(e)
    return String("")


def _error_of_read(fs: _Fs, path: String, offset: Int, length: Int) -> String:
    try:
        var h = fs.open(path)
        _ = fs.read_at(h, Int64(offset), Int64(length))
    except e:
        return String(e)
    return String("")


def _error_of_list(fs: _Fs, prefix: String) -> String:
    try:
        _ = fs.list(prefix)
    except e:
        return String(e)
    return String("")


def _assert_kind(msg: String, kind: UInt8, what: String) raises:
    assert_true(msg.byte_length() > 0, what + ": no error raised")
    assert_equal(
        Int(azure_store_error_kind_from_message(msg)), Int(kind), what + ": " + msg
    )


def _sorted_entries(xs: List[ShallowDirEntry]) -> List[String]:
    """`name` plus `/` for a directory, sorted: the set of children, whatever
    order the pages delivered them in.

    A deliberate tolerance: list_dir_shallow emits each page's prefixes
    before its blobs, so its order is not name order (komira issue #524).
    Compare the returned order directly once that is fixed."""
    var out = List[String]()
    for i in range(len(xs)):
        var suffix = String("/") if xs[i].is_dir else String("")
        out.append(xs[i].name + suffix)
    for i in range(1, len(out)):
        var k = out[i]
        var j = i - 1
        while j >= 0 and out[j] > k:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = k
    return out^


def _assert_names(got: List[String], var want: List[String], what: String) raises:
    var g = String()
    for i in range(len(got)):
        g += got[i] + " | "
    var w = String()
    for i in range(len(want)):
        w += want[i] + " | "
    assert_equal(g, w, what)


# =============================================================================
# The client leg: one scenario, run on the client thread.
# =============================================================================


struct _Leg(ClientLeg):
    var port: UInt16
    var scenario: Int
    var key_b64: String

    def __init__(out self, port: UInt16, scenario: Int, var key_b64: String):
        self.port = port
        self.scenario = scenario
        self.key_b64 = key_b64^

    def run(mut self) raises:
        var fs = _Fs(
            container=String(_CONTAINER),
            client=_client(self.port, self.key_b64),
            mk_client=_no_factory,
        )
        if self.scenario == _SCENARIO_READS:
            self._reads(fs)
        elif self.scenario == _SCENARIO_LISTING:
            self._listing(fs)
        elif self.scenario == _SCENARIO_ERRORS:
            self._errors(fs)
        else:
            self._wrong_key(fs)

    def _reads(self, fs: _Fs) raises:
        var h = fs.open(String(_EVENTS))
        _expect_bytes(fs.read_at(h, Int64(0), Int64(16)), 0, 16, "read_at 0+16")
        _expect_bytes(fs.read_at(h, Int64(500), Int64(37)), 500, 37, "read_at 500+37")
        _expect_bytes(fs.read_at(h, Int64(999), Int64(1)), 999, 1, "the last byte")

        # 990+20 runs 10 bytes past the end: the service answers 206 with the
        # 10 bytes that exist, and AzureFs refuses the short body.
        var short = _error_of_read(fs, String(_EVENTS), 990, 20)
        assert_true(short.find("short read") >= 0, "short read at EOF: " + short)
        assert_true(short.find("got 10") >= 0, "short read at EOF: " + short)

        assert_equal(fs.file_size(String(_EVENTS)), _EVENTS_SIZE, "file_size")

        var footer = fs.read_footer(String(_EVENTS), 64)
        assert_equal(footer.offset, _EVENTS_SIZE - 64, "read_footer offset")
        assert_equal(footer.file_size, _EVENTS_SIZE, "read_footer file_size")
        assert_equal(len(footer.bytes), 64, "read_footer length")
        for i in range(64):
            assert_equal(footer.bytes[i], _pattern(_EVENTS_SIZE - 64 + i), "footer byte")

        var ranges = List[Tuple[Int64, Int64]]()
        ranges.append((Int64(0), Int64(4)))
        ranges.append((Int64(996), Int64(4)))
        var bufs = fs.read_ranges_prefetched(h, ranges)
        assert_equal(len(bufs), 2, "read_ranges_prefetched count")
        _expect_bytes(bufs[0], 0, 4, "prefetched range 0")
        _expect_bytes(bufs[1], 996, 4, "prefetched range 1")

        # AzureClient's own verbs, on a second client.
        var client = _client(self.port, self.key_b64)
        var meta = client.head_blob(String(_CONTAINER), String(_EVENTS))
        assert_equal(Int(meta.size), _EVENTS_SIZE, "head_blob size")
        assert_true(meta.etag.startswith('"0x8DC'), "head_blob etag: " + meta.etag)
        var got = client.get_blob_range(
            String(_CONTAINER), String(_EVENTS), Int64(10), Int64(19)
        )
        assert_equal(len(got), 10, "get_blob_range length")
        for i in range(10):
            assert_equal(got[i], _pattern(10 + i), "get_blob_range byte")

        # A name with a reserved character: the wire path carries it
        # percent-encoded, and the signature covers the encoded path.
        var amp = fs.open(String("data/notes&more.txt"))
        _expect_bytes(fs.read_at(amp, Int64(0), Int64(5)), 0, 5, "notes&more.txt")

    def _listing(self, fs: _Fs) raises:
        var want = List[String]()
        want.append(String("data/"))
        want.append(String("data/events.bin"))
        want.append(String("data/notes&more.txt"))
        want.append(String("data/year=2025/part-0.parquet"))
        want.append(String("data/year=2025/part-1.parquet"))
        want.append(String("data/year=2026/month=01/part-0.parquet"))
        want.append(String("data/year=2026/part-0.parquet"))
        want.append(String("data/zzz.bin"))
        _assert_names(fs.list(String("data/")), want^, "list data/ (all pages)")

        var shallow = List[String]()
        shallow.append(String("events.bin"))
        shallow.append(String("notes&more.txt"))
        shallow.append(String("year=2025/"))
        shallow.append(String("year=2026/"))
        shallow.append(String("zzz.bin"))
        _assert_names(
            _sorted_entries(fs.list_dir_shallow(String("data"))),
            shallow^,
            "list_dir_shallow data",
        )

        var root = List[String]()
        root.append(String("data.parquet"))
        root.append(String("data/"))
        root.append(String("other/"))
        _assert_names(
            _sorted_entries(fs.list_dir_shallow(String(""))),
            root^,
            "list_dir_shallow at the root",
        )

        assert_true(fs.is_dir(String("data")), "is_dir data")
        assert_true(fs.is_dir(String("data/year=2025")), "is_dir data/year=2025")
        assert_false(fs.is_dir(String(_EVENTS)), "is_dir on a blob")
        assert_false(fs.is_dir(String("nothing")), "is_dir on nothing")

    def _errors(self, fs: _Fs) raises:
        _assert_kind(
            _error_of_file_size(fs, String("data/missing.bin")),
            AZURE_ERR_NOT_FOUND, "HEAD of a missing blob",
        )
        var get404 = _error_of_read(fs, String("data/missing.bin"), 0, 4)
        _assert_kind(get404, AZURE_ERR_NOT_FOUND, "GET of a missing blob")
        assert_true(get404.find("azure_code=BlobNotFound") >= 0, get404)

        var at_eof = _error_of_read(fs, String(_EVENTS), _EVENTS_SIZE, 4)
        _assert_kind(at_eof, AZURE_ERR_MALFORMED, "a range starting at EOF")
        assert_true(at_eof.find("status=416") >= 0, at_eof)

        var other = _Fs(
            container=String("nocontainer"),
            client=_client(self.port, self.key_b64),
            mk_client=_no_factory,
        )
        var no_container = _error_of_list(other, String(""))
        _assert_kind(no_container, AZURE_ERR_NOT_FOUND, "a missing container")
        assert_true(no_container.find("azure_code=ContainerNotFound") >= 0, no_container)

    def _wrong_key(self, fs: _Fs) raises:
        _assert_kind(
            _error_of_file_size(fs, String(_EVENTS)),
            AZURE_ERR_PERMISSION_DENIED, "HEAD under the wrong key",
        )
        var get403 = _error_of_read(fs, String(_EVENTS), 0, 4)
        _assert_kind(get403, AZURE_ERR_PERMISSION_DENIED, "GET under the wrong key")
        assert_true(get403.find("azure_code=AuthenticationFailed") >= 0, get403)
        _assert_kind(
            _error_of_list(fs, String("data/")),
            AZURE_ERR_PERMISSION_DENIED, "List Blobs under the wrong key",
        )


def _run(scenario: Int, var key_b64: String) raises -> BlobServeLoop:
    var loop = BlobServeLoop(_fixture())
    var leg = _Leg(loop.port(), scenario, key_b64^)
    serve_while(loop, leg)
    _ = leg^
    return loop^


def _signed_ok(loop: BlobServeLoop) raises:
    assert_equal(
        loop.service.auth_failures, 0,
        "requests the fake refused; it signed: "
        + loop.service.last_refused_string_to_sign,
    )


# =============================================================================
# Tests
# =============================================================================


def test_reads_over_loopback() raises:
    var loop = _run(_SCENARIO_READS, String(AZURITE_KEY_B64))
    _signed_ok(loop)
    # Every request, in order, as the server parsed it: verb, path, Range
    # ("" on HEAD) and the status it was answered with.
    var ev = "/" + String(AZURITE_ACCOUNT) + "/lake/data/events.bin "
    var want = List[String]()
    want.append("GET " + ev + "bytes=0-15 206")
    want.append("GET " + ev + "bytes=500-536 206")
    want.append("GET " + ev + "bytes=999-999 206")
    want.append("GET " + ev + "bytes=990-1009 206")
    want.append("HEAD " + ev + " 200")
    want.append("HEAD " + ev + " 200")
    want.append("GET " + ev + "bytes=936-999 206")
    want.append("GET " + ev + "bytes=0-3 206")
    want.append("GET " + ev + "bytes=996-999 206")
    want.append("HEAD " + ev + " 200")
    want.append("GET " + ev + "bytes=10-19 206")
    want.append(
        "GET /" + String(AZURITE_ACCOUNT) + "/lake/data/notes%26more.txt"
        + " bytes=0-4 206"
    )
    var got = List[String]()
    for i in range(len(loop.service.log)):
        ref r = loop.service.log[i]
        got.append(
            r.method + " " + r.path + " " + r.range_header + " " + String(r.status)
        )
    _assert_names(got, want^, "the requests on the wire")
    print("  test_reads_over_loopback PASS")


def test_listing_pages_over_loopback() raises:
    var loop = _run(_SCENARIO_LISTING, String(AZURITE_KEY_B64))
    _signed_ok(loop)
    # Each List Blobs request's query, as it arrived: the recursive list's
    # four pages, the shallow list's three, the root's two, one per is_dir.
    var want = List[String]()
    var base = String("restype=container&comp=list")
    want.append(base + "&prefix=data%2F")
    want.append(base + "&prefix=data%2F&marker=2%21mk%3D2%2Fp")
    want.append(base + "&prefix=data%2F&marker=2%21mk%3D4%2Fp")
    want.append(base + "&prefix=data%2F&marker=2%21mk%3D6%2Fp")
    want.append(base + "&prefix=data%2F&delimiter=%2F")
    want.append(base + "&prefix=data%2F&delimiter=%2F&marker=2%21mk%3D2%2Fp")
    want.append(base + "&prefix=data%2F&delimiter=%2F&marker=2%21mk%3D4%2Fp")
    want.append(base + "&delimiter=%2F")
    want.append(base + "&delimiter=%2F&marker=2%21mk%3D2%2Fp")
    want.append(base + "&prefix=data%2F&delimiter=%2F")
    want.append(base + "&prefix=data%2Fyear%3D2025%2F&delimiter=%2F")
    want.append(base + "&prefix=data%2Fevents.bin%2F&delimiter=%2F")
    want.append(base + "&prefix=nothing%2F&delimiter=%2F")
    var got = List[String]()
    for i in range(len(loop.service.log)):
        ref r = loop.service.log[i]
        assert_equal(r.method, "GET", "List Blobs verb")
        assert_equal(r.path, "/" + String(AZURITE_ACCOUNT) + "/lake", "List Blobs path")
        assert_equal(r.status, 200, "List Blobs status: " + r.query)
        got.append(r.query)
    _assert_names(got, want^, "the List Blobs requests on the wire")
    print("  test_listing_pages_over_loopback PASS")


def test_errors_over_loopback() raises:
    var loop = _run(_SCENARIO_ERRORS, String(AZURITE_KEY_B64))
    _signed_ok(loop)
    var statuses = String()
    for i in range(len(loop.service.log)):
        statuses += String(loop.service.log[i].status) + " "
    assert_equal(statuses, String("404 404 416 404 "), "the statuses served")
    print("  test_errors_over_loopback PASS")


def test_wrong_key_is_refused() raises:
    var loop = _run(_SCENARIO_WRONG_KEY, _wrong_key())
    assert_equal(loop.service.auth_failures, 3, "requests refused 403")
    for i in range(len(loop.service.log)):
        assert_equal(loop.service.log[i].status, 403, "status under the wrong key")
    print("  test_wrong_key_is_refused PASS")


def main() raises:
    test_reads_over_loopback()
    test_listing_pages_over_loopback()
    test_errors_over_loopback()
    test_wrong_key_is_refused()
    print("PASS komira_azure_blob_e2e loopback")
