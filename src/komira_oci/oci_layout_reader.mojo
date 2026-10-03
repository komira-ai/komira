# =============================================================================
# oci_layout_reader.mojo — read, and VERIFY, an OCI image layout DIRECTORY.
# =============================================================================
#
# WHAT A LAYOUT IS. The farm builds an image into a directory holding
#
#     oci-layout            {"imageLayoutVersion": "1.0.0"}
#     index.json            an OCI image index with EXACTLY ONE manifest
#     blobs/sha256/<hex>    the manifest, the config and every layer, each
#                           named by the sha256 of its own bytes
#
# and nothing else. There is NO Docker `manifest.json` (that file belongs to the
# `docker save` tarball format, not to an OCI layout) and none is needed.
#
# THE ONE IMPLEMENTATION OF LAYOUT VERIFICATION. Everything that wants to know
# "is this directory a sound, pushable image?" calls `read_oci_layout`; nobody
# re-implements digest, size or ceiling checks next to it. It verifies, before
# it returns a value, that:
#
#   * `oci-layout` says version 1.0.0;
#   * `index.json` describes exactly one image (`layout_image_digest`'s rule),
#     and that image is an image MANIFEST, not a nested index (a multi-arch
#     index is a tree of images and is refused loudly, never half-pushed);
#   * the manifest, the config and every layer EXIST under `blobs/sha256/`;
#   * every blob's byte length equals its descriptor's `size`, and its sha256
#     equals the digest that names it — computed by STREAMING the file, so
#     verifying a layer never holds the layer;
#   * no blob exceeds `MAX_MONOLITHIC_BLOB_BYTES`, checked over the WHOLE layout
#     BEFORE any blob is hashed: chunked upload is not implemented, and a layer
#     that cannot be sent must be refused up front, not 400 MiB into a push;
#   * the config names an `os` and an `architecture` (the layout's platform).
#
# MEMORY. Verification streams in `_HASH_CHUNK_BYTES` chunks. Sending is a
# SECOND, single read (`OciLayout.read_blob`) whose bytes are moved into the
# request: the peak is one blob, never the hash-time copy plus the send-time
# copy. `read_blob` re-hashes what it read, so a file changed between the verify
# and the send is caught before a byte leaves the machine.
#
# Symlinks are followed, deliberately: every byte read is checked against the
# descriptor's sha256, so a link cannot smuggle in content that is not the
# image — it can only fail the check.
#
# Encapsulation: owned String / List values only. No pointer, no wildcard origin.
# =============================================================================

from std.io import FileHandle
from std.os import stat
from std.os.path import isdir, isfile
from std.pathlib import Path

from komira_crypto import Sha256, hex_lower_array_32
from komira_json import JsonValue, parse_json_bytes

from .oci_digest import digest_of_bytes, validate_digest_format
from .oci_layout import layout_image_digest
from .oci_ref import (
    MEDIA_TYPE_DOCKER_MANIFEST,
    MEDIA_TYPE_OCI_MANIFEST,
    media_type_is_index,
)


# The largest single blob this client will send. A monolithic PUT puts the whole
# blob in one request; the resident cost is a small multiple of it, and a request
# has a time budget. Chunked (PATCH) upload is NOT implemented, so a blob above
# this is REFUSED with a message that says so. Raising it is a code change.
comptime MAX_MONOLITHIC_BLOB_BYTES: Int = 256 * 1024 * 1024

# `index.json`, a manifest and a config are read whole and parsed. They are
# kilobytes in practice; this bounds a hostile or corrupt layout.
comptime MAX_LAYOUT_DOCUMENT_BYTES: Int = 4 * 1024 * 1024

comptime _HASH_CHUNK_BYTES: Int = 1024 * 1024


struct LayoutBlob(Copyable, Movable, Deinitable):
    """One blob of the layout: where it is, what it must hash to, how long it is.

    `digest` is the `sha256:<hex>` that names it; `path` is the file under the
    layout directory; `size` is the descriptor's byte length (verified against
    the file)."""

    var digest: String
    var size: Int
    var media_type: String
    var path: String

    def __init__(
        out self,
        var digest: String,
        size: Int,
        var media_type: String,
        var path: String,
    ):
        self.digest = digest^
        self.size = size
        self.media_type = media_type^
        self.path = path^

    def copy(self) -> Self:
        return LayoutBlob(
            self.digest.copy(),
            self.size,
            self.media_type.copy(),
            self.path.copy(),
        )


