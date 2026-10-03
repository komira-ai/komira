# =============================================================================
# test_oci_push_layout_order.mojo — `OciLayoutPusher` uploads a local OCI
#   layout LEAVES FIRST and only what is missing (hermetic; NO network).
# =============================================================================
#
#   (1) test_fresh_push_blobs_before_manifest_then_tag — into an empty
#       repository: every layer, then the config, each HEAD -> POST -> PUT;
#       then the manifest by DIGEST; then the tag. No manifest PUT precedes
#       the last blob PUT, and the bytes sent hash to their digests.
#   (2) test_present_blobs_are_skipped — a HEAD 200 moves no bytes; only the
#       missing layer opens an upload session.
#   (3) test_rerun_is_idempotent — the same push twice: the second run is
#       HEADs and the two manifest PUTs, sends the SAME manifest bytes, and
#       returns the SAME digest.
#   (4) test_index_children_before_index — a multi-platform layout: each
#       platform's blobs, then that platform's manifest, then the index, then
#       the tag; a layer the two platforms share is HEADed once.
#   (5) test_directory_layout_of_komira_pack_shape — the same push read from a
#       DIRECTORY laid out as `komira_pack oci` writes it (oci-layout,
#       index.json with platform + annotations, blobs/sha256/<hex>).
#
# Every digest is computed from bytes with the package's own function, so the
# pusher's content checks run rather than being bypassed.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from komira_http_core.codec.types import (
    HTTP_METHOD_HEAD,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_layout_source import DirOciLayout, MemOciLayout
from komira_oci.oci_push import OciLayoutPusher
from komira_oci.oci_ref import MEDIA_TYPE_OCI_INDEX, MEDIA_TYPE_OCI_MANIFEST
from komira_oci.oci_transport import OciResponse, ScriptedOciTransport


comptime _HOST: String = "europe-docker.pkg.dev"
comptime _REPO: String = "example-release/images/app"
comptime _TAG: String = "0.1.0"
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


def _manifest(cfg: String, cfg_size: Int, l1: String, s1: Int, l2: String, s2: Int) -> String:
    return (
        String('{"schemaVersion":2,"mediaType":"') + MEDIA_TYPE_OCI_MANIFEST
        + String('","config":') + _desc(_CONFIG_TYPE, cfg, cfg_size)
        + String(',"layers":[') + _desc(_LAYER_TYPE, l1, s1) + String(",")
        + _desc(_LAYER_TYPE, l2, s2) + String("]}")
    )


def _layout_index(media: String, digest: String, size: Int) -> String:
    """index.json as komira_pack writes it: one descriptor, with a platform
    and the two name annotations."""
    return (
        String('{"manifests":[{"annotations":{"io.containerd.image.name":"docker.io/example/app:0.1.0",'
        '"org.opencontainers.image.ref.name":"0.1.0"},"digest":"') + digest
        + String('","mediaType":"') + media
        + String('","platform":{"architecture":"amd64","os":"linux"},"size":') + String(size)
        + String('}],"mediaType":"') + MEDIA_TYPE_OCI_INDEX + String('","schemaVersion":2}')
    )


struct _Image(Copyable, Movable, Deinitable):
    """The digests of one single-image layout, and the manifest bytes."""

    var layer1: String
    var layer2: String
    var config: String
    var manifest: String
    var manifest_bytes: List[UInt8]

    def __init__(
        out self, var layer1: String, var layer2: String, var config: String,
        var manifest: String, var manifest_bytes: List[UInt8],
    ):
        self.layer1 = layer1^
        self.layer2 = layer2^
        self.config = config^
        self.manifest = manifest^
        self.manifest_bytes = manifest_bytes^

    def __init__(out self, *, copy: Self):
        self.layer1 = copy.layer1.copy()
        self.layer2 = copy.layer2.copy()
        self.config = copy.config.copy()
        self.manifest = copy.manifest.copy()
        self.manifest_bytes = copy.manifest_bytes.copy()


