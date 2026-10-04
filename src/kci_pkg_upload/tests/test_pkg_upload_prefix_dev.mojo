# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_prefix_dev.mojo — the prefix.dev
#   conda upload: the exact request, every answer a kind, a 409 settled by
#   reading back, and every local refusal before anything is sent.
# =============================================================================
#
# ROWS
#   (1) the golden request: POST to `/api/v1/upload/<channel>` on the
#       channel's host, the three headers IN ORDER (Content-Type with the
#       derived boundary, Accept, the Bearer), and the whole one-part body
#       byte for byte (part headers Content-Type, Content-Length, X-File-Name,
#       X-File-SHA256); no `force` anywhere in the request;
#   (2) the boundary is a function of the file's sha256 only (a retry sends
#       identical bytes);
#   (3) every answer is a kind: 2xx CREATED, 409 DUPLICATE_REFUSED, 401/403
#       AUTH_REFUSED, 429 RATE_LIMITED, 5xx UNKNOWN, 400/404/413/422 and a 303
#       REJECTED; a transport raise is UNKNOWN, never a raise;
#   (4) a 409 is settled by reading back: the channel holding OUR bytes reads
#       PRESENT_IDENTICAL (nothing to upload), other bytes PRESENT_DIFFERENT
#       (a conflict the caller refuses); an upload is never redirected;
#   (5) local refusals, each before any request: an empty Authorization, a non-conda file, no subdir, a repo with
#       no channel or three segments, a coordinate whose name or version is not
#       the file's, a file holding its own delimiter, an unapproved name;
#   (6) `prefix_dev_repo_of_location` takes exactly `https://<host>/<namespace>`
#       or `https://<host>/<namespace>/<channel>`;
#   (7) an upload answer that echoes the token is withheld;
#   (8) a NAMESPACED channel (`<namespace>/<channel>`, prefix.dev's form for
#       every non-primary channel): the upload is
#       `POST /api/v1/upload/<namespace>/<channel>`, the read-back and the fetch
#       are under `/<namespace>/<channel>/<subdir>/`; a third segment, an empty
#       or dot segment and an `@` (the website route only) are refused before
#       any request.
#
# Hermetic: ScriptedPkgTransport + ScriptedCredential; no network.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_http_core.codec.types import HTTP_METHOD_POST

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import SURFACE_PREFIX_DEV, ScriptedCredential
from kci_pkg_upload.identity import content_identity_of
from kci_pkg_upload.outcome import (
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    UPLOAD_AUTH_REFUSED,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    presence_kind_name,
    upload_kind_name,
)
from kci_pkg_upload.prefix_dev_registry import (
    classify_prefix_dev_upload,
    encode_prefix_dev_form,
    prefix_dev_repo_of_location,
    prefix_dev_upload_boundary,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _REPO: String = "prefix.dev/example-channel"
comptime _FILE: String = "komira-probe-1.2.3-h0123abc_0.conda"
comptime _BYTES: String = "conda-bytes-v1"
comptime _TOKEN: String = "pfx_example_token_0123456789abcdef"


def _coord(
    file_name: String = String(_FILE),
    subdir: String = String("linux-64"),
    repo: String = String(_REPO),
    name: String = String("komira-probe"),
    version: String = String("1.2.3"),
) -> PackageCoordinate:
    return PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA,
        repo.copy(),
        name.copy(),
        version.copy(),
        subdir.copy(),
        file_name.copy(),
    )


def _file(var c: PackageCoordinate, content: String = String(_BYTES)) -> PackageFile:
    return PackageFile(c^, bytes_of(content), String(""))


def _creds(token: String = String(_TOKEN)) -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PREFIX_DEV, String("Bearer ") + token)
    return c^


def _names() raises -> ApprovedNames:
    var p = ApprovedNames()
    p.approve(String("komira-probe"))
    return p^


def _set(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())


def _repodata(file_name: String, sha: String) -> PkgResponse:
    var r = PkgResponse(200)
    r.with_header(String("content-type"), String("application/json"))
    r.with_body(
        bytes_of(
            String('{"info": {"subdir": "linux-64"}, "packages": {}, ')
            + String('"packages.conda": {"')
            + file_name
            + String('": {"sha256": "')
            + sha
            + String('", "size": 14}}}')
        )
    )
    return r^


