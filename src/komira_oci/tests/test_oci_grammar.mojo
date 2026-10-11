# =============================================================================
# test_oci_grammar.mojo — the small refusals: digest shape, image refs, the
#   layout index, the upload Location, the scripted transport, and the push
#   inputs.
# =============================================================================
#
#   (1) a digest must be `sha256:` + exactly 64 LOWERCASE hex characters: 63
#       and 65 are refused, and so is a non-hex or uppercase character at the
#       first, a middle and the LAST position (each byte is checked);
#   (2) an image ref with no host (no `/`, or a `/` first) and one with an
#       empty repository before `@` are refused;
#   (3) `layout_image_digest` refuses a document with no `manifests`, with
#       zero, and with an entry that has no `digest`;
#   (4) an upload Location with an EMPTY host is refused in its own words;
#   (5) the scripted transport raises, naming the call, when it runs out of
#       answers; a response header lookup ignores case but not a different
#       name of the same length;
#   (6) `push_outcome_name` of an unknown code is UNKNOWN;
#   (7) a push to a malformed repository or registry is REFUSED, naming the
#       rule, before any request is made.
# =============================================================================

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_digest import validate_digest_format
from komira_oci.oci_fake_registry import FakeOciRegistry
from komira_oci.oci_layout import layout_image_digest
from komira_oci.oci_layout_fixture import write_test_layout
from komira_oci.oci_layout_reader import OciLayout, read_oci_layout
from komira_oci.oci_location import resolve_upload_location
from komira_oci.oci_push import (
    LayoutPusher,
    PUSH_REFUSED,
    push_outcome_name,
)
from komira_oci.oci_ref import parse_oci_ref
from komira_oci.oci_transport import OciRequest, OciResponse, ScriptedOciTransport
from komira_http_core.codec.types import HTTP_METHOD_HEAD

comptime _HOST: String = "us-central1-docker.pkg.dev"
comptime _HEX: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _raises_with(needle: String, why: String, msg: String, raised: Bool) raises:
    assert_true(raised, why + String(": must raise"))
    assert_true(
        msg.find(needle) >= 0,
        why + String(": expected '") + needle + String("' in: ") + msg,
    )


def _digest_refused(digest: String, needle: String, why: String) raises:
    var raised = False
    var msg = String("")
    try:
        validate_digest_format(digest, String("the test digest"))
    except e:
        raised = True
        msg = String(e)
    _raises_with(needle, why, msg, raised)
    assert_true(msg.find(String("the test digest")) >= 0, "names its context: " + msg)


def _with_byte(at: Int, c: String) -> String:
    return (
        String("sha256:")
        + String(_HEX[byte=0:at])
        + c
        + String(_HEX[byte = at + 1 : 64])
    )


def test_digest_length_and_case_are_checked() raises:
    validate_digest_format(String("sha256:") + _HEX, String("ok"))
    _digest_refused(
        String("sha256:") + String(_HEX[byte=0:63]),
        String("must be 64 hex chars, got 63"),
        String("63 hex chars"),
    )
    _digest_refused(
        String("sha256:") + _HEX + String("0"),
        String("must be 64 hex chars, got 65"),
        String("65 hex chars"),
    )
    # Every byte position is checked: first, middle, last.
    var positions = List[Int]()
    positions.append(0)
    positions.append(31)
    positions.append(63)
    var bad = List[String]()
    bad.append(String("A"))  # uppercase hex
    bad.append(String("F"))
    bad.append(String("g"))  # one past 'f'
    bad.append(String("`"))  # one before 'a'
    bad.append(String("/"))  # one before '0'
    bad.append(String(":"))  # one past '9'
    for p in range(len(positions)):
        for b in range(len(bad)):
            _digest_refused(
                _with_byte(positions[p], bad[b]),
                String("must be LOWERCASE hex"),
                String("byte '") + bad[b] + String("' at ") + String(positions[p]),
            )
    print("  test_digest_length_and_case_are_checked: PASS")


def _ref_refused(ref_text: String, needle: String, why: String) raises:
    var raised = False
    var msg = String("")
    try:
        _ = parse_oci_ref(ref_text)
    except e:
        raised = True
        msg = String(e)
    _raises_with(needle, why, msg, raised)


def test_ref_without_host_or_repository_is_refused() raises:
    var d = String("sha256:") + _HEX
    _ref_refused(
        String("worker@") + d,
        String("no registry host found"),
        String("a ref with no '/'"),
    )
    _ref_refused(
        String("/worker@") + d,
        String("no registry host found"),
        String("a ref whose '/' is its first byte"),
    )
    _ref_refused(
        _HOST + String("/@") + d,
        String("empty repository before '@'"),
        String("an empty repository"),
    )
    var ok = parse_oci_ref(String("h/r@") + d)
    assert_equal(ok.registry, String("h"), "a one-byte host is a host")
    assert_equal(ok.repository, String("r"), "a one-byte repository is a repository")
    print("  test_ref_without_host_or_repository_is_refused: PASS")


def _index_refused(doc: String, needle: String, why: String) raises:
    var raised = False
    var msg = String("")
    try:
        _ = layout_image_digest(doc)
    except e:
        raised = True
        msg = String(e)
    _raises_with(needle, why, msg, raised)


