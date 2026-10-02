# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_conda_reads.mojo — read_back,
#   presence and fetch on a prefix.dev conda channel answer with a KIND.
# =============================================================================
#
# ROWS
#   (1) the subdir's repodata, read at `/<channel>/<subdir>/repodata.json`:
#       a 404 is ABSENT; the file listed with OUR sha256 is PRESENT_IDENTICAL,
#       with another sha256 PRESENT_DIFFERENT, with NO sha256 NO_COMMON_FIELD
#       (never IDENTICAL); a listing without the file is ABSENT;
#   (2) the channel's 303 to a signed URL on ANOTHER host is followed, and
#       the credential reaches only the channel's own host — never the signed
#       one; an anonymous credential (EMPTY for PREFIX_DEV) sends no
#       Authorization header at all;
#   (3) ABSENT only from a listing that was READ: a body that is not JSON or
#       not an object, a `packages.conda` that is not an object, a document
#       with neither listing key, an entry that is not an object, a sha256
#       that is not a string — each UNKNOWN (read_back AND presence), never
#       ABSENT; a repodata with only the `.tar.bz2` listing lists no `.conda`
#       file, so it IS ABSENT;
#   (4) a `.tar.bz2` file is read from `packages`;
#   (5) fetch follows the redirect and returns the bytes; a 404 is ABSENT;
#       401/403 AUTH_REFUSED, 429 RATE_LIMITED, 5xx and a transport fault
#       UNKNOWN;
#   (6) a credentialed read whose error body echoes the token ACROSS the
#       excerpt's byte bound quotes no prefix of it (repodata 403 and 5xx, the
#       file GET 403);
#   (7) package_names: the names of BOTH listings, lowercased, sorted, once
#       each, read from `/<channel>/<subdir>/repodata.json`; a 404 is ABSENT
#       with no name; a listing that was not read (not an object, neither
#       key, an entry that is not an object, a key that is not
#       <name>-<version>-<build>, a 5xx, a transport fault) is UNKNOWN with NO
#       name and `holds` RAISES on it, never answering "not held"; a 403 is
#       AUTH_REFUSED; PyPI has no subdir listing and a malformed subdir is a
#       local fault — both RAISE with ZERO requests.
#
# Hermetic: ScriptedPkgTransport + ScriptedCredential; no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from kci_pkg_upload.conda_repodata import NameListing, conda_package_name_of_file
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    SUBSTRATE_PUBLIC_PYPI,
    PackageCoordinate,
)
from kci_pkg_upload.credential import SURFACE_PREFIX_DEV, ScriptedCredential
from kci_pkg_upload.identity import ContentIdentity, content_identity_of
from kci_pkg_upload.outcome import (
    DETAIL_EXCERPT_BYTES,
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


comptime _REPO: String = "prefix.dev/example-channel"
comptime _FILE: String = "komira-probe-1.2.3-h0123abc_0.conda"
comptime _BYTES: String = "conda-bytes-v1"
comptime _SIGNED_HOST: String = "packages.example.invalid"
comptime _OTHER_HEX: String = "abababababababababababababababababababababababababababababababab"
comptime _LONG_TOKEN: String = "pfx_echo_probe_0123456789abcdefghijklmnopqrstuvwxyz"


def _coord(file_name: String = String(_FILE)) -> PackageCoordinate:
    return PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA,
        String(_REPO),
        String("komira-probe"),
        String("1.2.3"),
        String("linux-64"),
        file_name.copy(),
    )


def _ours() -> ContentIdentity:
    return content_identity_of(bytes_of(String(_BYTES)))


def _sha() -> String:
    return _ours().sha256_hex.copy()


def _creds(value: String = String("Bearer pfx-token")) -> ScriptedCredential:
    var c = ScriptedCredential()
    c.serve(SURFACE_PREFIX_DEV, value.copy())
    return c^


def _set(
    var t: ScriptedPkgTransport, value: String = String("Bearer pfx-token")
) -> RegistrySet[ScriptedPkgTransport, ScriptedCredential]:
    return RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, _creds(value))


