# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_reads.mojo — read_back,
#   presence and fetch answer with a KIND, on the warehouse arm.
# =============================================================================
#
# ROWS — the warehouse arm (pypi.org / TestPyPI JSON API):
#   (1) a 404 (no project, no version) is ABSENT, never a raise — read_back,
#       presence AND fetch;
#   (2) a listing that names the file: PRESENT with its sha256; presence is
#       PRESENT_IDENTICAL / PRESENT_DIFFERENT against ours; an entry with NO
#       digest is NO_COMMON_FIELD, never IDENTICAL;
#   (3) a listing that does not name the file is ABSENT;
#   (4) the read is ANONYMOUS and addressed by the PEP 503 normalised name;
#   (5) fetch follows the listing's URL to the file host and a 302 beyond it,
#       and returns the bytes; a 404 on the file is ABSENT;
#   (6) a transport fault on a read is UNKNOWN; 403 AUTH_REFUSED; 429
#       RATE_LIMITED; a malformed JSON body UNKNOWN.
# ROWS — the listing's own shape:
#   (7) a listing whose `urls` is not an array (null, an object, a string), or
#       whose every entry is unreadable (not an object, or no string
#       `filename`), is UNKNOWN, never ABSENT — read_back AND presence — and
#       its detail names the key. ABSENT is the answer a publisher uploads on,
#       so it may only come from a listing that was READ;
#   (8) an unreadable entry beside one that names the file is still PRESENT;
#       beside readable entries that do not name it, UNKNOWN; a listing whose
#       every entry is readable and none names the file (or that is empty) is
#       ABSENT.
#
# Hermetic: ScriptedPkgTransport; no network.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_pkg_upload.coordinate import (
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
)
from kci_pkg_upload.credential import SURFACE_PYPI_UPLOAD, ScriptedCredential
from kci_pkg_upload.identity import ContentIdentity, content_identity_of
from kci_pkg_upload.outcome import (
    PRESENCE_ABSENT,
    PRESENCE_NO_COMMON_FIELD,
    PRESENCE_PRESENT_DIFFERENT,
    PRESENCE_PRESENT_IDENTICAL,
    PRESENCE_UNKNOWN,
    READ_ABSENT,
    READ_AUTH_REFUSED,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
    presence_kind_name,
    read_kind_name,
)
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of


comptime _FILE: String = "Komira.Probe-1.1.3-py3-none-linux_x86_64.whl"
comptime _WHEEL_BYTES: String = "wheel-bytes-v1"
# sha256("wheel-bytes-v1"), hex
comptime _SHA_HEX: String = "bd3411c7a8ecbcdae2986cf44014dc62e23004b5134fff832407d2e407a13eff"
comptime _OTHER_HEX: String = "0000000000000000000000000000000000000000000000000000000000000000"


def _coord(substrate: Int, repo: String) -> PackageCoordinate:
    return PackageCoordinate(
        substrate,
        repo.copy(),
        String("Komira.Probe"),
        String("1.1.3"),
        String("linux-64"),
        String(_FILE),
    )


def _ours() -> ContentIdentity:
    return content_identity_of(bytes_of(String(_WHEEL_BYTES)))


def _ok(var body: String, ctype: String = String("application/json")) -> PkgResponse:
    var r = PkgResponse(200)
    r.with_header(String("content-type"), ctype.copy())
    r.with_body(bytes_of(body))
    return r^


def _status(code: Int) -> PkgResponse:
    return PkgResponse(code)


def _pypi_json(sha: String, include_digest: Bool = True) -> String:
    var digests = String("{}")
    if include_digest:
        digests = String('{"md5": "x", "sha256": "') + sha + String('"}')
    return (
        String('{"info": {"name": "komira-probe"}, "urls": [')
        + String('{"filename": "komira_probe-1.1.3.tar.gz", "digests": {"sha256": "')
        + String(_OTHER_HEX)
        + String('"}, "url": "https://files.pythonhosted.org/x.tar.gz"}, ')
        + String('{"filename": "')
        + String(_FILE)
        + String('", "digests": ')
        + digests
        + String(', "url": "https://files.pythonhosted.org/packages/ab/cd/')
        + String(_FILE)
        + String('"}]}')
    )


def _creds() -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PYPI_UPLOAD, String("Basic warehouse-upload"))
    return c^


def _set(var t: ScriptedPkgTransport) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds())


# ── the warehouse arm ───────────────────────────────────────────────────────


def test_pypi_404_is_absent_on_every_read() raises:
    var t = ScriptedPkgTransport()
    t.queue(_status(404))
    t.queue(_status(404))
    t.queue(_status(404))
    var rs = _set(t^)
    var c = _coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org"))
    assert_equal(rs.read_back(c).kind, READ_ABSENT)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_ABSENT)
    assert_equal(rs.fetch(c).kind, READ_ABSENT)
    var req = rs.transport().call(0)
    assert_equal(req.host, String("pypi.org"))
    assert_equal(req.path, String("/pypi/komira-probe/1.1.3/json"))
    assert_equal(req.header_value(String("Authorization")), String(""))
    assert_equal(rs.credential().asked_count(), 0)
    print("  test_pypi_404_is_absent_on_every_read: PASS")


