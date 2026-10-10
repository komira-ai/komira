# =============================================================================
# komira_test_bucket/flags.mojo -- the runner-supplied flags, which store a
# test bucket runs against, and opening it from them.
# =============================================================================
#
# Configuration is flags. The test runner passes these, and this package
# reads nothing else (no environment variable, no configuration file):
#
#   --test-s3-endpoint=<url>              an external S3-compatible store:
#   --test-s3-region=<region>             all four, or none. The bucket must
#   --test-s3-bucket=<bucket>             already exist; it is never created
#   --test-s3-credentials-file=<path>     or deleted. The credentials file is
#                                         an AWS shared-credentials file: the
#                                         secret stays in it, never in argv
#                                         or the environment.
#   --test-minio-binary=<path>            a pinned MinIO binary the test
#                                         starts itself (komira_test_minio)
#   --test-target=<label>                 the test target, recorded in the
#                                         lease
#   --test-max-lease-seconds=<n>          a run's lease: creation + n
#                                         (default 5400, 90 minutes)
#   --test-teardown-budget-seconds=<n>    stop creating n seconds before the
#                                         deadline (default 120)
#
# Every run lives under `runs/<run_id>/`; there is no flag for it.
#
# The teardown default is 120 s: a close is two lists, at most two delete
# batches, a final list and, on an embedded MinIO, a stop with a 5 s grace
# and a directory removal. Two minutes covers that against a slow store with
# room to spare, and is 1/45 of the default lease, so a long test loses
# almost none of its time to the reserve.
#
# Other flags are left to the test. A flag in this family that is not one of
# the above (a misspelling, or a retired `--testinfra-*` spelling), a
# repeated one, one with an empty value, or a lease value that is not a whole
# number from 1 to 999999999 raises. The family is `--test-s3-*`,
# `--test-minio-*`, `--test-target*`, `--test-max-lease*`,
# `--test-teardown*` and the retired `--testinfra-*`; a test's own
# `--test-<other>` flags are left alone.
#
# Store choice:
#
#   all four --test-s3-* flags, valid          -> EXTERNAL_S3
#   some but not all --test-s3-* flags         -> CANNOT_TELL (exit 3), naming
#                                                each missing flag
#   --test-s3-* AND --test-minio-binary        -> CANNOT_TELL: the run asked
#                                                for two stores
#   an invalid --test-s3-* value, or a teardown
#   budget not below the lease                 -> CANNOT_TELL, naming the flag
#   --test-minio-binary alone                  -> EMBEDDED_MINIO
#   none of them (the default)                 -> SKIP (exit 77)
#
# A CANNOT_TELL is NEVER a fall back to the embedded MinIO: a run asked for
# something and did not get it. The default -- no flags -- needs nothing on
# the machine and SKIPS with a reason.
#
# ⛔ NO MESSAGE CARRIES A VALUE. A test's output can land in a public log, so
# every refusal names the FLAG and never what it holds. An unknown name that
# starts with a known (or retired) flag name -- a value glued on without `=`,
# e.g. `--test-s3-bucketmy-prod-bucket` -- shows only that flag name plus
# `with text glued on`; any other name not shaped like one is not echoed.
# An embedded MinIO that does not start is reported naming
# `--test-minio-binary`, never the path it holds.
#
# `exit_unless_runnable()` is how a test acts on the choice: it returns for
# EXTERNAL_S3 and EMBEDDED_MINIO and otherwise ENDS THE PROCESS (77 for
# SKIP, 3 for CANNOT_TELL). `exit_code()` is the same number as data, for a
# caller that reports it; a code returned to a caller can be dropped, and a
# dropped 77 followed by a return from `main` is exit 0, a pass.
#
#     var choice = select_backend(TestStoreFlags.from_process_args())
#     choice.exit_unless_runnable()
#     var bucket = open_test_bucket_from_flags(choice, mint_run_id(clock, entropy),
#                                              tmp_root, client^, runner^, entropy, clock)
# =============================================================================

from std.sys import argv

from komira_test_minio import EmbeddedMinio, ProcessRunner, start_embedded_minio
from komira_test_run_id import Entropy, RunId, WallClock
from komira_test_verdict import (
    CANNOT_TELL_EXIT_CODE,
    SKIP_EXIT_CODE,
    exit_cannot_tell,
    exit_skip,
)

from .bucket import TestBucket, _open_external, open_embedded_minio_bucket
from .store import ObjectStoreClient, StoreScope, StoreTarget

comptime FLAG_S3_ENDPOINT: String = "--test-s3-endpoint"
comptime FLAG_S3_REGION: String = "--test-s3-region"
comptime FLAG_S3_BUCKET: String = "--test-s3-bucket"
comptime FLAG_S3_CREDENTIALS_FILE: String = "--test-s3-credentials-file"
comptime FLAG_MINIO_BINARY: String = "--test-minio-binary"
comptime FLAG_TARGET: String = "--test-target"
comptime FLAG_MAX_LEASE_SECONDS: String = "--test-max-lease-seconds"
comptime FLAG_TEARDOWN_BUDGET_SECONDS: String = "--test-teardown-budget-seconds"

