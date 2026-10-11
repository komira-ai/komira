# =============================================================================
# test_oci_layout_reader_refusals.mojo — every refusal of `read_oci_layout`
#   and `OciLayout.read_blob`, each over a hand-written layout directory whose
#   one defect is the one the row names.
# =============================================================================
#
#   (1) a path that is not a directory;
#   (2) a layout document above 4 MiB (one byte over is refused; exactly the
#       limit passes the limit and fails for what it holds);
#   (3) a descriptor with no digest, no size, a non-integer size (a string, a
#       fraction) or a negative size, named by WHICH descriptor it is;
#   (4) the manifest: declared above the document limit, a different length
#       than declared, bytes that do not hash to the index's digest, an image
#       index in its place, an unsupported media type, no config;
#   (5) the config: declared above the monolithic ceiling (refused before any
#       hashing), above the document limit on disk, naming no os or no
#       architecture; a `variant` is part of the platform;
#   (6) `read_blob`: a blob declared above the ceiling, and a file now shorter
#       or longer than its descriptor;
#   (7) the helpers: `_blob_path` adds the one '/' a directory lacks, and
#       `_stream_digest` refuses a file longer or shorter than the size it is
#       told.
# =============================================================================

from std.os import getenv, makedirs
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_layout_reader import (
    LayoutBlob,
    MAX_LAYOUT_DOCUMENT_BYTES,
    MAX_MONOLITHIC_BLOB_BYTES,
    _blob_path,
    _stream_digest,
    read_oci_layout,
)
from komira_oci.oci_ref import MEDIA_TYPE_OCI_MANIFEST

comptime _CONFIG: String = '{"architecture":"amd64","os":"linux"}'
comptime _LAYER: String = "layer-bytes-for-refusals"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _fresh(name: String) raises -> String:
    var dir = getenv("TEST_TMPDIR", "/tmp") + String("/komira_oci_refusals_") + name
    makedirs(dir + String("/blobs/sha256"), exist_ok=True)
    Path(dir + String("/oci-layout")).write_text(String('{"imageLayoutVersion": "1.0.0"}'))
    return dir^


def _hex(digest: String) -> String:
    return String(digest[byte=7 : digest.byte_length()])


def _put(dir: String, data: List[UInt8]) raises -> String:
    var d = digest_of_bytes(Span(data))
    Path(dir + String("/blobs/sha256/") + _hex(d)).write_bytes(Span(data))
    return d^


def _desc(digest: String, size: String, media: String = String("")) -> String:
    var m = String("")
    if media.byte_length() > 0:
        m = String('"mediaType":"') + media + String('",')
    return String("{") + m + String('"digest":"') + digest + String('","size":') + size + String("}")


def _index(dir: String, digest: String, size: Int, media: String = String(MEDIA_TYPE_OCI_MANIFEST)) raises:
    Path(dir + String("/index.json")).write_text(
        String('{"schemaVersion":2,"manifests":[') + _desc(digest, String(size), media) + String("]}")
    )


def _manifest(config_desc: String, layers: String = String("[]"), media: String = String(MEDIA_TYPE_OCI_MANIFEST)) -> String:
    var m = String("")
    if media.byte_length() > 0:
        m = String('"mediaType":"') + media + String('",')
    return String('{"schemaVersion":2,') + m + String('"config":') + config_desc + String(',"layers":') + layers + String("}")


def _config_desc(dir: String, text: String = String(_CONFIG)) raises -> String:
    var data = _bytes(text)
    var d = _put(dir, data)
    return _desc(d, String(len(data)))


def _layers(dir: String) raises -> String:
    var data = _bytes(String(_LAYER))
    return String("[") + _desc(_put(dir, data), String(len(data))) + String("]")


def _write_manifest(dir: String, text: String, media: String = String(MEDIA_TYPE_OCI_MANIFEST)) raises -> String:
    var data = _bytes(text)
    var d = _put(dir, data)
    _index(dir, d, len(data), media)
    return d^


def _refuses(dir: String, needle: String, why: String) raises:
    var raised = False
    var msg = String("")
    try:
        _ = read_oci_layout(dir)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, why + String(": must be refused"))
    assert_true(
        msg.find(needle) >= 0,
        why + String(": expected '") + needle + String("' in: ") + msg,
    )


def test_not_a_directory() raises:
    var dir = _fresh(String("notdir")) + String("/absent")
    _refuses(dir, String("' is not a directory"), String("a missing directory"))
    print("  test_not_a_directory: PASS")


