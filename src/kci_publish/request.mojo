# =============================================================================
# src/kci_publish/request.mojo -- what one PUBLISH step of a stage is asked
#   to do.
# =============================================================================
#
# Every input arrives in `PublishRequest`; nothing under kci_publish parses a
# command line (the kci binary's one parser builds the request from its
# flags and the machine file's PUBLISH step):
#
#   step_name             the step's name in the machine file (the result's
#                         `steps[].name`)
#   artifacts_file     the artifacts (what the release is)
#   release_dir           --release-dir: the top release directory; this
#                         step reads `<release_dir>/<platform>/`
#                         (kci_api's layout), which a BUILD step wrote
#   platform              the step's platform: must be the one
#                         `release.json` names
#   revision_id           --revision-id: a full commit id; must be the one
#                         `release.json` names (the set hash holds it too)
#   stage                 the stage this step runs in (the result's
#                         `new_names[].stage`)
#   environment           the stage's GitHub environment (the machine file's
#                         `environment`, by default the stage's name; ""
#                         here means the stage's name). For a channel that
#                         publishes with OIDC trusted publishing it must be
#                         the environment the channel's push identity names,
#                         and the OIDC token's `environment` claim is held to
#                         it
#   channels_file, channel  the channels file (kci_release_channel) and the
#                         channel to publish to
#   release_version_file  release_version.sh's stdout for the release commit
#   concurrency           how many members upload at once, 1..16
#   never_backward        the run never publishes a lower build number
#                         than its channel lists, nor a build its
#                         channel's newest one descends from (run.mojo;
#                         kci_cli sets it for a push to main, and for a
#                         stage without `break_glass` on any run)
#   main_line_only        never_backward counts only the channel's
#                         main-line builds (plan.mojo `main_line_files`;
#                         kci_cli sets it for a `break_glass` stage, whose
#                         channel also takes break-glass builds)
#   revision_history      what never_backward holds the channel to: the
#                         revision's history and main's (kci_cli reads them
#                         with git)
#   break_glass           the run is BREAK-GLASS (kci_cli: any run but a
#                         push to main): an OIDC channel's
#                         `break_glass_push_identity` is the trusted
#                         publisher, and `environment` is the stage's
#                         `break_glass_environment` (flow.mojo)
#   plan                  `kci run --plan`: no write to the channel; under
#                         CI, an OIDC channel's token is exchanged and
#                         discarded (flow.mojo)
#   run                   --run-id, --attempt, --context (kci_api)
#
# Which names the release publishes is the artifacts file's: there is no
# per-run claim and no approved-set input. A name new to the channel is
# reported (`new_names`), never refused.
#
# ⛔ NO SECRET here: no field takes a token.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_api import RunIdentity, release_platform_dir

from .plan import RevisionHistory
from .workers import DEFAULT_CONCURRENCY


struct PublishRequest(Copyable, Movable):
    """The inputs of one PUBLISH step (file header).

    Layout: owned values only. No pointer field."""

    var step_name: String
    var artifacts_file: String
    var release_dir: String
    var platform: String
    var revision_id: String
    var stage: String
    var environment: String
    var channels_file: String
    var channel: String
    var release_version_file: String
    var concurrency: Int
    var never_backward: Bool
    var main_line_only: Bool
    var revision_history: RevisionHistory
    var break_glass: Bool
    var plan: Bool
    var run: RunIdentity

    def __init__(out self, var run: RunIdentity):
        self.step_name = String("")
        self.artifacts_file = String("")
        self.release_dir = String("")
        self.platform = String("")
        self.revision_id = String("")
        self.stage = String("")
        self.environment = String("")
        self.channels_file = String("")
        self.channel = String("")
        self.release_version_file = String("")
        self.concurrency = DEFAULT_CONCURRENCY
        self.never_backward = False
        self.main_line_only = False
        self.revision_history = RevisionHistory()
        self.break_glass = False
        self.plan = False
        self.run = run^

    def github_environment(self) -> String:
        """The stage's GitHub environment: `environment`, or the stage's
        name when it is "" (the machine file's default)."""
        if self.environment.byte_length() > 0:
            return self.environment.copy()
        return self.stage.copy()

    def platform_dir(self) raises -> String:
        """`<release_dir>/<platform>`: the release directory this step
        reads."""
        return release_platform_dir(self.release_dir, self.platform)