def _json(var body: String) -> PkgResponse:
    var r = PkgResponse(200)
    r.with_header(String("content-type"), String("application/json"))
    r.with_body(bytes_of(body))
    return r^


def _status(code: Int) -> PkgResponse:
    return PkgResponse(code)


def _listing(entry: String) -> String:
    return (
        String('{"info": {"subdir": "linux-64"}, "packages": {}, "packages.conda": {')
        + String('"other-0.1-0.conda": {"sha256": "00"}')
        + entry
        + String("}}")
    )


def _named(sha_field: String) -> String:
    return String(', "') + String(_FILE) + String('": {') + sha_field + String("}")


def test_repodata_kinds() raises:
    var t = ScriptedPkgTransport()
    t.queue(_status(404))
    t.queue(_json(_listing(_named(String('"sha256": "') + _sha() + String('"')))))
    t.queue(_json(_listing(_named(String('"sha256": "') + String(_OTHER_HEX) + String('"')))))
    t.queue(_json(_listing(_named(String('"md5": "x", "size": 14')))))
    t.queue(_json(_listing(String(""))))
    var rs = _set(t^)
    var c = _coord()
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_ABSENT)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_PRESENT_IDENTICAL)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_PRESENT_DIFFERENT)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_NO_COMMON_FIELD)
    assert_equal(rs.presence(c, _ours()).kind, PRESENCE_ABSENT)
    var req = rs.transport().call(0)
    assert_equal(req.host, String("prefix.dev"))
    assert_equal(req.path, String("/example-channel/linux-64/repodata.json"))
    assert_equal(req.header_value(String("Accept")), String("application/json"))
    print("  test_repodata_kinds: PASS")


def test_the_redirect_and_where_the_credential_goes() raises:
    var t = ScriptedPkgTransport()
    var hop = PkgResponse(303)
    hop.with_header(
        String("location"),
        String("https://") + String(_SIGNED_HOST) + String("/s/linux-64/repodata.json?sig=abc"),
    )
    t.queue(hop^)
    t.queue(_json(_listing(_named(String('"sha256": "') + _sha() + String('"')))))
    var rs = _set(t^)
    var rb = rs.read_back(_coord())
    assert_equal(rb.kind, READ_PRESENT, read_kind_name(rb.kind) + rb.detail)
    assert_equal(rb.observed.sha256_hex, _sha())
    assert_equal(rs.transport().call(0).header_value(String("Authorization")), String("Bearer pfx-token"))
    assert_equal(rs.transport().call(1).host, String(_SIGNED_HOST))
    assert_equal(rs.transport().call(1).path, String("/s/linux-64/repodata.json?sig=abc"))
    assert_equal(rs.transport().call(1).header_value(String("Authorization")), String(""))

    # Anonymous: the credential gives EMPTY for PREFIX_DEV; no header is sent.
    var t2 = ScriptedPkgTransport()
    t2.queue(_status(404))
    var anon = _set(t2^, String(""))
    assert_equal(anon.read_back(_coord()).kind, READ_ABSENT)
    assert_equal(len(anon.transport().call(0).header_names), 1)
    assert_equal(anon.transport().call(0).header_value(String("Authorization")), String(""))
    print("  test_the_redirect_and_where_the_credential_goes: PASS")


def _assert_unknown(body: String) raises:
    var t = ScriptedPkgTransport()
    t.queue(_json(body.copy()))
    t.queue(_json(body.copy()))
    var rs = _set(t^)
    var rb = rs.read_back(_coord())
    assert_equal(rb.kind, READ_UNKNOWN, body + String(" -> ") + read_kind_name(rb.kind))
    var p = rs.presence(_coord(), _ours())
    assert_equal(p.kind, PRESENCE_UNKNOWN, body + String(" -> ") + presence_kind_name(p.kind))
    assert_equal(rs.transport().unconsumed(), 0)


