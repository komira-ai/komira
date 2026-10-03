# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_uv_fidelity.mojo — the
#   upload this client sends IS the upload `uv publish` sends, byte for byte.
# =============================================================================
#
# THE EVIDENCE. `tests/fidelity/capture_uv_publish.py` ran the real `uv publish`
# at a recorder bound to 127.0.0.1 (no registry anywhere) for three probe
# wheels and committed what arrived: the wheel, its METADATA, and the request
# (method, path, Content-Type, Accept, and the RAW body). This test builds the
# same upload with `kci_pkg_upload` — through `RegistrySet`, the path a real
# publish takes — and compares.
#
# THE ONE SUBSTITUTION. uv's multipart boundary is random; ours is derived from
# the file's sha256. Both are four 16-hex groups (67 characters), so after
# putting OUR boundary where uv's was, the bodies must be IDENTICAL, byte for
# byte, and so must their lengths (the Content-Length the transport sends).
#
# ROWS
#   (1) minimal / rich / description_header: body, path, method, Content-Type
#       (modulo the boundary), Accept and Authorization all equal uv's — over
#       the PyPI arm (`/legacy/`);
#   (2) the comparison is not vacuous: the minimal golden and the rich golden
#       differ, and one flipped byte in a golden is found at its offset.
#
# Hermetic: the fixtures are staged test data; ScriptedPkgTransport; no
# socket, no network.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_http_core.codec.types import HTTP_METHOD_POST

from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.credential import (
    SURFACE_PYPI_UPLOAD,
    ScriptedCredential,
    pypi_upload_authorization,
)
from kci_pkg_upload.legacy_upload import legacy_upload_boundary
from kci_pkg_upload.outcome import UPLOAD_CREATED
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_find, bytes_of


comptime _DIR: String = "src/kci_pkg_upload/tests/fidelity/"
comptime _PLACEHOLDER: String = "fidelity-probe-placeholder-not-a-credential"


def _read(name: String) raises -> List[UInt8]:
    """A staged fixture. The test runs with its staged data directory as the
    current directory, so the path is the fixture's path in the tree."""
    var path = String(_DIR) + name
    if not Path(path).exists():
        raise Error("fixture `" + path + "` is not staged for this test")
    return Path(path).read_bytes()