def test_the_golden_request() raises:
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    var rs = _set(t^)
    var f = _file(_coord())
    var o = rs.upload(f, _names())
    assert_equal(o.kind, UPLOAD_CREATED, upload_kind_name(o.kind))
    var req = rs.transport().call(0)
    var b = prefix_dev_upload_boundary(f.identity.sha256_hex)
    assert_equal(req.method, HTTP_METHOD_POST)
    assert_equal(req.host, String("prefix.dev"))
    assert_equal(req.path, String("/api/v1/upload/example-channel"))
    assert_true(req.path.find(String("force")) < 0, req.path)
    assert_equal(len(req.header_names), 3)
    assert_equal(req.header_names[0], String("Content-Type"))
    assert_equal(req.header_values[0], String("multipart/form-data; boundary=") + b)
    assert_equal(req.header_names[1], String("Accept"))
    assert_equal(req.header_values[1], String("application/json"))
    assert_equal(req.header_names[2], String("Authorization"))
    assert_equal(req.header_values[2], String("Bearer ") + String(_TOKEN))
    var want = (
        String("--")
        + b
        + String('\r\nContent-Disposition: form-data; name="file"; filename="')
        + String(_FILE)
        + String('"\r\nContent-Type: application/octet-stream\r\n')
        + String("Content-Length: 14\r\n")
        + String("X-File-Name: ")
        + String(_FILE)
        + String("\r\nX-File-SHA256: ")
        + content_identity_of(bytes_of(String(_BYTES))).sha256_hex
        + String("\r\n\r\n")
        + String(_BYTES)
        + String("\r\n--")
        + b
        + String("--\r\n")
    )
    assert_equal(String(unsafe_from_utf8=Span(req.body)), want)
    assert_equal(rs.credential().asked_count(), 1)
    assert_equal(rs.credential().asked(0), SURFACE_PREFIX_DEV)
    print("  test_the_golden_request: PASS")


def test_the_boundary_is_a_function_of_the_file() raises:
    var a = _file(_coord())
    var b = _file(_coord())
    var c = _file(_coord(), String("other bytes"))
    var ba = prefix_dev_upload_boundary(a.identity.sha256_hex)
    assert_equal(ba, prefix_dev_upload_boundary(b.identity.sha256_hex))
    assert_true(ba != prefix_dev_upload_boundary(c.identity.sha256_hex))
    assert_equal(ba.byte_length(), 67)
    print("  test_the_boundary_is_a_function_of_the_file: PASS")


def _k(status: Int) -> Int:
    return classify_prefix_dev_upload(status, List[UInt8](), String("Bearer x-token")).kind


def test_every_answer_is_a_kind() raises:
    assert_equal(_k(200), UPLOAD_CREATED)
    assert_equal(_k(201), UPLOAD_CREATED)
    assert_equal(_k(409), UPLOAD_DUPLICATE_REFUSED)
    assert_equal(_k(401), UPLOAD_AUTH_REFUSED)
    assert_equal(_k(403), UPLOAD_AUTH_REFUSED)
    assert_equal(_k(429), UPLOAD_RATE_LIMITED)
    assert_equal(_k(500), UPLOAD_UNKNOWN)
    assert_equal(_k(503), UPLOAD_UNKNOWN)
    assert_equal(_k(400), UPLOAD_REJECTED)
    assert_equal(_k(404), UPLOAD_REJECTED)
    assert_equal(_k(413), UPLOAD_REJECTED)
    assert_equal(_k(422), UPLOAD_REJECTED)
    assert_equal(_k(303), UPLOAD_REJECTED)
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection reset after 9 of 14 bytes"))
    var rs = _set(t^)
    var o = rs.upload(_file(_coord()), _names())
    assert_equal(o.kind, UPLOAD_UNKNOWN, upload_kind_name(o.kind))
    assert_true(o.detail.find(String("may or may not have been stored")) >= 0, o.detail)
    print("  test_every_answer_is_a_kind: PASS")