def test_absent_only_from_a_listing_that_was_read() raises:
    _assert_unknown(String("{not json"))
    _assert_unknown(String("[]"))
    _assert_unknown(String("null"))
    _assert_unknown(String('{"packages.conda": null}'))
    _assert_unknown(String('{"packages.conda": []}'))
    _assert_unknown(String('{"packages.conda": "x", "packages": {}}'))
    _assert_unknown(String('{"info": {}}'))
    _assert_unknown(String('{"packages": null}'))
    _assert_unknown(
        String('{"packages.conda": {"') + String(_FILE) + String('": "x"}}')
    )
    _assert_unknown(
        String('{"packages.conda": {"') + String(_FILE) + String('": {"sha256": 7}}}')
    )
    # Only the `.tar.bz2` listing: it lists no `.conda` file — ABSENT.
    var t = ScriptedPkgTransport()
    t.queue(_json(String('{"packages": {"other-0.1-0.tar.bz2": {}}}')))
    var rs = _set(t^)
    assert_equal(rs.read_back(_coord()).kind, READ_ABSENT)
    print("  test_absent_only_from_a_listing_that_was_read: PASS")


def test_a_tar_bz2_file_is_read_from_packages() raises:
    var file = String("komira-probe-1.2.3-h0123abc_0.tar.bz2")
    var t = ScriptedPkgTransport()
    t.queue(
        _json(
            String('{"packages": {"')
            + file
            + String('": {"sha256": "')
            + _sha()
            + String('"}}, "packages.conda": {}}')
        )
    )
    var rs = _set(t^)
    var rb = rs.read_back(_coord(file))
    assert_equal(rb.kind, READ_PRESENT, rb.detail)
    assert_equal(rb.observed.sha256_hex, _sha())
    print("  test_a_tar_bz2_file_is_read_from_packages: PASS")


def test_fetch_and_server_answers() raises:
    var t = ScriptedPkgTransport()
    var hop = PkgResponse(302)
    hop.with_header(String("location"), String("https://") + String(_SIGNED_HOST) + String("/f/1"))
    t.queue(hop^)
    var file = PkgResponse(200)
    file.with_body(bytes_of(String(_BYTES)))
    t.queue(file^)
    t.queue(_status(404))
    t.queue(_status(403))
    t.queue(_status(429))
    t.queue(_status(502))
    t.queue_fault(String("dial: connection refused"))
    var rs = _set(t^)
    var c = _coord()
    var f = rs.fetch(c)
    assert_equal(f.kind, READ_PRESENT, f.detail)
    assert_equal(content_identity_of(f.bytes).sha256_hex, _sha())
    assert_equal(rs.transport().call(0).path, String("/example-channel/linux-64/") + String(_FILE))
    assert_equal(rs.transport().call(1).header_value(String("Authorization")), String(""))
    assert_equal(rs.fetch(c).kind, READ_ABSENT)
    assert_equal(rs.read_back(c).kind, READ_AUTH_REFUSED)
    assert_equal(rs.read_back(c).kind, READ_RATE_LIMITED)
    assert_equal(rs.read_back(c).kind, READ_UNKNOWN)
    assert_equal(rs.read_back(c).kind, READ_UNKNOWN)
    assert_equal(rs.transport().unconsumed(), 0)
    print("  test_fetch_and_server_answers: PASS")


def _echo_cut(status: Int, keep: Int) -> PkgResponse:
    var body = List[UInt8]()
    for _ in range(DETAIL_EXCERPT_BYTES - keep):
        body.append(UInt8(ord("x")))
    var tb = String(_LONG_TOKEN).as_bytes()
    for i in range(len(tb)):
        body.append(tb[i])
    var r = PkgResponse(status)
    r.with_body(body^)
    return r^


