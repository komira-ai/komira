# =============================================================================
# komira_gcp_core/sources.mojo -- where the credential chain reads from
# =============================================================================
#
# The Application Default Credentials chain (adc.mojo) reads the outside
# world through three seams, each a trait, as komira_aws_core's chain does:
#
#   EnvSource  -- environment variables. `ProcessEnv` calls getenv(3) through
#                 komira_libc's one `_read_env`; `MapEnv` is an in-memory
#                 map for tests (and for any caller that wants to hand the
#                 chain a fixed environment). It records every name read.
#   FileSource -- whole small files: a credentials file, the gcloud
#                 well-known file and the DMI product name. `ProcessFiles`
#                 reads the filesystem; `MapFiles` is a map.
#   WallClock  -- the wall clock, for a JWT's `iat` and `exp`.
#                 `SystemWallClock` reads the process's wall clock
#                 (komira_clock); `FixedWallClock` is a fixed instant.
#
# ⛔ This file is the ONLY file of komira_gcp_core that may read the process
# environment. A welded test (tests/test_env_source_only.mojo) scans every
# source of the package and fails on a getenv or `_read_env` anywhere else,
# and on an `env.get` of any name but the variables Google's own auth
# libraries read (adc.mojo names each, with the library that defines it).
# komira adds no environment variable of its own; komira settings are
# parameters.
#
# Values read here can be secrets (a key file's `private_key`, a refresh
# token). None of these types is `Writable`, and nothing here logs or echoes
# a value.
# =============================================================================

from std.collections import Dict
from std.os.path import exists, isfile, lexists

from komira_clock import now_unix_ms
from komira_libc.posix import _read_env


trait EnvSource:
    """Environment variables, read by name.

    An unset variable and an empty one both read as "": Google's Go auth
    library (`cloud.google.com/go/auth`, `credentials/detect.go` and
    `compute/metadata`) treats an empty value as unset."""

    def get(mut self, name: StaticString) -> String:
        ...


struct ProcessEnv(EnvSource, Movable, Deinitable):
    """The process environment, through komira_libc's one getenv."""

    def __init__(out self):
        pass

    def get(mut self, name: StaticString) -> String:
        return _read_env(name)


struct MapEnv(EnvSource, Movable, Deinitable):
    """A fixed environment held in memory. Records every name read, in
    order, so a test can assert exactly what the chain looked at."""

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
        """Whether `path` is a regular file (through any symlink)."""
        ...

    def present(mut self, path: String) -> Bool:
        """Whether anything is at `path`: a regular file, a directory, a
        broken symlink. Only read to say WHY a path that is not a regular
        file cannot be used."""
        ...

    def read(mut self, path: String) raises -> String:
        """The file's contents. Raises when it cannot be read; the message
        names the path, never the contents."""
        ...


struct ProcessFiles(FileSource, Movable, Deinitable):
    """The local filesystem."""

    def __init__(out self):
        pass

    def exists(mut self, path: String) -> Bool:
        return exists(path) and isfile(path)

    def present(mut self, path: String) -> Bool:
        return lexists(path)

    def read(mut self, path: String) raises -> String:
        try:
            with open(path, "r") as f:
                return f.read()
        except:
            raise Error("cannot read the file " + path)


struct MapFiles(FileSource, Movable, Deinitable):
    """Files held in memory, and paths holding something that is not a
    regular file (`put_other`: a directory, a broken symlink). Records every
    path asked about or read."""

    var files: Dict[String, String]
    var others: List[String]
    var reads: List[String]
    var probes: List[String]

    def __init__(out self):
        self.files = Dict[String, String]()
        self.others = List[String]()
        self.reads = List[String]()
        self.probes = List[String]()

    def put(mut self, path: String, contents: String):
        self.files[path] = contents

    def put_other(mut self, path: String):
        self.others.append(path)

    def exists(mut self, path: String) -> Bool:
        self.probes.append(path)
        return path in self.files

    def present(mut self, path: String) -> Bool:
        if path in self.files:
            return True
        for i in range(len(self.others)):
            if self.others[i] == path:
                return True
        return False

    def read(mut self, path: String) raises -> String:
        self.reads.append(path)
        var v = self.files.get(path)
        if v:
            return v.value()
        raise Error("cannot read the file " + path)


trait WallClock(Movable, Deinitable):
    """The wall clock, in whole seconds since the Unix epoch (UTC)."""

    def now_unix_seconds(mut self) -> Int64:
        ...


struct SystemWallClock(WallClock, Copyable, Movable, Deinitable):
    """The process's wall clock (`CLOCK_REALTIME`, komira_clock), read each
    time it is asked."""

    def __init__(out self):
        pass

    def now_unix_seconds(mut self) -> Int64:
        return Int64(Int(now_unix_ms() // 1000))


@fieldwise_init
struct FixedWallClock(WallClock, Copyable, Movable, Deinitable):
    """A clock stopped at one instant."""

    var unix_seconds: Int64

    def now_unix_seconds(mut self) -> Int64:
        return self.unix_seconds
