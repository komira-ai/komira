"""`kci_publish` -- the `kci publish` verb: publish built package files to a
release channel.

A run takes a channels file and a channel name (where), artifact manifests
(what), an approved-names file (which names may be claimed at all) and a
credential spec (as whom). It resolves every artifact to its channel
repository, checks each file against its manifest and every name against the
approved list, reads what the registry already holds, and plans each file as
UPLOAD, SKIP (already there, identical) or REFUSE. `--dry-run` stops there:
it prints the plan and resolves no credential. Otherwise the plan is carried
out with kci_pkg_upload, and every upload is read back.

  * flags.mojo    `parse_publish_flags` -> `PublishFlags`
  * manifest.mojo the artifact manifest and the approved-names file
  * plan.mojo     targets, the file and name checks, `plan_from_presence`
  * run.mojo      `plan_publish`, `run_publish`, the exit codes
  * pause.mojo    `UsleepSleeper`, the wait between read-back polls
  * cli.mojo      `publish_main` (the binary) and `publish_flow` (generic over
                  the transport, so tests drive the verb over scripted ones)

This package names no channel, account or organisation: all of that comes from
the files and flags it is given.

Encapsulation: owned values and generic seams. No UnsafePointer crosses a
module boundary; no wildcard origin; no unsafe_from_address.
"""

from .flags import (
    CREDENTIAL_OIDC,
    CREDENTIAL_TOKEN_FILE,
    CREDENTIAL_TOKEN_SECRET,
    PUBLISH_USAGE,
    PublishFlags,
    parse_publish_flags,
)
from .manifest import (
    ArtifactManifest,
    parse_approved_names,
    parse_artifact_manifest,
    read_approved_names,
    read_artifact_manifest,
)
from .plan import (
    ACTION_REFUSE,
    ACTION_SKIP,
    ACTION_UPLOAD,
    PlannedArtifact,
    PublishPlan,
    PublishTarget,
    plan_from_presence,
    refuse_unapproved_names,
    resolve_targets,
    verify_target_files,
)
from .run import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    PublishReport,
    RunOptions,
    plan_publish,
    render_plan,
    run_publish,
)
from .pause import UsleepSleeper
from .cli import NoSecretStore, publish_flow, publish_main, publish_main_with_store
