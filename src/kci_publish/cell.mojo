# =============================================================================
# src/kci_publish/cell.mojo -- the release set of a PUBLISH step into a
#   cell: the images it holds, each with the digest the set names for it.
# =============================================================================
#
# A PUBLISH step with `cells` and `cell` pushes the release set's images to
# the cell's registry (kci_cli cell_publish.mojo). `load_cell_release`
# (artifacts file, `<release-dir>/<platform>`, --revision-id, the step's
# platform, --release-set-hash) is everything checked before the cell is
# touched; it returns a `CellRelease` whose `error_id` is "" when the step
# may go on, and otherwise names the first refusal (outcome REFUSED):
#
#   KCI-E-ARTIFACT           the artifacts file does not read;
#   KCI-E-REVISION-MISMATCH  `release.json` names another revision (the
#                            image's tag is the revision, so an image built
#                            from another commit is never tagged with it);
#   KCI-E-PLATFORM-MISMATCH  `release.json` names another platform;
#   KCI-E-MEMBER             the release directory is refused member by
#                            member (`load_release`: every member re-verified
#                            by `kci_release_set.verify_member`, which for an
#                            image hashes every blob and ties the layout's
#                            manifest digest to the set), or the set holds no
#                            OCI member (nothing to push into a cell);
#   KCI-E-SET-HASH           the members recompute to another set hash than
#                            --release-set-hash (the set this run was
#                            handed).
#
# Each OCI member becomes a `CellImage`: its name (the repository under the
# cell's registry), its layout directory, and `digest`, `sha256:` + the hex
# its artifact manifest records: the digest the set hash carries. The push
# (`kci_publish_oci.publish_layout`) reads the layout a second time and
# compares its own read with that digest, so a layout that changed after
# this load is refused before anything is sent. Members of another type
# (a CONDA package built beside the image) are not a cell's: they are not
# returned, and `skipped` names them.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os.path import exists

from kci_artifact import read_artifacts
from kci_artifact_proto.artifact import Artifacts
from kci_api import (
    ERROR_ARTIFACT,
    ERROR_FORMAT,
    ERROR_MEMBER,
    ERROR_PLATFORM_MISMATCH,
    ERROR_REVISION_MISMATCH,
    ERROR_SET_HASH,
)
from kci_release_channel import ARTIFACT_TYPE_OCI
from kci_release_set.release_manifest import RELEASE_MANIFEST_NAME, ReleaseManifest, read_release_manifest

from .inputs import LoadedRelease, load_release


struct CellImage(Copyable, Movable):
    """One image of the release set (file header): its artifact `name`, its
    layout directory, its `platform` and `digest` (`sha256:<hex>`, the set's).

    Layout: owned values only. No pointer field."""

    var name: String
    var layout_dir: String
    var platform: String
    var digest: String

    def __init__(out self, var name: String, var layout_dir: String, var platform: String, var digest: String):
        self.name = name^
        self.layout_dir = layout_dir^
        self.platform = platform^
        self.digest = digest^


struct CellRelease(Copyable, Movable):
    """What `load_cell_release` found (file header): `error_id` "" and the
    images, or the first refusal's id and message. `set_hash` is the
    recomputed one when the set loaded.

    Layout: owned values only. No pointer field."""

    var error_id: String
    var message: String
    var set_hash: String
    var images: List[CellImage]
    var skipped: List[String]

    def __init__(out self):
        self.error_id = String("")
        self.message = String("")
        self.set_hash = String("")
        self.images = List[CellImage]()
        self.skipped = List[String]()

    def ok(self) -> Bool:
        return self.error_id.byte_length() == 0


def _refused(error_id: String, var message: String) -> CellRelease:
    var r = CellRelease()
    r.error_id = error_id.copy()
    r.message = message^
    return r^


def _slash(dir: String) -> String:
    if dir.endswith(String("/")):
        return dir.copy()
    return dir + String("/")


def cell_images(loaded: LoadedRelease) -> CellRelease:
    """The OCI members of `loaded`, each with the set's digest (file
    header); KCI-E-MEMBER when there is none."""
    var r = CellRelease()
    r.set_hash = loaded.set_hash()
    for i in range(len(loaded.members)):
        ref m = loaded.members[i]
        if m.manifest.artifact_type != ARTIFACT_TYPE_OCI:
            r.skipped.append(m.artifact.copy())
            continue
        r.images.append(
            CellImage(
                m.artifact.copy(),
                _slash(m.dir) + m.manifest.file,
                m.manifest.platform.copy(),
                String("sha256:") + m.manifest.sha256_hex,
            )
        )
    if len(r.images) == 0:
        return _refused(
            String(ERROR_MEMBER),
            String("the release set in '") + loaded.dir
            + String("' holds no OCI member: a PUBLISH step into a cell pushes images, and there is none to push"),
        )
    return r^


def load_cell_release(
    artifacts_file: String, dir: String, revision_id: String, platform: String, release_set_hash: String
) -> CellRelease:
    """Every check of a PUBLISH step into a cell before the cell is touched
    (file header). Never raises."""
    var arts: Artifacts
    try:
        arts = read_artifacts(artifacts_file)
    except e:
        return _refused(String(ERROR_ARTIFACT), String(e))
    var manifest_path = _slash(dir) + String(RELEASE_MANIFEST_NAME)
    if exists(manifest_path):
        var recorded: ReleaseManifest
        try:
            recorded = read_release_manifest(manifest_path)
        except e:
            return _refused(String(ERROR_FORMAT), String(e))
        if recorded.revision != revision_id:
            return _refused(
                String(ERROR_REVISION_MISMATCH),
                String("the release in '") + dir + String("' was built from revision ") + recorded.revision
                + String(", not --revision-id ") + revision_id
                + String(": an image is tagged with the revision it was built from"),
            )
        if recorded.platform != platform:
            return _refused(
                String(ERROR_PLATFORM_MISMATCH),
                String("the release in '") + dir + String("' is for platform ") + recorded.platform
                + String(", not this step's ") + platform,
            )
    var loaded: LoadedRelease
    try:
        loaded = load_release(arts, dir)
    except e:
        return _refused(String(ERROR_MEMBER), String(e))
    if loaded.set_hash() != release_set_hash:
        return _refused(
            String(ERROR_SET_HASH),
            String("the release directory recomputes to set hash ") + loaded.set_hash() + String(", not ")
            + release_set_hash + String(" (the set this run was handed): a cell receives only the bytes that were built"),
        )
    return cell_images(loaded)