comptime DEFAULT_MAX_LEASE_SECONDS: Int = 5400
comptime DEFAULT_TEARDOWN_BUDGET_SECONDS: Int = 120

comptime BACKEND_CHOICE_EXTERNAL_S3: Int = 0
comptime BACKEND_CHOICE_EMBEDDED_MINIO: Int = 1
comptime BACKEND_CHOICE_SKIP: Int = 2
comptime BACKEND_CHOICE_CANNOT_TELL: Int = 3

comptime _P: String = "komira_test_bucket: "


def _in_family(name: String) -> Bool:
    """True for a flag this package owns or refuses: see the module header."""
    return (
        name.startswith("--test-s3-")
        or name.startswith("--test-minio-")
        or name.startswith("--test-target")
        or name.startswith("--test-max-lease")
        or name.startswith("--test-teardown")
        or name.startswith("--testinfra-")
    )


def _known_flags() -> List[String]:
    return [
        FLAG_S3_ENDPOINT,
        FLAG_S3_REGION,
        FLAG_S3_BUCKET,
        FLAG_S3_CREDENTIALS_FILE,
        FLAG_MINIO_BINARY,
        FLAG_TARGET,
        FLAG_MAX_LEASE_SECONDS,
        FLAG_TEARDOWN_BUDGET_SECONDS,
    ]


def _retired_flags() -> List[String]:
    """The retired spellings, for the same glued-value check: a runner
    passing `--testinfra-config/etc/x` must not have the path echoed."""
    return [
        "--testinfra-s3-config",
        "--testinfra-minio-binary",
        "--testinfra-target",
        "--testinfra-config",
        "--testinfra-local-minio",
    ]


def _glued_onto(name: String, known: List[String]) -> String:
    """The longest flag in `known` that `name` starts with and is longer
    than, else "". Such a `name` is that flag with text glued on without
    `=`, and the text is a VALUE: a bucket or region is made only of
    `[a-z0-9-]`, so the shape check in `_shown_flag` cannot catch it."""
    var best = String("")
    for k in known:
        if (
            name.byte_length() > k.byte_length()
            and name.startswith(k)
            and k.byte_length() > best.byte_length()
        ):
            best = String(k)
    return best^


def _shown_flag(name: String) -> String:
    """How an unknown `name` appears in a refusal. A name that starts with a
    known (or retired) flag name and is longer shows only that flag name
    plus `with text glued on`. Otherwise `name` when it is shaped like a
    flag name (`--` then lowercase letters, digits and `-`, at most 64
    bytes), else a placeholder: a value glued on without `=` must never be
    echoed."""
    var glued = _glued_onto(name, _known_flags())
    if glued.byte_length() == 0:
        glued = _glued_onto(name, _retired_flags())
    if glued.byte_length() > 0:
        return glued + " with text glued on (missing `=`?)"
    var b = name.as_bytes()
    var ok = len(b) > 2 and len(b) <= 64
    for i in range(len(b)):
        var c = Int(b[i])
        var lower = c >= ord("a") and c <= ord("z")
        var digit = c >= ord("0") and c <= ord("9")
        if not (lower or digit or c == ord("-")):
            ok = False
    if ok:
        return name
    return String("(a flag whose name is not shown: not shaped like a flag name)")


def _whole_seconds(name: String, value: String) raises -> Int:
    var b = value.as_bytes()
    var ok = len(b) > 0 and len(b) <= 9
    var v = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            ok = False
            break
        v = v * 10 + (c - ord("0"))
    if not ok or v == 0:
        raise Error(_P + name + ": expected a whole number from 1 to 999999999")
    return v


