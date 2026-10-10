# =============================================================================
# komira_job_supervisor/job_supervisor_config.mojo: the supervisor's
# configuration, from command-line flags.
# =============================================================================
#
# Every setting is a `--name=value` flag, parsed once at startup by
# `JobSupervisorConfig.from_args`. A required flag that is absent or empty is
# REFUSED naming the flag, before anything runs; an unknown flag, a flag given
# twice and a number that does not parse are refused the same way, so a typo
# never becomes a silent default. The supervisor reads no environment
# variable for its configuration.
#
#   --job-name=NAME             the job's name: sent in every heartbeat and
#                               the default object-key prefix for logs
#                               (REQUIRED)
#   --job-binary=PATH           the local path the job is spawned from
#                               (REQUIRED)
#   --heartbeat-url=URL         where heartbeats are POSTed, http:// or
#                               https:// (REQUIRED; no userinfo)
#   --instance-name=NAME        this supervisor instance's name, sent in every
#                               heartbeat (default: empty)
#   --job-arg=ARG               one argument for the job, repeatable, in order;
#                               everything after a bare `--` is appended too
#   --heartbeat-interval-secs=N seconds between RUNNING heartbeats (default 5)
#   --max-stderr-lines=N        stderr lines kept for failure forensics
#                               (default 100)
#   --max-stdout-bytes=N        stdout bytes kept in memory for logs.txt
#                               (default 8 MiB)
#   --binary-key=KEY            fetch the job binary from this key of the
#                               binary object store before spawning it
#                               (default: run the local --job-binary as is)
#   --binary-sha256=HEX         the downloaded binary's expected SHA-256
#                               (default: a 64-hex segment of the key, if any)
#   --binary-download-path=PATH where a fetched binary is written (default:
#                               --job-binary)
#   --log-prefix=PREFIX         object-key prefix for the log store's objects
#                               (default: --job-name)
#   --log-chunk-bytes=N         stream stdout in chunks of this size
#                               (default 64 KiB)
#   --log-flush-secs=N          ... or after this many seconds (default 10)
#   --max-runtime-secs=N        stop the job once it has run N seconds since
#                               its spawn (SIGTERM, a 5 s grace, SIGKILL) and
#                               report FAILED with a timeout message
#                               (default: no limit)
#
# Which object stores exist, and how the heartbeat is authenticated, is the
# embedding binary's choice; its own flags are passed through `from_args`'s
# `other_flags` so they are not refused as unknown.
#
# Owned String and plain-value fields only; no pointer type.
# =============================================================================

from komira_job_supervisor.heartbeat_client import parse_heartbeat_url

comptime FLAG_JOB_NAME: StaticString = "--job-name"
comptime FLAG_JOB_BINARY: StaticString = "--job-binary"
comptime FLAG_HEARTBEAT_URL: StaticString = "--heartbeat-url"
comptime FLAG_INSTANCE_NAME: StaticString = "--instance-name"
comptime FLAG_JOB_ARG: StaticString = "--job-arg"
comptime FLAG_HEARTBEAT_INTERVAL_SECS: StaticString = "--heartbeat-interval-secs"
comptime FLAG_MAX_STDERR_LINES: StaticString = "--max-stderr-lines"
comptime FLAG_MAX_STDOUT_BYTES: StaticString = "--max-stdout-bytes"
comptime FLAG_BINARY_KEY: StaticString = "--binary-key"
comptime FLAG_BINARY_SHA256: StaticString = "--binary-sha256"
comptime FLAG_BINARY_DOWNLOAD_PATH: StaticString = "--binary-download-path"
comptime FLAG_LOG_PREFIX: StaticString = "--log-prefix"
comptime FLAG_LOG_CHUNK_BYTES: StaticString = "--log-chunk-bytes"
comptime FLAG_LOG_FLUSH_SECS: StaticString = "--log-flush-secs"
comptime FLAG_MAX_RUNTIME_SECS: StaticString = "--max-runtime-secs"

comptime _DEFAULT_HEARTBEAT_SECS = 5
comptime _DEFAULT_STDERR_LINES = 100
comptime _DEFAULT_STDOUT_BYTES = 8 * 1024 * 1024
comptime _DEFAULT_CHUNK_BYTES = 64 * 1024
comptime _DEFAULT_FLUSH_SECS = 10


