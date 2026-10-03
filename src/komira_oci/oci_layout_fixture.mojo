# =============================================================================
# oci_layout_fixture.mojo — write a real OCI layout DIRECTORY, for tests.
# =============================================================================
#
# The reader and the pusher are only worth trusting if they are driven over the
# real thing: a directory with `oci-layout`, `index.json` and
# `blobs/sha256/<hex>`, whose digests are the real sha256 of real bytes and
# whose manifest is INDENTED JSON (a compact document is a fixed point of a JSON
# parse/serialize round trip, so a client that wrongly re-serialized a manifest
# would still pass over it; an indented one would not).
#
# This module is deliberately in the library, not under tests/: two test files
# need it, and a test source cannot import another test source.
#
# Like `oci_fake_registry`, it is test support. Nothing production calls it.
# =============================================================================

from std.os import makedirs
from std.pathlib import Path

from .oci_digest import digest_of_bytes
from .oci_ref import MEDIA_TYPE_OCI_MANIFEST


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _hex_of(digest: String) -> String:
    return String(digest[byte=7 : digest.byte_length()])


def layout_blob_path(dir: String, digest: String) -> String:
    return dir + String("/blobs/sha256/") + _hex_of(digest)


def _put_blob(dir: String, data: List[UInt8]) raises -> String:
    var d = digest_of_bytes(Span(data))
    Path(layout_blob_path(dir, d)).write_bytes(Span(data))
    return d^


def write_test_layout(
    dir: String,
    layers: List[List[UInt8]],
    os_name: String = String("linux"),
    architecture: String = String("amd64"),
    declared_first_layer_size: Int = -1,
    descriptor_media_type: String = String("default"),
    manifest_media_type: String = String("default"),
) raises -> String:
    """Write a single-image layout at `dir` holding `layers` (their bytes are
    the layer blobs verbatim). Returns the manifest digest.

    `declared_first_layer_size >= 0` makes the manifest DECLARE that size for
    layer 0 whatever its file holds — how a test presents an over-the-ceiling
    layer without writing 256 MiB."""
    makedirs(dir + String("/blobs/sha256"), exist_ok=True)
    Path(dir + String("/oci-layout")).write_bytes(
        Span(_bytes(String('{"imageLayoutVersion": "1.0.0"}')))
    )

    var config = _bytes(
        String('{\n  "architecture": "')
        + architecture
        + String('",\n  "os": "')
        + os_name
        + String('",\n  "rootfs": {"type": "layers", "diff_ids": []}\n}\n')
    )
    var config_digest = _put_blob(dir, config)

    var layer_entries = String("")
    for i in range(len(layers)):
        var ld = _put_blob(dir, layers[i])
        var size = len(layers[i])
        if i == 0 and declared_first_layer_size >= 0:
            size = declared_first_layer_size
        if i > 0:
            layer_entries += String(",\n")
        layer_entries += (
            String('    {\n      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",\n      "digest": "')
            + ld
            + String('",\n      "size": ')
            + String(size)
            + String("\n    }")
        )
    # "default" = the OCI manifest type; "" = the field is OMITTED.
    var own_type = manifest_media_type.copy()
    if own_type == String("default"):
        own_type = String(MEDIA_TYPE_OCI_MANIFEST)
    var own_field = String("")
    if own_type.byte_length() > 0:
        own_field = String('  "mediaType": "') + own_type + String('",\n')
    var desc_type = descriptor_media_type.copy()
    if desc_type == String("default"):
        desc_type = String(MEDIA_TYPE_OCI_MANIFEST)
    var desc_field = String("")
    if desc_type.byte_length() > 0:
        desc_field = String('      "mediaType": "') + desc_type + String('",\n')
    var manifest = _bytes(
        String('{\n  "schemaVersion": 2,\n')
        + own_field
        + String('  "config": {\n    "mediaType": "application/vnd.oci.image.config.v1+json",\n    "digest": "')
        + config_digest
        + String('",\n    "size": ')
        + String(len(config))
        + String('\n  },\n  "layers": [\n')
        + layer_entries
        + String("\n  ]\n}\n")
    )
    var manifest_digest = _put_blob(dir, manifest)
    Path(dir + String("/index.json")).write_bytes(
        Span(
            _bytes(
                String('{\n  "schemaVersion": 2,\n  "manifests": [\n    {\n')
                + desc_field
                + String('      "digest": "')
                + manifest_digest
                + String('",\n      "size": ')
                + String(len(manifest))
                + String("\n    }\n  ]\n}\n")
            )
        )
    )
    return manifest_digest^


def overwrite_layout_blob(dir: String, digest: String) raises:
    """Replace the blob file for `digest` with same-length DIFFERENT bytes — a
    corruption that a size check alone cannot see."""
    var path = layout_blob_path(dir, digest)
    var old = Path(path).read_bytes()
    var flipped = List[UInt8]()
    for i in range(len(old)):
        flipped.append(old[i] ^ UInt8(0xFF))
    Path(path).write_bytes(Span(flipped))
