# =============================================================================
# src/kci_build/request.mojo -- what a `kci build` run is asked to do, how it
#   ends, and the exit codes it ends with.
# =============================================================================
#
# Every input arrives in `BuildRequest`; nothing under kci_build reads the
# environment. The exit codes are kci publish's, so the two verbs of one
# binary mean the same thing by the same number:
#
#   0 OK          everything listed was built, checked and written out
#   2 USAGE       the flags are wrong; nothing was run
#   3 REFUSED     an input or an output breaks the contract; nothing copied
#   4 FAILED      buck2 ran and failed (or a copy failed)
#   5 CANNOT_TELL the farm could not be reached or asked: no verdict
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

comptime EXIT_OK: Int = 0
comptime EXIT_USAGE: Int = 2
comptime EXIT_REFUSED: Int = 3
comptime EXIT_FAILED: Int = 4
comptime EXIT_CANNOT_TELL: Int = 5

comptime MANIFEST_SUB_TARGET: String = "manifest"
"""The sub-target of a publishable target whose one output is its manifest."""

comptime FARM_FAULT_ATTEMPTS: Int = 3
"""How many times one target is rebuilt alone after a farm fault."""


struct BuildRequest(Copyable, Movable):
    """The inputs of one run (see `flags.mojo` for the flag of each).

    `buck2_config` holds `key=value` strings, each passed as `-c key=value`.
    `probe_nonce` makes the probe action's key new on every run, so the probe
    must execute on the farm: a cache hit would prove only the cache.

    Layout: owned values only. No pointer field."""

    var buck2_path: String
    var repo_root: String
    var publishable_file: String
    var only: List[String]
    var buck2_config: List[String]
    var target_platforms: String
    var probe_target: String
    var probe_timeout_s: Int
    var build_timeout_s: Int
    var probe_nonce: String
    var out_dir: String
    var log_dir: String

    def __init__(out self):
        self.buck2_path = String("")
        self.repo_root = String("")
        self.publishable_file = String("")
        self.only = List[String]()
        self.buck2_config = List[String]()
        self.target_platforms = String("")
        self.probe_target = String("")
        self.probe_timeout_s = 120
        self.build_timeout_s = 3600
        self.probe_nonce = String("")
        self.out_dir = String("")
        self.log_dir = String("")


struct BuildOutcome(Copyable, Movable):
    """How a run ended: its exit code, one message, and on success the
    manifests it wrote under `out_dir`.

    Layout: owned values only. No pointer field."""

    var exit_code: Int
    var message: String
    var manifests: List[String]

    def __init__(out self, exit_code: Int, var message: String):
        self.exit_code = exit_code
        self.message = message^
        self.manifests = List[String]()

    def ok(self) -> Bool:
        return self.exit_code == EXIT_OK
