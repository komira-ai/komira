# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_wire_edges.mojo — the byte
#   helpers, the kind names, the detail excerpt and the local refusals, at
#   their edges.
# =============================================================================
#
# ROWS
#   (1) `bytes_find` of an EMPTY needle is `start` while `start <= len`, and
#       -1 past the end;
#   (2) `is_valid_utf8` accepts the first and last value of every RFC 3629
#       lead class and refuses one byte past each bound: a stray continuation,
#       an overlong lead (C0/C1), a lead above F4, E0 below A0, ED at A0 (a
#       surrogate), F0 below 90, F4 at 90, a bad second, third or fourth
#       byte, and a sequence cut off at the end of the input; `decode_utf8`
#       raises naming `what`;
#   (3) every kind has its name; an out-of-range kind is named with its
#       number, never as another kind;
#   (4) a quoted server body becomes printable: tab, LF and CR are spaces,
#       any other byte outside printable ASCII is `?`;
#   (5) echo detection: a Basic pair whose decoded bytes are not ASCII does
#       not withhold an ASCII prefix of its password; the whole value and its
#       blob still are withheld; a non-ASCII bearer token is matched WHOLE,
#       never by its windows. (Such a pair also yields no decoded-password
#       shape today: a gap, komira-ai/komira#1185, deliberately not asserted.)
#   (6) local refusals before any request: an EMPTY repo, whitespace in a
#       repo, an EMPTY file name, a file name that is not one path segment,
#       a file with no conda extension asked for its repodata key;
#   (7) METADATA with CRLF line ends parses to the same values as with LF; a
#       header line with no `:` or a leading `:` is refused;
#   (8) the scripted transport RAISES when it runs off its script, naming the
#       call; the scripted credential records the host it was asked for; the
#       static credential reports its surface and host; an identity that
#       exposes nothing says so; identity match kinds are named.
#
# Hermetic: no transport but the scripted one; no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_encoding import base64_encode
from komira_http_core.codec.types import HTTP_METHOD_GET
from komira_secret_store import SecretValue

from kci_pkg_upload.conda_repodata import repodata_key_for
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
    refuse_malformed_file_name,
    repo_host,
    repo_path,
)
from kci_pkg_upload.core_metadata import parse_core_metadata
from kci_pkg_upload.credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    ScriptedCredential,
)
from kci_pkg_upload.identity import (
    IDENTITY_MATCH,
    IDENTITY_MISMATCH,
    IDENTITY_NO_COMMON_FIELD,
    ContentIdentity,
    identity_match_name,
)
from kci_pkg_upload.outcome import (
    PRESENCE_ABSENT,
    PRESENCE_AUTH_REFUSED,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_RATE_LIMITED,
    PRESENCE_UNKNOWN,
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    UPLOAD_AUTH_REFUSED,
    UPLOAD_BURNED,
    UPLOAD_CONFLICT,
    UPLOAD_CREATED,
    UPLOAD_DUPLICATE_REFUSED,
    UPLOAD_RATE_LIMITED,
    UPLOAD_REJECTED,
    UPLOAD_UNKNOWN,
    UPLOAD_WINDOW_CLOSED,
    echoes_credential,
    excerpt_unless_echoes,
    presence_kind_name,
    read_kind_name,
    upload_kind_name,
)
from kci_pkg_upload.static_token_credential import StaticTokenCredential
from kci_pkg_upload.transport import PkgRequest, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_find, bytes_of, decode_utf8, is_valid_utf8


def _b(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(xs)):
        out.append(UInt8(xs[i]))
    return out^


def _ok(var b: List[UInt8], what: String) raises:
    assert_true(is_valid_utf8(Span(b)), String("must accept: ") + what)


def _bad(var b: List[UInt8], what: String) raises:
    assert_false(is_valid_utf8(Span(b)), String("must refuse: ") + what)


def test_bytes_find_of_an_empty_needle() raises:
    var hay = bytes_of(String("abc"))
    assert_equal(bytes_find(Span(hay), String(""), 0), 0)
    assert_equal(bytes_find(Span(hay), String(""), 2), 2)
    assert_equal(bytes_find(Span(hay), String(""), 3), 3, "start == len is the end")
    assert_equal(bytes_find(Span(hay), String(""), 4), -1, "past the end")
    print("  test_bytes_find_of_an_empty_needle: PASS")


