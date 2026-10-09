# =============================================================================
# src/kci_pkg_upload/tests/test_pkg_upload_read_edges.mojo — the GET loop,
#   index hrefs, listed-file fetches and conda reads, at their edges.
# =============================================================================
#
# ROWS
#   (1) the GET loop follows exactly MAX_REDIRECT_HOPS (5) redirects; the
#       sixth is refused, naming the hop budget and where the chain started,
#       after exactly six requests;
#   (2) every refused redirect is data, never a raise, and its detail names
#       the status, the hop it came from and WHICH refusal: no Location, a
#       plaintext http:// URL, a host with no path, an empty host, a
#       path-relative Location;
#   (3) an index href resolves against the page: relative to its directory
#       with `.`/`..` removed (RFC 3986 §5.2.4, a trailing `.`/`..` leaves a
#       trailing `/`, `..` above the root stays at the root), the fragment
#       dropped, the query kept; another scheme (a colon before the first
#       `/`) is refused, a colon after it is a path byte;
#   (4) a listed-file fetch: an entry with no URL, or one that cannot be
#       followed, is UNKNOWN naming why, keeping the listing's status; the
#       index credential reaches the file only when the file host IS the
#       index host; a transport fault is UNKNOWN with status 0; a 429 on the
#       file is RATE_LIMITED;
#   (5) a PEP 691 read: a 200 that is not the JSON asked for is UNKNOWN and
#       `not_json`, naming the Content-Type; one that is, is read; a listing
#       array that is a boolean or a number is named as such;
#   (6) prefix.dev: a channel holding `?`, `#` or `%` is refused; a
#       `.tar.bz2` file name splits at the same `-` as a `.conda` one; a file
#       name with no `-` is refused; a quote, LF or CR in a file name cannot
#       be carried in the form; a fetch whose GET faults is UNKNOWN, status 0;
#   (7) conda repodata for a `.tar.bz2` file: a repodata holding only
#       `packages.conda` lists no such file (ABSENT); one holding neither
#       listing cannot be read (UNKNOWN, naming both keys).
#
# Hermetic: ScriptedPkgTransport + ScriptedCredential; no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_http_client.redirect_policy import (
    REDIRECT_REFUSED_UNRESOLVABLE,
    REDIRECT_RESOLVED,
)

from kci_pkg_upload.conda_repodata import classify_repodata_answer
from kci_pkg_upload.coordinate import (
    SUBSTRATE_PREFIX_DEV_CONDA,
    PackageCoordinate,
    PackageFile,
)
from kci_pkg_upload.credential import SURFACE_PREFIX_DEV, ScriptedCredential
from kci_pkg_upload.http_read import GetResult, get_following_redirects, resolve_index_href
from kci_pkg_upload.index_lookup import PEP691_JSON, IndexEntry, _json_kind_word, classify_index_answer
from kci_pkg_upload.outcome import (
    READ_ABSENT,
    READ_PRESENT,
    READ_RATE_LIMITED,
    READ_UNKNOWN,
)
from kci_pkg_upload.prefix_dev_registry import (
    encode_prefix_dev_form,
    prefix_dev_channel,
    refuse_name_not_the_files,
)
from kci_pkg_upload.pypi_registry import fetch_listed_file, read_kind_of_fetch_status
from kci_pkg_upload.registry_set import RegistrySet
from kci_pkg_upload.transport import PkgResponse, ScriptedPkgTransport
from kci_pkg_upload.wire import bytes_of

from komira_json import JSON_ARRAY


def _redirect(status: Int, location: String) -> PkgResponse:
    var r = PkgResponse(status)
    if location.byte_length() > 0:
        r.with_header(String("Location"), location.copy())
    return r^


