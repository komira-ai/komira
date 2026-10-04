# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_credential_dispatch.mojo —
#   credentials keyed by SURFACE, and the one substrate ladder.
# =============================================================================
#
# ROWS
#   (1) `pypi_upload_authorization` is uv's Basic `__token__:<token>` and
#       refuses an empty token; `bearer_authorization` is `Bearer <token>` and
#       refuses an empty token;
#   (2) `RegistrySet` routes PUBLIC_PYPI to the warehouse arm: pypi.org
#       uploads to `upload.pypi.org/legacy/`, any other warehouse to
#       `<host><path>/legacy/`, each with the PYPI_UPLOAD credential; and
#       PREFIX_DEV_CONDA to the prefix.dev arm with the PREFIX_DEV credential;
#   (3) a substrate with no arm RAISES `no registry arm for substrate <n>` on
#       all four methods, with ZERO requests sent;
#   (4) a credential refusing the surface RAISES before any request (the
#       transport records zero calls) — a misrouted credential is never sent;
#   (5) a public index read asks the credential for nothing and sends no
#       Authorization header;
#   (6) a malformed repo (a scheme, a port, a trailing slash) RAISES before any
#       request.
#
# Hermetic: ScriptedPkgTransport + ScriptedCredential; no network.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

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
    ScriptedCredential,
    bearer_authorization,
    pypi_upload_authorization,
)
from kci_pkg_upload.identity import ContentIdentity
from kci_pkg_upload.outcome import READ_ABSENT
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _WHEEL: String = "komira_probe-1.1.3-py3-none-linux_x86_64.whl"


def _meta() -> String:
    return String(
        "Metadata-Version: 2.1\nName: komira_probe\nVersion: 1.1.3\n"
        "Summary: s\n\n"
    )


def _coord(substrate: Int, repo: String) -> PackageCoordinate:
    return PackageCoordinate(
        substrate,
        repo.copy(),
        String("komira_probe"),
        String("1.1.3"),
        String("linux-64"),
        String(_WHEEL),
    )


def _file(substrate: Int, repo: String) -> PackageFile:
    return PackageFile(_coord(substrate, repo), bytes_of(String("wheel-bytes")), _meta())


def _creds() -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, String("Basic warehouse-upload"))
    return c^


def _names() raises -> ApprovedNames:
    """The approved names the uploads here are held to. Every distribution in
    this file is on it, so the verdicts under test are the registry's, never
    the name's (test_pkg_upload_approved_names.mojo covers the refusal)."""
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    return p^


def test_authorization_shapes() raises:
    assert_equal(
        pypi_upload_authorization(String("fidelity-probe-placeholder-not-a-credential")),
        String(
            "Basic X190b2tlbl9fOmZpZGVsaXR5LXByb2JlLXBsYWNlaG9sZGVyLW5vdC1hLWNyZWRlbnRpYWw="
        ),
    )
    with assert_raises(contains="EMPTY upload token"):
        _ = pypi_upload_authorization(String(""))
    assert_equal(bearer_authorization(String("tok-1")), String("Bearer tok-1"))
    with assert_raises(contains="EMPTY token"):
        _ = bearer_authorization(String(""))
    print("  test_authorization_shapes: PASS")