def test_a_409_is_settled_by_reading_back() raises:
    var ours = content_identity_of(bytes_of(String(_BYTES))).sha256_hex
    var other = content_identity_of(bytes_of(String("someone else's bytes"))).sha256_hex
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(409))
    t.queue(_repodata(String(_FILE), ours))
    t.queue(PkgResponse(409))
    t.queue(_repodata(String(_FILE), other))
    var redirect = PkgResponse(307)
    redirect.with_header(String("location"), String("https://elsewhere.example/upload"))
    t.queue(redirect^)
    var rs = _set(t^)
    var f = _file(_coord())
    # identical bytes already there: converged, nothing to upload.
    var u1 = rs.upload(f, _names())
    assert_equal(u1.kind, UPLOAD_DUPLICATE_REFUSED, upload_kind_name(u1.kind))
    var p1 = rs.presence(f.coordinate, f.identity)
    assert_equal(p1.kind, PRESENCE_PRESENT_IDENTICAL, presence_kind_name(p1.kind) + p1.detail)
    # other bytes under the name: a conflict, never overwritten.
    var u2 = rs.upload(f, _names())
    assert_equal(u2.kind, UPLOAD_DUPLICATE_REFUSED)
    var p2 = rs.presence(f.coordinate, f.identity)
    assert_equal(p2.kind, PRESENCE_PRESENT_DIFFERENT, presence_kind_name(p2.kind))
    # an upload is never redirected: REJECTED, one request.
    var before = rs.transport().call_count()
    var u3 = rs.upload(f, _names())
    assert_equal(u3.kind, UPLOAD_REJECTED, upload_kind_name(u3.kind))
    assert_equal(rs.transport().call_count(), before + 1)
    assert_equal(rs.transport().unconsumed(), 0)
    for i in range(rs.transport().call_count()):
        assert_true(rs.transport().call(i).path.find(String("force")) < 0)
    print("  test_a_409_is_settled_by_reading_back: PASS")


def _refused(f: PackageFile, want: String, var cred: ScriptedCredential) raises:
    """`f`'s upload must RAISE containing `want`, with ZERO requests."""
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
    var raised = False
    try:
        _ = rs.upload(f, _names())
    except e:
        raised = True
        assert_true(String(e).find(want) >= 0, String(e))
    assert_true(raised, String("expected a refusal containing: ") + want)
    assert_equal(rs.transport().call_count(), 0)


def test_local_refusals_send_nothing() raises:
    var anon = ScriptedCredential()
    anon.serve(SURFACE_PREFIX_DEV, String(""))
    _refused(_file(_coord()), String("needs a credential"), anon^)
    _refused(
        _file(_coord(file_name=String("komira-probe-1.2.3-h0_0.zip"))),
        String("is not a conda package file"),
        _creds(),
    )
    _refused(_file(_coord(subdir=String(""))), String("names no subdir"), _creds())
    _refused(
        _file(_coord(subdir=String("linux-64/x"))), String("is not one path segment"), _creds()
    )
    _refused(_file(_coord(repo=String("prefix.dev"))), String("names no channel"), _creds())
    _refused(
        _file(_coord(repo=String("prefix.dev/a/b/c"))),
        String("<namespace> or <namespace>/<channel>"),
        _creds(),
    )
    _refused(
        _file(_coord(version=String("1.2.4"))), String("does not name the file"), _creds()
    )
    _refused(
        _file(_coord(file_name=String("probe-1.2.3.conda"))),
        String("is not <name>-<version>-<build>.conda"),
        _creds(),
    )
    # A name the list does not hold: refused before the credential is asked.
    var c = _coord(name=String("other-pkg"), file_name=String("other-pkg-1.2.3-h0_0.conda"))
    _refused(_file(c^), String("is not in the approved-names list"), _creds())
    # A file holding its own delimiter: the boundary hashes the bytes, so
    # the encoder is driven with a chosen boundary the bytes contain.
    var holder = _file(_coord(), String("abc--BOUNDARYxyz"))
    with assert_raises(contains="contains its own multipart delimiter"):
        _ = encode_prefix_dev_form(holder, String("BOUNDARY"))
    print("  test_local_refusals_send_nothing: PASS")


def test_location_parsing() raises:
    assert_equal(
        prefix_dev_repo_of_location(String("https://prefix.dev/example-channel")),
        String("prefix.dev/example-channel"),
    )
    with assert_raises(contains="is not an https:// URL"):
        _ = prefix_dev_repo_of_location(String("http://prefix.dev/example-channel"))
    with assert_raises(contains="names a PORT"):
        _ = prefix_dev_repo_of_location(String("https://prefix.dev:8443/c"))
    with assert_raises(contains="names no channel"):
        _ = prefix_dev_repo_of_location(String("https://prefix.dev"))
    with assert_raises(contains="<namespace> or <namespace>/<channel>"):
        _ = prefix_dev_repo_of_location(String("https://prefix.dev/a/b/c"))
    with assert_raises(contains="trailing slash"):
        _ = prefix_dev_repo_of_location(String("https://prefix.dev/c/"))
    print("  test_location_parsing: PASS")