struct OciLayout(Copyable, Movable, Deinitable):
    """A VERIFIED single-image OCI layout.

    Obtained only from `read_oci_layout`, which has already checked every blob.
    `manifest_raw` is the manifest's exact bytes (a digest covers them verbatim;
    they are never re-serialized). `layers` are in manifest order; `config` is
    separate. `os` / `architecture` come from the config."""

    var dir: String
    var manifest_digest: String
    var manifest_media_type: String
    var manifest_raw: List[UInt8]
    var config: LayoutBlob
    var layers: List[LayoutBlob]
    var os: String
    var architecture: String
    var variant: String

    def __init__(
        out self,
        var dir: String,
        var manifest_digest: String,
        var manifest_media_type: String,
        var manifest_raw: List[UInt8],
        var config: LayoutBlob,
        var layers: List[LayoutBlob],
        var os: String,
        var architecture: String,
        var variant: String,
    ):
        self.dir = dir^
        self.manifest_digest = manifest_digest^
        self.manifest_media_type = manifest_media_type^
        self.manifest_raw = manifest_raw^
        self.config = config^
        self.layers = layers^
        self.os = os^
        self.architecture = architecture^
        self.variant = variant^

    def copy(self) -> Self:
        return OciLayout(
            self.dir.copy(),
            self.manifest_digest.copy(),
            self.manifest_media_type.copy(),
            self.manifest_raw.copy(),
            self.config.copy(),
            self.layers.copy(),
            self.os.copy(),
            self.architecture.copy(),
            self.variant.copy(),
        )

    def platform(self) -> String:
        """`os/architecture[/variant]` — the OCI spelling, e.g. `linux/amd64`."""
        var p = self.os + String("/") + self.architecture
        if self.variant.byte_length() > 0:
            p += String("/") + self.variant
        return p^

    def push_blobs(self) -> List[LayoutBlob]:
        """The blobs a push must make present, in upload order: the layers, then
        the config, each digest ONCE (an image may list the same empty layer
        twice; uploading it twice would be a wasted round trip)."""
        var out = List[LayoutBlob]()
        for i in range(len(self.layers)):
            if not _has_digest(out, self.layers[i].digest):
                out.append(self.layers[i].copy())
        if not _has_digest(out, self.config.digest):
            out.append(self.config.copy())
        return out^

    def read_blob(self, blob: LayoutBlob) raises -> List[UInt8]:
        """Read `blob` ONCE, whole, and RE-VERIFY it against its digest.

        The re-hash is over bytes already in memory (cheap), and it is what
        catches a file that changed after `read_oci_layout` verified it: the
        bytes returned are always the bytes the digest names, or this raises."""
        if blob.size > MAX_MONOLITHIC_BLOB_BYTES:
            raise _ceiling_error(blob.digest, blob.size)
        var h = FileHandle(blob.path, "r")
        var data = List[UInt8]()
        while len(data) <= blob.size:
            var chunk = h.read_bytes(_HASH_CHUNK_BYTES)
            if len(chunk) == 0:
                break
            data.extend(Span(chunk))
        if len(data) != blob.size:
            raise Error(
                String("oci layout: blob ")
                + blob.digest
                + String(" is ")
                + String(len(data))
                + String(" bytes on disk but its descriptor says ")
                + String(blob.size)
                + String(" — the layout changed after it was verified")
            )
        var actual = digest_of_bytes(Span(data))
        if actual != blob.digest:
            raise Error(
                String("oci layout: DIGEST MISMATCH reading blob ")
                + blob.digest
                + String(" — its bytes content-address to ")
                + actual
                + String(
                    ". The layout changed after it was verified; nothing was"
                    " sent."
                )
            )
        return data^


def _has_digest(blobs: List[LayoutBlob], digest: String) -> Bool:
    for i in range(len(blobs)):
        if blobs[i].digest == digest:
            return True
    return False


def _ceiling_error(digest: String, size: Int) -> Error:
    return Error(
        String("oci layout: blob ")
        + digest
        + String(" is ")
        + String(size)
        + String(" bytes; the monolithic upload limit is ")
        + String(MAX_MONOLITHIC_BLOB_BYTES)
        + String(
            " bytes (256 MiB). Chunked upload is not implemented, so this"
            " image cannot be pushed. Nothing was sent."
        )
    )


def _blob_path(dir: String, digest: String) -> String:
    """`<dir>/blobs/sha256/<hex>` for a digest already validated as
    `sha256:` + 64 lowercase hex — so the result cannot contain a path
    separator or `..`."""
    var base = dir.copy()
    if not base.endswith(String("/")):
        base += String("/")
    return (
        base
        + String("blobs/sha256/")
        + String(digest[byte=7 : digest.byte_length()])
    )


def _file_size(path: String, what: String) raises -> Int:
    if not isfile(path):
        raise Error(
            String("oci layout: ") + what + String(" is missing or not a file: ") + path
        )
    return Int(stat(path).st_size)


