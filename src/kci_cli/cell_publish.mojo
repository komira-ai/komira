# =============================================================================
# src/kci_cli/cell_publish.mojo -- what `kci run` does for a PUBLISH step
#   into a cell (`cells` and `cell`, no channel): the release set's images
#   pushed to the cell's image registry, tagged with the revision.
# =============================================================================
#
# `cell_publish_step` is generic over the cloud adapter and the registry
# client (`[S: CloudAdapter, T: OciTransport & Copyable]`); it is reached
# through the `CellDeploys` seam (deploy_step.mojo), like a DEPLOY step, so
# the kci binary, built with no cloud (`NoCloudBuilt`), refuses every PUBLISH
# step into a cell at step 1. In order, each step stopping the PUBLISH:
#
#   1. THE CELL. The cells file (kci_cell), the step's `cell` in it, and the
#      cell's `cloud` through `Clouds.resolve`: a cells file or cell that
#      does not read is REFUSED (KCI-E-FORMAT); a cloud this kci was not
#      built with, or not the one this step runs on, is REFUSED
#      (KCI-E-CLOUD, "this kci was not built with that cloud").
#   2. THE RELEASE SET (kci_publish `load_cell_release`), before the cloud
#      is asked anything: the step's artifacts file, `release.json` naming
#      --revision-id and the step's platform, every member re-verified
#      (`verify_member`: an image's every blob hashed and its manifest digest
#      tied to the set), the set hash equal to --release-set-hash, and at
#      least one OCI member. Any refusal is REFUSED with its id. Only the
#      OCI members are pushed; a CONDA member built beside them is not a
#      cell's and is named in the summary.
#   3. THE CONTEXT AND THE CREDENTIALS, as a DEPLOY step's (deploy_step.mojo,
#      3 and 4): scope (machine file `name`, cell), provenance, the cell's
#      settings; `configure(ctx)`, `whoami`, `trust_check`. A finding is
#      REFUSED (KCI-E-CLOUD); a `whoami` or `trust_check` that raises is
#      FAILED, exit 4, nothing sent. The push identity is the cell's deploy
#      identity, which the trust check verifies.
#   4. THE REGISTRY. `image_registry(ctx)` is the cell's registry address,
#      computed from the cell and never written down a second time: its host
#      is the part before the first `/`, and each image goes to repository
#      `<the rest>/<artifact name>` (just `<artifact name>` when the address
#      is a bare host). Without `--plan`, `registry_login(creds)` is the
#      basic-auth user and secret the client presents; one that raises is
#      FAILED (KCI-E-CLOUD), nothing sent. The secret is never printed.
#   5. THE PUSH, image by image in artifacts-file order:
#      kci_publish_oci `publish_layout` with the SET'S DIGEST for the image.
#      It reads the layout a second time and refuses one whose manifest
#      digest is not the set's (KCI-E-MEMBER) before any request, under
#      `--plan` too; it tags the push with --revision-id, and komira_oci
#      reads it back (another digest served, or a tag that does not read
#      back, is INDETERMINATE, exit 5). Each image adds its artifact row.
#      The first image that does not end SUCCEEDED or NOOP stops the step;
#      when an earlier image of the step was uploaded, a REFUSED or FAILED
#      stop is PARTIAL (the registry changed).
#   6. THE OUTCOME. NOOP when every image's tag already named its bytes,
#      SUCCEEDED otherwise (and on every `--plan`, which sends nothing and
#      skips step 4's login). The row carries `cell` and `cloud`.
#
# Encapsulation: owned values and generic parameters; the registry client is
# copied into each push; no pointer, no wildcard origin.
# =============================================================================

from komira_oci.oci_auth import OciAuth
from komira_oci.oci_push import LayoutPusher
from komira_oci.oci_transport import OciRequest, OciResponse, OciTransport

from kci_reconciler import CellScope, Creds, Provenance
from kci_cloud import Catalog, CellContext, CloudAdapter, CloudId, Clouds, Finding, Setting, refusal_text
from kci_cell import Cell, CellSetting, find_cell, parse_cells_file
from kci_api import (
    ARTIFACT_UPLOADED,
    ERROR_CLOUD,
    ERROR_FORMAT,
    ERROR_USAGE,
    OUTCOME_FAILED,
    OUTCOME_NOOP,
    OUTCOME_PARTIAL,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    STEP_KIND_PUBLISH,
    ResultStep,
    release_platform_dir,
)
from kci_api import RunResult as KciRunResult
from kci_publish import load_cell_release
from kci_publish_oci import ImagePublish, publish_layout
from kci_release_machine import Stage, StageStep

