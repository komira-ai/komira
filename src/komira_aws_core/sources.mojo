# =============================================================================
# komira_aws_core/sources.mojo -- where the credential chain reads from
# =============================================================================
#
# The credential and region chains read the outside world through exactly
# three seams, each a trait:
#
#   EnvSource   -- environment variables. `ProcessEnv` calls getenv(3) through
#                  komira_core_ffi's one `_read_env`; `MapEnv` is an in-memory
#                  map for tests (and for any caller that wants to hand the
#                  chain a fixed environment).
#   FileSource  -- whole small files: the shared config and credentials files
#                  and the token files they and the environment name.
#                  `ProcessFiles` reads the filesystem; `MapFiles` is a map.
#   AwsClock    -- the wall clock, for SigV4 signing time and the default role
#                  session name. `FixedClock` is a fixed instant. The
#                  production clock arrives with the transport.
#
# ⛔ This file is the ONLY file of komira_aws_core that may read the process
# environment. A welded test (tests/test_env_source_only.mojo) scans every
# source of the package and fails on a getenv or `_read_env` anywhere else, so
# the tests' `MapEnv` sees every read the chain makes.
#
# The chain reads only STANDARD AWS SDK variable names, each defined in the AWS
# SDKs and Tools Reference Guide and cited where it is read. komira adds no
# environment variable of its own; komira settings are parameters.
#
# Values read here can be secrets (AWS_SECRET_ACCESS_KEY, a token file). None
# of these types is `Writable`, and nothing here logs or echoes a value.
# =============================================================================

from std.collections import Dict
from std.os.path import exists, isfile

from komira_core_ffi.posix import _read_env


trait EnvSource:
    """Environment variables, read by name.

    An unset variable and an empty one both read as "": the AWS SDKs treat an
    empty value as unset.
    """

    def get(mut self, name: StaticString) -> String:
        ...


struct ProcessEnv(EnvSource, Movable):
    """The process environment, through komira_core_ffi's one getenv."""

    def __init__(out self):
        pass

    def get(mut self, name: StaticString) -> String:
        return _read_env(name)


struct MapEnv(EnvSource, Movable):
    """A fixed environment held in memory. Records every name read, in order,
    so a test can assert exactly what the chain looked at."""

    var values: Dict[String, String]
    var reads: List[String]

    def __init__(out self):
        self.values = Dict[String, String]()
        self.reads = List[String]()

    def set(mut self, name: String, value: String):
        self.values[name] = value

    def get(mut self, name: StaticString) -> String:
        var key = String(name)
        self.reads.append(key)
        var v = self.values.get(key)
        if v:
            return v.value()
        return String("")

    def was_read(self, name: String) -> Bool:
        for i in range(len(self.reads)):
            if self.reads[i] == name:
                return True
        return False


trait FileSource:
    """Small whole files, read by path."""

    def exists(mut self, path: String) -> Bool:
        ...

    def read(mut self, path: String) raises -> String:
        """The file's contents. Raises when it cannot be read; the message
        names the path, never the contents."""
        ...


struct ProcessFiles(FileSource, Movable):
    """The local filesystem."""

    def __init__(out self):
        pass

    def exists(mut self, path: String) -> Bool:
        return exists(path) and isfile(path)

    def read(mut self, path: String) raises -> String:
        try:
            with open(path, "r") as f:
                return f.read()
        except:
            raise Error("cannot read the file " + path)


struct MapFiles(FileSource, Movable):
    """Files held in memory. Records every path read."""

    var files: Dict[String, String]
    var reads: List[String]

    def __init__(out self):
        self.files = Dict[String, String]()
        self.reads = List[String]()

    def put(mut self, path: String, contents: String):
        self.files[path] = contents

    def exists(mut self, path: String) -> Bool:
        return path in self.files

    def read(mut self, path: String) raises -> String:
        self.reads.append(path)
        var v = self.files.get(path)
        if v:
            return v.value()
        raise Error("cannot read the file " + path)


trait AwsClock:
    """The wall clock, in whole seconds since the Unix epoch (UTC)."""

    def now_unix_seconds(mut self) -> Int:
        ...


@fieldwise_init
struct FixedClock(AwsClock, Copyable, Movable):
    """A clock stopped at one instant."""

    var unix_seconds: Int

    def now_unix_seconds(mut self) -> Int:
        return self.unix_seconds


def _two(mut out: String, v: Int):
    if v < 10:
        out += "0"
    out += String(v)


def amz_date_from_unix(unix_seconds: Int) raises -> String:
    """The SigV4 signing time "YYYYMMDDTHHMMSSZ" for a Unix time (UTC).

    Civil-from-days (proleptic Gregorian), valid from 1970 to 9999.
    """
    if unix_seconds < 0 or unix_seconds >= 253402300800:
        raise Error("the clock is outside 1970..9999")
    var days = unix_seconds // 86400
    var secs = unix_seconds % 86400
    var z = days + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    var out = String(y)
    _two(out, m)
    _two(out, d)
    out += "T"
    _two(out, secs // 3600)
    _two(out, (secs % 3600) // 60)
    _two(out, secs % 60)
    out += "Z"
    return out