def _read_document(path: String, what: String) raises -> List[UInt8]:
    """Read a small layout document whole, refusing one above the cap."""
    var size = _file_size(path, what)
    if size > MAX_LAYOUT_DOCUMENT_BYTES:
        raise Error(
            String("oci layout: ")
            + what
            + String(" is ")
            + String(size)
            + String(" bytes, above the ")
            + String(MAX_LAYOUT_DOCUMENT_BYTES)
            + String(" byte limit for a layout document")
        )
    return Path(path).read_bytes()


def _stream_digest(path: String, size: Int) raises -> String:
    """The `sha256:` digest of the file at `path`, computed in fixed chunks.

    Reads at most `size + 1` bytes: a file longer than its descriptor says is
    refused without being read to the end."""
    var h = FileHandle(path, "r")
    var hasher = Sha256()
    var total = 0
    while True:
        var chunk = h.read_bytes(_HASH_CHUNK_BYTES)
        var n = len(chunk)
        if n == 0:
            break
        total += n
        if total > size:
            raise Error(
                String("oci layout: ")
                + path
                + String(" is longer than its descriptor's size ")
                + String(size)
            )
        hasher.update(Span(chunk))
    if total != size:
        raise Error(
            String("oci layout: ")
            + path
            + String(" is ")
            + String(total)
            + String(" bytes but its descriptor says ")
            + String(size)
        )
    var out = Array[UInt8, 32](fill=UInt8(0))
    hasher.finalize_into(out)
    return String("sha256:") + hex_lower_array_32(out)


def _descriptor(
    d: JsonValue, what: String, dir: String
) raises -> LayoutBlob:
    """A descriptor object (`digest`, `size`, optional `mediaType`) as a blob."""
    if not d.has(String("digest")):
        raise Error(String("oci layout: ") + what + String(" has no 'digest'"))
    var digest = d.get(String("digest")).as_string()
    validate_digest_format(digest, what)
    if not d.has(String("size")):
        raise Error(String("oci layout: ") + what + String(" has no 'size'"))
    var size_v = d.get(String("size"))
    if not size_v.is_integral_number():
        raise Error(
            String("oci layout: ") + what + String(" 'size' is not an integer")
        )
    var size = Int(size_v.as_int64())
    if size < 0:
        raise Error(String("oci layout: ") + what + String(" has a negative 'size'"))
    var media_type = String("")
    if d.has(String("mediaType")):
        media_type = d.get(String("mediaType")).as_string()
    return LayoutBlob(digest^, size, media_type^, _blob_path(dir, digest))


