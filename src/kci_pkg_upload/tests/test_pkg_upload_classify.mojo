# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_classify.mojo — every
#   upload answer is a KIND, and a transport fault on the POST is UNKNOWN.
# =============================================================================
#
# THE FIXTURES. The warehouse refusal texts below are the strings warehouse's
# legacy upload handler raises (`forklift/legacy.py`), rendered in the JSON
# shape its error views produce when the client accepts JSON (which the upload
# does — see the Accept header in `legacy_upload.mojo`). They are the research
# record, NOT a recording: the classifier is re-run over recorded TestPyPI
# answers once a live run has captured them.
#
# ROWS
#   (1) warehouse: 200 CREATED; 400 "File already exists" DUPLICATE_REFUSED;
#       400 deleted-file-name BURNED (both texts warehouse has used); 400
#       release-too-old WINDOW_CLOSED; another 400 REJECTED; 401/403
#       AUTH_REFUSED; 409 DUPLICATE_REFUSED; 429 RATE_LIMITED; 500/502/503
#       UNKNOWN; 301/404/413 REJECTED;
#   (2) a transport raise on the POST is UNKNOWN, NEVER a raise — through
#       `RegistrySet.upload`, to pypi.org and to TestPyPI;
#   (3) a detail that echoes the credential (whole value, the bearer token,
#       or a Basic pair's password) is WITHHELD;
#   (4) an upload is never redirected: a 307 answer is REJECTED and the
#       transport records exactly ONE request;
#   (5) an echo the excerpt's byte bound CUTS is still withheld: the check
#       runs over the whole body, so OUR cut never leaves a prefix to quote;
#   (6) an echo the SERVER truncated is withheld when it keeps
#       `ECHO_WINDOW_BYTES` (16) or more consecutive bytes of any credential
#       shape — a token prefix with an ellipsis, a run from its middle, a
#       Basic password's prefix, the Basic blob's prefix — through both the
#       server-body path and `withhold_if_echoes`; a body that shares only a
#       SHORTER run with the token (its public `pypi-` prefix) is still
#       quoted. What is not held, and is not claimed: an echo shorter than 16
#       bytes, or a re-encoding that leaves no 16-byte run intact.
#
# Hermetic: no network.
# =============================================================================

from std.testing import assert_equal, assert_true

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
from kci_pkg_upload.legacy_upload import classify_warehouse_upload
from kci_pkg_upload.outcome import (
    DETAIL_EXCERPT_BYTES,
    ECHO_WINDOW_BYTES,
    UPLOAD_AUTH_REFUSED,
    UPLOAD_BURNED,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    UPLOAD_WINDOW_CLOSED,
    upload_kind_name,
    withhold_if_echoes,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


def _pyramid_json(message: String) -> List[UInt8]:
    return bytes_of(
        String('{"message": "The server could not comply with the request since it')
        + String(' is either malformed or otherwise incorrect.\\n\\n')
        + message
        + String('", "code": "400 ')
        + message
        + String('", "title": "Bad Request"}')
    )


comptime _DUP: String = (
    "File already exists ('komira_probe-1.1.3-py3-none-linux_x86_64.whl', with"
    " blake2_256 hash '00ff'). See https://pypi.org/help/#file-name-reuse for"
    " more information."
)
comptime _DELETED_NOW: String = (
    "This filename was previously used by a file that has since been deleted."
    " Use a different version. See https://pypi.org/help/#file-name-reuse for"
    " more information."
)
comptime _DELETED_OLD: String = (
    "This filename has already been used, use a different version. See"
    " https://pypi.org/help/#file-name-reuse for more information."
)
comptime _TOO_OLD: String = (
    "Uploading new files to releases older than 14 days is not allowed."
)
comptime _BAD_META: String = "'' is an invalid value for Version."


def _w(status: Int, body: List[UInt8]) -> Int:
    return classify_warehouse_upload(status, body, String("Basic c2VjcmV0")).kind


def _names() raises -> ApprovedNames:
    """The approved names the uploads here are held to. Every distribution in
    this file is on it, so the verdicts under test are the registry's, never
    the name's (test_pkg_upload_approved_names.mojo covers the refusal)."""
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    return p^


def test_warehouse_classification() raises:
    var empty = List[UInt8]()
    assert_equal(_w(200, bytes_of(String("OK"))), UPLOAD_CREATED)
    assert_equal(_w(400, _pyramid_json(String(_DUP))), UPLOAD_DUPLICATE_REFUSED)
    assert_equal(_w(400, _pyramid_json(String(_DELETED_NOW))), UPLOAD_BURNED)
    assert_equal(_w(400, _pyramid_json(String(_DELETED_OLD))), UPLOAD_BURNED)
    assert_equal(_w(400, _pyramid_json(String(_TOO_OLD))), UPLOAD_WINDOW_CLOSED)
    assert_equal(_w(400, _pyramid_json(String(_BAD_META))), UPLOAD_REJECTED)
    assert_equal(_w(401, empty), UPLOAD_AUTH_REFUSED)
    assert_equal(_w(403, empty), UPLOAD_AUTH_REFUSED)
    assert_equal(_w(409, empty), UPLOAD_DUPLICATE_REFUSED)
    assert_equal(_w(429, bytes_of(String("Too many new projects created"))), UPLOAD_RATE_LIMITED)
    assert_equal(_w(500, empty), UPLOAD_UNKNOWN)
    assert_equal(_w(502, empty), UPLOAD_UNKNOWN)
    assert_equal(_w(503, empty), UPLOAD_UNKNOWN)
    assert_equal(_w(301, empty), UPLOAD_REJECTED)
    assert_equal(_w(404, empty), UPLOAD_REJECTED)
    assert_equal(_w(413, empty), UPLOAD_REJECTED)
    print("  test_warehouse_classification: PASS")


def _wheel_file(substrate: Int, repo: String) -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            substrate,
            repo.copy(),
            String("komira_probe"),
            String("1.1.3"),
            String("linux-64"),
            String("komira_probe-1.1.3-py3-none-linux_x86_64.whl"),
        ),
        bytes_of(String("wheel-bytes")),
        String("Metadata-Version: 2.1\nName: komira_probe\nVersion: 1.1.3\n\n"),
    )