def test_layout_index_without_one_digested_image_is_refused() raises:
    _index_refused(
        String('{"schemaVersion":2}'),
        String("has no 'manifests' array"),
        String("no manifests key"),
    )
    _index_refused(
        String('{"schemaVersion":2,"manifests":[]}'),
        String("describes ZERO images"),
        String("an empty manifests array"),
    )
    _index_refused(
        String('{"manifests":[{"size":3}]}'),
        String("manifest descriptor has no 'digest' field"),
        String("an entry with no digest"),
    )
    assert_equal(
        layout_image_digest(
            String('{"manifests":[{"digest":"sha256:') + _HEX + String('"}]}')
        ),
        String("sha256:") + _HEX,
    )
    print("  test_layout_index_without_one_digested_image_is_refused: PASS")


def test_upload_location_with_empty_host_is_refused() raises:
    var raised = False
    var msg = String("")
    try:
        _ = resolve_upload_location(_HOST, String("https:///v2/r/blobs/uploads/1"))
    except e:
        raised = True
        msg = String(e)
    _raises_with(
        String("the upload Location 'https:///v2/r/blobs/uploads/1' has an EMPTY host"),
        String("an empty host"),
        msg,
        raised,
    )
    print("  test_upload_location_with_empty_host_is_refused: PASS")


def test_scripted_transport_runs_out_and_header_lookup() raises:
    var t = ScriptedOciTransport()
    t.queue(OciResponse(200))
    _ = t.send(OciRequest(HTTP_METHOD_HEAD, _HOST, String("/v2/a")))
    var raised = False
    var msg = String("")
    try:
        _ = t.send(OciRequest(HTTP_METHOD_HEAD, _HOST, String("/v2/b")))
    except e:
        raised = True
        msg = String(e)
    _raises_with(
        String("no scripted response for call #1 (") + _HOST + String("/v2/b)"),
        String("an exhausted script"),
        msg,
        raised,
    )
    assert_equal(t.call_count(), 2, "the unanswered call is still recorded")

    var r = OciResponse(200)
    r.with_header(String("X-Abc"), String("one"))
    assert_equal(r.header(String("x-aBC")), String("one"), "case is ignored")
    assert_equal(r.header(String("x-abd")), String(""), "same length, other last byte")
    assert_equal(r.header(String("y-abc")), String(""), "same length, other first byte")
    assert_equal(r.header(String("x-ab")), String(""), "a prefix is another name")
    print("  test_scripted_transport_runs_out_and_header_lookup: PASS")


def test_unknown_outcome_name() raises:
    assert_equal(push_outcome_name(7), String("UNKNOWN"))
    assert_equal(push_outcome_name(-1), String("UNKNOWN"))
    print("  test_unknown_outcome_name: PASS")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _layout() raises -> OciLayout:
    var dir = getenv("TEST_TMPDIR", "/tmp") + String("/komira_oci_grammar_layout")
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("grammar-layer-bytes")))
    _ = write_test_layout(dir, layers)
    return read_oci_layout(dir)


def _push_refused(
    layout: OciLayout, registry: String, repository: String, needle: String
) raises:
    var pusher = LayoutPusher[FakeOciRegistry](
        FakeOciRegistry(_HOST), OciAuth.bearer(String("tok")), False, 0
    )
    var r = pusher.push(layout, registry, repository, String("v1"))
    assert_true(
        r.outcome == PUSH_REFUSED,
        repository + String(" @ ") + registry + String(": expected REFUSED, got ")
        + push_outcome_name(r.outcome) + String(": ") + r.detail,
    )
    assert_true(
        r.detail.find(needle) >= 0,
        String("expected '") + needle + String("' in: ") + r.detail,
    )
    assert_equal(pusher.transport().call_count(), 0, "refused before any request")


def test_push_refuses_malformed_repository_and_registry() raises:
    var layout = _layout()
    _push_refused(layout, _HOST, String(""), String("the repository is empty"))
    _push_refused(layout, _HOST, String("/a/b"), String("has a leading or trailing '/'"))
    _push_refused(layout, _HOST, String("a/b/"), String("has a leading or trailing '/'"))
    _push_refused(layout, _HOST, String("a//b"), String("has an empty or '..' segment"))
    _push_refused(layout, _HOST, String("a/../b"), String("has an empty or '..' segment"))
    var bad = List[String]()
    bad.append(String("Acme/b"))  # uppercase
    bad.append(String("a/b@c"))
    bad.append(String("a/b{c"))  # one past 'z'
    bad.append(String("a/b`c"))  # one before 'a'
    bad.append(String("a/b:c"))  # one past '9'
    bad.append(String("a/b,c"))  # one before '-'
    bad.append(String("a/bZ"))  # the last byte
    for i in range(len(bad)):
        _push_refused(
            layout, _HOST, bad[i], String("must be lowercase [a-z0-9._-] segments")
        )
    _push_refused(layout, String(""), String("a/b"), String("the registry host is empty"))
    _push_refused(
        layout, String("h.example:5000"), String("a/b"), String("must be a bare host name")
    )
    _push_refused(
        layout, String("https://h.example"), String("a/b"), String("must be a bare host name")
    )
    _push_refused(
        layout, String("h.example/x"), String("a/b"), String("must be a bare host name")
    )
    print("  test_push_refuses_malformed_repository_and_registry: PASS")


def main() raises:
    test_digest_length_and_case_are_checked()
    test_ref_without_host_or_repository_is_refused()
    test_layout_index_without_one_digested_image_is_refused()
    test_upload_location_with_empty_host_is_refused()
    test_scripted_transport_runs_out_and_header_lookup()
    test_unknown_outcome_name()
    test_push_refuses_malformed_repository_and_registry()
    print("test_oci_grammar: ALL PASS")