def read_oci_layout(dir: String) raises -> OciLayout:
    """Read and VERIFY the single-image OCI layout at `dir`. See the file header
    for exactly what is checked. RAISES on the first violation, naming it;
    returns only a layout every blob of which has been hashed and sized."""
    if not isdir(dir):
        raise Error(
            String("oci layout: '") + dir + String("' is not a directory")
        )
    var base = dir.copy()
    if not base.endswith(String("/")):
        base += String("/")

    # ---- oci-layout ----------------------------------------------------------
    var marker = parse_json_bytes(
        _read_document(base + String("oci-layout"), String("the oci-layout file"))
    )
    if (
        not marker.has(String("imageLayoutVersion"))
        or marker.get(String("imageLayoutVersion")).as_string()
        != String("1.0.0")
    ):
        raise Error(
            String(
                "oci layout: the oci-layout file does not say"
                " imageLayoutVersion 1.0.0"
            )
        )

    # ---- index.json: exactly one image ----------------------------------------
    var index_raw = _read_document(
        base + String("index.json"), String("index.json")
    )
    var index_text = String(unsafe_from_utf8=Span(index_raw))
    var manifest_digest = layout_image_digest(index_text)
    var index_doc = parse_json_bytes(index_raw)
    var entry = index_doc.get(String("manifests")).element_at(0)
    var manifest_blob = _descriptor(entry, String("the index.json descriptor"), base)
    if media_type_is_index(manifest_blob.media_type):
        raise Error(
            String(
                "oci layout: index.json's one entry is itself an image index"
                " (multi-arch). Only a single image manifest can be pushed;"
                " refusing rather than pushing half a tree."
            )
        )

    # ---- the manifest ---------------------------------------------------------
    if manifest_blob.size > MAX_LAYOUT_DOCUMENT_BYTES:
        raise Error(
            String("oci layout: the manifest is ")
            + String(manifest_blob.size)
            + String(" bytes, above the layout-document limit")
        )
    var manifest_raw = _read_document(manifest_blob.path, String("the manifest blob"))
    if len(manifest_raw) != manifest_blob.size:
        raise Error(
            String("oci layout: the manifest blob is ")
            + String(len(manifest_raw))
            + String(" bytes but index.json says ")
            + String(manifest_blob.size)
        )
    var actual_manifest = digest_of_bytes(Span(manifest_raw))
    if actual_manifest != manifest_digest:
        raise Error(
            String("oci layout: DIGEST MISMATCH for the manifest — index.json"
                   " names ")
            + manifest_digest
            + String(" but the blob content-addresses to ")
            + actual_manifest
        )
    var manifest_doc = parse_json_bytes(manifest_raw)
    if manifest_doc.has(String("manifests")):
        raise Error(
            String(
                "oci layout: the manifest blob is an image index, not an image"
                " manifest"
            )
        )
    # The Content-Type a registry validates the manifest against is stated by
    # the descriptor, by the manifest itself, or both; when both, they must
    # agree, and when neither does there is nothing to PUT it under.
    var media_type = manifest_blob.media_type.copy()
    var own_media_type = String("")
    if manifest_doc.has(String("mediaType")):
        own_media_type = manifest_doc.get(String("mediaType")).as_string()
    if media_type.byte_length() > 0 and own_media_type.byte_length() > 0:
        if media_type != own_media_type:
            raise Error(
                String("oci layout: the manifest says it is '")
                + own_media_type
                + String("' but its index.json descriptor says '")
                + media_type
                + String("'; refusing to choose between them")
            )
    if media_type.byte_length() == 0:
        media_type = own_media_type^
    if media_type.byte_length() == 0:
        raise Error(
            String(
                "oci layout: the manifest states no mediaType and neither does"
                " its index.json descriptor; refusing to guess the"
                " Content-Type a registry validates it against"
            )
        )
    if (
        media_type != String(MEDIA_TYPE_OCI_MANIFEST)
        and media_type != String(MEDIA_TYPE_DOCKER_MANIFEST)
    ):
        raise Error(
            String("oci layout: unsupported manifest media type '")
            + media_type
            + String("'")
        )

    if not manifest_doc.has(String("config")):
        raise Error(String("oci layout: the manifest has no 'config'"))
    var config = _descriptor(
        manifest_doc.get(String("config")), String("the manifest's config"), base
    )
    var layers = List[LayoutBlob]()
    if manifest_doc.has(String("layers")):
        var arr = manifest_doc.get(String("layers"))
        for i in range(arr.array_len()):
            layers.append(
                _descriptor(
                    arr.element_at(i),
                    String("layer ") + String(i),
                    base,
                )
            )

    # ---- the ceiling, over the WHOLE layout, BEFORE any blob is hashed --------
    if config.size > MAX_MONOLITHIC_BLOB_BYTES:
        raise _ceiling_error(config.digest, config.size)
    for i in range(len(layers)):
        if layers[i].size > MAX_MONOLITHIC_BLOB_BYTES:
            raise _ceiling_error(layers[i].digest, layers[i].size)

    # ---- verify every blob, streaming -----------------------------------------
    _verify_blob(config)
    for i in range(len(layers)):
        _verify_blob(layers[i])

    # ---- the platform, from the config ----------------------------------------
    if config.size > MAX_LAYOUT_DOCUMENT_BYTES:
        raise Error(String("oci layout: the config blob is too large to read"))
    var cfg = parse_json_bytes(Path(config.path).read_bytes())
    var os_name = String("")
    var arch = String("")
    var variant = String("")
    if cfg.has(String("os")):
        os_name = cfg.get(String("os")).as_string()
    if cfg.has(String("architecture")):
        arch = cfg.get(String("architecture")).as_string()
    if cfg.has(String("variant")):
        variant = cfg.get(String("variant")).as_string()
    if os_name.byte_length() == 0 or arch.byte_length() == 0:
        raise Error(
            String(
                "oci layout: the image config names no 'os' / 'architecture' —"
                " the platform of the image is unknown"
            )
        )

    return OciLayout(
        dir.copy(),
        manifest_digest^,
        media_type^,
        manifest_raw^,
        config^,
        layers^,
        os_name^,
        arch^,
        variant^,
    )


def _verify_blob(blob: LayoutBlob) raises:
    var size = _file_size(blob.path, String("blob ") + blob.digest)
    if size != blob.size:
        raise Error(
            String("oci layout: blob ")
            + blob.digest
            + String(" is ")
            + String(size)
            + String(" bytes on disk but its descriptor says ")
            + String(blob.size)
        )
    var actual = _stream_digest(blob.path, blob.size)
    if actual != blob.digest:
        raise Error(
            String("oci layout: DIGEST MISMATCH for blob ")
            + blob.digest
            + String(" — its bytes content-address to ")
            + actual
        )
