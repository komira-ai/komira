# =============================================================================
# src/kci_publish_oci/arm.mojo -- the OCI image arm of a PUBLISH: push one
#   built OCI layout to a registry repository, tagged with the revision.
# =============================================================================
#
# `publish_layout(pusher, layout_dir, registry, repository, revision,
# platform, plan) -> ImagePublish` is a THIN arm over komira_oci's
# `LayoutPusher`: it states kci's checks and maps the push's end state onto
# kci_api's outcome words and error ids. The push itself (tag read
# first, blobs, manifest by digest, tag, read back, the bounded retries) is
# komira_oci's and is not restated here.
#
# Checks, each before any registry request:
#   1. `revision` is a full commit id (KCI-E-REVISION): THE TAG IS THE
#      REVISION, so an abbreviated id would be a tag that can never be fixed
#      on an immutable-tag registry.
#   2. `platform` is one kci releases (KCI-E-PLATFORM).
#   3. the layout at `layout_dir` reads and verifies (`read_oci_layout`
#      hashes every blob); a layout that does not is REFUSED
#      (KCI-E-IMAGE-PUSH).
#   4. the layout's own platform (its config's `os/arch`) is the step's
#      platform in OCI spelling (kci_api `oci_platform_of`), else
#      REFUSED (KCI-E-IMAGE-PLATFORM): an image for another CPU is never
#      tagged with this release's revision.
# Under `plan` the arm stops after these checks and sends NOTHING: the row is
# WOULD_UPLOAD and the outcome SUCCEEDED.
#
# The push's end state (komira_oci `PUSH_*`) maps onto kci's one exit table:
#
#   PUSH_UPLOADED, PUSH_TAG_ADDED  SUCCEEDED      0  effect UPLOADED
#   PUSH_NOOP                      NOOP           0  effect ALREADY_PRESENT
#                                                    (the tag already names
#                                                    these bytes: success)
#   PUSH_REFUSED                   REFUSED        3  KCI-E-IMAGE-PUSH
#   PUSH_FAILED                    FAILED         4  KCI-E-IMAGE-PUSH
#   PUSH_INDETERMINATE             INDETERMINATE  5  KCI-E-IMAGE-PUSH
#   PUSH_PARTIAL                   PARTIAL        6  KCI-E-IMAGE-PUSH, retry
#                                                    UNSAFE (usable by digest,
#                                                    the tag was not added)
#
# The error message carries `PushResult.detail`, which by komira_oci's
# contract holds no credential.
#
# NOT WIRED into `kci run`: an image step needs a cell (the repository a cell
# pushes to is derived when the cell is bootstrapped), which is the deploy
# side. A step kind for images, and the dispatch that calls this arm, come
# with it.
#
# Encapsulation: owned values; the pusher is borrowed `mut` for one call; no
# pointer, no wildcard origin.
# =============================================================================

from komira_oci.oci_layout_reader import OciLayout, read_oci_layout
from komira_oci.oci_push import (
    PUSH_FAILED,
    PUSH_INDETERMINATE,
    PUSH_NOOP,
    PUSH_PARTIAL,
    PUSH_REFUSED,
    PUSH_TAG_ADDED,
    PUSH_UPLOADED,
    LayoutPusher,
    PushResult,
    push_outcome_name,
)
from komira_oci.oci_transport import OciTransport

from kci_api import (
    ARTIFACT_ALREADY_PRESENT,
    ARTIFACT_NOT_REACHED,
    ARTIFACT_UPLOADED,
    ARTIFACT_WOULD_UPLOAD,
    ERROR_IMAGE_PLATFORM,
    ERROR_IMAGE_PUSH,
    ERROR_PLATFORM,
    ERROR_REVISION,
    OUTCOME_FAILED,
    OUTCOME_INDETERMINATE,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    STEP_KIND_PUBLISH,
    ResultArtifact,
    ResultStep,
    exit_code_of,
    oci_platform_of,
    require_full_commit_id,
    require_release_platform,
)
from kci_api import RunResult as KciRunResult

comptime ARTIFACT_TYPE_OCI: String = "OCI"
"""`artifacts[].artifact_type` of an image row: the one word kci spells an
image with, the value of `kci_release_channel`'s `ARTIFACT_TYPE_OCI`
(kci_publish_oci does not depend on that package)."""


struct ImagePublish(Copyable, Movable):
    """How one image push ended: a kci_api outcome word, an error id
    ("" on success), a message, and the image's artifact row.

    Layout: owned values only. No pointer field."""

    var outcome: String
    var error_id: String
    var message: String
    var artifact: ResultArtifact

    def __init__(out self, var outcome: String, var error_id: String, var message: String):
        self.outcome = outcome^
        self.error_id = error_id^
        self.message = message^
        self.artifact = ResultArtifact()
        self.artifact.artifact_type = String(ARTIFACT_TYPE_OCI)
        self.artifact.effect = String(ARTIFACT_NOT_REACHED)

    def ok(self) -> Bool:
        return self.outcome == OUTCOME_SUCCEEDED or self.outcome == OUTCOME_NOOP

    def exit_code(self) raises -> Int:
        """The exit number (kci_api's exit table)."""
        return exit_code_of(self.outcome, self.error_id)


