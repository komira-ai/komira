# =============================================================================
# komira_test_infra/seams.mojo -- the wall clock, the random source and the
# file reader the library runs on, each a trait so a test pins them.
# =============================================================================
#
# Real conformers: `SystemClock` (CLOCK_REALTIME through the package-private
# `_sys`), `UrandomEntropy` (/dev/urandom) and `ProcessFiles` (the local
# filesystem).
# Fakes: `FixedWallClock`, `ScriptedEntropy` and `MapFiles`.
#
# The entropy here names test resources (run ids, ports, a throwaway local
# server's root credential). It is not used to make anything a third party
# must not guess, except that throwaway credential, which never leaves the
# test's private temporary directory.
# =============================================================================

from std.collections import Dict
from std.os.path import exists, isfile

from ._sys import _clock_realtime_unix_seconds


trait WallClock(Movable, Deinitable):
    """Whole seconds since the Unix epoch. Creation times and deadlines are
    stamped from it."""

    def now_unix(mut self) -> Int:
        ...


trait Entropy(Movable, Deinitable):
    """Uniformly distributed 64-bit values. Raises when it cannot produce
    one; a caller never substitutes a constant."""

    def next_u64(mut self) raises -> UInt64:
        ...


struct SystemClock(WallClock):
    """The process's wall clock (`CLOCK_REALTIME`)."""

    def __init__(out self):
        pass

    def now_unix(mut self) -> Int:
        return _clock_realtime_unix_seconds()


struct FixedWallClock(WallClock):
    """A test clock: reads `now`, moves only when told to."""

    var now: Int

    def __init__(out self, now: Int):
        self.now = now

    def now_unix(mut self) -> Int:
        return self.now

    def advance(mut self, seconds: Int):
        self.now += seconds


struct UrandomEntropy(Entropy):
    """Reads `/dev/urandom`, eight bytes per value."""

    def __init__(out self):
        pass

    def next_u64(mut self) raises -> UInt64:
        var bytes: List[UInt8]
        try:
            with open("/dev/urandom", "r") as f:
                bytes = f.read_bytes(8)
        except:
            raise Error("entropy: cannot read /dev/urandom")
        if len(bytes) != 8:
            raise Error("entropy: short read from /dev/urandom")
        var v = UInt64(0)
        for i in range(8):
            v = (v << 8) | UInt64(bytes[i])
        return v


struct ScriptedEntropy(Entropy):
    """A test source: returns `values` in order, then raises. Running out is
    an error, so a test that draws more than it scripted fails loudly instead
    of repeating a value."""

    var values: List[UInt64]
    var drawn: Int

    def __init__(out self, var values: List[UInt64]):
        self.values = values^
        self.drawn = 0

    def next_u64(mut self) raises -> UInt64:
        if self.drawn >= len(self.values):
            raise Error(
                "ScriptedEntropy: script exhausted after "
                + String(self.drawn)
                + " values"
            )
        var v = self.values[self.drawn]
        self.drawn += 1
        return v


trait FileSource(Movable, Deinitable):
    """Small whole files, read by path."""

    def exists(mut self, path: String) -> Bool:
        ...

    def read(mut self, path: String) raises -> String:
        """The file's contents. Raises when it cannot be read; the message
        names the path, never the contents."""
        ...


struct ProcessFiles(FileSource):
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


struct MapFiles(FileSource):
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
