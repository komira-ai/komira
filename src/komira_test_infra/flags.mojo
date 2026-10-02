# =============================================================================
# komira_test_infra/flags.mojo -- the runner-supplied flags, and which backend
# a test runs against.
# =============================================================================
#
# The test runner passes at most three flags, and this library reads nothing
# else (no environment variable):
#
#   --testinfra-config=<path>      the TestInfraConfig file of a shared store
#   --testinfra-target=<label>     the test target, recorded in the lease
#   --testinfra-local-minio=<path> a pinned MinIO binary, for the local backend
#
# Other flags are left to the test. An unknown `--testinfra-*` flag, a
# repeated one, or one with an empty value raises (an empty value and an
# absent flag must not mean the same thing).
#
# Backend choice:
#
#   config flag given, file read and parsed   -> FARM (the shared store)
#   config flag given, unreadable or invalid  -> CANNOT_TELL (exit 3). NEVER a
#                                               fall back to local: a run
#                                               asked for the shared store
#                                               and did not get it.
#   no config flag, a MinIO path given        -> LOCAL
#   neither                                   -> SKIP (exit 77, see skip.mojo)
# =============================================================================

from std.sys import argv

from .config import TestInfraConfig, load_test_infra_config
from .seams import FileSource

comptime _FLAG_CONFIG: String = "--testinfra-config"
comptime _FLAG_TARGET: String = "--testinfra-target"
comptime _FLAG_LOCAL_MINIO: String = "--testinfra-local-minio"
comptime _FLAG_FAMILY: String = "--testinfra-"

comptime BACKEND_CHOICE_FARM: Int = 0
comptime BACKEND_CHOICE_LOCAL: Int = 1
comptime BACKEND_CHOICE_SKIP: Int = 2
comptime BACKEND_CHOICE_CANNOT_TELL: Int = 3


struct TestInfraFlags(Copyable, Movable):
    """The parsed flags. An empty string means the flag was not given (an
    empty VALUE is refused at parse time, so the two cannot be confused)."""

    var config_path: String
    var target: String
    var local_minio: String

    def __init__(out self):
        self.config_path = String("")
        self.target = String("")
        self.local_minio = String("")

    @staticmethod
    def parse(args: List[String]) raises -> TestInfraFlags:
        """Parse `args` (the arguments after the program name)."""
        var out = TestInfraFlags()
        var seen_config = False
        var seen_target = False
        var seen_minio = False
        for a in args:
            if not a.startswith(_FLAG_FAMILY):
                continue
            var eq = a.find("=")
            var name = a if eq < 0 else String(a[byte=0:eq])
            if name != _FLAG_CONFIG and name != _FLAG_TARGET and name != _FLAG_LOCAL_MINIO:
                raise Error("komira_test_infra: unknown flag " + name)
            if eq < 0:
                raise Error("komira_test_infra: " + name + " needs a value (" + name + "=<value>)")
            var value = String(a[byte = eq + 1 :])
            if value.byte_length() == 0:
                raise Error("komira_test_infra: " + name + " has an empty value")
            if name == _FLAG_CONFIG:
                if seen_config:
                    raise Error("komira_test_infra: " + name + " given more than once")
                seen_config = True
                out.config_path = value^
            elif name == _FLAG_TARGET:
                if seen_target:
                    raise Error("komira_test_infra: " + name + " given more than once")
                seen_target = True
                out.target = value^
            else:
                if seen_minio:
                    raise Error("komira_test_infra: " + name + " given more than once")
                seen_minio = True
                out.local_minio = value^
        return out^

    @staticmethod
    def from_process_args() raises -> TestInfraFlags:
        """Parse this process's own command line (program name dropped)."""
        var args = List[String]()
        var all = argv()
        for i in range(1, len(all)):
            args.append(String(all[i]))
        return TestInfraFlags.parse(args)


struct BackendChoice(Copyable, Movable):
    """Which backend to run against; `config` is set only for FARM, `reason`
    only for SKIP and CANNOT_TELL (field names, never values)."""

    var kind: Int
    var reason: String
    var config: Optional[TestInfraConfig]

    def __init__(out self, kind: Int, var reason: String, var config: Optional[TestInfraConfig]):
        self.kind = kind
        self.reason = reason^
        self.config = config^

    def exit_code(self) -> Int:
        """3 for CANNOT_TELL, 77 for SKIP, 0 otherwise (the test runs)."""
        if self.kind == BACKEND_CHOICE_CANNOT_TELL:
            return 3
        if self.kind == BACKEND_CHOICE_SKIP:
            return 77
        return 0


def select_backend[F: FileSource](flags: TestInfraFlags, mut files: F) -> BackendChoice:
    """Choose the backend; see the module header for the table."""
    if flags.config_path.byte_length() > 0:
        try:
            var cfg = load_test_infra_config(flags.config_path, files)
            return BackendChoice(BACKEND_CHOICE_FARM, String(""), Optional(cfg^))
        except e:
            return BackendChoice(BACKEND_CHOICE_CANNOT_TELL, String(e), None)
    if flags.local_minio.byte_length() > 0:
        return BackendChoice(BACKEND_CHOICE_LOCAL, String(""), None)
    return BackendChoice(
        BACKEND_CHOICE_SKIP,
        String(
            "no shared store configured (--testinfra-config) and no pinned MinIO"
            " given (--testinfra-local-minio)"
        ),
        None,
    )