from std.pathlib import Path

from .args import KciCommand
from .seam import StepEnd

comptime CELL_NOT_BUILT_WITH: String = "this kci was not built with that cloud"
"""The refusal of a cell whose cloud is not built into this kci (step 1);
the same words as a DEPLOY step's."""


struct CellPublishRequest(Copyable, Movable):
    """One PUBLISH step into a cell (file header): the step, the machine
    file's `name`, the cells file and the cell, the step's platform and
    artifacts file, the release directory and the set hash the run was
    handed, the run's provenance and `--plan`.

    Layout: owned values only. No pointer field."""

    var stage: String
    var step_name: String
    var machine: String
    var cells_file: String
    var cell: String
    var platform: String
    var artifacts_file: String
    var release_dir: String
    var release_set_hash: String
    var run_id: String
    var revision_id: String
    var plan: Bool

    def __init__(out self):
        self.stage = String("")
        self.step_name = String("")
        self.machine = String("")
        self.cells_file = String("")
        self.cell = String("")
        self.platform = String("")
        self.artifacts_file = String("")
        self.release_dir = String("")
        self.release_set_hash = String("")
        self.run_id = String("")
        self.revision_id = String("")
        self.plan = False


def cell_publish_request(cmd: KciCommand, machine: String, stage: Stage, step: StageStep) -> CellPublishRequest:
    """The request for PUBLISH step `step` (into a cell) of `stage`;
    `machine` is the machine file's `name`."""
    var req = CellPublishRequest()
    req.stage = stage.name.copy()
    req.step_name = step.name.copy()
    req.machine = machine.copy()
    req.cells_file = step.cells.copy()
    req.cell = step.cell.copy()
    req.platform = step.platform.copy()
    req.artifacts_file = step.artifacts.copy()
    req.release_dir = cmd.release_dir.copy()
    req.release_set_hash = cmd.release_set_hash.copy()
    req.run_id = cmd.run_id.copy()
    req.revision_id = cmd.revision_id.copy()
    req.plan = cmd.plan
    return req^


struct NoRegistryClient(OciTransport, Copyable, Movable, Deinitable):
    """The registry client of a kci built with no cloud: every request
    raises. It is never reached (step 1 refuses first); it fills
    `CloudDeploys`' registry parameter where no PUBLISH into a cell runs."""

    def __init__(out self):
        pass

    def send(mut self, var request: OciRequest) raises -> OciResponse:
        raise Error(String("this kci was built with no registry client"))


def registry_host_and_path(address: String) -> Tuple[String, String]:
    """`image_registry(ctx)` split at its first `/` (file header, 4): the
    host, and the path under it ("" for a bare host)."""
    var at = address.find(String("/"))
    if at < 0:
        return (address.copy(), String(""))
    return (String(address[byte=:at]), String(address[byte = at + 1 :]))


def _repository(path: String, name: String) -> String:
    if path.byte_length() == 0:
        return name.copy()
    return path + String("/") + name


struct _Ended(Movable):
    """How the step ends: an outcome, an error id and a message."""

    var outcome: String
    var error_id: String
    var message: String

    def __init__(out self, outcome: String, error_id: String, message: String):
        self.outcome = outcome.copy()
        self.error_id = error_id.copy()
        self.message = message.copy()


def cell_publish_markdown(step: String, row: ResultStep, images: List[ImagePublish], skipped: List[String], plan: Bool, message: String) -> String:
    """The step's summary block: the cell and its cloud, the outcome, each
    image's destination and effect, and the members not pushed."""
    var s = String("### PUBLISH step `") + step + String("`")
    if row.deploy.cell.byte_length() > 0:
        s += String(" into cell `") + row.deploy.cell + String("` (cloud `") + row.deploy.cloud + String("`)")
    s += String(": ") + row.outcome + String("\n\n")
    if message.byte_length() > 0:
        s += message + String("\n\n")
    if plan:
        s += String("Dry run (--plan): nothing was sent to the cell's registry.\n\n")
    for i in range(len(images)):
        ref a = images[i].artifact
        s += String("- image `") + a.name + String("` -> `") + a.file + String("` (") + a.effect + String(")\n")
    if len(skipped) > 0:
        s += String("- not pushed (not an image):")
        for i in range(len(skipped)):
            s += (String(" `") if i == 0 else String(", `")) + skipped[i] + String("`")
        s += String("\n")
    return s^