def test_layout_document_size_limit() raises:
    var dir = _fresh(String("doc_over"))
    Path(dir + String("/oci-layout")).write_bytes(
        Span(List[UInt8](length=MAX_LAYOUT_DOCUMENT_BYTES + 1, fill=UInt8(32)))
    )
    _refuses(
        dir,
        String("the oci-layout file is 4194305 bytes, above the 4194304 byte limit"),
        String("one byte over"),
    )
    var dir2 = _fresh(String("doc_at"))
    Path(dir2 + String("/oci-layout")).write_bytes(
        Span(List[UInt8](length=MAX_LAYOUT_DOCUMENT_BYTES, fill=UInt8(32)))
    )
    var raised = False
    try:
        _ = read_oci_layout(dir2)
    except e:
        raised = True
        assert_true(String(e).find(String("byte limit")) < 0, "exactly the limit is allowed: " + String(e))
    assert_true(raised, "a blank oci-layout still fails, for what it holds")
    print("  test_layout_document_size_limit: PASS")


def test_descriptor_refusals() raises:
    var cd = String("sha256:") + "aa" * 32
    var rows = List[String]()
    var needles = List[String]()
    rows.append(String('{"size":3}'))
    needles.append(String("the manifest's config has no 'digest'"))
    rows.append(String('{"digest":"') + cd + String('"}'))
    needles.append(String("the manifest's config has no 'size'"))
    rows.append(String('{"digest":"') + cd + String('","size":"12"}'))
    needles.append(String("the manifest's config 'size' is not an integer"))
    rows.append(String('{"digest":"') + cd + String('","size":1.5}'))
    needles.append(String("the manifest's config 'size' is not an integer"))
    rows.append(String('{"digest":"') + cd + String('","size":-1}'))
    needles.append(String("the manifest's config has a negative 'size'"))
    for i in range(len(rows)):
        var dir = _fresh(String("desc_") + String(i))
        _ = _write_manifest(dir, _manifest(rows[i]))
        _refuses(dir, needles[i], String("config descriptor row ") + String(i))

    # A layer descriptor is named by its position.
    var dir = _fresh(String("desc_layer"))
    var layers = String("[") + _desc(cd, String(2)) + String(',{"digest":"') + cd + String('"}]')
    _ = _write_manifest(dir, _manifest(_config_desc(dir), layers))
    _refuses(dir, String("layer 1 has no 'size'"), String("the second layer"))
    print("  test_descriptor_refusals: PASS")


def test_manifest_refusals() raises:
    # Declared above the document limit: refused before it is read.
    var dir = _fresh(String("m_over"))
    var d = _write_manifest(dir, _manifest(_config_desc(dir)))
    _index(dir, d, MAX_LAYOUT_DOCUMENT_BYTES + 1)
    _refuses(dir, String("the manifest is 4194305 bytes, above the layout-document limit"), String("declared over"))
    # Declared exactly at the limit: passes the limit, fails the length.
    _index(dir, d, MAX_LAYOUT_DOCUMENT_BYTES)
    _refuses(dir, String("bytes but index.json says 4194304"), String("declared at the limit"))

    # Bytes that do not hash to the digest the index names.
    var dir2 = _fresh(String("m_digest"))
    var good = _bytes(_manifest(_config_desc(dir2)))
    var twin = good.copy()
    twin[len(twin) - 2] = UInt8(32)  # same length, other bytes
    var named = digest_of_bytes(Span(twin))
    Path(dir2 + String("/blobs/sha256/") + _hex(named)).write_bytes(Span(good))
    _index(dir2, named, len(good))
    _refuses(
        dir2,
        String("DIGEST MISMATCH for the manifest — index.json names ") + named
        + String(" but the blob content-addresses to ") + digest_of_bytes(Span(good)),
        String("a substituted manifest"),
    )

    var dir3 = _fresh(String("m_index"))
    _ = _write_manifest(dir3, String('{"schemaVersion":2,"manifests":[]}'))
    _refuses(dir3, String("the manifest blob is an image index"), String("an index as the manifest"))

    var dir4 = _fresh(String("m_type"))
    _ = _write_manifest(
        dir4, _manifest(_config_desc(dir4), String("[]"), String("application/json")), String("application/json")
    )
    _refuses(dir4, String("unsupported manifest media type 'application/json'"), String("a JSON media type"))

    var dir5 = _fresh(String("m_noconfig"))
    _ = _write_manifest(dir5, String('{"schemaVersion":2,"mediaType":"') + MEDIA_TYPE_OCI_MANIFEST + String('","layers":[]}'))
    _refuses(dir5, String("the manifest has no 'config'"), String("no config"))
    print("  test_manifest_refusals: PASS")