def test_a_read_never_quotes_a_cut_echo_of_its_credential() raises:
    var prefix = String(String(_LONG_TOKEN)[byte=0:24])
    var t = ScriptedPkgTransport()
    t.queue(_echo_cut(403, 24))
    t.queue(_echo_cut(500, 24))
    t.queue(_echo_cut(403, 24))
    var rs = _set(t^, String("Bearer ") + String(_LONG_TOKEN))
    var c = _coord()
    var a = rs.read_back(c)
    assert_equal(a.kind, READ_AUTH_REFUSED, a.detail)
    assert_true(a.detail.find(prefix) < 0, a.detail)
    var b = rs.read_back(c)
    assert_equal(b.kind, READ_UNKNOWN, b.detail)
    assert_true(b.detail.find(prefix) < 0, b.detail)
    var e = rs.fetch(c)
    assert_equal(e.kind, READ_AUTH_REFUSED, e.detail)
    assert_true(e.detail.find(prefix) < 0, e.detail)
    assert_equal(rs.transport().unconsumed(), 0)
    print("  test_a_read_never_quotes_a_cut_echo_of_its_credential: PASS")


def _names(var t: ScriptedPkgTransport, subdir: String = String("linux-64")) raises -> NameListing:
    var rs = _set(t^)
    var n = rs.package_names(SUBSTRATE_PREFIX_DEV_CONDA, String(_REPO), subdir)
    assert_equal(rs.transport().unconsumed(), 0)
    return n^


def test_package_names_from_both_listings() raises:
    var t = ScriptedPkgTransport()
    t.queue(
        _json(
            String('{"info": {"subdir": "linux-64"}, "packages": {')
            + String('"Old-Lib-0.1-0.tar.bz2": {"sha256": "00"}}, "packages.conda": {')
            + String('"komira-probe-1.2.3-h0123abc_0.conda": {},')
            + String('"komira-probe-1.2.4-h0123abc_0.conda": {},')
            + String('"a-lib-9-0.conda": {}}}')
        )
    )
    var rs = _set(t^)
    var n = rs.package_names(SUBSTRATE_PREFIX_DEV_CONDA, String(_REPO), String("noarch"))
    assert_equal(n.kind, READ_PRESENT, read_kind_name(n.kind) + n.detail)
    assert_equal(len(n.names), 3)
    assert_equal(n.names[0], String("a-lib"))
    assert_equal(n.names[1], String("komira-probe"))
    assert_equal(n.names[2], String("old-lib"))
    assert_true(n.holds(String("Komira-Probe")))
    assert_true(n.holds(String("old-lib")))
    assert_false(n.holds(String("komira")))
    var req = rs.transport().call(0)
    assert_equal(req.host, String("prefix.dev"))
    assert_equal(req.path, String("/example-channel/noarch/repodata.json"))
    assert_equal(req.header_value(String("Authorization")), String("Bearer pfx-token"))

    # Only one listing present, as an object: read, and its names are all.
    var t2 = ScriptedPkgTransport()
    t2.queue(_json(String('{"packages.conda": {}}')))
    var empty = _names(t2^)
    assert_equal(empty.kind, READ_PRESENT, empty.detail)
    assert_equal(len(empty.names), 0)
    assert_false(empty.holds(String("komira-probe")))

    # 404: the subdir holds no repodata, so no name; ABSENT is a read answer.
    var t3 = ScriptedPkgTransport()
    t3.queue(_status(404))
    var none = _names(t3^)
    assert_equal(none.kind, READ_ABSENT)
    assert_true(none.was_read())
    assert_false(none.holds(String("komira-probe")))
    print("  test_package_names_from_both_listings: PASS")


def _assert_names_not_read(var r: PkgResponse, expect_kind: Int) raises:
    var t = ScriptedPkgTransport()
    t.queue(r^)
    var n = _names(t^)
    assert_equal(n.kind, expect_kind, read_kind_name(n.kind) + String(" ") + n.detail)
    assert_equal(len(n.names), 0, n.detail)
    assert_false(n.was_read())
    var raised = False
    try:
        _ = n.holds(String("komira-probe"))
    except e:
        raised = True
        assert_true(String(e).find(String("not read")) >= 0, String(e))
    assert_true(raised, String("holds() answered from a listing that was not read"))