def _creds() raises -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, pypi_upload_authorization(String("fake-upload-token")))
    return c^


def test_a_transport_raise_on_the_post_is_unknown_never_a_raise() raises:
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection reset by peer after 3 of 11 KiB"))
    t.queue_fault(String("TLS alert: close_notify before the response"))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    var o1 = rs.upload(
        _wheel_file(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")), _names()
    )
    assert_equal(o1.kind, UPLOAD_UNKNOWN, upload_kind_name(o1.kind))
    assert_equal(o1.status, 0)
    assert_true(o1.detail.find(String("may or may not have been stored")) >= 0)
    var o2 = rs.upload(
        _wheel_file(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org")), _names()
    )
    assert_equal(o2.kind, UPLOAD_UNKNOWN)
    assert_equal(rs.transport().call_count(), 2)
    print("  test_a_transport_raise_on_the_post_is_unknown_never_a_raise: PASS")


def test_a_detail_that_echoes_the_credential_is_withheld() raises:
    # the whole value
    var o1 = classify_warehouse_upload(
        403, bytes_of(String("bad header: Bearer tok-123456")), String("Bearer tok-123456")
    )
    assert_true(o1.detail.find(String("tok-123456")) < 0, o1.detail)
    assert_true(o1.detail.find(String("withheld")) >= 0)
    # the bearer token alone
    var o2 = classify_warehouse_upload(
        403, bytes_of(String("token tok-123456 is revoked")), String("Bearer tok-123456")
    )
    assert_true(o2.detail.find(String("tok-123456")) < 0, o2.detail)
    # a Basic pair's PASSWORD, echoed in the clear
    var basic = pypi_upload_authorization(String("fake-upload-token-9876"))
    var o3 = classify_warehouse_upload(
        403, bytes_of(String("invalid API token: fake-upload-token-9876")), basic
    )
    assert_true(o3.detail.find(String("fake-upload-token-9876")) < 0, o3.detail)
    # a detail with no echo is quoted
    var o4 = classify_warehouse_upload(
        403, bytes_of(String("Invalid or non-existent authentication information.")), basic
    )
    assert_true(o4.detail.find(String("non-existent authentication")) >= 0, o4.detail)
    assert_equal(
        withhold_if_echoes(String("plain"), String("")), String("plain")
    )
    print("  test_a_detail_that_echoes_the_credential_is_withheld: PASS")


comptime _LONG_TOKEN: String = "pypi-echo-probe-0123456789abcdefghijklmnopqrstuvwxyz"


def _cut_by_the_excerpt(token: String, keep: Int) -> List[UInt8]:
    """A body whose echo of `token` STRADDLES the excerpt's byte bound, so the
    excerpt holds only the token's first `keep` characters. The bound is the
    package's own (`DETAIL_EXCERPT_BYTES`), so this row moves with it."""
    var body = List[UInt8]()
    for _ in range(DETAIL_EXCERPT_BYTES - keep):
        body.append(UInt8(ord("x")))
    var tb = token.as_bytes()
    for i in range(len(tb)):
        body.append(tb[i])
    return body^


def test_an_echo_cut_by_the_excerpt_bound_is_still_withheld() raises:
    """⛔ The excerpt is bounded, and the echo check must not be. A server that
    echoes the credential ACROSS the excerpt's byte bound leaves only a PREFIX
    of it in the excerpt; a check that looks for the whole secret in the
    excerpt finds nothing and quotes that prefix into a refusal a terminal and
    a log both see. The check runs over the WHOLE body."""
    var token = String(_LONG_TOKEN)
    var prefix = String(token[byte=0:24])
    var o = classify_warehouse_upload(
        403, _cut_by_the_excerpt(token, 24), String("Bearer ") + token
    )
    assert_true(o.detail.find(prefix) < 0, o.detail)
    assert_true(o.detail.find(String("withheld")) >= 0, o.detail)
    # The kind and status stay readable: only the server's text is withheld.
    assert_true(o.detail.find(String("AUTH_REFUSED (HTTP 403)")) >= 0, o.detail)
    var a = classify_warehouse_upload(
        503, _cut_by_the_excerpt(token, 24), String("Bearer ") + token
    )
    assert_true(a.detail.find(prefix) < 0, a.detail)
    print("  test_an_echo_cut_by_the_excerpt_bound_is_still_withheld: PASS")


def _holds_a_window_of(detail: String, secret: String) -> Bool:
    """True when `detail` contains ANY `ECHO_WINDOW_BYTES`-long run of
    `secret` (an ASCII test token)."""
    var n = secret.byte_length()
    for j in range(n - ECHO_WINDOW_BYTES + 1):
        if detail.find(String(secret[byte = j : j + ECHO_WINDOW_BYTES])) >= 0:
            return True
    return False


def test_a_server_truncated_echo_is_withheld() raises:
    """⛔ Checking the whole body before OUR cut does not cover a server that
    truncates the echo ITSELF (`<first 20 chars>...`): the whole token never
    occurs, and a whole-shape check quotes the prefix. Any run of
    `ECHO_WINDOW_BYTES` consecutive bytes of a credential shape is withheld."""
    var token = String(_LONG_TOKEN)
    var bearer = String("Bearer ") + token
    # (a) the server's own truncation: a 20-byte prefix and an ellipsis.
    var a = classify_warehouse_upload(
        403,
        bytes_of(String("invalid token '") + String(token[byte=0:20]) + String("...'")),
        bearer,
    )
    assert_true(not _holds_a_window_of(a.detail, token), a.detail)
    assert_true(a.detail.find(String("withheld")) >= 0, a.detail)
    # (b) exactly one window from the MIDDLE of the token, in a 5xx body.
    var b = classify_warehouse_upload(
        503,
        bytes_of(String("upstream said: ") + String(token[byte = 10 : 10 + ECHO_WINDOW_BYTES])),
        bearer,
    )
    assert_true(not _holds_a_window_of(b.detail, token), b.detail)
    assert_true(b.detail.find(String("withheld")) >= 0, b.detail)
    # (c) a Basic pair: the decoded PASSWORD's prefix, and the blob's prefix.
    var password = String("fake-upload-token-9876-0123456789abcdef")
    var basic = pypi_upload_authorization(password)
    var c = classify_warehouse_upload(
        403, bytes_of(String("bad key ") + String(password[byte=0:18]) + String("...")), basic
    )
    assert_true(not _holds_a_window_of(c.detail, password), c.detail)
    assert_true(c.detail.find(String("withheld")) >= 0, c.detail)
    var blob = String(basic[byte=6:])
    var d = classify_warehouse_upload(
        401, bytes_of(String("header was Basic ") + String(blob[byte=0:24]) + String("...")), basic
    )
    assert_true(not _holds_a_window_of(d.detail, blob), d.detail)
    assert_true(d.detail.find(String("withheld")) >= 0, d.detail)
    # (e) text that is not a server body goes through the same matcher.
    var e = withhold_if_echoes(
        String("dial failed for ") + String(token[byte=0:20]) + String("..."), bearer
    )
    assert_true(not _holds_a_window_of(e, token), e)
    assert_true(e.find(String("withheld")) >= 0, e)
    # (f) a SHORTER shared run (the token's public scheme prefix) is quoted:
    #     the detail stays readable.
    var f = classify_warehouse_upload(
        403, bytes_of(String("tokens start with pypi-echo; this one expired")), bearer
    )
    assert_true(f.detail.find(String("this one expired")) >= 0, f.detail)
    print("  test_a_server_truncated_echo_is_withheld: PASS")


def test_an_upload_is_never_redirected() raises:
    var t = ScriptedPkgTransport()
    var r = PkgResponse(307)
    r.with_header(String("location"), String("https://elsewhere.example/legacy/"))
    t.queue(r^)
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    var o = rs.upload(
        _wheel_file(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")), _names()
    )
    assert_equal(o.kind, UPLOAD_REJECTED)
    assert_equal(rs.transport().call_count(), 1)
    print("  test_an_upload_is_never_redirected: PASS")


def main() raises:
    test_warehouse_classification()
    test_a_transport_raise_on_the_post_is_unknown_never_a_raise()
    test_a_detail_that_echoes_the_credential_is_withheld()
    test_an_echo_cut_by_the_excerpt_bound_is_still_withheld()
    test_a_server_truncated_echo_is_withheld()
    test_an_upload_is_never_redirected()
    print("test_pkg_upload_classify: ALL PASS")
