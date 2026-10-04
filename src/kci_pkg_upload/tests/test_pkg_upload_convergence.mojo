# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_convergence.mojo — an
#   upload whose outcome is UNKNOWN converges, and never writes twice.
# =============================================================================
#
# THE SCENARIO. The registry STORES the upload, then the transport raises
# before the answer arrives. The client cannot know whether bytes landed, so
# the answer is UNKNOWN. The caller re-probes; the index is served through a
# cache and still reads ABSENT (stale). The caller re-uploads; the registry
# answers the duplicate. The caller reads back: PRESENT and IDENTICAL —
# converged. The registry accepted exactly ONE write.
#
# The registry here is a STATEFUL MODEL, not a FIFO script, so "one accepted
# write" is counted by the thing that would have done the writing:
# `_FakeRegistry` parses each POST's multipart body, stores the file on first
# sight, answers duplicates the way the configured registry does, and serves
# its simple index / JSON API from a view that can be held STALE for N reads.
#
# The ORCHESTRATION of these steps belongs to the publisher, not to this
# library. What this test holds is that the four methods answer every step
# with the kind the publisher needs:
#   presence ABSENT -> upload UNKNOWN (fault after store) -> presence ABSENT
#   (stale) -> upload (duplicate) -> read_back PRESENT, MATCH.
#
# ROWS
#   (1) warehouse: an IDENTICAL re-upload answers 200 (CREATED) without a
#       second write; the read-back matches; accepted writes == 1;
#   (2) a DIFFERENT file under the same name: DUPLICATE_REFUSED at upload, and
#       the read-back MISMATCHES — the case the caller turns into CONFLICT.
#
# Hermetic: no network.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST

from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.credential import SURFACE_PYPI_UPLOAD, ScriptedCredential
from kci_pkg_upload.identity import (
    IDENTITY_MATCH,
    IDENTITY_MISMATCH,
    content_identity_of,
    identity_matches,
)
from kci_pkg_upload.outcome import (
    PRESENCE_ABSENT,
    READ_PRESENT,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_UNKNOWN,
    presence_kind_name,
    upload_kind_name,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgRequest, PkgResponse, PkgTransport
from kci_pkg_upload.wire import bytes_find, bytes_of


comptime _WHEEL: String = "komira_probe-1.1.4-py3-none-linux_x86_64.whl"
comptime _MODE_WAREHOUSE: Int = 1


struct _FakeRegistry(PkgTransport, Deinitable):
    """A package registry MODEL. One file name, one stored body at most.

      mode                WAREHOUSE (identical dup -> 200, different dup ->
                          400 "File already exists").
      fault_after_store   the FIRST accepted POST stores the file and then the
                          transport raises (the answer is lost).
      stale_reads         the next N index reads still serve the pre-upload
                          view (a cache).

    Layout: owned values. No pointer field."""

    var mode: Int
    var fault_after_store: Bool
    var stale_reads: Int
    var stored: Bool
    var stored_bytes: List[UInt8]
    var accepted_writes: Int
    var posts: Int

    def __init__(out self, mode: Int, fault_after_store: Bool, stale_reads: Int):
        self.mode = mode
        self.fault_after_store = fault_after_store
        self.stale_reads = stale_reads
        self.stored = False
        self.stored_bytes = List[UInt8]()
        self.accepted_writes = 0
        self.posts = 0

    def exchange(mut self, req: PkgRequest) raises -> PkgResponse:
        if req.method == HTTP_METHOD_POST:
            return self._post(req)
        if req.method == HTTP_METHOD_GET:
            return self._index()
        raise Error("the fake registry models GET and POST only")

    def _post(mut self, req: PkgRequest) raises -> PkgResponse:
        self.posts += 1
        var content = _multipart_content(req)
        if not self.stored:
            self.stored = True
            self.stored_bytes = content^
            self.accepted_writes += 1
            if self.fault_after_store:
                self.fault_after_store = False
                raise Error("connection reset after the registry stored the upload")
            return PkgResponse(200)
        var same = len(content) == len(self.stored_bytes)
        if same:
            for i in range(len(content)):
                if content[i] != self.stored_bytes[i]:
                    same = False
                    break
        if same:
            return PkgResponse(200)  # warehouse: an identical duplicate is OK, no write
        var r = PkgResponse(400)
        r.with_body(bytes_of(String("File already exists ('") + String(_WHEEL) + String("')")))
        return r^

    def _index(mut self) raises -> PkgResponse:
        var visible = self.stored
        if self.stale_reads > 0:
            self.stale_reads -= 1
            visible = False
        var sha = content_identity_of(self.stored_bytes).sha256_hex
        var files = String("")
        if visible:
            files = (
                String('{"filename": "')
                + String(_WHEEL)
                + String('", "url": "/f", "hashes": {"sha256": "')
                + sha
                + String('"}, "digests": {"sha256": "')
                + sha
                + String('"}}')
            )
        var r = PkgResponse(200)
        r.with_header(String("content-type"), String("application/json"))
        r.with_body(bytes_of(String('{"urls": [') + files + String("]}")))
        return r^


def _multipart_content(req: PkgRequest) raises -> List[UInt8]:
    """The `content` part's bytes of a legacy upload body."""
    var ct = req.header_value(String("Content-Type"))
    var at = ct.find(String("boundary="))
    if at < 0:
        raise Error("the upload has no multipart boundary")
    var boundary = String(ct[byte = at + 9 :])
    var start = bytes_find(Span(req.body), String('name="content"; filename="'))
    if start < 0:
        raise Error("the upload has no content part")
    var body_start = bytes_find(Span(req.body), String("\r\n\r\n"), start) + 4
    var end = bytes_find(Span(req.body), String("\r\n--") + boundary + String("--"), body_start)
    if end < 0:
        raise Error("the upload has no closing delimiter")
    var out = List[UInt8]()
    for i in range(body_start, end):
        out.append(req.body[i])
    return out^


def _creds() -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, String("Basic warehouse-upload"))
    return c^