struct TestStoreFlags(Copyable, Movable):
    """The parsed flags. An empty string (or -1 for a number) means the flag
    was not given; an empty VALUE is refused at parse time, so the two
    cannot be confused. Not `Writable`: its fields are deployment facts."""

    var s3_endpoint: String
    var s3_region: String
    var s3_bucket: String
    var s3_credentials_file: String
    var minio_binary: String
    var target: String
    var max_lease_seconds: Int
    var teardown_budget_seconds: Int

    def __init__(out self):
        self.s3_endpoint = String("")
        self.s3_region = String("")
        self.s3_bucket = String("")
        self.s3_credentials_file = String("")
        self.minio_binary = String("")
        self.target = String("")
        self.max_lease_seconds = -1
        self.teardown_budget_seconds = -1

    @staticmethod
    def parse(args: List[String]) raises -> TestStoreFlags:
        """Parse `args` (the arguments after the program name)."""
        var out = TestStoreFlags()
        var seen = List[String]()
        for a in args:
            if not _in_family(a):
                continue
            var eq = a.find("=")
            var name = a if eq < 0 else String(a[byte=0:eq])
            if (
                name != FLAG_S3_ENDPOINT
                and name != FLAG_S3_REGION
                and name != FLAG_S3_BUCKET
                and name != FLAG_S3_CREDENTIALS_FILE
                and name != FLAG_MINIO_BINARY
                and name != FLAG_TARGET
                and name != FLAG_MAX_LEASE_SECONDS
                and name != FLAG_TEARDOWN_BUDGET_SECONDS
            ):
                if name.startswith("--testinfra-"):
                    raise Error(
                        _P
                        + "unknown flag "
                        + _shown_flag(name)
                        + " (the --testinfra-* flags are retired; use the --test-* flags)"
                    )
                raise Error(_P + "unknown flag " + _shown_flag(name))
            if eq < 0:
                raise Error(_P + name + " needs a value (" + name + "=<value>)")
            var value = String(a[byte = eq + 1 :])
            if value.byte_length() == 0:
                raise Error(_P + name + " has an empty value")
            for s in seen:
                if s == name:
                    raise Error(_P + name + " given more than once")
            seen.append(name)
            if name == FLAG_S3_ENDPOINT:
                out.s3_endpoint = value^
            elif name == FLAG_S3_REGION:
                out.s3_region = value^
            elif name == FLAG_S3_BUCKET:
                out.s3_bucket = value^
            elif name == FLAG_S3_CREDENTIALS_FILE:
                out.s3_credentials_file = value^
            elif name == FLAG_MINIO_BINARY:
                out.minio_binary = value^
            elif name == FLAG_TARGET:
                out.target = value^
            elif name == FLAG_MAX_LEASE_SECONDS:
                out.max_lease_seconds = _whole_seconds(name, value)
            else:
                out.teardown_budget_seconds = _whole_seconds(name, value)
        return out^

    @staticmethod
    def from_process_args() raises -> TestStoreFlags:
        """Parse this process's own command line (program name dropped)."""
        var args = List[String]()
        var all = argv()
        for i in range(1, len(all)):
            args.append(String(all[i]))
        return TestStoreFlags.parse(args)


struct BackendChoice(Copyable, Movable):
    """Which store to run against. `s3_target` is set only for EXTERNAL_S3,
    `minio_binary` only for EMBEDDED_MINIO, `reason` only for SKIP and
    CANNOT_TELL (flag names, never values). Not `Writable`."""

    var kind: Int
    var reason: String
    var target_label: String
    var s3_target: Optional[StoreTarget]
    var minio_binary: String
    var max_lease_seconds: Int
    var teardown_budget_seconds: Int

    def __init__(out self, kind: Int, var reason: String):
        self.kind = kind
        self.reason = reason^
        self.target_label = String("")
        self.s3_target = None
        self.minio_binary = String("")
        self.max_lease_seconds = DEFAULT_MAX_LEASE_SECONDS
        self.teardown_budget_seconds = DEFAULT_TEARDOWN_BUDGET_SECONDS

    def scope(self) raises -> StoreScope:
        """The external store and the lease limits. EXTERNAL_S3 only."""
        if self.kind != BACKEND_CHOICE_EXTERNAL_S3 or not self.s3_target:
            raise Error(_P + "scope(): the choice is not EXTERNAL_S3")
        return StoreScope(
            self.s3_target.value().copy(), self.max_lease_seconds, self.teardown_budget_seconds
        )

    def exit_code(self) -> Int:
        """3 for CANNOT_TELL, 77 for SKIP, 0 otherwise (the test runs)."""
        if self.kind == BACKEND_CHOICE_CANNOT_TELL:
            return CANNOT_TELL_EXIT_CODE
        if self.kind == BACKEND_CHOICE_SKIP:
            return SKIP_EXIT_CODE
        return 0

    def exit_unless_runnable(self):
        """Return for EXTERNAL_S3 and EMBEDDED_MINIO. Otherwise print the
        reason and end the process: SKIP through `exit_skip` (77),
        CANNOT_TELL through `exit_cannot_tell` (3)."""
        if self.kind == BACKEND_CHOICE_SKIP:
            exit_skip(self.reason)
        if self.kind == BACKEND_CHOICE_CANNOT_TELL:
            exit_cannot_tell(self.reason)


def _cannot_tell(var reason: String) -> BackendChoice:
    return BackendChoice(BACKEND_CHOICE_CANNOT_TELL, reason^)


