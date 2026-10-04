# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_legacy_form.mojo — the
#   golden request bytes of one small upload, written out IN FULL here, and
#   every local refusal the form makes before anything is sent.
# =============================================================================
#
# The uv fidelity test compares against recordings; this one states the wire
# for a tiny file inline, so a reader can see the exact bytes without a hex
# viewer and so a change to the encoder shows up as a readable diff.
#
# ROWS
#   (1) golden request: method, host, path, the three headers IN ORDER, and
#       the whole body, byte for byte;
#   (2) the boundary is uv's SHAPE (4 x 16 lowercase hex, 67 chars), is a
#       function of the file's sha256 only (same file -> same boundary, other
#       file -> other boundary), so a retry sends identical bytes;
#   (3) refusals, each raising BEFORE any request (the transport records zero
#       calls): a FOLDED header, an RFC 2047 encoded word, a missing Version,
#       a Project-URL with no comma, a METADATA Name or Version that is not the
#       file's, a coordinate whose version is not the file's, a non-wheel file,
#       a malformed wheel name, a file name with a quote, and a file that
#       contains its own multipart delimiter.
#
# Hermetic: no network.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_crypto import blake2b_256, hex_lower

from kci_pkg_upload.approved_names import ApprovedNames
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.core_metadata import FormField, parse_core_metadata
from kci_pkg_upload.credential import SURFACE_PYPI_UPLOAD, ScriptedCredential
from kci_pkg_upload.legacy_upload import (
    build_legacy_upload_request,
    encode_legacy_multipart,
    legacy_upload_boundary,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _WHEEL: String = "komira_tiny-1.1.2-py3-none-any.whl"


def _file(
    meta: String,
    file_name: String = String(_WHEEL),
    version: String = String("1.1.2"),
    content: String = String("PK-tiny"),
) -> PackageFile:
    return PackageFile(
        PackageCoordinate(
            SUBSTRATE_PUBLIC_PYPI,
            String("test.pypi.org"),
            String("komira_tiny"),
            version.copy(),
            String("noarch"),
            file_name.copy(),
        ),
        bytes_of(content),
        meta.copy(),
    )


comptime _META: String = "Metadata-Version: 2.1\nName: komira_tiny\nVersion: 1.1.2\nSummary: s\n\n"


def _names() raises -> ApprovedNames:
    """The approved names. This file's pinned golden distribution
    `komira_tiny` is on the list, so every refusal asserted here must be the
    FORM's, and each names the text it expects, so a name refusal in their
    place is RED rather than a vacuous pass."""
    var p = ApprovedNames()
    p.approve(String("komira_tiny"))
    return p^


def test_golden_request_bytes() raises:
    var f = _file(String(_META))
    var b = legacy_upload_boundary(f.identity.sha256_hex)
    var b2 = hex_lower(Span(blake2b_256(Span(f.bytes))))
    var req = build_legacy_upload_request(
        String("test.pypi.org"), String("/legacy/"), f, String("Basic xyz")
    )
    assert_equal(req.host, String("test.pypi.org"))
    assert_equal(req.path, String("/legacy/"))
    assert_equal(len(req.header_names), 3)
    assert_equal(req.header_names[0], String("Content-Type"))
    assert_equal(req.header_values[0], String("multipart/form-data; boundary=") + b)
    assert_equal(req.header_names[1], String("Accept"))
    assert_equal(
        req.header_values[1],
        String("application/json;q=0.9, text/plain;q=0.8, text/html;q=0.7"),
    )
    assert_equal(req.header_names[2], String("Authorization"))
    assert_equal(req.header_values[2], String("Basic xyz"))

    var d = String("--") + b + String("\r\n")
    var cd = String('Content-Disposition: form-data; name="')
    var want = (
        d + cd + String(':action"\r\n\r\nfile_upload\r\n')
        + d + cd + String('sha256_digest"\r\n\r\n') + f.identity.sha256_hex + String("\r\n")
        + d + cd + String('blake2_256_digest"\r\n\r\n') + b2 + String("\r\n")
        + d + cd + String('protocol_version"\r\n\r\n1\r\n')
        + d + cd + String('metadata_version"\r\n\r\n2.1\r\n')
        + d + cd + String('name"\r\n\r\nkomira_tiny\r\n')
        + d + cd + String('version"\r\n\r\n1.1.2\r\n')
        + d + cd + String('filetype"\r\n\r\nbdist_wheel\r\n')
        + d + cd + String('pyversion"\r\n\r\npy3\r\n')
        + d + cd + String('summary"\r\n\r\ns\r\n')
        + d + cd + String('requires_python"\r\n\r\n\r\n')
        + d + cd + String('content"; filename="') + String(_WHEEL) + String('"\r\n\r\n')
        + String("PK-tiny\r\n")
        + String("--") + b + String("--\r\n")
    )
    assert_equal(String(unsafe_from_utf8=Span(req.body)), want)
    print("  test_golden_request_bytes: PASS")


def test_boundary_shape_and_determinism() raises:
    var f1 = _file(String(_META))
    var f2 = _file(String(_META))
    var f3 = _file(String(_META), content=String("PK-other"))
    var b1 = legacy_upload_boundary(f1.identity.sha256_hex)
    assert_equal(b1.byte_length(), 67)
    var bb = b1.as_bytes()
    for i in range(len(bb)):
        if i == 16 or i == 33 or i == 50:
            assert_equal(bb[i], UInt8(ord("-")))
        else:
            var c = bb[i]
            assert_true(
                (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
                or (c >= UInt8(ord("a")) and c <= UInt8(ord("f")))
            )
    assert_equal(b1, legacy_upload_boundary(f2.identity.sha256_hex))
    assert_true(b1 != legacy_upload_boundary(f3.identity.sha256_hex))
    var r1 = build_legacy_upload_request(String("h"), String("/legacy/"), f1, String(""))
    var r2 = build_legacy_upload_request(String("h"), String("/legacy/"), f2, String(""))
    assert_equal(len(r1.body), len(r2.body))
    for i in range(len(r1.body)):
        assert_equal(r1.body[i], r2.body[i])
    # EMPTY authorization = no Authorization header at all.
    assert_equal(len(r1.header_names), 2)
    print("  test_boundary_shape_and_determinism: PASS")


def _refused_before_any_request(f: PackageFile, contains: String) raises:
    var t = ScriptedPkgTransport()
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PYPI_UPLOAD, String("Basic xyz"))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
    var raised = False
    try:
        _ = rs.upload(f, _names())
    except e:
        raised = True
        assert_true(String(e).find(contains) >= 0, String(e))
    assert_true(raised, String("expected a refusal containing: ") + contains)
    assert_equal(rs.transport().call_count(), 0)


def test_local_refusals() raises:
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: komira_tiny\nVersion: 1.1.2\nLicense: a\n  b\n\n")),
        String("FOLDED"),
    )
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: komira_tiny\nVersion: 1.1.2\nSummary: =?utf-8?q?x?=\n\n")),
        String("RFC 2047"),
    )
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: komira_tiny\n\n")),
        String("'Version' is missing"),
    )
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: komira_tiny\nVersion: 1.1.2\nProject-URL: nocomma\n\n")),
        String("has no comma"),
    )
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: other\nVersion: 1.1.2\n\n")),
        String("is not the distribution of file"),
    )
    _refused_before_any_request(
        _file(String("Metadata-Version: 2.1\nName: komira_tiny\nVersion: 1.1.0\n\n")),
        String("is not the version of file"),
    )
    _refused_before_any_request(
        _file(String(_META), version=String("1.1.9")),
        String("does not name the file"),
    )
    _refused_before_any_request(
        _file(String(_META), file_name=String("komira_tiny-1.1.2.tar.gz")),
        String("is not a wheel"),
    )
    _refused_before_any_request(
        _file(String(_META), file_name=String("komira_tiny-1.1.2.whl")),
        String("5 or 6 dash-separated parts"),
    )
    print("  test_local_refusals: PASS")