def _as_string(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


struct _Golden(Movable):
    var method: String
    var path: String
    var content_type: String
    var accept: String
    var boundary: String
    var file_name: String
    var body_length: Int
    var body: List[UInt8]

    def __init__(out self, raw: List[UInt8]) raises:
        self.method = String("")
        self.path = String("")
        self.content_type = String("")
        self.accept = String("")
        self.boundary = String("")
        self.file_name = String("")
        self.body_length = -1
        self.body = List[UInt8]()
        var sep = bytes_find(Span(raw), String("\n\n"))
        if sep <= 0:
            raise Error("a .request fixture has no header block")
        var head = List[UInt8]()
        for i in range(sep):
            head.append(raw[i])
        for i in range(sep + 2, len(raw)):
            self.body.append(raw[i])
        var text = _as_string(head)
        var start = 0
        while start < text.byte_length():
            var nl = text.find(String("\n"), start)
            var end = nl if nl >= 0 else text.byte_length()
            var line = String(text[byte=start:end])
            var sp = line.find(String(" "))
            var key = String(line[byte=:sp])
            var val = String(line[byte = sp + 1 :])
            if key == String("METHOD"):
                self.method = val^
            elif key == String("PATH"):
                self.path = val^
            elif key == String("CONTENT-TYPE"):
                self.content_type = val^
            elif key == String("ACCEPT"):
                self.accept = val^
            elif key == String("BOUNDARY"):
                self.boundary = val^
            elif key == String("FILENAME"):
                self.file_name = val^
            elif key == String("BODY-LENGTH"):
                self.body_length = Int(val)
            if nl < 0:
                break
            start = nl + 1


def _replace_all(src: List[UInt8], old: String, new: String) -> List[UInt8]:
    var out = List[UInt8]()
    var nb = new.as_bytes()
    var i = 0
    while i < len(src):
        var at = bytes_find(Span(src), old, i)
        if at < 0:
            for j in range(i, len(src)):
                out.append(src[j])
            break
        for j in range(i, at):
            out.append(src[j])
        for j in range(len(nb)):
            out.append(nb[j])
        i = at + old.byte_length()
    return out^


def _first_difference(a: List[UInt8], b: List[UInt8]) -> Int:
    """The first differing offset, or -1 when equal (length included)."""
    var n = len(a) if len(a) < len(b) else len(b)
    for i in range(n):
        if a[i] != b[i]:
            return i
    if len(a) != len(b):
        return n
    return -1


def _file(which: String, substrate: Int, repo: String) raises -> PackageFile:
    var golden = _Golden(_read(which + String(".request")))
    var coord = PackageCoordinate(
        substrate,
        repo.copy(),
        String("komira_fidelity_probe"),
        String("1.1.7"),
        String("linux-64"),
        golden.file_name.copy(),
    )
    return PackageFile(
        coord^,
        _read(which + String(".whl")),
        _as_string(_read(which + String(".METADATA"))),
    )


def _check_case_pypi(which: String) raises:
    var golden = _Golden(_read(which + String(".request")))
    var f = _file(which, SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"))
    var ours = legacy_upload_boundary(f.identity.sha256_hex)
    assert_equal(ours.byte_length(), golden.boundary.byte_length(), "boundary shapes agree")

    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(200))
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PYPI_UPLOAD, pypi_upload_authorization(String(_PLACEHOLDER)))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
    var out = rs.upload(f, _names())
    assert_equal(out.kind, UPLOAD_CREATED)

    var req = rs.transport().call(0)
    assert_equal(req.method, HTTP_METHOD_POST)
    assert_equal(golden.method, String("POST"))
    assert_equal(req.host, String("test.pypi.org"))
    assert_equal(req.path, golden.path, which + String(": upload path"))
    assert_equal(
        req.header_value(String("Content-Type")),
        _as_string(_replace_all(bytes_of(golden.content_type), golden.boundary, ours)),
        which + String(": Content-Type"),
    )
    assert_equal(req.header_value(String("Accept")), golden.accept, which + String(": Accept"))
    # uv's header was asserted by the capture script to be exactly this
    # function of the same placeholder.
    assert_equal(
        req.header_value(String("Authorization")),
        pypi_upload_authorization(String(_PLACEHOLDER)),
    )
    var want = _replace_all(golden.body, golden.boundary, ours)
    assert_equal(len(golden.body), golden.body_length, which + String(": fixture length"))
    assert_equal(len(req.body), golden.body_length, which + String(": Content-Length"))
    assert_equal(_first_difference(req.body, want), -1, which + String(": body byte for byte"))
    print(String("  ") + which + String(" (PyPI arm): byte-identical to uv publish"))


def _names() raises -> ApprovedNames:
    """The approved names the uploads here are held to. The probe's name is
    on it, so the verdicts under test are the registry's, never the name's
    (test_pkg_upload_approved_names.mojo covers the refusal)."""
    var p = ApprovedNames()
    p.approve(String("komira_fidelity_probe"))
    return p^


def test_every_case_is_byte_identical_to_uv() raises:
    var cases = List[String]()
    cases.append(String("minimal"))
    cases.append(String("rich"))
    cases.append(String("description_header"))
    for i in range(len(cases)):
        _check_case_pypi(cases[i])
    print("  test_every_case_is_byte_identical_to_uv: PASS")


def test_the_comparison_is_not_vacuous() raises:
    var minimal = _Golden(_read(String("minimal.request")))
    var rich = _Golden(_read(String("rich.request")))
    assert_true(_first_difference(minimal.body, rich.body) >= 0, "two goldens differ")

    var f = _file(String("minimal"), SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"))
    var ours = legacy_upload_boundary(f.identity.sha256_hex)
    var want = _replace_all(minimal.body, minimal.boundary, ours)
    # Flip one byte in the middle of the form (inside the `name` field's value)
    # and the comparison must find exactly that offset.
    var at = bytes_find(Span(want), String("komira_fidelity_probe\r\n"))
    assert_true(at > 0)
    var mutated = want.copy()
    mutated[at + 3] = mutated[at + 3] ^ UInt8(1)
    assert_equal(_first_difference(want, mutated), at + 3)
    print("  test_the_comparison_is_not_vacuous: PASS")


def main() raises:
    test_every_case_is_byte_identical_to_uv()
    test_the_comparison_is_not_vacuous()
    print("test_pkg_upload_uv_fidelity: ALL PASS")
