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
#   declarations_file     the artifact declarations (what the release is)
#   release_dir           --release-dir: the top release directory; this
#                         step reads `<release_dir>/<platform>/`
#                         (kci_contract's layout), which a BUILD step wrote
#   platform              the step's platform: must be the one
#                         `release.json` names
#   revision_id           --revision-id: a full commit id; must be the one
#                         `release.json` names (the set hash holds it too)
#   stage                 the stage this step runs in: for a channel that
#                         publishes with OIDC trusted publishing it must be
#                         the GitHub environment the channel's push identity
#                         names,
#                         and the OIDC token's `environment` claim is held
#                         to it
#   channels_file, channel  the channels file (kci_release_channel) and the
#                         channel to publish to
#   release_version_file  release_version.sh's stdout for the release commit
#   expect_set_hash       the set hash that was approved
#   claims                names this run may claim for the first time
#   concurrency           how many members upload at once, 1..16
#   plan                  `kci run --plan`: steps 0 and 1 only: reads, no
#                         write
#   run                   --run-id, --attempt, --context (kci_contract)
#
# ⛔ NO SECRET here: no field takes a token.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from kci_contract import RunIdentity, release_platform_dir

from .workers import DEFAULT_CONCURRENCY


struct PublishRequest(Copyable, Movable):
    """The inputs of one PUBLISH step (file header).

    Layout: owned values only. No pointer field."""

    var step_name: String
    var declarations_file: String
    var release_dir: String
    var platform: String
    var revision_id: String
    var stage: String
    var channels_file: String
    var channel: String
    var release_version_file: String
    var expect_set_hash: String
    var claims: List[String]
    var concurrency: Int
    var plan: Bool
    var run: RunIdentity

    def __init__(out self, var run: RunIdentity):
        self.step_name = String("")
        self.declarations_file = String("")
        self.release_dir = String("")
        self.platform = String("")
        self.revision_id = String("")
        self.stage = String("")
        self.channels_file = String("")
        self.channel = String("")
        self.release_version_file = String("")
        self.expect_set_hash = String("")
        self.claims = List[String]()
        self.concurrency = DEFAULT_CONCURRENCY
        self.plan = False
        self.run = run^

    def platform_dir(self) raises -> String:
        """`<release_dir>/<platform>`: the release directory this step
        reads."""
        return release_platform_dir(self.release_dir, self.platform)