def _refused(error_id: String, why: String) -> ImagePublish:
    return ImagePublish(String(OUTCOME_REFUSED), error_id.copy(), String("PUBLISH step (image): ") + why)


def _outcome_of(code: Int) -> String:
    if code == PUSH_UPLOADED or code == PUSH_TAG_ADDED:
        return String(OUTCOME_SUCCEEDED)
    if code == PUSH_NOOP:
        return String(OUTCOME_NOOP)
    if code == PUSH_REFUSED:
        return String(OUTCOME_REFUSED)
    if code == PUSH_PARTIAL:
        return String(OUTCOME_PARTIAL)
    if code == PUSH_INDETERMINATE:
        return String(OUTCOME_INDETERMINATE)
    return String(OUTCOME_FAILED)  # PUSH_FAILED, and any code komira_oci adds later


def _effect_of(code: Int) -> String:
    if code == PUSH_UPLOADED or code == PUSH_TAG_ADDED or code == PUSH_PARTIAL:
        return String(ARTIFACT_UPLOADED)
    if code == PUSH_NOOP:
        return String(ARTIFACT_ALREADY_PRESENT)
    return String(ARTIFACT_NOT_REACHED)


def _hex_of(digest: String) -> String:
    if digest.startswith(String("sha256:")):
        return String(digest[byte=7:])
    return digest.copy()


def _row(
    mut p: ImagePublish, layout: OciLayout, registry: String, repository: String, revision: String, platform: String
):
    p.artifact.name = repository.copy()
    p.artifact.file = registry + String("/") + repository + String("@") + layout.manifest_digest
    p.artifact.platform = platform.copy()
    p.artifact.revision = revision.copy()
    p.artifact.sha256 = _hex_of(layout.manifest_digest)


def publish_layout[T: OciTransport](
    mut pusher: LayoutPusher[T],
    layout_dir: String,
    registry: String,
    repository: String,
    revision: String,
    platform: String,
    plan: Bool,
) -> ImagePublish:
    """Push the OCI layout at `layout_dir` to `registry`/`repository`, tagged
    `revision` (file header). Never raises."""
    try:
        require_full_commit_id(String("--revision-id"), revision)
    except e:
        return _refused(String(ERROR_REVISION), String(e) + String(" (the image's tag is the revision)"))
    try:
        require_release_platform(platform)
    except e:
        return _refused(String(ERROR_PLATFORM), String(e))
    var want: String
    try:
        want = oci_platform_of(platform)
    except e:
        return _refused(String(ERROR_PLATFORM), String(e))
    var layout: OciLayout
    try:
        layout = read_oci_layout(layout_dir)
    except e:
        return _refused(String(ERROR_IMAGE_PUSH), String("the image layout is refused: ") + String(e))
    if layout.platform() != want:
        return _refused(
            String(ERROR_IMAGE_PLATFORM),
            String("the image layout '") + layout_dir + String("' is for ") + layout.platform()
            + String("; this step publishes ") + platform + String(" (") + want
            + String("). Nothing was sent."),
        )
    if plan:
        var p = ImagePublish(
            String(OUTCOME_SUCCEEDED),
            String(""),
            String("PUBLISH step (image): plan: would push ") + layout.manifest_digest + String(" to ")
            + registry + String("/") + repository + String(":") + revision + String("; nothing was sent"),
        )
        _row(p, layout, registry, repository, revision, platform)
        p.artifact.effect = String(ARTIFACT_WOULD_UPLOAD)
        return p^
    var r = pusher.push(layout, registry, repository, revision)
    var outcome = _outcome_of(r.outcome)
    var id = String("")
    var message = String("PUBLISH step (image): ") + push_outcome_name(r.outcome) + String(" ") + r.reference()
    if not r.is_success():
        id = String(ERROR_IMAGE_PUSH)
        message += String(": ") + r.detail
    var p = ImagePublish(outcome^, id^, message^)
    _row(p, layout, registry, repository, revision, platform)
    p.artifact.effect = _effect_of(r.outcome)
    return p^


def record_image_publish(
    p: ImagePublish, step_name: String, platform: String, mut result: KciRunResult
) raises:
    """Put this image step's part into the run's result document: its row
    (kind PUBLISH), the image's artifact row, and the first error."""
    result.steps.append(ResultStep(step_name.copy(), String(STEP_KIND_PUBLISH), platform.copy(), p.outcome.copy()))
    result.artifacts.append(p.artifact.copy())
    if p.error_id.byte_length() > 0:
        result.set_error(p.error_id.copy(), p.message.copy())