def test_an_answer_echoing_the_token_is_withheld() raises:
    var t = ScriptedPkgTransport()
    var r = PkgResponse(401)
    r.with_body(bytes_of(String("invalid token ") + String(_TOKEN)))
    t.queue(r^)
    var r2 = PkgResponse(422)
    r2.with_body(bytes_of(String("bad upload: ") + String(String(_TOKEN)[byte=0:20]) + String("...")))
    t.queue(r2^)
    var rs = _set(t^)
    var o = rs.upload(_file(_coord()), _names())
    assert_equal(o.kind, UPLOAD_AUTH_REFUSED)
    assert_true(o.detail.find(String(_TOKEN)) < 0, o.detail)
    assert_true(o.detail.find(String("withheld")) >= 0, o.detail)
    var o2 = rs.upload(_file(_coord()), _names())
    assert_equal(o2.kind, UPLOAD_REJECTED)
    assert_true(o2.detail.find(String(String(_TOKEN)[byte=0:20])) < 0, o2.detail)
    print("  test_an_answer_echoing_the_token_is_withheld: PASS")


comptime _NS_REPO: String = "prefix.dev/komira-ai/gamma"


def test_a_namespaced_channel() raises:
    # the location of a non-primary channel, and of a primary one
    assert_equal(
        prefix_dev_repo_of_location(String("https://prefix.dev/komira-ai/gamma")),
        String(_NS_REPO),
    )
    assert_equal(
        prefix_dev_repo_of_location(String("https://prefix.dev/komira-ai/prod")),
        String("prefix.dev/komira-ai/prod"),
    )
    assert_equal(
        prefix_dev_repo_of_location(String("https://prefix.dev/komira-ai")),
        String("prefix.dev/komira-ai"),
    )
    # upload, then read back and fetch: the two segments travel unchanged
    var ours = content_identity_of(bytes_of(String(_BYTES))).sha256_hex
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    t.queue(_repodata(String(_FILE), ours))
    var got = PkgResponse(200)
    got.with_body(bytes_of(String(_BYTES)))
    t.queue(got^)
    var rs = _set(t^)
    var f = _file(_coord(repo=String(_NS_REPO)))
    var o = rs.upload(f, _names())
    assert_equal(o.kind, UPLOAD_CREATED, upload_kind_name(o.kind) + o.detail)
    var p = rs.presence(f.coordinate, f.identity)
    assert_equal(p.kind, PRESENCE_PRESENT_IDENTICAL, presence_kind_name(p.kind) + p.detail)
    _ = rs.fetch(f.coordinate)
    assert_equal(rs.transport().call_count(), 3)
    assert_equal(rs.transport().call(0).method, HTTP_METHOD_POST)
    assert_equal(rs.transport().call(0).host, String("prefix.dev"))
    assert_equal(rs.transport().call(0).path, String("/api/v1/upload/komira-ai/gamma"))
    assert_equal(rs.transport().call(1).host, String("prefix.dev"))
    assert_equal(
        rs.transport().call(1).path, String("/komira-ai/gamma/linux-64/repodata.json")
    )
    assert_equal(
        rs.transport().call(2).path, String("/komira-ai/gamma/linux-64/") + String(_FILE)
    )
    # refused before any request: a third segment, an empty segment, a dot
    # segment, and an `@` in either segment (the website route's spelling)
    _refused(
        _file(_coord(repo=String("prefix.dev/komira-ai/gamma/x"))),
        String("<namespace> or <namespace>/<channel>"),
        _creds(),
    )
    _refused(
        _file(_coord(repo=String("prefix.dev/komira-ai//gamma"))),
        String("EMPTY channel path segment"),
        _creds(),
    )
    _refused(
        _file(_coord(repo=String("prefix.dev/komira-ai/.."))),
        String("is not a channel path segment"),
        _creds(),
    )
    _refused(
        _file(_coord(repo=String("prefix.dev/@komira-ai/gamma"))),
        String("website route"),
        _creds(),
    )
    _refused(
        _file(_coord(repo=String("prefix.dev/@komira-ai"))),
        String("website route"),
        _creds(),
    )
    with assert_raises(contains="website route"):
        _ = prefix_dev_repo_of_location(String("https://prefix.dev/@komira-ai/gamma"))
    print("  test_a_namespaced_channel: PASS")


def main() raises:
    test_a_namespaced_channel()
    test_the_golden_request()
    test_the_boundary_is_a_function_of_the_file()
    test_every_answer_is_a_kind()
    test_a_409_is_settled_by_reading_back()
    test_local_refusals_send_nothing()
    test_location_parsing()
    test_an_answer_echoing_the_token_is_withheld()
    print("test_pkg_upload_prefix_dev: ALL PASS")