def test_encoder_refusals() raises:
    var fields = List[FormField]()
    fields.append(FormField(String("name"), String("v")))
    with assert_raises(contains="quoted filename parameter"):
        _ = encode_legacy_multipart(
            fields, String('a"b.whl'), Span(bytes_of(String("x"))), String("B")
        )
    with assert_raises(contains="contains its own multipart delimiter"):
        _ = encode_legacy_multipart(
            fields, String("a.whl"), Span(bytes_of(String("zz\r\n--B\r\n"))), String("B")
        )
    var bad = List[FormField]()
    bad.append(FormField(String("description"), String("text --B more")))
    with assert_raises(contains="contains the multipart delimiter"):
        _ = encode_legacy_multipart(
            bad, String("a.whl"), Span(bytes_of(String("x"))), String("B")
        )
    # The parser keeps TRAILING whitespace and strips LEADING (uv measured).
    var meta = parse_core_metadata(
        String("Metadata-Version: 2.1\nName: tiny\nVersion: 1.1.2\nLicense:   MIT  \n\n")
    )
    assert_equal(meta.first(String("license")), String("MIT  "))
    print("  test_encoder_refusals: PASS")


def main() raises:
    test_golden_request_bytes()
    test_boundary_shape_and_determinism()
    test_local_refusals()
    test_encoder_refusals()
    print("test_pkg_upload_legacy_form: ALL PASS")
