"""`kci_publish` -- the `kci publish` verb: publish the release set `kci build`
left in a release directory to a conda channel, or refuse it whole.

THE CONTRACT, IN ORDER. Step 0 checks the set before any request: every
declared artifact is in the release directory and nothing else is, each member
re-verified over its bytes by the SAME function `kci build` ran
(`kci_release_set.verify_member`), lockstep against `--release-version`, the
requirement closure, and the set hash against `--expect-set-hash`. Step 1 reads
the channel by DOWNLOAD (other bytes under one of our file names stops the run;
a name the channel has never held must be claimed). Steps 2 to 4 upload the
members still missing, read every member back, and only then publish the
metapackage. Step 6 writes one JSON report; the exit code says which verdict.

  * flags.mojo            `parse_publish_flags` -> `PublishFlags`
  * release_version.mojo  the `--release-version` file
  * inputs.mojo           `load_release`: steps 0.1 and 0.2
  * verify.mojo           lockstep, closure, set hash (0.3 to 0.5)
  * plan.mojo             targets, file states, step 1's verdict, claims
  * channel_state.mojo    step 1's reads (by download; name listings)
  * upload.mojo           the channel credential, steps 2 to 4
  * index.mojo            step 5, report-only
  * report.mojo           the report and the exit codes
  * run.mojo              `run_publish`: steps 1 to 6
  * cli.mojo              `publish_main` and `publish_flow`
  * scripted_channel.mojo `ScriptedChannel`, an in-memory channel (tests)
  * pause.mojo            `UsleepSleeper`

This package names no channel, account or organisation: all of that comes from
the files and flags it is given.

Encapsulation: owned values and generic seams. No UnsafePointer crosses a
module boundary; no wildcard origin; no unsafe_from_address.
"""

from .flags import PUBLISH_USAGE, PublishFlags, parse_publish_flags
from .release_version import ReleaseVersion, parse_release_version, read_release_version
from .inputs import LoadedRelease, load_release
from .verify import (
    guard_for_subdir,
    require_closure,
    require_conda_only,
    require_lockstep,
    require_set_hash,
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
    plan_from_state,
    resolve_targets,
)
from .channel_state import read_channel, read_file_state
from .upload import PublishCredential, RunOptions
from .report import (
    EXIT_ALREADY_PUBLISHED,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_PARTIAL,
    EXIT_PUBLISHED,
    EXIT_READ_BACK_MISMATCH,
    EXIT_REFUSED,
    EXIT_STOP_DIFFERENT_BYTES,
    EXIT_STOP_NEW_NAME,
    EXIT_USAGE,
    PublishReport,
    render_report,
)
from .run import run_publish
from .scripted_channel import ScriptedChannel
from .pause import UsleepSleeper
from .cli import NoSecretStore, publish_flow, publish_main, publish_main_with_store
