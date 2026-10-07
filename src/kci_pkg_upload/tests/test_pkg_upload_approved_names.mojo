# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_approved_names.mojo — the upload
#   seam refuses a published name the caller did not approve, BY NAME, before
#   any request.
# =============================================================================
#
# ROWS
#   (1) an approved name is uploaded (one request, CREATED) — the CONTROL:
#       without it every refusal below could be an upload path that refuses
#       everything;
#   (2) a name not on the list RAISES naming the distribution, with the
#       transport recording ZERO calls and the credential never asked —
#       nothing was claimed and nothing was presented;
#   (3) the list is EXACT: a name that merely starts or ends with an approved
#       one is refused, and so is the approved name with a suffix;
#   (4) on a python index the comparison is PEP 503's: `Komira.Probe` is the
#       project `komira-probe`, which is the approved `komira_probe`;
#   (5) an EMPTY list approves nothing;
#   (6) the list refuses a statement that would admit more or less than it
#       says: an empty name, a name holding whitespace or '/', and a name
#       stated twice in two spellings;
#   (7) `refusal` (the pure half) is EMPTY exactly for an approved name, and
#       on a substrate that is not a python index the comparison is ASCII-case
#       only — `-`, `_` and `.` stay distinct.
#
# Hermetic: ScriptedPkgTransport + ScriptedCredential; no network.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from kci_pkg_upload.approved_names import ApprovedNames, approved_name_key
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import SURFACE_PYPI_UPLOAD, ScriptedCredential
from kci_pkg_upload.outcome import UPLOAD_CREATED, upload_kind_name
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


# An ordinal that is not a python index: compared ASCII-case-insensitively.
comptime _NOT_PYTHON: Int = 99


def _names() raises -> ApprovedNames:
    """The list under test: two exact names."""
    var p = ApprovedNames()
    p.approve(String("komira_probe"))
    p.approve(String("komira_arrow"))
    return p^


def _file(distribution: String, wheel_dist: String) -> PackageFile:
    """A self-consistent wheel: the coordinate's distribution, the file name's
    and METADATA's `Name` agree (PEP 503), so the only thing an upload of it
    can be refused for here is its NAME."""
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            distribution.copy(),
            String("1.1.3"),
            String("linux-64"),
            wheel_dist + String("-1.1.3-py3-none-any.whl"),
        ),
        bytes_of(String("wheel-bytes")),
        String("Metadata-Version: 2.1\nName: ")
        + distribution
        + String("\nVersion: 1.1.3\nSummary: s\n\n"),
    )


def _creds() -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, String("Basic warehouse-upload"))
    return c^


def _set_answering(n: Int) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    var t = ScriptedPkgTransport()
    for _ in range(n):
        t.queue(PkgResponse(200))
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())


def _refused_by_name(f: PackageFile, names: ApprovedNames) raises:
    """`f` must RAISE naming its distribution, before any request is composed
    and before any credential is asked for. A 200 is queued, so an upload the
    list wrongly admits is CREATED and this goes RED."""
    var rs = _set_answering(1)
    var raised = False
    try:
        _ = rs.upload(f, names)
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find(String("'") + f.coordinate.distribution + String("'")) >= 0,
            msg,
        )
        assert_true(msg.find(String("is not in the approved-names list")) >= 0, msg)
    assert_true(
        raised,
        String("expected the upload of '")
        + f.coordinate.distribution
        + String("' to be refused by name"),
    )
    assert_equal(rs.transport().call_count(), 0)
    assert_equal(rs.credential().asked_count(), 0)


def test_an_approved_name_is_uploaded() raises:
    var rs = _set_answering(1)
    var o = rs.upload(_file(String("komira_probe"), String("komira_probe")), _names())
    assert_equal(o.kind, UPLOAD_CREATED, upload_kind_name(o.kind))
    assert_equal(rs.transport().call_count(), 1)
    print("  test_an_approved_name_is_uploaded: PASS")