def test_utf8_lead_classes_and_their_bounds() raises:
    _ok(_b(0x61, 0xC2, 0x80, 0x62), "C2 80 between ASCII")
    _ok(_b(0xDF, 0xBF), "DF BF")
    _bad(_b(0x80), "a stray continuation byte")
    _bad(_b(0xC1, 0xBF), "overlong lead C1")
    _bad(_b(0xF5, 0x80, 0x80, 0x80), "lead F5 (above U+10FFFF)")
    _bad(_b(0xC2, 0x7F), "C2 then a byte below 80")
    _bad(_b(0xC2, 0xC0), "C2 then a byte above BF")
    _bad(_b(0xC2, 0x80, 0x80), "a continuation after a whole sequence")
    # E0: second byte A0..BF.
    _ok(_b(0xE0, 0xA0, 0x80), "E0 A0 80")
    _bad(_b(0xE0, 0x9F, 0xBF), "E0 9F (overlong)")
    # ED: second byte 80..9F (no surrogates).
    _ok(_b(0xED, 0x9F, 0xBF), "ED 9F BF")
    _bad(_b(0xED, 0xA0, 0x80), "ED A0 (a surrogate)")
    # E1..EF.
    _ok(_b(0xE1, 0x80, 0x80), "E1 80 80")
    _ok(_b(0xEF, 0xBF, 0xBF), "EF BF BF")
    _bad(_b(0xE1, 0xC0, 0x80), "E1 then C0")
    _bad(_b(0xE1, 0x80, 0x7F), "E1 80 then a third byte below 80")
    _bad(_b(0xE1, 0x80, 0xC0), "E1 80 then a third byte above BF")
    # F0: second byte 90..BF.
    _ok(_b(0xF0, 0x90, 0x80, 0x80), "F0 90 80 80")
    _bad(_b(0xF0, 0x8F, 0xBF, 0xBF), "F0 8F (overlong)")
    # F4: second byte 80..8F.
    _ok(_b(0xF4, 0x8F, 0xBF, 0xBF), "F4 8F BF BF (U+10FFFF)")
    _bad(_b(0xF4, 0x90, 0x80, 0x80), "F4 90 (above U+10FFFF)")
    # F1..F3.
    _ok(_b(0xF1, 0x80, 0x80, 0x80), "F1 80 80 80")
    _ok(_b(0xF3, 0xBF, 0xBF, 0xBF), "F3 BF BF BF")
    _bad(_b(0xF1, 0x80, 0x80, 0xC0), "F1 80 80 then a fourth byte above BF")
    _bad(_b(0xF2, 0x80, 0x7F, 0x80), "F2 80 then a third byte below 80")
    # Truncated at the end of the input.
    _bad(_b(0xC2), "C2 alone")
    _bad(_b(0x61, 0xE1, 0x80), "E1 80 cut off")
    _bad(_b(0xF1, 0x80, 0x80), "F1 80 80 cut off")
    _ok(_b(0x61, 0xF1, 0x80, 0x80, 0x80), "F1 sequence ending exactly at the end")
    with assert_raises(contains="the probe body is not valid UTF-8"):
        _ = decode_utf8(Span(_b(0x61, 0xFF)), String("the probe body"))
    assert_equal(decode_utf8(Span(_b(0x61, 0xC3, 0xA9)), String("x")), String("aé"))
    print("  test_utf8_lead_classes_and_their_bounds: PASS")