def _body(status: Int, body: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(bytes_of(body))
    return r^


def test_the_hop_budget() raises:
    var t = ScriptedPkgTransport()
    for i in range(6):
        t.queue(_redirect(302, String("/hop") + String(i)))
    var got = get_following_redirects(
        t, String("idx.example.invalid"), String("/start"), String(""), String("")
    )
    assert_false(got.ok)
    assert_equal(got.response.status, 302)
    assert_equal(
        got.detail,
        String("more than 5 redirects starting at idx.example.invalid/start"),
    )
    assert_equal(got.path, String("/hop4"), "the sixth redirect came from the fifth hop")
    assert_equal(t.call_count(), 6, "five redirects followed, the sixth refused")
    assert_equal(t.unconsumed(), 0)
    # Five redirects then an answer: followed to the end.
    var t2 = ScriptedPkgTransport()
    for i in range(5):
        t2.queue(_redirect(301, String("/hop") + String(i)))
    t2.queue(_body(200, String("done")))
    var got2 = get_following_redirects(
        t2, String("idx.example.invalid"), String("/start"), String(""), String("")
    )
    assert_true(got2.ok, got2.detail)
    assert_equal(got2.path, String("/hop4"))
    print("  test_the_hop_budget: PASS")


def _refused(location: String, want: String) raises:
    var t = ScriptedPkgTransport()
    t.queue(_redirect(307, location))
    var got = get_following_redirects(
        t, String("idx.example.invalid"), String("/p"), String(""), String("")
    )
    assert_false(got.ok, location)
    assert_equal(got.response.status, 307)
    assert_equal(got.detail, String("HTTP 307 from idx.example.invalid/p is ") + want)
    assert_equal(t.call_count(), 1)


def test_each_refused_redirect_is_named() raises:
    _refused(String(""), String("a redirect with no Location header"))
    _refused(
        String("http://cdn.example.invalid/f"),
        String("a redirect to a plaintext http:// URL (refused, never upgraded)"),
    )
    _refused(String("https://cdn.example.invalid"), String("a redirect to a host with no path"))
    _refused(String("https:///f"), String("a redirect with an empty host"))
    _refused(
        String("relative/f"),
        String("a redirect whose Location cannot be resolved without guessing"),
    )
    print("  test_each_refused_redirect_is_named: PASS")


def _href(page_path: String, href: String, want_path: String) raises:
    var t = resolve_index_href(String("idx.example.invalid"), page_path, href)
    assert_equal(t.kind, REDIRECT_RESOLVED, href)
    assert_equal(t.host, String("idx.example.invalid"), href)
    assert_equal(t.path, want_path, href)


def test_index_hrefs_resolve_against_the_page() raises:
    _href(String("/simple/p/"), String("f.whl#sha256=ab"), String("/simple/p/f.whl"))
    _href(String("/simple/p/"), String("../../pkgs/f.whl?x=1#h"), String("/pkgs/f.whl?x=1"))
    _href(String("/simple/p/index"), String("./f.whl"), String("/simple/p/f.whl"))
    _href(String("/a/b/c"), String(".."), String("/a/"))
    _href(String("/a/b/c"), String("."), String("/a/b/"))
    _href(String("/a/b/c"), String("x/.."), String("/a/b/"))
    _href(String("/a/"), String("../../../../x"), String("/x"))
    _href(String("/a/"), String(".."), String("/"))
    _href(String("/a/b/"), String("c//d/./e"), String("/a/b/c//d/e"))
    _href(String("/a/"), String("b/c:d"), String("/a/b/c:d"))
    _href(String("/a/"), String("/abs/f.whl#frag"), String("/abs/f.whl"))
    var data = resolve_index_href(String("idx.example.invalid"), String("/a/"), String("data:abc"))
    assert_equal(data.kind, REDIRECT_REFUSED_UNRESOLVABLE)
    var mailto = resolve_index_href(String("idx.example.invalid"), String("/a/"), String("x:y/z"))
    assert_equal(mailto.kind, REDIRECT_REFUSED_UNRESOLVABLE)
    print("  test_index_hrefs_resolve_against_the_page: PASS")


def _entry(url: String, page_host: String = String("idx.example.invalid")) -> IndexEntry:
    return IndexEntry(
        READ_PRESENT,
        200,
        String(""),
        url.copy(),
        page_host.copy(),
        String("/simple/p/"),
        False,
        String(""),
    )


def test_listed_file_fetches() raises:
    var t = ScriptedPkgTransport()
    var none = fetch_listed_file(t, _entry(String("")), String(""), String(""))
    assert_equal(none.kind, READ_UNKNOWN)
    assert_equal(none.status, 200)
    assert_equal(none.detail, String("the index lists the file with no URL"))
    var bad = fetch_listed_file(t, _entry(String("data:x")), String(""), String(""))
    assert_equal(bad.kind, READ_UNKNOWN)
    assert_equal(bad.status, 200)
    assert_equal(bad.detail, String("the index's file URL cannot be followed: data:x"))
    assert_equal(t.call_count(), 0, "neither is requested")
    # The file on the index host: the index credential goes with it.
    t.queue(_body(200, String("wheel")))
    var same = fetch_listed_file(
        t, _entry(String("f.whl")), String("idx.example.invalid"), String("Bearer idx-token")
    )
    assert_equal(same.kind, READ_PRESENT)
    assert_equal(String(unsafe_from_utf8=Span(same.bytes)), String("wheel"))
    assert_equal(t.call(0).path, String("/simple/p/f.whl"))
    assert_equal(t.call(0).header_value(String("Authorization")), String("Bearer idx-token"))
    # On another host: it does not.
    t.queue(_body(200, String("wheel")))
    _ = fetch_listed_file(
        t,
        _entry(String("https://files.example.invalid/f.whl")),
        String("idx.example.invalid"),
        String("Bearer idx-token"),
    )
    assert_equal(t.call(1).host, String("files.example.invalid"))
    assert_equal(t.call(1).header_value(String("Authorization")), String(""))
    # A transport fault, and a 429.
    t.queue_fault(String("connection reset"))
    var fault = fetch_listed_file(t, _entry(String("f.whl")), String(""), String(""))
    assert_equal(fault.kind, READ_UNKNOWN)
    assert_equal(fault.status, 0)
    assert_equal(
        fault.detail,
        String("transport fault on GET idx.example.invalid/simple/p/f.whl: connection reset"),
    )
    t.queue(_body(429, String("slow down")))
    var limited = fetch_listed_file(t, _entry(String("f.whl")), String(""), String(""))
    assert_equal(limited.kind, READ_RATE_LIMITED)
    assert_equal(limited.status, 429)
    assert_equal(read_kind_of_fetch_status(429), READ_RATE_LIMITED)
    assert_equal(t.unconsumed(), 0)
    print("  test_listed_file_fetches: PASS")


def _got(status: Int, content_type: String, body: String) -> GetResult:
    var r = _body(status, body)
    if content_type.byte_length() > 0:
        r.with_header(String("Content-Type"), content_type.copy())
    return GetResult(True, r^, String("idx.example.invalid"), String("/simple/p/"), String(""))


def test_a_pep691_read_checks_the_content_type() raises:
    var listing = String('{"files": [{"filename": "f.whl", "hashes": {"sha256": "ab"}, "url": "f.whl"}]}')
    var html = classify_index_answer(
        _got(200, String("text/html"), listing),
        String("f.whl"), String("files"), String("hashes"), String(PEP691_JSON), String(""),
    )
    assert_equal(html.kind, READ_UNKNOWN)
    assert_true(html.not_json)
    assert_equal(
        html.detail,
        String("the index answered 200 as 'text/html', not application/vnd.pypi.simple.v1+json"),
    )
    # Plain JSON is not the PEP 691 type asked for, and no Content-Type at all
    # is not it either.
    var plain = classify_index_answer(
        _got(200, String("application/json"), listing),
        String("f.whl"), String("files"), String("hashes"), String(PEP691_JSON), String(""),
    )
    assert_equal(plain.kind, READ_UNKNOWN)
    assert_true(plain.not_json)
    var untyped = classify_index_answer(
        _got(200, String(""), listing),
        String("f.whl"), String("files"), String("hashes"), String(PEP691_JSON), String(""),
    )
    assert_equal(untyped.kind, READ_UNKNOWN)
    assert_true(untyped.not_json)
    assert_equal(
        untyped.detail,
        String("the index answered 200 as '', not application/vnd.pypi.simple.v1+json"),
    )
    var json = classify_index_answer(
        _got(200, String(PEP691_JSON) + String("; charset=utf-8"), listing),
        String("f.whl"), String("files"), String("hashes"), String(PEP691_JSON), String(""),
    )
    assert_equal(json.kind, READ_PRESENT)
    assert_false(json.not_json)
    assert_equal(json.sha256_hex, String("ab"))
    var boolean = classify_index_answer(
        _got(200, String(""), String('{"urls": true}')),
        String("f.whl"), String("urls"), String("digests"), String(""), String(""),
    )
    assert_equal(boolean.kind, READ_UNKNOWN)
    assert_true(boolean.detail.find(String("'urls' is a boolean, not an array")) >= 0, boolean.detail)
    var number = classify_index_answer(
        _got(200, String(""), String('{"urls": 3}')),
        String("f.whl"), String("urls"), String("digests"), String(""), String(""),
    )
    assert_true(number.detail.find(String("'urls' is a number, not an array")) >= 0, number.detail)
    assert_equal(_json_kind_word(JSON_ARRAY), String("an array"))
    assert_equal(_json_kind_word(9), String("JSON kind 9"))
    print("  test_a_pep691_read_checks_the_content_type: PASS")


def _conda(file_name: String, repo: String = String("prefix.dev/example-channel")) -> PackageCoordinate:
    return PackageCoordinate(
        SUBSTRATE_PREFIX_DEV_CONDA,
        repo.copy(),
        String("komira-probe"),
        String("1.2.3"),
        String("linux-64"),
        file_name.copy(),
    )


def test_prefix_dev_local_edges() raises:
    with assert_raises(contains="holds a query, a fragment or a percent sign"):
        _ = prefix_dev_channel(String("prefix.dev/a?b"))
    with assert_raises(contains="holds a query, a fragment or a percent sign"):
        _ = prefix_dev_channel(String("prefix.dev/a#b"))
    with assert_raises(contains="holds a query, a fragment or a percent sign"):
        _ = prefix_dev_channel(String("prefix.dev/a%2Fb"))
    refuse_name_not_the_files(_conda(String("komira-probe-1.2.3-h0123abc_0.tar.bz2")))
    with assert_raises(contains="does not name the file"):
        refuse_name_not_the_files(_conda(String("komira-probe-1.2.4-h0123abc_0.tar.bz2")))
    # The extension is stripped whole: an EMPTY build is not `.tar.bz2`.
    with assert_raises(contains="'komira-probe-1.2.3-.tar.bz2' is not <name>-<version>-<build>.conda"):
        refuse_name_not_the_files(_conda(String("komira-probe-1.2.3-.tar.bz2")))
    with assert_raises(contains="'nodashes.whl' is not <name>-<version>-<build>.conda"):
        refuse_name_not_the_files(_conda(String("nodashes.whl")))
    var names = List[String]()
    names.append(String('komira-probe-1.2.3-h"0.conda'))
    names.append(String("komira-probe-1.2.3-h\n0.conda"))
    names.append(String("komira-probe-1.2.3-h\r0.conda"))
    for i in range(len(names)):
        var f = PackageFile(_conda(names[i]), bytes_of(String("x")), String(""))
        with assert_raises(contains="cannot be carried in a quoted filename parameter"):
            _ = encode_prefix_dev_form(f, String("b0b0"))
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection reset"))
    var cred = ScriptedCredential()
    cred.serve(SURFACE_PREFIX_DEV, String("Bearer pfx-token"))
    var rs = RegistrySet[ScriptedPkgTransport, ScriptedCredential](t^, cred^)
    var got = rs.fetch(_conda(String("komira-probe-1.2.3-h0123abc_0.conda")))
    assert_equal(got.kind, READ_UNKNOWN)
    assert_equal(got.status, 0)
    assert_equal(
        got.detail,
        String(
            "transport fault on GET prefix.dev/example-channel/linux-64/"
            "komira-probe-1.2.3-h0123abc_0.conda: connection reset"
        ),
    )
    print("  test_prefix_dev_local_edges: PASS")


def _repodata(body: String) -> GetResult:
    return GetResult(
        True, _body(200, body), String("prefix.dev"), String("/c/linux-64/repodata.json"), String("")
    )


def test_tar_bz2_repodata_keys() raises:
    var f = String("komira-probe-1.2.3-h0_0.tar.bz2")
    var only_conda = classify_repodata_answer(
        _repodata(String('{"packages.conda": {"x-1-0.conda": {}}}')), f, String("")
    )
    assert_equal(only_conda.kind, READ_ABSENT)
    assert_equal(
        only_conda.detail,
        String("the repodata has no 'packages' listing, so it lists no file named ") + f,
    )
    var neither = classify_repodata_answer(_repodata(String('{"info": {}}')), f, String(""))
    assert_equal(neither.kind, READ_UNKNOWN)
    assert_equal(
        neither.detail,
        String(
            "the repodata has neither a 'packages' nor a 'packages.conda'"
            " listing: it cannot be read, so it is not ABSENT"
        ),
    )
    print("  test_tar_bz2_repodata_keys: PASS")


def main() raises:
    test_the_hop_budget()
    test_each_refused_redirect_is_named()
    test_index_hrefs_resolve_against_the_page()
    test_listed_file_fetches()
    test_a_pep691_read_checks_the_content_type()
    test_prefix_dev_local_edges()
    test_tar_bz2_repodata_keys()
    print("test_pkg_upload_read_edges: ALL PASS")