def test_pypi_listing_presence_kinds() raises:
    var t = ScriptedPkgTransport()
    t.queue(_ok(_pypi_json(String(_SHA_HEX))))
    t.queue(_ok(_pypi_json(String(_SHA_HEX))))
    t.queue(_ok(_pypi_json(String(_OTHER_HEX))))
    t.queue(_ok(_pypi_json(String(""), include_digest=False)))
    var rs = _set(t^)
    var c = _coord(SUBSTRATE_PUBLIC_PYPI, String("test.pypi.org"))
    var rb = rs.read_back(c)
    assert_equal(rb.kind, READ_PRESENT)
    assert_equal(rb.observed.sha256_hex, String(_SHA_HEX))
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_PRESENT_IDENTICAL)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_PRESENT_DIFFERENT)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_NO_COMMON_FIELD)
    assert_equal(rs.transport().call(0).host, String("test.pypi.org"))
    print("  test_pypi_listing_presence_kinds: PASS")


def test_pypi_listing_without_the_file_is_absent() raises:
    var t = ScriptedPkgTransport()
    t.queue(_ok(String('{"urls": [{"filename": "other.whl", "digests": {}}]}')))
    var rs = _set(t^)
    assert_equal(rs.read_back(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org"))).kind, READ_ABSENT)
    print("  test_pypi_listing_without_the_file_is_absent: PASS")


def test_pypi_fetch_follows_the_listing_and_a_redirect() raises:
    var t = ScriptedPkgTransport()
    t.queue(_ok(_pypi_json(String(_SHA_HEX))))
    var hop = PkgResponse(302)
    hop.with_header(String("location"), String("https://cdn.example.invalid/blob/1"))
    t.queue(hop^)
    var file = PkgResponse(200)
    file.with_body(bytes_of(String(_WHEEL_BYTES)))
    t.queue(file^)
    var rs = _set(t^)
    var f = rs.fetch(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org")))
    assert_equal(f.kind, READ_PRESENT, read_kind_name(f.kind) + f.detail)
    assert_equal(content_identity_of(f.bytes).sha256_hex, String(_SHA_HEX))
    assert_equal(rs.transport().call(1).host, String("files.pythonhosted.org"))
    assert_equal(
        rs.transport().call(1).path, String("/packages/ab/cd/") + String(_FILE)
    )
    assert_equal(rs.transport().call(2).host, String("cdn.example.invalid"))
    assert_equal(rs.transport().call(2).header_value(String("Authorization")), String(""))

    var t2 = ScriptedPkgTransport()
    t2.queue(_ok(_pypi_json(String(_SHA_HEX))))
    t2.queue(_status(404))
    var rs2 = _set(t2^)
    assert_equal(rs2.fetch(_coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org"))).kind, READ_ABSENT)
    print("  test_pypi_fetch_follows_the_listing_and_a_redirect: PASS")


def test_pypi_server_answers_are_kinds() raises:
    var t = ScriptedPkgTransport()
    t.queue_fault(String("dial: connection refused"))
    t.queue(_status(403))
    t.queue(_status(429))
    t.queue(_ok(String("{not json")))
    t.queue(_status(503))
    var rs = _set(t^)
    var c = _coord(SUBSTRATE_PUBLIC_PYPI, String("pypi.org"))
    assert_equal(rs.read_back(c).kind, READ_UNKNOWN)
    assert_equal(rs.read_back(c).kind, READ_AUTH_REFUSED)
    assert_equal(rs.read_back(c).kind, READ_RATE_LIMITED)
    assert_equal(rs.read_back(c).kind, READ_UNKNOWN)
    assert_equal(rs.read_back(c).kind, READ_UNKNOWN)
    print("  test_pypi_server_answers_are_kinds: PASS")


# ── the listing's own shape (rows 7, 8) ──────────────────────────────────────


def _listing(key: String, var entries: String) -> String:
    return String('{"') + key + String('": ') + entries + String("}")


def _named_entry(digests_key: String) -> String:
    """A readable entry that names `_FILE`, with its sha256 and a URL."""
    return (
        String('{"filename": "')
        + String(_FILE)
        + String('", "url": "x", "')
        + digests_key
        + String('": {"sha256": "')
        + String(_SHA_HEX)
        + String('"}}')
    )


def _read_twice(
    ctype: String, body: String
) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    """A RegistrySet scripted to answer `body` to exactly TWO requests: one
    read_back and one presence, each a single index GET. A third request
    would raise for want of an answer."""
    var t = ScriptedPkgTransport()
    t.queue(_ok(body.copy(), ctype))
    t.queue(_ok(body.copy(), ctype))
    return _set(t^)


def _assert_unknown(
    substrate: Int, repo: String, ctype: String, key: String, body: String
) raises:
    var rs = _read_twice(ctype, body)
    var c = _coord(substrate, repo)
    var rb = rs.read_back(c)
    assert_equal(
        rb.kind,
        READ_UNKNOWN,
        body + String(" -> ") + read_kind_name(rb.kind) + String(": ") + rb.detail,
    )
    assert_true(
        rb.detail.find(String("'") + key + String("'")) >= 0,
        body + String(" -> the detail does not name the key: ") + rb.detail,
    )
    var p = rs.presence(c, _ours())
    assert_equal(
        p.kind,
        PRESENCE_UNKNOWN,
        body + String(" -> ") + presence_kind_name(p.kind) + String(": ") + p.detail,
    )
    assert_equal(rs.transport().call_count(), 2, body)
    assert_equal(rs.transport().unconsumed(), 0, body)


def _assert_read(
    substrate: Int,
    repo: String,
    ctype: String,
    body: String,
    want_read: Int,
    want_presence: Int,
) raises:
    var rs = _read_twice(ctype, body)
    var c = _coord(substrate, repo)
    var rb = rs.read_back(c)
    assert_equal(
        rb.kind,
        want_read,
        body + String(" -> ") + read_kind_name(rb.kind) + String(": ") + rb.detail,
    )
    var p = rs.presence(c, _ours())
    assert_equal(
        p.kind,
        want_presence,
        body + String(" -> ") + presence_kind_name(p.kind) + String(": ") + p.detail,
    )
    assert_equal(rs.transport().unconsumed(), 0, body)


def _unreadable_listings(key: String) -> List[String]:
    """Row 7: a listing no entry of which can be read, or with no listing at
    all under `key`."""
    var out = List[String]()
    out.append(_listing(key, String("null")))
    out.append(_listing(key, String("{}")))
    out.append(_listing(key, String('"x"')))
    out.append(_listing(key, String('[{"url": "x"}]')))
    out.append(_listing(key, String('["x", null]')))
    out.append(_listing(key, String('[{"filename": 7}]')))
    # The array key MISSING (the header's first bullet): an object without
    # it, and a top-level document that is not an object at all.
    out.append(String("{}"))
    out.append(String('{"meta": {}}'))
    out.append(String("null"))
    out.append(String("[]"))
    return out^


def test_an_unreadable_listing_is_unknown_never_absent() raises:
    """⛔ `JsonValue.array_len()` is 0 for ANY non-array, so a loop over it
    reads `{"urls": null}` as an empty listing. ABSENT is the presence answer
    a publisher UPLOADS on; it may only come from a listing that was read,
    never from one that could not be."""
    var pypi = _unreadable_listings(String("urls"))
    for i in range(len(pypi)):
        _assert_unknown(
            SUBSTRATE_PUBLIC_PYPI,
            String("pypi.org"),
            String("application/json"),
            String("urls"),
            pypi[i],
        )
    print("  test_an_unreadable_listing_is_unknown_never_absent: PASS")


def test_an_unreadable_entry_beside_readable_ones() raises:
    """Row 8: the file found is PRESENT whatever else the listing holds; an
    unreadable entry beside readable ones that do not name it is UNKNOWN; a
    listing read in full that does not name it is ABSENT."""
    var substrate = SUBSTRATE_PUBLIC_PYPI
    var repo = String("pypi.org")
    var ctype = String("application/json")
    var key = String("urls")
    var digests = String("digests")
    var named = _named_entry(digests)
    # (a) the file is found past an entry with no filename: PRESENT.
    _assert_read(
        substrate,
        repo,
        ctype,
        _listing(key, String('[{"url": "x"}, ') + named + String("]")),
        READ_PRESENT,
        PRESENCE_PRESENT_IDENTICAL,
    )
    # (b) ... and past a non-string filename and a non-object entry.
    _assert_read(
        substrate,
        repo,
        ctype,
        _listing(key, String('[{"filename": 7}, "x", ') + named + String("]")),
        READ_PRESENT,
        PRESENCE_PRESENT_IDENTICAL,
    )
    # (c) an unreadable entry beside a readable one naming ANOTHER file:
    #     the unreadable one could be ours, so UNKNOWN.
    _assert_unknown(
        substrate,
        repo,
        ctype,
        key,
        _listing(key, String('[{"url": "x"}, {"filename": "other.whl"}]')),
    )
    # (d) every entry readable, none names the file: ABSENT.
    _assert_read(
        substrate,
        repo,
        ctype,
        _listing(key, String('[{"filename": "other.whl"}]')),
        READ_ABSENT,
        PRESENCE_ABSENT,
    )
    # (e) an empty array is a listing read in full: ABSENT.
    _assert_read(
        substrate, repo, ctype, _listing(key, String("[]")), READ_ABSENT, PRESENCE_ABSENT
    )
    print("  test_an_unreadable_entry_beside_readable_ones: PASS")


def main() raises:
    test_pypi_404_is_absent_on_every_read()
    test_pypi_listing_presence_kinds()
    test_pypi_listing_without_the_file_is_absent()
    test_pypi_fetch_follows_the_listing_and_a_redirect()
    test_pypi_server_answers_are_kinds()
    test_an_unreadable_listing_is_unknown_never_absent()
    test_an_unreadable_entry_beside_readable_ones()
    print("test_pkg_upload_reads: ALL PASS")