def _single_image(mut layout: MemOciLayout, salt: String) -> _Image:
    var l1b = _bytes(String("layer one ") + salt)
    var l2b = _bytes(String("layer two, longer ") + salt)
    var cb = _bytes(String('{"architecture":"amd64","os":"linux","salt":"') + salt + String('"}'))
    var s1 = len(l1b)
    var s2 = len(l2b)
    var sc = len(cb)
    var l1 = layout.add_blob(l1b^)
    var l2 = layout.add_blob(l2b^)
    var c = layout.add_blob(cb^)
    var mb = _bytes(_manifest(c, sc, l1, s1, l2, s2))
    var msize = len(mb)
    var m = layout.add_blob(mb.copy())
    layout.set_index_json(_bytes(_layout_index(MEDIA_TYPE_OCI_MANIFEST, m, msize)))
    return _Image(l1^, l2^, c^, m^, mb^)


def _status(code: Int) -> OciResponse:
    return OciResponse(code)


def _session(var location: String) -> OciResponse:
    var r = OciResponse(202)
    r.with_header(String("location"), location^)
    return r^


def _created(var digest: String) -> OciResponse:
    var r = OciResponse(201)
    r.with_header(String("docker-content-digest"), digest^)
    return r^


def _body_digest(log: ScriptedOciTransport, i: Int) -> String:
    var body = log.call_body(i)
    return digest_of_bytes(Span(body))


def _blob_path(digest: String) -> String:
    return String("/v2/") + _REPO + String("/blobs/") + digest


def _manifest_path(reference: String) -> String:
    return String("/v2/") + _REPO + String("/manifests/") + reference


def _upload_path(n: Int) -> String:
    return String("/v2/") + _REPO + String("/blobs/uploads/u") + String(n) + String("?_state=s")


def _queue_upload(mut t: ScriptedOciTransport, n: Int, digest: String):
    t.queue(_status(404))
    t.queue(_session(_upload_path(n)))
    t.queue(_created(digest.copy()))


def _tag_ref() -> String:
    return _HOST + String("/") + _REPO + String(":") + _TAG


def test_fresh_push_blobs_before_manifest_then_tag() raises:
    var layout = MemOciLayout()
    var img = _single_image(layout, String("fresh"))

    var t = ScriptedOciTransport()
    _queue_upload(t, 1, img.layer1)
    _queue_upload(t, 2, img.layer2)
    _queue_upload(t, 3, img.config)
    t.queue(_created(img.manifest.copy()))
    t.queue(_created(img.manifest.copy()))

    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var got = pusher.push(layout, _tag_ref())
    assert_equal(got, img.manifest, "push returns the digest the build computed")

    ref log = pusher.transport()
    assert_equal(log.call_count(), 11, "3 x (HEAD, POST, PUT) + manifest + tag")
    var blobs = List[String]()
    blobs.append(img.layer1.copy())
    blobs.append(img.layer2.copy())
    blobs.append(img.config.copy())
    for k in range(3):
        var base = 3 * k
        assert_equal(log.call_method(base), HTTP_METHOD_HEAD, "HEAD first")
        assert_equal(log.call_path(base), _blob_path(blobs[k]), "layers in order, then the config")
        assert_equal(log.call_method(base + 1), HTTP_METHOD_POST, "then an upload session")
        assert_equal(log.call_method(base + 2), HTTP_METHOD_PUT, "then the bytes")
        assert_equal(
            log.call_path(base + 2),
            _upload_path(k + 1) + String("&digest=") + blobs[k],
            "the PUT goes to the server-chosen session with digest= appended",
        )
        assert_equal(
            _body_digest(log, base + 2), blobs[k],
            "the bytes sent hash to the digest named",
        )
    for i in range(9):
        assert_true(
            log.call_path(i).find(String("/manifests/")) < 0,
            "no manifest is written before every blob is in place",
        )
    assert_equal(log.call_path(9), _manifest_path(img.manifest), "manifest by DIGEST")
    assert_equal(
        _body_digest(log, 9), img.manifest,
        "the manifest bytes are sent verbatim",
    )
    assert_equal(log.call_path(10), _manifest_path(String(_TAG)), "the tag moves LAST")
    for i in range(log.call_count()):
        assert_equal(log.call_registry(i), String(_HOST), "every call goes to the destination")
        assert_equal(log.call_auth(i), String("Bearer ") + _TOKEN, "every call carries the bearer")


