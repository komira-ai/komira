# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_static_token_credential.mojo —
#   one token, from a FILE or a secret NAME, on the one surface it serves.
# =============================================================================
#
# ROWS
#   (1) a token file holding the token and one line ending is Basic
#       `__token__:<token>` on PYPI_UPLOAD and `Bearer <token>` on PREFIX_DEV;
#   (2) a token resolved by NAME from a secret store, the same shapes;
#   (3) refusals that never quote the token: a missing file (naming the
#       path), an empty file, a file holding whitespace or a second line, a
#       secret name the store cannot resolve (naming the name), a surface with
#       no token shape;
#   (4) ONE surface: a token for PREFIX_DEV is refused on PYPI_UPLOAD (and the
#       reverse) — through `RegistrySet.upload`, with zero requests sent;
#   (5) `AnonymousCredential` presents nothing, and an upload with it is
#       refused before any request on both arms.
#
# Hermetic: files under the test's own temporary directory; no network.
# =============================================================================

from std.os import getenv
from std.pathlib import Path
from std.testing import assert_equal, assert_raises, assert_true

from komira_secret_store import StaticSecretStore

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    AnonymousCredential,
    pypi_upload_authorization,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.static_token_credential import StaticTokenCredential
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _TOKEN: String = "static-probe-token-0123456789abcdef"


def _tmp(name: String) raises -> String:
    var dir = getenv("TEST_TMPDIR", "")
    if dir == "":
        dir = getenv("TMPDIR", "")
    if dir == "":
        raise Error("no TEST_TMPDIR or TMPDIR for this test's files")
    return dir + String("/") + name


def _write(name: String, content: String) raises -> String:
    var path = _tmp(name)
    Path(path).write_text(content)
    return path^


def _never_quotes_the_token(msg: String) raises:
    assert_true(msg.find(String(_TOKEN)) < 0, msg)
    assert_true(msg.find(String(String(_TOKEN)[byte=0:16])) < 0, msg)


def test_a_token_file_in_both_shapes() raises:
    var path = _write(String("token_lf"), String(_TOKEN) + String("\n"))
    var pypi = StaticTokenCredential.token_file(SURFACE_PYPI_UPLOAD, path)
    assert_equal(pypi.authorization(SURFACE_PYPI_UPLOAD), pypi_upload_authorization(String(_TOKEN)))
    var crlf = _write(String("token_crlf"), String(_TOKEN) + String("\r\n"))
    var pfx = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, crlf)
    assert_equal(pfx.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_TOKEN))
    var bare = _write(String("token_bare"), String(_TOKEN))
    var b = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, bare)
    assert_equal(b.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_TOKEN))
    print("  test_a_token_file_in_both_shapes: PASS")


def test_a_token_by_secret_name() raises:
    var store = StaticSecretStore()
    store.put(String("registry/prefix-dev"), String(_TOKEN))
    var cred = StaticTokenCredential.token_secret(SURFACE_PREFIX_DEV, store, String("registry/prefix-dev"))
    assert_equal(cred.authorization(SURFACE_PREFIX_DEV), String("Bearer ") + String(_TOKEN))
    store.put(String("registry/pypi"), String(_TOKEN) + String("\n"))
    var p = StaticTokenCredential.token_secret(SURFACE_PYPI_UPLOAD, store, String("registry/pypi"))
    assert_equal(p.authorization(SURFACE_PYPI_UPLOAD), pypi_upload_authorization(String(_TOKEN)))
    print("  test_a_token_by_secret_name: PASS")


def test_refusals_never_quote_the_token() raises:
    var missing = _tmp(String("no_such_token_file"))
    try:
        _ = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, missing)
        assert_true(False, "a missing token file must be refused")
    except e:
        assert_true(String(e).find(missing) >= 0, String(e))
    var empty = _write(String("token_empty"), String("\n"))
    with assert_raises(contains="is EMPTY"):
        _ = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, empty)
    var spaced = _write(String("token_spaced"), String("static-probe ") + String(_TOKEN))
    try:
        _ = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, spaced)
        assert_true(False, "a token file holding a space must be refused")
    except e:
        assert_true(String(e).find(String("holds whitespace")) >= 0, String(e))
        _never_quotes_the_token(String(e))
    var two = _write(String("token_two_lines"), String(_TOKEN) + String("\nsecond\n"))
    try:
        _ = StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, two)
        assert_true(False, "a token file holding two lines must be refused")
    except e:
        _never_quotes_the_token(String(e))
    var store = StaticSecretStore()
    try:
        _ = StaticTokenCredential.token_secret(SURFACE_PREFIX_DEV, store, String("registry/absent"))
        assert_true(False, "an unresolved secret must be refused")
    except e:
        assert_true(String(e).find(String("'registry/absent'")) >= 0, String(e))
    var ok = _write(String("token_ok"), String(_TOKEN))
    with assert_raises(contains="no token shape"):
        _ = StaticTokenCredential.token_file(99, ok)
    print("  test_refusals_never_quote_the_token: PASS")


def _wheel() -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            String("komira_probe"),
            String("1.1.3"),
            String("linux-64"),
            String("komira_probe-1.1.3-py3-none-any.whl"),
        ),
        bytes_of(String("wheel-bytes")),
        String("Metadata-Version: 2.1\nName: komira_probe\nVersion: 1.1.3\n\n"),
    )


def _conda() -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            String("prefix.dev/example-channel"),
            String("komira-probe"),
            String("1.2.3"),
            String("linux-64"),
            String("komira-probe-1.2.3-h0_0.conda"),
        ),
        bytes_of(String("conda-bytes")),
        String(""),
    )


def _names() raises -> ApprovedNames:
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    p.approve(String("komira-probe"))
    return p^


def test_one_credential_one_surface() raises:
    var path = _write(String("token_one_surface"), String(_TOKEN))
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    var rs = RegistrySet[ScriptedPkgTransport, StaticTokenCredential](
        t^, StaticTokenCredential.token_file(SURFACE_PREFIX_DEV, path)
    )
    with assert_raises(contains="cannot serve the PYPI_UPLOAD surface"):
        _ = rs.upload(_wheel(), _names())
    assert_equal(rs.transport().call_count(), 0)
    # CONTROL: the same credential uploads on its own surface.
    _ = rs.upload(_conda(), _names())
    assert_equal(rs.transport().call_count(), 1)
    assert_equal(
        rs.transport().call(0).header_value(String("Authorization")),
        String("Bearer ") + String(_TOKEN),
    )
    print("  test_one_credential_one_surface: PASS")


def test_an_anonymous_upload_is_refused_before_any_request() raises:
    var anon = AnonymousCredential()
    assert_equal(anon.authorization(SURFACE_PREFIX_DEV), String(""))
    assert_equal(anon.authorization(SURFACE_PYPI_UPLOAD), String(""))
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(200))
    var rs = RegistrySet[ScriptedPkgTransport, AnonymousCredential](t^, AnonymousCredential())
    with assert_raises(contains="needs a credential"):
        _ = rs.upload(_wheel(), _names())
    with assert_raises(contains="needs a credential"):
        _ = rs.upload(_conda(), _names())
    assert_equal(rs.transport().call_count(), 0)
    print("  test_an_anonymous_upload_is_refused_before_any_request: PASS")


def main() raises:
    test_a_token_file_in_both_shapes()
    test_a_token_by_secret_name()
    test_refusals_never_quote_the_token()
    test_one_credential_one_surface()
    test_an_anonymous_upload_is_refused_before_any_request()
    print("test_pkg_upload_static_token_credential: ALL PASS")
