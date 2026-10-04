# =============================================================================
# test_oci_layout_reader.mojo — the layout reader over REAL directories.
# =============================================================================
#
#   (1) a sound layout reads, with its platform from the config, and carries NO
#       Docker `manifest.json` (an OCI layout never has one);
#   (2) a blob whose bytes were corrupted (same length, so a size check alone
#       passes) is refused by digest;
#   (3) a blob of the wrong length is refused;
#   (4) a missing blob is refused;
#   (5) a layer DECLARED above the monolithic ceiling is refused up front,
#       naming the ceiling and saying chunked upload is not implemented — and
#       before any blob is hashed (the layer file need not even exist);
#   (6) an index.json with two images, and one whose entry is itself an index,
#       are refused; a bad oci-layout version is refused;
#   (7) `read_blob` re-verifies: a file changed after the layout was verified is
#       caught before its bytes are returned;
#   (8) `push_blobs` is layers then config, each digest once.
# =============================================================================

from std.os import getenv, remove
from std.os.path import isfile
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_oci.oci_digest import digest_of_bytes
from komira_oci.oci_layout_fixture import (
    layout_blob_path,
    overwrite_layout_blob,
    write_test_layout,
)
from komira_oci.oci_layout_reader import (
    MAX_MONOLITHIC_BLOB_BYTES,
    read_oci_layout,
)


def _scratch(name: String) -> String:
    var base = getenv("TEST_TMPDIR", "/tmp")
    return base + String("/komira_oci_layout_reader_") + name


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _layers_two() -> List[List[UInt8]]:
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("layer-one-bytes-aaaaaaaaaaaaaaaa")))
    layers.append(_bytes(String("layer-two-bytes-bbbbbbbbbbbbbbbbbbbbbb")))
    return layers^


def _refuses(dir: String, needle: String, why: String) raises:
    var raised = False
    try:
        var _l = read_oci_layout(dir)
    except e:
        raised = True
        assert_true(
            String(e).find(needle) >= 0,
            why + String(": the refusal must mention '") + needle + String("', got: ") + String(e),
        )
    assert_true(raised, why + String(": must be refused"))


def test_sound_layout_reads() raises:
    var dir = _scratch(String("sound"))
    var digest = write_test_layout(dir, _layers_two())
    var layout = read_oci_layout(dir)
    assert_equal(layout.manifest_digest, digest)
    assert_equal(layout.platform(), String("linux/amd64"))
    assert_equal(len(layout.layers), 2)
    assert_equal(layout.layers[0].size, 32)
    assert_true(
        not isfile(dir + String("/manifest.json")),
        "an OCI layout has no Docker manifest.json, and the reader needs none",
    )
    # The manifest bytes are carried VERBATIM: they hash to the manifest digest.
    assert_equal(digest_of_bytes(Span(layout.manifest_raw)), digest)
    print("  test_sound_layout_reads: PASS")


def test_platform_comes_from_the_config() raises:
    var dir = _scratch(String("arm"))
    _ = write_test_layout(dir, _layers_two(), String("linux"), String("arm64"))
    assert_equal(read_oci_layout(dir).platform(), String("linux/arm64"))
    print("  test_platform_comes_from_the_config: PASS")


def test_corrupted_blob_same_length_is_refused() raises:
    var dir = _scratch(String("corrupt"))
    _ = write_test_layout(dir, _layers_two())
    var layout = read_oci_layout(dir)
    overwrite_layout_blob(dir, layout.layers[1].digest)
    _refuses(dir, String("DIGEST MISMATCH"), String("a corrupted layer"))
    print("  test_corrupted_blob_same_length_is_refused: PASS")


def test_wrong_length_blob_is_refused() raises:
    var dir = _scratch(String("short"))
    _ = write_test_layout(dir, _layers_two())
    var layout = read_oci_layout(dir)
    Path(layout_blob_path(dir, layout.layers[0].digest)).write_bytes(
        Span(_bytes(String("short")))
    )
    _refuses(dir, String("descriptor says"), String("a truncated layer"))
    print("  test_wrong_length_blob_is_refused: PASS")


def test_missing_blob_is_refused() raises:
    var dir = _scratch(String("missing"))
    _ = write_test_layout(dir, _layers_two())
    var layout = read_oci_layout(dir)
    remove(layout_blob_path(dir, layout.layers[1].digest))
    _refuses(dir, String("missing or not a file"), String("an absent layer"))
    print("  test_missing_blob_is_refused: PASS")


def test_layer_over_the_ceiling_is_refused_up_front() raises:
    var dir = _scratch(String("ceiling"))
    var declared = MAX_MONOLITHIC_BLOB_BYTES + 1
    _ = write_test_layout(dir, _layers_two(), String("linux"), String("amd64"), declared)
    var raised = False
    try:
        var _l = read_oci_layout(dir)
    except e:
        raised = True
        var msg = String(e)
        assert_true(msg.find(String("monolithic upload limit")) >= 0, msg)
        assert_true(msg.find(String("Chunked upload is not implemented")) >= 0, msg)
        assert_true(msg.find(String(String(declared))) >= 0, "names the size: " + msg)
    assert_true(raised, "a layer above the ceiling must be refused")
    print("  test_layer_over_the_ceiling_is_refused_up_front: PASS")


