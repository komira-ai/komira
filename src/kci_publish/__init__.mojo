"""`kci_publish` -- one PUBLISH step of a stage (`kci run --stage S`): publish
the release set a BUILD step left in
`<release-dir>/<platform>/` to a conda channel, or refuse it whole.

THE CONTRACT, IN ORDER. Step 0 checks the set before any request: every
declared artifact is in the release directory and nothing else is, each member
re-verified over its bytes by the SAME function a BUILD step ran
(`kci_release_set.verify_member`), lockstep against `--release-version`, the
requirement closure, and `release.json`'s set hash against the recomputation.
Step 1 reads the channel by DOWNLOAD (other bytes under one of our file names
stops the run) and reports every name the channel has never held (NEW NAMES):
which names a release publishes is its artifacts file's, never a per-run
claim. Steps 2 to 4 upload the
members still missing, read every member back, and only then publish the
metapackage; the missing members upload on up to `--concurrency` worker
threads. Step 6 is the step's part of the run's result document
(kci_api's `kci.result`): an outcome word, an error id, one artifact
row per file. The exit number is kci_api's: a release whose every file
is already in the channel with the same bytes is NOOP, exit 0.

The release is the one `--revision-id` names, built for the step's
platform: `release.json` must say both. For a channel that publishes with
OIDC trusted publishing the stage's GitHub environment must be the one its push
identity names. A dry run (`--plan`) writes nothing to the channel; under CI it
exchanges an OIDC channel's token and discards it, so the dry run proves the
trusted publisher accepts the job.

  * request.mojo          `PublishRequest` (the kci binary's one parser fills it)
  * release_version.mojo  the `--release-version` file
  * inputs.mojo           `load_release`: steps 0.1 and 0.2
  * verify.mojo           lockstep, closure (0.3, 0.4)
  * plan.mojo             targets, file states, step 1's verdict, new names
  * actions_env.mojo      `ActionsOidcEnv`: the runner's OIDC handshake
  * channel_state.mojo    step 1's reads (by download; name listings)
  * upload.mojo           the channel credential, steps 2 to 4, the workers
  * workers.mojo          what one more worker needs: transport, sleeper
  * index.mojo            step 5, report-only
  * report.mojo           the reasons, their outcomes, the result rows
  * run.mojo              `run_publish`: steps 1 to 6
  * flow.mojo             `publish_flow`, `publish_release_with_store`
  * lookahead.mojo        `read_new_names`, `lookahead_new_names`: a later
                          stage's NEW NAMES, read anonymously
  * summary.mojo          the NEW NAMES block of a job summary (markdown)
  * cell.mojo             `load_cell_release`: the release set of a PUBLISH
                          step into a cell, its images with the set's digest
  * scripted_channel.mojo `ScriptedChannel`, an in-memory channel (tests)
  * pause.mojo            `UsleepSleeper`, `NoWaitSleeper` (tests)

This package names no channel, account or organisation: all of that comes from
the files and flags it is given.

Encapsulation: owned values and generic seams. No UnsafePointer crosses a
module boundary; no wildcard origin; no unsafe_from_address.
"""

from .request import PublishRequest
from .actions_env import ActionsOidcEnv
from .release_version import ReleaseVersion, parse_release_version, read_release_version
from .inputs import LoadedRelease, load_release
from .verify import (
    guard_for_subdir,
    require_closure,
    require_conda_only,
    require_lockstep,
)
from .plan import (
    STATE_ABSENT,
    STATE_CANNOT_TELL,
    STATE_DIFFERENT,
    STATE_SAME,
    ChannelRead,
    FileState,
    PublishTarget,
    approved_names_for,
    build_number_of,
    is_held,
    new_names,
    plan_from_state,
    previous_build_number,
    RevisionHistory,
    backward_files,
    resolve_targets,
    superseding_files,
)
from .channel_state import read_channel, read_file_state
from .upload import PublishCredential, RunOptions, upload_members
from .workers import (
    DEFAULT_CONCURRENCY,
    MAX_CONCURRENCY,
    MIN_CONCURRENCY,
    ChannelTransport,
    HttpChannelTransport,
    WorkerSleeper,
)
from .report import (
    REASON_ALREADY_PUBLISHED,
    REASON_CANNOT_TELL,
    REASON_FAILED,
    REASON_PARTIAL,
    REASON_PUBLISHED,
    REASON_READ_BACK_MISMATCH,
    REASON_REFUSED,
    REASON_STOP_DIFFERENT_BYTES,
    FileRow,
    PublishReport,
    artifact_effect_of,
    record_publish_result,
)
from .run import run_publish
from .scripted_channel import ScriptedChannel
from .pause import NoWaitSleeper, UsleepSleeper
from .flow import NoSecretStore, PreparedRelease, publish_flow, publish_release_with_store
from .lookahead import NewNamesReport, lookahead_new_names, lookahead_new_names_https, new_names_of, read_new_names
from .summary import new_names_markdown
from .cell import CellImage, CellRelease, cell_images, load_cell_release
