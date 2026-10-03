# =============================================================================
# test_oci_push_layout_refusals.mojo — what `OciLayoutPusher` refuses, and how
#   far it got before refusing (hermetic; NO network).
# =============================================================================
#
#   (1) test_layout_file_not_matching_its_name_is_refused_offline — a layer
#       file in a layout DIRECTORY rewritten after the build: refused, naming
#       it, with ZERO registry calls.
#   (2) test_descriptor_size_mismatch_is_refused_offline — right bytes, wrong
#       `size` in the manifest: refused with zero registry calls.
#   (3) test_registry_digest_header_mismatch_is_refused — the registry answers
#       the manifest PUT with a `Docker-Content-Digest` naming other content:
#       refused, and the TAG is never moved.
#   (4) test_auth_failure_stops_at_the_first_call — a 401 on the first HEAD:
#       refused as a credential problem carrying the challenge; nothing else
#       is sent.
#   (5) test_pinned_destination_digest_must_be_the_layout_root — a
#       `@sha256:` destination naming another image: refused before any call.
#   (6) test_directory_without_oci_layout_marker_is_refused — a directory
#       that is not an OCI layout is refused when opened.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from komira_http_core.codec.types import HTTP_METHOD_PUT

from komira_oci.oci_layout_source import (
    DirOciLayout,
    MemOciLayout,
    OciLayoutSource,
)
from komira_oci.oci_push import OciLayoutPusher
from komira_oci.oci_ref import MEDIA_TYPE_OCI_INDEX, MEDIA_TYPE_OCI_MANIFEST
from komira_oci.oci_transport import OciResponse, ScriptedOciTransport


comptime _HOST: String = "europe-docker.pkg.dev"
comptime _REPO: String = "example-release/images/app"
comptime _TOKEN: String = "push-tok"
comptime _CONFIG_TYPE: String = "application/vnd.oci.image.config.v1+json"
comptime _LAYER_TYPE: String = "application/vnd.oci.image.layer.v1.tar+gzip"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _desc(media: String, digest: String, size: Int) -> String:
    return (
        String('{"mediaType":"') + media + String('","digest":"') + digest
        + String('","size":') + String(size) + String("}")
    )


def _layout_index(digest: String, size: Int) -> String:
    return (
        String('{"schemaVersion":2,"mediaType":"') + MEDIA_TYPE_OCI_INDEX
        + String('","manifests":[') + _desc(MEDIA_TYPE_OCI_MANIFEST, digest, size)
        + String("]}")
    )


def _image(mut layout: MemOciLayout, layer_size_delta: Int) -> List[String]:
    """A one-layer image; returns [layer, config, manifest]. The manifest
    states the layer's size plus `layer_size_delta`."""
    var lb = _bytes(String("the only layer"))
    var cb = _bytes(String('{"architecture":"amd64","os":"linux"}'))
    var sl = len(lb) + layer_size_delta
    var sc = len(cb)
    var l = layout.add_blob(lb^)
    var c = layout.add_blob(cb^)
    var mb = _bytes(
        String('{"schemaVersion":2,"mediaType":"') + MEDIA_TYPE_OCI_MANIFEST
        + String('","config":') + _desc(_CONFIG_TYPE, c, sc)
        + String(',"layers":[') + _desc(_LAYER_TYPE, l, sl) + String("]}")
    )
    var sm = len(mb)
    var m = layout.add_blob(mb^)
    layout.set_index_json(_bytes(_layout_index(m, sm)))
    var out = List[String]()
    out.append(l^)
    out.append(c^)
    out.append(m^)
    return out^


def _tag_ref() -> String:
    return _HOST + String("/") + _REPO + String(":0.1.0")


def _push_error[L: OciLayoutSource](
    mut pusher: OciLayoutPusher[ScriptedOciTransport], mut layout: L, ref_: String
) -> String:
    """The push's error message, or EMPTY when it did not raise."""
    try:
        _ = pusher.push(layout, ref_)
    except e:
        return String(e)
    return String("")


def _tmp_root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = (
        base + String("/oci_push_") + tag + String("_")
        + String(Int(external_call["getpid", Int32]()))
    )
    makedirs(d + String("/blobs/sha256"), exist_ok=True)
    return d^


def _write(path: String, data: List[UInt8]) raises:
    var f = open(path, "w")
    f.write_bytes(Span(data))
    f.close()


def _hex(digest: String) -> String:
    return String(digest[byte=7 : digest.byte_length()])


