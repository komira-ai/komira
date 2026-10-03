# =============================================================================
# oci_layout_source.mojo — where a layout PUSH reads its bytes from: the
#   `OciLayoutSource` seam, a directory conformer, and an in-memory conformer.
# =============================================================================
#
# WHAT AN OCI IMAGE LAYOUT IS, ON DISK. The `oci_image` rule
# (tools/build/package/defs.bzl, written by `komira_pack oci`) emits a directory:
#
#     oci-layout            {"imageLayoutVersion":"1.0.0"}
#     index.json            an image index whose manifests[] names the image
#     blobs/sha256/<hex>    every manifest, config and layer, each file named
#                           by the sha256 of its own bytes
#
# The Docker-style `manifest.json` is NOT in the layout directory: it lives
# only in the rule's `[docker_archive]` tar, for `docker load`. A push reads
# the layout, never the archive.
#
# WHY A SEAM AND NOT A DIRECTORY PATH. `oci_layout.layout_image_digest` already
# takes `index.json` TEXT rather than a path, so that a layout living in a
# tarball, a CAS or a build-action output is as usable as a directory. The push
# keeps that property with a two-method trait: the pusher asks for the index
# and for a blob BY DIGEST, and never learns where they live. `DirOciLayout` is
# the conformer for the `oci_image` output; `MemOciLayout` is the conformer for
# a layout already in memory, and it is what the falsifiers drive.
#
# ⚠ A SOURCE DOES NOT VERIFY. `read_blob` returns whatever bytes are stored
# under that name. Proving that a file hashes to its name is the PUSHER's job
# (oci_push.mojo), done once, in one place, for every conformer, so no
# conformer can forget it. `MemOciLayout.add_blob_named` exists precisely so a
# test can hold a layout whose file names lie.
#
# Encapsulation: owned `String` / `List[UInt8]` values only. No UnsafePointer,
# no wildcard origin.
# =============================================================================

from std.pathlib import Path

from komira_json import parse_json_value

from .oci_digest import digest_of_bytes, validate_digest_format


# The only image-layout version the OCI image spec has defined. A layout that
# names another version may arrange its files differently; refusing it is
# cheaper than misreading it.
comptime OCI_IMAGE_LAYOUT_VERSION: String = "1.0.0"


# =============================================================================
# §1 — the seam.
# =============================================================================


trait OciLayoutSource(Movable, Deinitable):
    """The bytes of one OCI image layout, addressed the way the layout
    addresses them: the `index.json` document, and blobs by digest.

    Both methods RAISE when the thing asked for does not exist. Neither
    verifies content: see the note at the top of this file."""

    def index_json(mut self) raises -> List[UInt8]:
        """The bytes of the layout's `index.json`."""
        ...

    def read_blob(mut self, digest: String) raises -> List[UInt8]:
        """The bytes stored under `digest` (`sha256:<64 lowercase hex>`)."""
        ...


# =============================================================================
# §2 — DirOciLayout: a layout directory, e.g. the `oci_image` rule's output.
# =============================================================================


struct DirOciLayout(OciLayoutSource, Movable, Deinitable):
    """An OCI image layout DIRECTORY.

    Opening it checks the `oci-layout` marker file, so a wrong path fails
    here, naming the path, rather than later as a missing `index.json`.

    One owned `String` field. No pointer field."""

    var _root: String

    def __init__(out self, var root: String) raises:
        """Open the layout at `root`. RAISES unless `root/oci-layout` exists
        and names image-layout version 1.0.0."""
        var marker = root + String("/oci-layout")
        if not Path(marker).exists():
            raise Error(
                String("oci: '")
                + root
                + String(
                    "' is not an OCI image layout directory: it has no"
                    " 'oci-layout' file. Pass the oci_image rule's DEFAULT"
                    " output (the .oci directory), not its [docker_archive]"
                    " tar."
                )
            )
        var doc = parse_json_value(Path(marker).read_text())
        var version = String("")
        if doc.has(String("imageLayoutVersion")):
            version = doc.get(String("imageLayoutVersion")).as_string()
        if version != OCI_IMAGE_LAYOUT_VERSION:
            raise Error(
                String("oci: '")
                + marker
                + String("' names image-layout version '")
                + version
                + String("'; only '")
                + OCI_IMAGE_LAYOUT_VERSION
                + String("' is understood")
            )
        self._root = root^

    def index_json(mut self) raises -> List[UInt8]:
        var p = self._root + String("/index.json")
        if not Path(p).exists():
            raise Error(
                String("oci: the layout '")
                + self._root
                + String("' has an 'oci-layout' file but no 'index.json'")
            )
        return Path(p).read_bytes()

    def read_blob(mut self, digest: String) raises -> List[UInt8]:
        # The digest is validated BEFORE it becomes part of a path: 64
        # lowercase hex characters cannot name a parent directory, so a
        # descriptor in a hostile manifest cannot make this read outside
        # blobs/sha256/.
        validate_digest_format(digest, String("a layout descriptor"))
        var hex = String(digest[byte=7 : digest.byte_length()])
        var p = self._root + String("/blobs/sha256/") + hex
        if not Path(p).exists():
            raise Error(
                String("oci: the layout '")
                + self._root
                + String("' has no blob ")
                + digest
                + String(" (no file blobs/sha256/")
                + hex
                + String(")")
            )
        return Path(p).read_bytes()


# =============================================================================
# §3 — MemOciLayout: a layout held in memory.
# =============================================================================


struct MemOciLayout(OciLayoutSource, Movable, Deinitable):
    """An OCI image layout held in memory: an `index.json` and named blobs.

    Owned `List` fields only. No pointer field."""

    var _index: List[UInt8]
    var _names: List[String]
    var _blobs: List[List[UInt8]]

    def __init__(out self):
        self._index = List[UInt8]()
        self._names = List[String]()
        self._blobs = List[List[UInt8]]()

    def set_index_json(mut self, var index: List[UInt8]):
        self._index = index^

    def add_blob(mut self, var data: List[UInt8]) -> String:
        """Store `data` under its own digest and return that digest."""
        var digest = digest_of_bytes(Span(data))
        self.add_blob_named(digest.copy(), data^)
        return digest^

    def add_blob_named(mut self, var digest: String, var data: List[UInt8]):
        """Store `data` under `digest`, which need NOT be its content address.

        A layout whose names lie is exactly what the pusher must refuse, so
        the in-memory layout has to be able to hold one. A second store under
        the same name replaces the first, as overwriting a file would."""
        for i in range(len(self._names)):
            if self._names[i] == digest:
                self._blobs[i] = data^
                return
        self._names.append(digest^)
        self._blobs.append(data^)

    def index_json(mut self) raises -> List[UInt8]:
        if len(self._index) == 0:
            raise Error(String("oci: the in-memory layout has no index.json"))
        return self._index.copy()

    def read_blob(mut self, digest: String) raises -> List[UInt8]:
        for i in range(len(self._names)):
            if self._names[i] == digest:
                return self._blobs[i].copy()
        raise Error(
            String("oci: the in-memory layout has no blob ") + digest
        )