def _finish(
    var row: ResultStep, mut result: KciRunResult, ended: _Ended, images: List[ImagePublish], skipped: List[String],
    plan: Bool, changed: Bool,
) -> StepEnd:
    row.outcome = ended.outcome.copy()
    var end = StepEnd(ended.outcome.copy(), ended.error_id.copy(), ended.message.copy())
    end.changed_outside = changed
    end.summary = cell_publish_markdown(row.name, row, images, skipped, plan, ended.message)
    if ended.error_id.byte_length() > 0:
        try:
            result.set_error(ended.error_id.copy(), ended.message.copy())
        except e:
            end.lines.append(String("kci: ") + String(e))
    result.steps.append(row^)
    return end^


def _stop(var row: ResultStep, mut result: KciRunResult, outcome: String, error_id: String, message: String) -> StepEnd:
    return _finish(
        row^, result, _Ended(outcome, error_id, String("PUBLISH step (cell): ") + message), List[ImagePublish](),
        List[String](), False, False,
    )


def _load_cell(req: CellPublishRequest, clouds: Clouds, mut cell: Cell, mut resolved: CloudId, mut why: _Ended) -> Bool:
    """Step 1's reads (file header). False with `why` set when it stops."""
    var cells: List[Cell]
    try:
        cells = parse_cells_file(Path(req.cells_file).read_text())
        cell = find_cell(cells, req.cell)
    except e:
        why = _Ended(OUTCOME_REFUSED, ERROR_FORMAT, String("the cells file '") + req.cells_file + String("': ") + String(e))
        return False
    try:
        resolved = clouds.resolve(cell.cloud)
    except e:
        why = _Ended(
            OUTCOME_REFUSED, ERROR_CLOUD,
            String(CELL_NOT_BUILT_WITH) + String(": cell '") + cell.name + String("' names cloud '") + cell.cloud
            + String("' (") + String(e) + String(")"),
        )
        return False
    return True