def test_an_unapproved_name_is_refused_by_name_before_any_request() raises:
    _refused_by_name(_file(String("device_rpc"), String("device_rpc")), _names())
    print("  test_an_unapproved_name_is_refused_by_name_before_any_request: PASS")


def test_the_list_is_exact() raises:
    var names = _names()
    _refused_by_name(_file(String("komira_probe2"), String("komira_probe2")), names)
    _refused_by_name(
        _file(String("acme_komira_probe"), String("acme_komira_probe")), names
    )
    _refused_by_name(_file(String("komira"), String("komira")), names)
    print("  test_the_list_is_exact: PASS")


def test_python_names_compare_under_pep_503() raises:
    var rs = _set_answering(1)
    var o = rs.upload(_file(String("Komira.Probe"), String("komira_probe")), _names())
    assert_equal(o.kind, UPLOAD_CREATED, upload_kind_name(o.kind))
    assert_equal(rs.transport().call_count(), 1)
    print("  test_python_names_compare_under_pep_503: PASS")


def test_an_empty_list_approves_nothing() raises:
    var none = ApprovedNames()
    assert_equal(none.count(), 0)
    _refused_by_name(_file(String("komira_probe"), String("komira_probe")), none)
    print("  test_an_empty_list_approves_nothing: PASS")


def test_the_list_refuses_a_statement_that_says_more_than_it_means() raises:
    var p = ApprovedNames()
    with assert_raises(contains="an EMPTY approved name"):
        p.approve(String(""))
    with assert_raises(contains="holds whitespace or '/'"):
        p.approve(String("komira probe"))
    with assert_raises(contains="holds whitespace or '/'"):
        p.approve(String("komira/probe"))
    p.approve(String("komira_probe"))
    with assert_raises(contains="'Komira_Probe' is approved twice"):
        p.approve(String("Komira_Probe"))
    assert_equal(p.count(), 1)
    print("  test_the_list_refuses_a_statement_that_says_more_than_it_means: PASS")


def test_refusal_is_empty_exactly_for_an_approved_name() raises:
    var names = _names()
    assert_equal(names.refusal(String("komira_arrow"), SUBSTRATE_PUBLIC_PYPI), String(""))
    assert_equal(names.refusal(String("komira-arrow"), SUBSTRATE_PUBLIC_PYPI), String(""))
    assert_equal(names.refusal(String("komira_arrow"), _NOT_PYTHON), String(""))
    assert_equal(names.refusal(String("KOMIRA_ARROW"), _NOT_PYTHON), String(""))
    # Off a python index `-` and `_` are distinct names.
    var other = names.refusal(String("komira-arrow"), _NOT_PYTHON)
    assert_true(other.find(String("'komira-arrow'")) >= 0, other)
    assert_true(other.find(String("SUBSTRATE(99)")) >= 0, other)
    var why = names.refusal(String("authz_port"), SUBSTRATE_PUBLIC_PYPI)
    assert_true(why.find(String("'authz_port'")) >= 0, why)
    assert_true(why.find(String("PUBLIC_PYPI")) >= 0, why)
    assert_true(names.refusal(String(""), SUBSTRATE_PUBLIC_PYPI).byte_length() > 0)
    assert_equal(
        approved_name_key(String("Foo.Bar_baz"), SUBSTRATE_PUBLIC_PYPI),
        String("foo-bar-baz"),
    )
    assert_equal(approved_name_key(String("Foo.Bar_baz"), _NOT_PYTHON), String("foo.bar_baz"))
    print("  test_refusal_is_empty_exactly_for_an_approved_name: PASS")


def main() raises:
    test_an_approved_name_is_uploaded()
    test_an_unapproved_name_is_refused_by_name_before_any_request()
    test_the_list_is_exact()
    test_python_names_compare_under_pep_503()
    test_an_empty_list_approves_nothing()
    test_the_list_refuses_a_statement_that_says_more_than_it_means()
    test_refusal_is_empty_exactly_for_an_approved_name()
    print("test_pkg_upload_approved_names: ALL PASS")