def test_present_blobs_are_skipped() raises:
    var layout = MemOciLayout()
    var img = _single_image(layout, String("skip"))

    var t = ScriptedOciTransport()
    t.queue(_status(200))  # layer1 present
    _queue_upload(t, 1, img.layer2)  # layer2 missing
    t.queue(_status(200))  # config present
    t.queue(_created(img.manifest.copy()))
    t.queue(_created(img.manifest.copy()))

    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    _ = pusher.push(layout, _tag_ref())

    ref log = pusher.transport()
    assert_equal(log.call_count(), 7, "HEAD, HEAD+POST+PUT, HEAD, manifest, tag")
    var posts = 0
    for i in range(log.call_count()):
        if log.call_method(i) == HTTP_METHOD_POST:
            posts += 1
    assert_equal(posts, 1, "only the missing layer opens an upload session")
    assert_equal(
        log.call_path(3), _upload_path(1) + String("&digest=") + img.layer2,
        "the one upload is the missing layer",
    )
    assert_equal(log.call_method(4), HTTP_METHOD_HEAD, "the present config is only HEADed")


def test_rerun_is_idempotent() raises:
    var layout = MemOciLayout()
    var img = _single_image(layout, String("rerun"))

    var t = ScriptedOciTransport()
    # run 1: an empty repository
    _queue_upload(t, 1, img.layer1)
    _queue_upload(t, 2, img.layer2)
    _queue_upload(t, 3, img.config)
    t.queue(_created(img.manifest.copy()))
    t.queue(_created(img.manifest.copy()))
    # run 2: everything is already there
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_status(200))
    t.queue(_created(img.manifest.copy()))
    t.queue(_created(img.manifest.copy()))

    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var first = pusher.push(layout, _tag_ref())
    var second = pusher.push(layout, _tag_ref())
    assert_equal(first, second, "a re-run returns the same digest")

    ref log = pusher.transport()
    assert_equal(log.call_count(), 16, "11 calls, then 3 HEADs + manifest + tag")
    for i in range(11, 14):
        assert_equal(log.call_method(i), HTTP_METHOD_HEAD, "the re-run only HEADs the blobs")
    for i in range(11, 16):
        assert_true(log.call_method(i) != HTTP_METHOD_POST, "the re-run opens no upload session")
    assert_equal(log.call_path(14), _manifest_path(img.manifest), "the manifest again, by digest")
    assert_equal(
        _body_digest(log, 14),
        _body_digest(log, 9),
        "the same manifest bytes both times",
    )
    assert_equal(log.call_path(15), _manifest_path(String(_TAG)), "and the tag again")