def cell_publish_step[
    S: CloudAdapter, T: OciTransport & Copyable
](
    req: CellPublishRequest, clouds: Clouds, mut cloud: S, registry: T, creds: Creds, backoff_ms: Int,
    mut result: KciRunResult,
) -> StepEnd:
    """One PUBLISH step into a cell on the built-in cloud `cloud` (one of
    `clouds`), pushing through copies of `registry` with `creds` (file
    header). `backoff_ms` is komira_oci's sleep before a retry. Never
    raises."""
    var row = ResultStep(req.step_name.copy(), String(STEP_KIND_PUBLISH), req.platform.copy(), String(""))
    # 1. the cell
    var cell = Cell(String(""), String(""), List[CellSetting](), 0)
    var resolved = CloudId(String(""))
    var why = _Ended(String(""), String(""), String(""))
    if not _load_cell(req, clouds, cell, resolved, why):
        if cell.name.byte_length() > 0:
            row.deploy.cell = cell.name.copy()
            row.deploy.cloud = cell.cloud.copy()
        return _stop(row^, result, why.outcome, why.error_id, why.message)
    row.deploy.cell = cell.name.copy()
    row.deploy.cloud = cell.cloud.copy()
    if resolved != cloud.cloud_id():
        return _stop(
            row^, result, OUTCOME_REFUSED, ERROR_CLOUD,
            String(CELL_NOT_BUILT_WITH) + String(": cell '") + cell.name + String("' names cloud '") + cell.cloud
            + String("', and this step runs on '") + cloud.cloud_id().text() + String("'"),
        )
    # 2. the release set, before the cloud is asked anything
    var dir: String
    try:
        dir = release_platform_dir(req.release_dir, req.platform)
    except e:
        return _stop(row^, result, OUTCOME_REFUSED, ERROR_USAGE, String("--release-dir: ") + String(e))
    var release = load_cell_release(req.artifacts_file, dir, req.revision_id, req.platform, req.release_set_hash)
    if not release.ok():
        return _stop(row^, result, OUTCOME_REFUSED, release.error_id, release.message)
    # 3. the context and the credentials
    var settings = List[Setting]()
    for i in range(len(cell.settings)):
        settings.append(Setting(cell.settings[i].key.copy(), cell.settings[i].value.copy()))
    var scope = CellScope(req.machine, cell.name, Provenance(req.run_id, req.revision_id))
    var ctx = CellContext(scope^, settings^, bootstrap_level=cell.bootstrap_level)
    var found = cloud.configure(ctx)
    if len(found) > 0:
        return _stop(row^, result, OUTCOME_REFUSED, ERROR_CLOUD, refusal_text(cloud.cloud_id(), found))
    try:
        _ = cloud.whoami(creds)
    except e:
        return _stop(row^, result, OUTCOME_FAILED, ERROR_CLOUD, String("whoami raised before anything was sent: ") + String(e))
    var trust: List[Finding]
    try:
        trust = cloud.trust_check(creds, ctx.scope)
    except e:
        return _stop(
            row^, result, OUTCOME_FAILED, ERROR_CLOUD, String("trust_check raised before anything was sent: ") + String(e)
        )
    if len(trust) > 0:
        return _stop(row^, result, OUTCOME_REFUSED, ERROR_CLOUD, refusal_text(cloud.cloud_id(), trust))
    # 4. the registry
    var hp = registry_host_and_path(cloud.image_registry(ctx))
    var host = hp[0].copy()
    var path = hp[1].copy()
    var auth = OciAuth.basic(String(""), String(""))
    if not req.plan:
        try:
            var login = cloud.registry_login(creds)
            auth = OciAuth.basic(login.user.copy(), login.secret.copy())
        except e:
            return _stop(
                row^, result, OUTCOME_FAILED, ERROR_CLOUD,
                String("registry_login raised before anything was sent: ") + String(e),
            )
    # 5. the push, image by image
    var images = List[ImagePublish]()
    var changed = False
    var all_noop = True
    var ended = _Ended(String(OUTCOME_SUCCEEDED), String(""), String(""))
    for i in range(len(release.images)):
        ref img = release.images[i]
        var pusher = LayoutPusher[T](registry.copy(), auth.copy(), False, backoff_ms)
        var p = publish_layout(
            pusher, img.layout_dir, img.digest, host, _repository(path, img.name), req.revision_id, req.platform,
            req.plan,
        )
        result.artifacts.append(p.artifact.copy())
        if p.artifact.effect == String(ARTIFACT_UPLOADED):
            changed = True
        if p.outcome != String(OUTCOME_NOOP):
            all_noop = False
        if not p.ok():
            var outcome = p.outcome.copy()
            if changed and (outcome == OUTCOME_REFUSED or outcome == OUTCOME_FAILED):
                outcome = String(OUTCOME_PARTIAL)
            ended = _Ended(outcome, p.error_id, p.message)
            images.append(p^)
            return _finish(row^, result, ended, images, release.skipped, req.plan, changed)
        images.append(p^)
    # 6. the outcome
    if all_noop and not req.plan:
        ended = _Ended(String(OUTCOME_NOOP), String(""), String(""))
    return _finish(row^, result, ended, images, release.skipped, req.plan, changed)


def cell_publish_without_cloud(req: CellPublishRequest, mut result: KciRunResult) -> StepEnd:
    """A PUBLISH step into a cell on a kci built with no cloud (deploy_step.mojo
    `NoCloudBuilt`): REFUSED at step 1, before the release set is read."""
    var row = ResultStep(req.step_name.copy(), String(STEP_KIND_PUBLISH), req.platform.copy(), String(""))
    var clouds: Clouds
    try:
        clouds = Clouds(Catalog.v1())
    except e:
        return _stop(row^, result, OUTCOME_FAILED, ERROR_CLOUD, String("kci's catalog cannot be built: ") + String(e))
    var cell = Cell(String(""), String(""), List[CellSetting](), 0)
    var resolved = CloudId(String(""))
    var why = _Ended(String(OUTCOME_REFUSED), String(ERROR_CLOUD), String(CELL_NOT_BUILT_WITH))
    # an empty list of clouds resolves none, so this stops at the cloud
    _ = _load_cell(req, clouds, cell, resolved, why)
    if cell.name.byte_length() > 0:
        row.deploy.cell = cell.name.copy()
        row.deploy.cloud = cell.cloud.copy()
    return _stop(row^, result, why.outcome, why.error_id, why.message)