def test_layer_at_the_ceiling_passes_the_ceiling_check() raises:
    # Exactly the ceiling is allowed by the ceiling rule; the file is not that
    # big, so it is then refused for LENGTH, not for the ceiling.
    var dir = _scratch(String("at_ceiling"))
    _ = write_test_layout(
        dir, _layers_two(), String("linux"), String("amd64"), MAX_MONOLITHIC_BLOB_BYTES
    )
    var raised = False
    try:
        var _l = read_oci_layout(dir)
    except e:
        raised = True
        assert_true(String(e).find(String("monolithic upload limit")) < 0, String(e))
    assert_true(raised, "the file is not 256 MiB, so it fails the length check")
    print("  test_layer_at_the_ceiling_passes_the_ceiling_check: PASS")


def test_two_images_and_nested_index_and_bad_version_are_refused() raises:
    var dir = _scratch(String("two"))
    _ = write_test_layout(dir, _layers_two())
    var idx = Path(dir + String("/index.json")).read_text()
    # Duplicate the single manifest entry: two images.
    var start = idx.find(String("{\n      \"mediaType\""))
    var end = idx.find(String("\n    }")) + 6
    var entry = String(idx[byte=start:end])
    var two = String(idx[byte=:end]) + String(",\n    ") + entry + String(idx[byte=end:])
    Path(dir + String("/index.json")).write_text(two)
    _refuses(dir, String("describes 2 images"), String("an index with two images"))

    var dir2 = _scratch(String("nested"))
    _ = write_test_layout(dir2, _layers_two())
    var idx2 = Path(dir2 + String("/index.json")).read_text()
    var swapped = String("")
    var needle = String("application/vnd.oci.image.manifest.v1+json")
    var at = idx2.find(needle)
    swapped = String(idx2[byte=:at]) + String("application/vnd.oci.image.index.v1+json") + String(idx2[byte = at + needle.byte_length() :])
    Path(dir2 + String("/index.json")).write_text(swapped)
    _refuses(dir2, String("multi-arch"), String("an entry that is itself an index"))

    var dir3 = _scratch(String("version"))
    _ = write_test_layout(dir3, _layers_two())
    Path(dir3 + String("/oci-layout")).write_text(String('{"imageLayoutVersion": "2.0.0"}'))
    _refuses(dir3, String("imageLayoutVersion 1.0.0"), String("a wrong layout version"))
    print("  test_two_images_and_nested_index_and_bad_version_are_refused: PASS")


def test_read_blob_reverifies() raises:
    var dir = _scratch(String("reverify"))
    _ = write_test_layout(dir, _layers_two())
    var layout = read_oci_layout(dir)
    var good = layout.read_blob(layout.layers[0])
    assert_equal(digest_of_bytes(Span(good)), layout.layers[0].digest)
    overwrite_layout_blob(dir, layout.layers[0].digest)
    var raised = False
    try:
        var _b = layout.read_blob(layout.layers[0])
    except e:
        raised = True
        assert_true(String(e).find(String("DIGEST MISMATCH")) >= 0, String(e))
        assert_true(String(e).find(String("nothing was sent")) >= 0, String(e))
    assert_true(raised, "a file changed after verification must not be returned")
    print("  test_read_blob_reverifies: PASS")


def test_push_blobs_is_layers_then_config_once() raises:
    var dir = _scratch(String("order"))
    var layers = List[List[UInt8]]()
    layers.append(_bytes(String("same-layer-yyyyyyyyyyyyyyyyyyyy")))
    layers.append(_bytes(String("same-layer-yyyyyyyyyyyyyyyyyyyy")))
    layers.append(_bytes(String("other-layer-zzzzzzzzzzzzzzzzzzzzzz")))
    _ = write_test_layout(dir, layers)
    var layout = read_oci_layout(dir)
    var blobs = layout.push_blobs()
    assert_equal(len(blobs), 3)
    assert_equal(blobs[0].digest, layout.layers[0].digest)
    assert_equal(blobs[1].digest, layout.layers[2].digest)
    assert_equal(blobs[2].digest, layout.config.digest)
    print("  test_push_blobs_is_layers_then_config_once: PASS")


def main() raises:
    test_sound_layout_reads()
    test_platform_comes_from_the_config()
    test_corrupted_blob_same_length_is_refused()
    test_wrong_length_blob_is_refused()
    test_missing_blob_is_refused()
    test_layer_over_the_ceiling_is_refused_up_front()
    test_layer_at_the_ceiling_passes_the_ceiling_check()
    test_two_images_and_nested_index_and_bad_version_are_refused()
    test_read_blob_reverifies()
    test_push_blobs_is_layers_then_config_once()
    print("test_oci_layout_reader: ALL PASS")