def test_index_children_before_index() raises:
    var layout = MemOciLayout()
    var shared_b = _bytes(String("the base layer both platforms share"))
    var ss = len(shared_b)
    var shared = layout.add_blob(shared_b^)

    var la_b = _bytes(String("amd64 app layer"))
    var lb_b = _bytes(String("arm64 app layer!"))
    var ca_b = _bytes(String('{"architecture":"amd64","os":"linux"}'))
    var cb_b = _bytes(String('{"architecture":"arm64","os":"linux"}'))
    var sa = len(la_b)
    var sb = len(lb_b)
    var sca = len(ca_b)
    var scb = len(cb_b)
    var la = layout.add_blob(la_b^)
    var lb = layout.add_blob(lb_b^)
    var ca = layout.add_blob(ca_b^)
    var cb = layout.add_blob(cb_b^)

    var ma_b = _bytes(_manifest(ca, sca, shared, ss, la, sa))
    var mb_b = _bytes(_manifest(cb, scb, shared, ss, lb, sb))
    var sma = len(ma_b)
    var smb = len(mb_b)
    var ma = layout.add_blob(ma_b^)
    var mb = layout.add_blob(mb_b^)
    var idx_b = _bytes(
        String('{"schemaVersion":2,"mediaType":"') + MEDIA_TYPE_OCI_INDEX
        + String('","manifests":[') + _desc(MEDIA_TYPE_OCI_MANIFEST, ma, sma)
        + String(",") + _desc(MEDIA_TYPE_OCI_MANIFEST, mb, smb) + String("]}")
    )
    var sidx = len(idx_b)
    var idx = layout.add_blob(idx_b^)
    layout.set_index_json(_bytes(_layout_index(MEDIA_TYPE_OCI_INDEX, idx, sidx)))

    var t = ScriptedOciTransport()
    for _ in range(3):  # shared, la, ca
        t.queue(_status(200))
    t.queue(_created(ma.copy()))
    for _ in range(2):  # lb, cb (shared is not asked again)
        t.queue(_status(200))
    t.queue(_created(mb.copy()))
    t.queue(_created(idx.copy()))
    t.queue(_created(idx.copy()))

    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var got = pusher.push(layout, _tag_ref())
    assert_equal(got, idx, "a multi-platform push returns the INDEX digest")

    ref log = pusher.transport()
    assert_equal(log.call_count(), 9, "5 HEADs + 2 platform manifests + index + tag")
    assert_equal(log.call_path(0), _blob_path(shared), "amd64: the shared layer")
    assert_equal(log.call_path(1), _blob_path(la), "amd64: its own layer")
    assert_equal(log.call_path(2), _blob_path(ca), "amd64: its config")
    assert_equal(log.call_path(3), _manifest_path(ma), "then the amd64 manifest")
    assert_equal(log.call_path(4), _blob_path(lb), "arm64: the shared layer is NOT asked again")
    assert_equal(log.call_path(5), _blob_path(cb), "arm64: its config")
    assert_equal(log.call_path(6), _manifest_path(mb), "then the arm64 manifest")
    assert_equal(log.call_path(7), _manifest_path(idx), "the index only after both children")
    assert_equal(log.call_path(8), _manifest_path(String(_TAG)), "and the tag last")
    for i in range(3, 9):
        if i == 4 or i == 5:
            continue
        assert_equal(log.call_method(i), HTTP_METHOD_PUT, "manifest writes are PUTs")
    var shared_heads = 0
    for i in range(log.call_count()):
        if log.call_path(i) == _blob_path(shared):
            shared_heads += 1
    assert_equal(shared_heads, 1, "a blob two platforms share is handled once")


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


def _write_dir_layout(mut mem: MemOciLayout, dir: String, img: _Image) raises:
    _write(dir + String("/oci-layout"), _bytes(String('{"imageLayoutVersion":"1.0.0"}')))
    _write(dir + String("/index.json"), mem.index_json())
    var names = List[String]()
    names.append(img.layer1.copy())
    names.append(img.layer2.copy())
    names.append(img.config.copy())
    names.append(img.manifest.copy())
    for i in range(len(names)):
        var hex = String(names[i][byte=7 : names[i].byte_length()])
        _write(dir + String("/blobs/sha256/") + hex, mem.read_blob(names[i]))


def test_directory_layout_of_komira_pack_shape() raises:
    var mem = MemOciLayout()
    var img = _single_image(mem, String("dir"))
    var dir = _tmp_root(String("order"))
    _write_dir_layout(mem, dir, img)

    var t = ScriptedOciTransport()
    for _ in range(3):
        t.queue(_status(200))
    t.queue(_created(img.manifest.copy()))
    t.queue(_created(img.manifest.copy()))

    var layout = DirOciLayout(dir.copy())
    var pusher = OciLayoutPusher[ScriptedOciTransport](t^, String(_TOKEN))
    var got = pusher.push(layout, _tag_ref())
    assert_equal(got, img.manifest, "the directory layout pushes the same image")
    ref log = pusher.transport()
    assert_equal(log.call_count(), 5, "3 HEADs + manifest + tag")
    assert_equal(
        _body_digest(log, 3), img.manifest,
        "the manifest file is sent verbatim",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