def test_every_kind_has_its_name() raises:
    assert_equal(presence_kind_name(PRESENCE_ABSENT), String("ABSENT"))
    assert_equal(presence_kind_name(PRESENCE_PRESENT_IDENTICAL), String("PRESENT_IDENTICAL"))
    assert_equal(presence_kind_name(PRESENCE_PRESENT_DIFFERENT), String("PRESENT_DIFFERENT"))
    assert_equal(presence_kind_name(PRESENCE_NO_COMMON_FIELD), String("NO_COMMON_FIELD"))
    assert_equal(presence_kind_name(PRESENCE_AUTH_REFUSED), String("AUTH_REFUSED"))
    assert_equal(presence_kind_name(PRESENCE_RATE_LIMITED), String("RATE_LIMITED"))
    assert_equal(presence_kind_name(PRESENCE_UNKNOWN), String("UNKNOWN"))
    assert_equal(presence_kind_name(99), String("PRESENCE(99)"))
    assert_equal(read_kind_name(READ_PRESENT), String("PRESENT"))
    assert_equal(read_kind_name(READ_ABSENT), String("ABSENT"))
    assert_equal(read_kind_name(READ_AUTH_REFUSED), String("AUTH_REFUSED"))
    assert_equal(read_kind_name(READ_RATE_LIMITED), String("RATE_LIMITED"))
    assert_equal(read_kind_name(READ_UNKNOWN), String("UNKNOWN"))
    assert_equal(read_kind_name(42), String("READ(42)"))
    assert_equal(upload_kind_name(UPLOAD_CREATED), String("CREATED"))
    assert_equal(upload_kind_name(UPLOAD_DUPLICATE_REFUSED), String("DUPLICATE_REFUSED"))
    assert_equal(upload_kind_name(UPLOAD_CONFLICT), String("CONFLICT"))
    assert_equal(upload_kind_name(UPLOAD_BURNED), String("BURNED"))
    assert_equal(upload_kind_name(UPLOAD_AUTH_REFUSED), String("AUTH_REFUSED"))
    assert_equal(upload_kind_name(UPLOAD_RATE_LIMITED), String("RATE_LIMITED"))
    assert_equal(upload_kind_name(UPLOAD_WINDOW_CLOSED), String("WINDOW_CLOSED"))
    assert_equal(upload_kind_name(UPLOAD_UNKNOWN), String("UNKNOWN"))
    assert_equal(upload_kind_name(UPLOAD_REJECTED), String("REJECTED"))
    assert_equal(upload_kind_name(17), String("UPLOAD(17)"))
    assert_equal(identity_match_name(IDENTITY_MATCH), String("MATCH"))
    assert_equal(identity_match_name(IDENTITY_MISMATCH), String("MISMATCH"))
    assert_equal(identity_match_name(IDENTITY_NO_COMMON_FIELD), String("NO_COMMON_FIELD"))
    assert_equal(identity_match_name(5), String("UNKNOWN_IDENTITY_MATCH(5)"))
    print("  test_every_kind_has_its_name: PASS")


def test_a_quoted_body_is_printable() raises:
    var body = _b(0x61, 0x09, 0x62, 0x0A, 0x63, 0x0D, 0x64, 0x01, 0x7F, 0xC3, 0xA9, 0x7E)
    assert_equal(excerpt_unless_echoes(body, String("")), String("a b c d????~"))
    print("  test_a_quoted_body_is_printable: PASS")


def test_echo_shapes_of_non_ascii_credentials() raises:
    # A Basic pair `u:abcdefgh` + U+00E9: its ASCII prefix `abcdefgh` (8
    # bytes, under the 16-byte window) is not the password and is not
    # withheld. Not asserted: whether the decoded non-ASCII password itself is
    # withheld (today it is not; komira-ai/komira#1185).
    var raw = bytes_of(String("u:abcdefgh"))
    raw.append(UInt8(0xC3))
    raw.append(UInt8(0xA9))
    var blob = base64_encode(Span(raw))
    var basic = String("Basic ") + blob
    assert_false(echoes_credential(bytes_of(String("x abcdefgh y")), basic))
    assert_true(echoes_credential(bytes_of(String("echo ") + blob), basic))
    assert_true(echoes_credential(bytes_of(String("echo ") + basic), basic))
    # A bearer token with a non-ASCII byte is matched whole.
    var tok = String("tökentökentökentöken")
    var bearer = String("Bearer ") + tok
    assert_true(echoes_credential(bytes_of(String("[") + tok + String("]")), bearer))
    assert_false(echoes_credential(bytes_of(String("[tökentökentöken]")), bearer))
    print("  test_echo_shapes_of_non_ascii_credentials: PASS")


def _coord(repo: String, file_name: String) -> PackageCoordinate:
    return PackageCoordinate(
        SUBSTRATE_PUBLIC_PYPI,
        repo.copy(),
        String("d"),
        String("1.0"),
        String("linux-64"),
        file_name.copy(),
    )