def test_config_refusals_and_variant() raises:
    # Declared above the monolithic ceiling: refused before anything is hashed
    # (the file need not exist).
    var dir = _fresh(String("c_ceiling"))
    var cd = String("sha256:") + "cd" * 32
    _ = _write_manifest(dir, _manifest(_desc(cd, String(MAX_MONOLITHIC_BLOB_BYTES + 1)), _layers(dir)))
    _refuses(
        dir,
        String("blob ") + cd + String(" is 268435457 bytes; the monolithic upload limit"),
        String("a config over the ceiling"),
    )

    # Above the document limit on disk: verified, then not parsed.
    var dir2 = _fresh(String("c_big"))
    var big = List[UInt8](length=MAX_LAYOUT_DOCUMENT_BYTES + 1, fill=UInt8(32))
    var bd = _put(dir2, big)
    _ = _write_manifest(dir2, _manifest(_desc(bd, String(len(big)))))
    _refuses(dir2, String("the config blob is too large to read"), String("a 4 MiB + 1 config"))

    var dir3 = _fresh(String("c_noarch"))
    _ = _write_manifest(dir3, _manifest(_config_desc(dir3, String('{"os":"linux"}'))))
    _refuses(dir3, String("names no 'os' / 'architecture'"), String("no architecture"))
    var dir4 = _fresh(String("c_noos"))
    _ = _write_manifest(dir4, _manifest(_config_desc(dir4, String('{"architecture":"amd64"}'))))
    _refuses(dir4, String("names no 'os' / 'architecture'"), String("no os"))

    var dir5 = _fresh(String("c_variant"))
    _ = _write_manifest(
        dir5,
        _manifest(_config_desc(dir5, String('{"architecture":"arm64","os":"linux","variant":"v8"}')), _layers(dir5)),
    )
    var layout = read_oci_layout(dir5)
    assert_equal(layout.variant, String("v8"))
    assert_equal(layout.platform(), String("linux/arm64/v8"))
    print("  test_config_refusals_and_variant: PASS")


def _read_blob_refused(dir: String, blob: LayoutBlob, needle: String, why: String) raises:
    var layout = read_oci_layout(dir)
    var raised = False
    var msg = String("")
    try:
        _ = layout.read_blob(blob)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, why + String(": must raise"))
    assert_true(msg.find(needle) >= 0, why + String(": expected '") + needle + String("' in: ") + msg)


def test_read_blob_refusals() raises:
    var dir = _fresh(String("rb"))
    _ = _write_manifest(dir, _manifest(_config_desc(dir), _layers(dir)))
    var layout = read_oci_layout(dir)
    var layer = layout.layers[0].copy()

    var huge = LayoutBlob(layer.digest.copy(), MAX_MONOLITHIC_BLOB_BYTES + 1, String(""), layer.path.copy())
    _read_blob_refused(dir, huge, String(" is 268435457 bytes; the monolithic upload limit"), String("over the ceiling"))

    var n = layer.size
    Path(layer.path).write_bytes(Span(_bytes(String(String(_LAYER)[byte = 0 : n - 1]))))
    var raised = False
    try:
        _ = layout.read_blob(layer)
    except e:
        raised = True
        assert_true(
            String(e).find(String(" is ") + String(n - 1) + String(" bytes on disk but its descriptor says ") + String(n)) >= 0,
            String(e),
        )
        assert_true(String(e).find(String("the layout changed after it was verified")) >= 0, String(e))
    assert_true(raised, "a file now one byte shorter")

    Path(layer.path).write_bytes(Span(_bytes(String(_LAYER) + String("+"))))
    raised = False
    try:
        _ = layout.read_blob(layer)
    except e:
        raised = True
        assert_true(
            String(e).find(String(" is ") + String(n + 1) + String(" bytes on disk but its descriptor says ") + String(n)) >= 0,
            String(e),
        )
    assert_true(raised, "a file now one byte longer")
    print("  test_read_blob_refusals: PASS")


def test_blob_path_and_stream_digest() raises:
    var d = String("sha256:") + "0f" * 32
    assert_equal(_blob_path(String("lay"), d), String("lay/blobs/sha256/") + "0f" * 32)
    assert_equal(_blob_path(String("lay/"), d), String("lay/blobs/sha256/") + "0f" * 32)

    var dir = _fresh(String("stream"))
    var data = _bytes(String("stream-bytes"))
    var sd = _put(dir, data)
    var path = dir + String("/blobs/sha256/") + _hex(sd)
    assert_equal(_stream_digest(path, len(data)), sd)
    var raised = False
    try:
        _ = _stream_digest(path, len(data) - 1)
    except e:
        raised = True
        assert_true(String(e).find(String(" is longer than its descriptor's size ") + String(len(data) - 1)) >= 0, String(e))
    assert_true(raised, "a file one byte longer than its size")
    raised = False
    try:
        _ = _stream_digest(path, len(data) + 1)
    except e:
        raised = True
        assert_true(
            String(e).find(String(" is ") + String(len(data)) + String(" bytes but its descriptor says ") + String(len(data) + 1)) >= 0,
            String(e),
        )
    assert_true(raised, "a file one byte shorter than its size")
    print("  test_blob_path_and_stream_digest: PASS")


def main() raises:
    test_not_a_directory()
    test_layout_document_size_limit()
    test_descriptor_refusals()
    test_manifest_refusals()
    test_config_refusals_and_variant()
    test_read_blob_refusals()
    test_blob_path_and_stream_digest()
    print("test_oci_layout_reader_refusals: ALL PASS")