def test_dispatch_routes_by_substrate() raises:
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(200))
    t.queue(PkgResponse(200))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    _ = rs.upload(_file(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")), _names())
    _ = rs.upload(_file(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org")), _names())
    assert_equal(rs.transport().call(0).host, String("upload.pypi.org"))
    assert_equal(rs.transport().call(0).path, String("/legacy/"))
    assert_equal(
        rs.transport().call(0).header_value(String("Authorization")),
        String("Basic warehouse-upload"),
    )
    assert_equal(rs.transport().call(1).host, String("test.pypi.org"))
    assert_equal(rs.transport().call(1).path, String("/legacy/"))
    assert_equal(rs.credential().asked_count(), 2)
    assert_equal(rs.credential().asked(0), SURFACE_PYPI_UPLOAD)
    print("  test_dispatch_routes_by_substrate: PASS")


def test_dispatch_routes_conda_to_prefix_dev() raises:
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(201))
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, String("Basic warehouse-upload"))
    c.serve(SURFACE_PREFIX_DEV, String("Bearer pfx"))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, c^)
    var names = ApprovedNames()
    names.approve(String("komira-probe"))
    var f = PackageFile(
        PackageCoordinate(
            SUBSTRATE_PREFIX_DEV_CONDA,
            String("prefix.dev/example-channel"),
            String("komira-probe"),
            String("1.1.3"),
            String("linux-64"),
            String("komira-probe-1.1.3-h0_0.conda"),
        ),
        bytes_of(String("conda-bytes")),
        String(""),
    )
    _ = rs.upload(f, names)
    assert_equal(rs.transport().call(0).host, String("prefix.dev"))
    assert_equal(rs.transport().call(0).path, String("/api/v1/upload/example-channel"))
    assert_equal(
        rs.transport().call(0).header_value(String("Authorization")), String("Bearer pfx")
    )
    assert_equal(rs.credential().asked_count(), 1)
    assert_equal(rs.credential().asked(0), SURFACE_PREFIX_DEV)
    print("  test_dispatch_routes_conda_to_prefix_dev: PASS")


def test_a_substrate_with_no_arm_raises_before_any_request() raises:
    var t = ScriptedPkgTransport()
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    var unserved = List[Int]()
    unserved.append(0)
    unserved.append(1)
    unserved.append(2)
    unserved.append(3)
    unserved.append(99)
    for i in range(len(unserved)):
        var s = unserved[i]
        with assert_raises(contains="no registry arm for substrate"):
            _ = rs.upload(_file(s, String("pypi.org")), _names())
        with assert_raises(contains="no registry arm for substrate"):
            _ = rs.read_back(_coord(s, String("pypi.org")))
        with assert_raises(contains="no registry arm for substrate"):
            _ = rs.fetch(_coord(s, String("pypi.org")))
        with assert_raises(contains="no registry arm for substrate"):
            _ = rs.presence(_coord(s, String("pypi.org")), ContentIdentity.none())
    assert_equal(rs.transport().call_count(), 0)
    print("  test_a_substrate_with_no_arm_raises_before_any_request: PASS")


def test_a_refused_surface_sends_nothing() raises:
    var only_prefix = ScriptedCredential()
    only_prefix.serve(SURFACE_PREFIX_DEV, String("Bearer x"))
    var t = ScriptedPkgTransport()
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, only_prefix^)
    # The warehouse upload needs PYPI_UPLOAD, which this credential lacks.
    with assert_raises(contains="cannot serve the PYPI_UPLOAD surface"):
        _ = rs.upload(_file(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")), _names())
    assert_equal(rs.transport().call_count(), 0)
    print("  test_a_refused_surface_sends_nothing: PASS")


def test_public_pypi_reads_ask_for_no_credential() raises:
    var t = ScriptedPkgTransport()
    t.queue(PkgResponse(404))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    var rb = rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")))
    assert_equal(rb.kind, READ_ABSENT)
    assert_equal(rs.credential().asked_count(), 0)
    assert_equal(rs.transport().call(0).header_value(String("Authorization")), String(""))
    print("  test_public_pypi_reads_ask_for_no_credential: PASS")


def test_malformed_repo_raises_before_any_request() raises:
    var t = ScriptedPkgTransport()
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())
    with assert_raises(contains="carries a scheme"):
        _ = rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("https://pypi.org")))
    with assert_raises(contains="names a PORT"):
        _ = rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org:8443")))
    with assert_raises(contains="trailing slash"):
        _ = rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org/")))
    with assert_raises(contains="has an EMPTY host"):
        _ = rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("/simple")))
    assert_equal(rs.transport().call_count(), 0)
    print("  test_malformed_repo_raises_before_any_request: PASS")


def main() raises:
    test_authorization_shapes()
    test_dispatch_routes_by_substrate()
    test_dispatch_routes_conda_to_prefix_dev()
    test_a_substrate_with_no_arm_raises_before_any_request()
    test_a_refused_surface_sends_nothing()
    test_public_pypi_reads_ask_for_no_credential()
    test_malformed_repo_raises_before_any_request()
    print("test_pkg_upload_credential_dispatch: ALL PASS")