def select_backend(flags: TestStoreFlags) -> BackendChoice:
    """Choose the store; see the module header for the table."""
    var s3_names: List[String] = [
        String(FLAG_S3_ENDPOINT),
        String(FLAG_S3_REGION),
        String(FLAG_S3_BUCKET),
        String(FLAG_S3_CREDENTIALS_FILE),
    ]
    var s3_values: List[String] = [
        flags.s3_endpoint,
        flags.s3_region,
        flags.s3_bucket,
        flags.s3_credentials_file,
    ]
    var missing = List[String]()
    for i in range(len(s3_values)):
        if s3_values[i].byte_length() == 0:
            missing.append(s3_names[i])
    var any_s3 = len(missing) < len(s3_names)
    var minio = flags.minio_binary.byte_length() > 0

    if any_s3 and minio:
        return _cannot_tell(
            String(
                "both an external S3-compatible store (--test-s3-*) and a MinIO binary"
                " (--test-minio-binary) were given; give one"
            )
        )
    if not any_s3 and not minio:
        return BackendChoice(
            BACKEND_CHOICE_SKIP,
            String(
                "no S3-compatible endpoint configured (--test-s3-endpoint,"
                " --test-s3-region, --test-s3-bucket, --test-s3-credentials-file) and no"
                " pinned MinIO binary given (--test-minio-binary)"
            ),
        )
    if any_s3 and len(missing) > 0:
        var msg = String("the --test-s3-* flags are all-or-none; missing ")
        for i in range(len(missing)):
            if i > 0:
                msg += ", "
            msg += missing[i]
        return _cannot_tell(msg^)
    if any_s3:
        if not (
            flags.s3_endpoint.startswith("http://") or flags.s3_endpoint.startswith("https://")
        ):
            return _cannot_tell(
                String(FLAG_S3_ENDPOINT) + ": must start with http:// or https://"
            )
        if not flags.s3_credentials_file.startswith("/"):
            return _cannot_tell(String(FLAG_S3_CREDENTIALS_FILE) + ": must be an absolute path")

    var lease = flags.max_lease_seconds
    if lease < 0:
        lease = DEFAULT_MAX_LEASE_SECONDS
    var teardown = flags.teardown_budget_seconds
    if teardown < 0:
        teardown = DEFAULT_TEARDOWN_BUDGET_SECONDS
    if teardown >= lease:
        return _cannot_tell(
            String(FLAG_TEARDOWN_BUDGET_SECONDS)
            + ": must be below "
            + FLAG_MAX_LEASE_SECONDS
            + " (defaults "
            + String(DEFAULT_TEARDOWN_BUDGET_SECONDS)
            + " and "
            + String(DEFAULT_MAX_LEASE_SECONDS)
            + ")"
        )

    var out: BackendChoice
    if any_s3:
        out = BackendChoice(BACKEND_CHOICE_EXTERNAL_S3, String(""))
        out.s3_target = StoreTarget(
            flags.s3_endpoint, flags.s3_region, flags.s3_bucket, flags.s3_credentials_file
        )
    else:
        out = BackendChoice(BACKEND_CHOICE_EMBEDDED_MINIO, String(""))
        out.minio_binary = flags.minio_binary
    out.target_label = flags.target
    out.max_lease_seconds = lease
    out.teardown_budget_seconds = teardown
    return out^


def open_test_bucket_from_flags[
    S: ObjectStoreClient, P: ProcessRunner, E: Entropy, C: WallClock
](
    choice: BackendChoice,
    run_id: RunId,
    tmp_root: String,
    var client: S,
    var runner: P,
    mut entropy: E,
    mut clock: C,
) raises -> TestBucket[S, P]:
    """Open this run's bucket on the store `choice` names. EXTERNAL_S3: the
    external store (`runner` is unused). EMBEDDED_MINIO: start the pinned
    MinIO under `tmp_root` with `runner`, then open on it; the handle owns
    the server. Any other choice raises: call `exit_unless_runnable()`
    first."""
    if choice.kind == BACKEND_CHOICE_EXTERNAL_S3:
        return _open_external[S, P, C](
            run_id, choice.scope(), choice.target_label, client^, clock
        )
    if choice.kind == BACKEND_CHOICE_EMBEDDED_MINIO:
        # komira_test_minio's messages carry no path; this names the flag
        # the binary came from, which that package cannot know.
        var server: EmbeddedMinio[P]
        try:
            server = start_embedded_minio(
                run_id, choice.minio_binary, tmp_root, runner^, entropy
            )
        except e:
            raise Error(
                _P + "the MinIO given by " + FLAG_MINIO_BINARY + " did not start: " + String(e)
            )
        return open_embedded_minio_bucket(
            run_id,
            server^,
            choice.target_label,
            choice.max_lease_seconds,
            choice.teardown_budget_seconds,
            client^,
            clock,
        )
    raise Error(
        _P
        + "open_test_bucket_from_flags: the choice is SKIP or CANNOT_TELL; call"
        " exit_unless_runnable() first"
    )
