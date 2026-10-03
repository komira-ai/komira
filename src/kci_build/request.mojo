# =============================================================================
# src/kci_build/request.mojo -- what a `kci build` run is asked to do, how it
#   ends, and the exit codes it ends with.
# =============================================================================
#
# Every input arrives in `BuildRequest`; nothing under kci_build reads the
# environment. The exit codes are kci publish's, so the two verbs of one
# binary mean the same thing by the same number:
#
#   0 OK          every declared artifact was built and verified, and
#                 `release.json` was written
#   2 USAGE       the flags are wrong; nothing was run
#   3 REFUSED     an input or a build's output breaks the contract
#                 (kci_release_set.verify_member); later artifacts not built
#   4 FAILED      a build exited non-zero, was killed by a signal or timed
#                 out; later artifacts not built
#   5 CANNOT_TELL a build could not be started at all: no verdict
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

comptime EXIT_OK: Int = 0
comptime EXIT_USAGE: Int = 2
comptime EXIT_REFUSED: Int = 3
comptime EXIT_FAILED: Int = 4
comptime EXIT_CANNOT_TELL: Int = 5

comptime DEFAULT_BUILD_TIMEOUT_S: Int = 3600
"""Per artifact."""


struct BuildRequest(Copyable, Movable):
    """The inputs of one run (see `flags.mojo` for the flag of each).

    Layout: owned values only. No pointer field."""

    var declarations_file: String
    var work_dir: String
    var out_dir: String
    var log_dir: String
    var revision_id: String
    var build_timeout_s: Int

    def __init__(out self):
        self.declarations_file = String("")
        self.work_dir = String("")
        self.out_dir = String("")
        self.log_dir = String("")
        self.revision_id = String("")
        self.build_timeout_s = DEFAULT_BUILD_TIMEOUT_S


struct BuildOutcome(Copyable, Movable):
    """How a run ended: its exit code, one message, and on success the
    lines to print (one per member, then `SET_HASH <hex>`) and the set hash.

    Layout: owned values only. No pointer field."""

    var exit_code: Int
    var message: String
    var lines: List[String]
    var set_hash: String

    def __init__(out self, exit_code: Int, var message: String):
        self.exit_code = exit_code
        self.message = message^
        self.lines = List[String]()
        self.set_hash = String("")

    def ok(self) -> Bool:
        return self.exit_code == EXIT_OK