def job_supervisor_flag_names() -> List[String]:
    """Every flag `JobSupervisorConfig.from_args` reads."""
    var out = List[String]()
    out.append(String(FLAG_JOB_NAME))
    out.append(String(FLAG_JOB_BINARY))
    out.append(String(FLAG_HEARTBEAT_URL))
    out.append(String(FLAG_INSTANCE_NAME))
    out.append(String(FLAG_JOB_ARG))
    out.append(String(FLAG_HEARTBEAT_INTERVAL_SECS))
    out.append(String(FLAG_MAX_STDERR_LINES))
    out.append(String(FLAG_MAX_STDOUT_BYTES))
    out.append(String(FLAG_BINARY_KEY))
    out.append(String(FLAG_BINARY_SHA256))
    out.append(String(FLAG_BINARY_DOWNLOAD_PATH))
    out.append(String(FLAG_LOG_PREFIX))
    out.append(String(FLAG_LOG_CHUNK_BYTES))
    out.append(String(FLAG_LOG_FLUSH_SECS))
    out.append(String(FLAG_MAX_RUNTIME_SECS))
    return out^


# =============================================================================
# §1: flag scanning, shared with the embedding binary's own flag sets.
# =============================================================================
struct FlagValues(Movable):
    """The `--name=value` flags of one argument list, in order, plus every
    argument after a bare `--`. Built by `scan_flags`, which refuses anything
    that is not of that shape."""

    var names: List[String]
    var values: List[String]
    var trailing: List[String]

    def __init__(out self):
        self.names = List[String]()
        self.values = List[String]()
        self.trailing = List[String]()

    def count(self, name: String) -> Int:
        var n = 0
        for i in range(len(self.names)):
            if self.names[i] == name:
                n += 1
        return n

    def get(self, name: String) raises -> Optional[String]:
        """The value of a single-valued flag; None when absent. Given twice
        is refused."""
        if self.count(name) > 1:
            raise Error(
                String("job supervisor: ") + name + String(" given more than once")
            )
        for i in range(len(self.names)):
            if self.names[i] == name:
                return Optional[String](self.values[i])
        return None

    def all(self, name: String) -> List[String]:
        """Every value of a repeatable flag, in order."""
        var out = List[String]()
        for i in range(len(self.names)):
            if self.names[i] == name:
                out.append(self.values[i])
        return out^

    def require(self, name: String) raises -> String:
        """A flag that must be given with a non-empty value."""
        var v = self.get(name)
        if not v:
            raise Error(
                String("job supervisor: missing required flag ") + name + String("=")
            )
        if v.value().byte_length() == 0:
            raise Error(
                String("job supervisor: required flag ") + name + String(" is empty")
            )
        return v.value()

    def positive_int(self, name: String, default: Int) raises -> Int:
        """A flag holding a positive decimal integer; `default` when absent.
        Anything else (empty, a sign, a non-digit, zero) is refused."""
        var v = self.get(name)
        if not v:
            return default
        var s = v.value()
        var b = s.as_bytes()
        if len(b) == 0 or len(b) > 18:
            raise Error(
                String("job supervisor: ") + name + String(" is not a positive integer")
            )
        var n = 0
        for i in range(len(b)):
            var c = Int(b[i])
            if c < 0x30 or c > 0x39:
                raise Error(
                    String("job supervisor: ")
                    + name
                    + String(" is not a positive integer")
                )
            n = n * 10 + (c - 0x30)
        if n <= 0:
            raise Error(
                String("job supervisor: ") + name + String(" must be at least 1")
            )
        return n