def test_layout_file_not_matching_its_name_is_refused_offline() raises:
    var mem = MemOciLayout()
    var d = _image(mem, 0)
    var dir = _tmp_root(String("tamper"))
    _write(dir + String("/oci-layout"), _bytes(String('{"imageLayoutVersion":"1.0.0"}')))
    _write(dir + String("/index.json"), mem.index_json())
    for i in range(len(d)):
        _write(dir + String("/blobs/sha256/") + _hex(d[i]), mem.read_blob(d[i]))
    # Rewrite the layer AFTER the build: same name, other bytes, same length.
    _write(dir + String("/blobs/sha256/") + _hex(d[0]), _bytes(String("THE ONLY LAYER")))

    var layout = DirOciLayout(dir.copy())
    var pusher = OciLayoutPusher[ScriptedOciTransport](ScriptedOciTransport(), String(_TOKEN))
    var msg = _push_error(pusher, layout, _tag_ref())
    assert_true(msg.find(String("DOES NOT HASH TO ITS NAME")) >= 0, "refused as a content mismatch: " + msg)
    assert_true(msg.find(d[0]) >= 0, "the refusal names the file: " + msg)
    assert_equal(pusher.transport().call_count(), 0, "refused before ANY registry call")


def test_descriptor_size_mismatch_is_refused_offline() raises:
    var layout = MemOciLayout()
    var d = _image(layout, 1)
    var pusher = OciLayoutPusher[ScriptedOciTransport](ScriptedOciTransport(), String(_TOKEN))
    var msg = _push_error(pusher, layout, _tag_ref())
    assert_true(msg.find(String("descriptor states size")) >= 0, "refused on size: " + msg)
    assert_true(msg.find(d[0]) >= 0, "the refusal names the layer: " + msg)
    assert_equal(pusher.transport().call_count(), 0, "refused before ANY registry call")


def test_registry_digest_header_mismatch_is_refused() raises:
    var layout = MemOciLayout()
    _ = _image(layout, 0)
    var t = ScriptedOciTransport()
    t.queue(OciResponse(200))
    t.queue(OciResponse(200))
    var lying = OciResponse(201)
    lying.with_header(String("Docker-Content-Digest"), String("sha256:") + "ee" * 32)
    t.queue(lying^)
    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var msg = _push_error(pusher, layout, _tag_ref())
    assert_true(msg.find(String("DIFFERENT digest")) >= 0, "refused on the header: " + msg)
    ref log = pusher.transport()
    assert_equal(log.call_count(), 3, "2 HEADs + the manifest PUT; the TAG is never moved")
    assert_equal(log.call_method(2), HTTP_METHOD_PUT, "the refused call is the manifest PUT")


def test_auth_failure_stops_at_the_first_call() raises:
    var layout = MemOciLayout()
    _ = _image(layout, 0)
    var t = ScriptedOciTransport()
    var denied = OciResponse(401)
    denied.with_header(
        String("www-authenticate"),
        String('Bearer realm="https://europe-docker.pkg.dev/v2/token",scope="repository:x:push"'),
    )
    t.queue(denied^)
    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var msg = _push_error(pusher, layout, _tag_ref())
    assert_true(msg.find(String("refused the credential (HTTP 401)")) >= 0, "named as auth: " + msg)
    assert_true(msg.find(String("realm=")) >= 0, "the challenge is carried: " + msg)
    assert_equal(pusher.transport().call_count(), 1, "nothing is sent after the refusal")


def test_pinned_destination_digest_must_be_the_layout_root() raises:
    var layout = MemOciLayout()
    _ = _image(layout, 0)
    var pusher = OciLayoutPusher[ScriptedOciTransport](ScriptedOciTransport(), String(_TOKEN))
    var other = _HOST + String("/") + _REPO + String("@sha256:") + "ab" * 32
    var msg = _push_error(pusher, layout, other)
    assert_true(msg.find(String("pins digest")) >= 0, "refused on the pin: " + msg)
    assert_equal(pusher.transport().call_count(), 0, "refused before ANY registry call")


def test_directory_without_oci_layout_marker_is_refused() raises:
    var dir = _tmp_root(String("nomarker"))
    var msg = String("")
    try:
        _ = DirOciLayout(dir.copy())
    except e:
        msg = String(e)
    assert_true(msg.find(String("no 'oci-layout' file")) >= 0, "refused when opened: " + msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