def test_package_names_never_empty_from_a_listing_not_read() raises:
    _assert_names_not_read(_json(String("{not json")), READ_UNKNOWN)
    _assert_names_not_read(_json(String("[]")), READ_UNKNOWN)
    _assert_names_not_read(_json(String('{"info": {}}')), READ_UNKNOWN)
    _assert_names_not_read(_json(String('{"packages.conda": null}')), READ_UNKNOWN)
    _assert_names_not_read(
        _json(String('{"packages": {}, "packages.conda": []}')), READ_UNKNOWN
    )
    _assert_names_not_read(
        _json(String('{"packages.conda": {"komira-1-0.conda": "x"}}')), READ_UNKNOWN
    )
    _assert_names_not_read(
        _json(String('{"packages.conda": {"komira-1-0.conda": {}, "README.md": {}}}')),
        READ_UNKNOWN,
    )
    _assert_names_not_read(
        _json(String('{"packages.conda": {"nodashes.conda": {}}}')), READ_UNKNOWN
    )
    _assert_names_not_read(_status(502), READ_UNKNOWN)
    _assert_names_not_read(_status(403), READ_AUTH_REFUSED)
    _assert_names_not_read(_status(429), READ_RATE_LIMITED)
    var t = ScriptedPkgTransport()
    t.queue_fault(String("dial: connection refused"))
    var n = _names(t^)
    assert_equal(n.kind, READ_UNKNOWN)
    assert_equal(len(n.names), 0)
    print("  test_package_names_never_empty_from_a_listing_not_read: PASS")


def test_package_names_local_faults_send_nothing() raises:
    var rs = _set(ScriptedPkgTransport())
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("linux-64/x"))
    bad.append(String(".."))
    bad.append(String("linux-64?x=1"))
    for i in range(len(bad)):
        var raised = False
        try:
            _ = rs.package_names(SUBSTRATE_PREFIX_DEV_CONDA, String(_REPO), bad[i])
        except:
            raised = True
        assert_true(raised, String("subdir '") + bad[i] + String("' was sent"))
    var raised = False
    try:
        _ = rs.package_names(SUBSTRATE_PUBLIC_PYPI, String("pypi.org"), String("noarch"))
    except e:
        raised = True
        assert_true(String(e).find(String("no registry arm")) >= 0, String(e))
    assert_true(raised, String("PyPI answered a subdir listing"))
    assert_equal(rs.transport().call_count(), 0)
    print("  test_package_names_local_faults_send_nothing: PASS")


def test_conda_package_name_of_file() raises:
    assert_equal(conda_package_name_of_file(String("komira-probe-1.2.3-h0_0.conda")), String("komira-probe"))
    assert_equal(conda_package_name_of_file(String("Mojo-Compiler-26.1-0.tar.bz2")), String("mojo-compiler"))
    assert_equal(conda_package_name_of_file(String("komira-1.2.3.conda")), String(""))
    assert_equal(conda_package_name_of_file(String("komira--0.conda")), String(""))
    assert_equal(conda_package_name_of_file(String("-1-0.conda")), String(""))
    assert_equal(conda_package_name_of_file(String("komira-1-.conda")), String(""))
    assert_equal(conda_package_name_of_file(String("komira-1-0.whl")), String(""))
    print("  test_conda_package_name_of_file: PASS")


def main() raises:
    test_repodata_kinds()
    test_the_redirect_and_where_the_credential_goes()
    test_absent_only_from_a_listing_that_was_read()
    test_a_tar_bz2_file_is_read_from_packages()
    test_fetch_and_server_answers()
    test_a_read_never_quotes_a_cut_echo_of_its_credential()
    test_package_names_from_both_listings()
    test_package_names_never_empty_from_a_listing_not_read()
    test_package_names_local_faults_send_nothing()
    test_conda_package_name_of_file()
    print("test_pkg_upload_conda_reads: ALL PASS")