def scan_flags(args: List[String], known: List[String]) raises -> FlagValues:
    """Split `args` (the program's arguments, WITHOUT the program name) into
    `--name=value` pairs. Refuses a bare word, a `--name` with no `=`, and a
    name not in `known`. Everything after a bare `--` is kept verbatim in
    `trailing`."""
    var out = FlagValues()
    var i = 0
    while i < len(args):
        ref a = args[i]
        if a == String("--"):
            for j in range(i + 1, len(args)):
                out.trailing.append(args[j])
            break
        if not a.startswith(String("--")):
            raise Error(
                String("job supervisor: unexpected argument '")
                + a
                + String("' (flags are --name=value; job arguments go after --)")
            )
        var eq = a.find(String("="))
        if eq < 0:
            raise Error(
                String("job supervisor: flag ")
                + a
                + String(" has no value (write ")
                + a
                + String("=VALUE)")
            )
        var b = a.as_bytes()
        var name = String(StringSlice(unsafe_from_utf8=b[0:eq]))
        var value = String(StringSlice(unsafe_from_utf8=b[eq + 1 : len(b)]))
        var is_known = False
        for k in range(len(known)):
            if known[k] == name:
                is_known = True
                break
        if not is_known:
            raise Error(String("job supervisor: unknown flag ") + name)
        out.names.append(name^)
        out.values.append(value^)
        i += 1
    return out^