def test_local_refusals() raises:
    with assert_raises(contains="a coordinate names an EMPTY repo"):
        _ = repo_host(String(""))
    with assert_raises(contains="contains whitespace"):
        _ = repo_path(String("pypi.org/a b"))
    with assert_raises(contains="contains whitespace"):
        _ = repo_host(String("pypi\t.org"))
    with assert_raises(contains="contains whitespace"):
        _ = repo_host(String("pypi.org/x\n"))
    with assert_raises(contains="contains whitespace"):
        _ = repo_host(String("pypi.org\r/x"))
    with assert_raises(contains="EMPTY file name for pypi.org linux-64/"):
        refuse_malformed_file_name(_coord(String("pypi.org"), String("")))
    with assert_raises(contains="file name 'a/b.whl' is not one path segment"):
        refuse_malformed_file_name(_coord(String("pypi.org"), String("a/b.whl")))
    with assert_raises(contains="is not one path segment"):
        refuse_malformed_file_name(_coord(String("pypi.org"), String("a\\b.whl")))
    refuse_malformed_file_name(_coord(String("pypi.org"), String("a.whl")))
    with assert_raises(contains="'d-1.0.zip' is not a conda package file"):
        _ = repodata_key_for(String("d-1.0.zip"))
    print("  test_local_refusals: PASS")


def test_metadata_line_ends_and_malformed_headers() raises:
    var crlf = parse_core_metadata(
        String("Metadata-Version: 2.1\r\nName: komira-probe\r\nVersion: 1.2.3\r\n\r\nbody\r\n")
    )
    assert_equal(crlf.first(String("Name")), String("komira-probe"))
    assert_equal(crlf.first(String("Version")), String("1.2.3"))
    var lf = parse_core_metadata(String("Metadata-Version: 2.1\nName: komira-probe\nVersion: 1.2.3\n\nbody\n"))
    assert_equal(lf.first(String("Version")), String("1.2.3"))
    with assert_raises(contains="line 'Version 1.2.3' is not a `Name: value` header"):
        _ = parse_core_metadata(String("Name: x\nVersion 1.2.3\n\n"))
    with assert_raises(contains="line ': 1.2.3' is not a `Name: value` header"):
        _ = parse_core_metadata(String("Name: x\n: 1.2.3\n\n"))
    print("  test_metadata_line_ends_and_malformed_headers: PASS")


def test_the_doubles_and_accessors() raises:
    var t = ScriptedPkgTransport()
    with assert_raises(contains="no scripted answer for call #0 (h.example.invalid/p); script more answers"):
        _ = t.exchange(PkgRequest(HTTP_METHOD_GET, String("h.example.invalid"), String("/p")))
    assert_equal(t.call_count(), 1, "the unscripted call is still recorded")
    var c = ScriptedCredential()
    c.serve(SURFACE_PREFIX_DEV, String("Bearer x"))
    assert_equal(c.authorization(SURFACE_PREFIX_DEV, String("prefix.dev")), String("Bearer x"))
    with assert_raises(contains="ScriptedCredential cannot serve the PYPI_UPLOAD surface"):
        _ = c.authorization(SURFACE_PYPI_UPLOAD, String("pypi.org"))
    assert_equal(c.asked_count(), 2)
    assert_equal(c.asked_host(0), String("prefix.dev"))
    assert_equal(c.asked_host(1), String("pypi.org"))
    var s = StaticTokenCredential(
        SURFACE_PYPI_UPLOAD, String("test.pypi.org"), SecretValue.from_string(String("pypi-abc"))
    )
    assert_equal(s.surface(), SURFACE_PYPI_UPLOAD)
    assert_equal(s.host(), String("test.pypi.org"))
    assert_true(ContentIdentity.none().exposes_nothing())
    assert_false(ContentIdentity.of_sha256_hex(String("ab")).exposes_nothing())
    assert_false(ContentIdentity(String(""), String("sha512-x"), String("")).exposes_nothing())
    assert_false(ContentIdentity(String(""), String(""), String("aa")).exposes_nothing())
    print("  test_the_doubles_and_accessors: PASS")


def main() raises:
    test_bytes_find_of_an_empty_needle()
    test_utf8_lead_classes_and_their_bounds()
    test_every_kind_has_its_name()
    test_a_quoted_body_is_printable()
    test_echo_shapes_of_non_ascii_credentials()
    test_local_refusals()
    test_metadata_line_ends_and_malformed_headers()
    test_the_doubles_and_accessors()
    print("test_pkg_upload_wire_edges: ALL PASS")