def _file(substrate: Int, repo: String, content: String) -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            substrate,
            repo.copy(),
            String("komira_probe"),
            String("1.1.4"),
            String("linux-64"),
            String(_WHEEL),
        ),
        bytes_of(content),
        String("Metadata-Version: 2.1\nName: komira_probe\nVersion: 1.1.4\n\n"),
    )


def _names() raises -> ApprovedNames:
    """The approved names the uploads here are held to. Every distribution in
    this file is on it, so the verdicts under test are the registry's, never
    the name's (test_pkg_upload_approved_names.mojo covers the refusal)."""
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    return p^


def test_warehouse_identical_reupload_is_created_without_a_write() raises:
    var rs = RegistrySet[_FakeRegistry, ScriptedCredential](
        _FakeRegistry(_MODE_WAREHOUSE, fault_after_store=True, stale_reads=1), _creds()
    )
    var f = _file(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"), String("the wheel"))
    assert_equal(rs.upload(f, _names()).kind, UPLOAD_UNKNOWN)
    assert_equal(rs.presence(f.coordinate, f.identity).kind, PRESENCE_ABSENT)
    var u2 = rs.upload(f, _names())
    assert_equal(u2.kind, UPLOAD_CREATED, upload_kind_name(u2.kind))
    var rb = rs.read_back(f.coordinate)
    assert_equal(rb.kind, READ_PRESENT, rb.detail)
    assert_equal(identity_matches(f.identity, rb.observed), IDENTITY_MATCH)
    assert_equal(rs.transport().accepted_writes, 1)
    print("  test_warehouse_identical_reupload_is_created_without_a_write: PASS")


def test_a_different_file_under_the_name_mismatches() raises:
    var rs = RegistrySet[_FakeRegistry, ScriptedCredential](
        _FakeRegistry(_MODE_WAREHOUSE, fault_after_store=False, stale_reads=0), _creds()
    )
    var first = _file(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"), String("bytes A"))
    var second = _file(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"), String("bytes B"))
    assert_equal(rs.upload(first, _names()).kind, UPLOAD_CREATED)
    var u = rs.upload(second, _names())
    assert_equal(u.kind, UPLOAD_DUPLICATE_REFUSED, upload_kind_name(u.kind))
    var rb = rs.read_back(second.coordinate)
    assert_equal(identity_matches(second.identity, rb.observed), IDENTITY_MISMATCH)
    assert_equal(rs.transport().accepted_writes, 1)
    print("  test_a_different_file_under_the_name_mismatches: PASS")


def main() raises:
    test_warehouse_identical_reupload_is_created_without_a_write()
    test_a_different_file_under_the_name_mismatches()
    print("test_pkg_upload_convergence: ALL PASS")