# =============================================================================
# §2: JobSupervisorConfig.
# =============================================================================
struct JobSupervisorConfig(Movable):
    """The supervisor's configuration (module header for each flag).

      job_name             : the job's name (heartbeats, default log prefix).
      instance_name        : this supervisor instance's name (heartbeats).
      job_binary_path      : the local path the job is spawned from.
      job_argv             : argv[1:] for the job.
      heartbeat_url        : where the shipped HTTP reporter POSTs.
      heartbeat_interval_secs, max_stderr_lines, max_stdout_bytes.
      binary_key           : Some -> fetch the binary from the binary store.
      binary_sha256        : Some -> the fetched binary's expected digest.
      binary_download_path : where a fetched binary is written.
      log_prefix           : the log store's key prefix.
      log_chunk_bytes, log_flush_secs : the live stdout stream's chunking.
      max_runtime_secs     : seconds the job may run from its spawn; 0 is
                             no limit."""

    var job_name: String
    var instance_name: String
    var job_binary_path: String
    var job_argv: List[String]
    var heartbeat_url: String
    var heartbeat_interval_secs: Int
    var max_stderr_lines: Int
    var max_stdout_bytes: Int
    var binary_key: Optional[String]
    var binary_sha256: Optional[String]
    var binary_download_path: String
    var log_prefix: String
    var log_chunk_bytes: Int
    var log_flush_secs: Int
    var max_runtime_secs: Int

    def __init__(
        out self,
        var job_name: String,
        var instance_name: String,
        var job_binary_path: String,
        var job_argv: List[String],
        var heartbeat_url: String,
        heartbeat_interval_secs: Int = _DEFAULT_HEARTBEAT_SECS,
        max_stderr_lines: Int = _DEFAULT_STDERR_LINES,
        max_stdout_bytes: Int = _DEFAULT_STDOUT_BYTES,
        var binary_key: Optional[String] = None,
        var binary_sha256: Optional[String] = None,
        var binary_download_path: String = String(""),
        var log_prefix: String = String(""),
        log_chunk_bytes: Int = _DEFAULT_CHUNK_BYTES,
        log_flush_secs: Int = _DEFAULT_FLUSH_SECS,
        max_runtime_secs: Int = 0,
    ):
        """A config stated in code (tests, an embedding binary). A
        non-positive number takes that setting's default; an empty
        `binary_download_path` is `job_binary_path`; an empty `log_prefix`
        is `job_name`; a non-positive `max_runtime_secs` is no limit."""
        self.job_name = job_name^
        self.instance_name = instance_name^
        self.job_binary_path = job_binary_path^
        self.job_argv = job_argv^
        self.heartbeat_url = heartbeat_url^
        self.heartbeat_interval_secs = (
            heartbeat_interval_secs if heartbeat_interval_secs
            > 0 else _DEFAULT_HEARTBEAT_SECS
        )
        self.max_stderr_lines = (
            max_stderr_lines if max_stderr_lines > 0 else _DEFAULT_STDERR_LINES
        )
        self.max_stdout_bytes = (
            max_stdout_bytes if max_stdout_bytes > 0 else _DEFAULT_STDOUT_BYTES
        )
        self.binary_key = binary_key^
        self.binary_sha256 = binary_sha256^
        if binary_download_path.byte_length() > 0:
            self.binary_download_path = binary_download_path^
        else:
            self.binary_download_path = self.job_binary_path
        if log_prefix.byte_length() > 0:
            self.log_prefix = log_prefix^
        else:
            self.log_prefix = self.job_name
        self.log_chunk_bytes = (
            log_chunk_bytes if log_chunk_bytes > 0 else _DEFAULT_CHUNK_BYTES
        )
        self.log_flush_secs = (
            log_flush_secs if log_flush_secs > 0 else _DEFAULT_FLUSH_SECS
        )
        self.max_runtime_secs = max_runtime_secs if max_runtime_secs > 0 else 0

    def uses_binary_store(self) -> Bool:
        """True iff the binary is fetched from the binary store first."""
        return self.binary_key.__bool__()

    @staticmethod
    def from_args(
        args: List[String], other_flags: List[String] = List[String]()
    ) raises -> JobSupervisorConfig:
        """Parse the supervisor's flags out of `args` (the program's
        arguments without the program name). `other_flags` names flags the
        embedding binary reads itself; they are skipped here rather than
        refused as unknown."""
        var known = job_supervisor_flag_names()
        for i in range(len(other_flags)):
            known.append(other_flags[i])
        var f = scan_flags(args, known)

        var job_name = f.require(String(FLAG_JOB_NAME))
        var job_binary = f.require(String(FLAG_JOB_BINARY))
        var heartbeat_url = f.require(String(FLAG_HEARTBEAT_URL))
        # Refused here, naming the flag, rather than at the first beat.
        try:
            _ = parse_heartbeat_url(heartbeat_url)
        except e:
            raise Error(
                String("job supervisor: ")
                + String(FLAG_HEARTBEAT_URL)
                + String(" is not a usable http(s) URL: ")
                + String(e)
            )
        var instance = f.get(String(FLAG_INSTANCE_NAME))
        var instance_name = instance.value() if instance else String("")

        var argv = f.all(String(FLAG_JOB_ARG))
        for i in range(len(f.trailing)):
            argv.append(f.trailing[i])

        var binary_key = f.get(String(FLAG_BINARY_KEY))
        if binary_key and binary_key.value().byte_length() == 0:
            raise Error(
                String("job supervisor: ") + String(FLAG_BINARY_KEY) + " is empty"
            )
        var binary_sha = f.get(String(FLAG_BINARY_SHA256))
        if binary_sha and not is_sha256_hex(binary_sha.value()):
            raise Error(
                String("job supervisor: ")
                + String(FLAG_BINARY_SHA256)
                + " is not 64 lowercase hex characters"
            )
        var dl = f.get(String(FLAG_BINARY_DOWNLOAD_PATH))
        var log_prefix = f.get(String(FLAG_LOG_PREFIX))

        return JobSupervisorConfig(
            job_name^,
            instance_name^,
            job_binary^,
            argv^,
            heartbeat_url^,
            heartbeat_interval_secs=f.positive_int(
                String(FLAG_HEARTBEAT_INTERVAL_SECS), _DEFAULT_HEARTBEAT_SECS
            ),
            max_stderr_lines=f.positive_int(
                String(FLAG_MAX_STDERR_LINES), _DEFAULT_STDERR_LINES
            ),
            max_stdout_bytes=f.positive_int(
                String(FLAG_MAX_STDOUT_BYTES), _DEFAULT_STDOUT_BYTES
            ),
            binary_key=binary_key^,
            binary_sha256=binary_sha^,
            binary_download_path=dl.value() if dl else String(""),
            log_prefix=log_prefix.value() if log_prefix else String(""),
            log_chunk_bytes=f.positive_int(
                String(FLAG_LOG_CHUNK_BYTES), _DEFAULT_CHUNK_BYTES
            ),
            log_flush_secs=f.positive_int(
                String(FLAG_LOG_FLUSH_SECS), _DEFAULT_FLUSH_SECS
            ),
            max_runtime_secs=f.positive_int(String(FLAG_MAX_RUNTIME_SECS), 0),
        )


def is_sha256_hex(s: String) -> Bool:
    """True iff `s` is exactly 64 lowercase-hex characters."""
    var bytes = s.as_bytes()
    if len(bytes) != 64:
        return False
    for i in range(len(bytes)):
        var c = bytes[i]
        var is_digit = c >= UInt8(0x30) and c <= UInt8(0x39)
        var is_lower_hex = c >= UInt8(0x61) and c <= UInt8(0x66)
        if not (is_digit or is_lower_hex):
            return False
    return True
