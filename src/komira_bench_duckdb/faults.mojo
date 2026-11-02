# The page faults of a process, as the benchmark records them for the DuckDB
# child: the minor and major fault counts in `/proc/<pid>/stat`, read before
# and after a query. A fault count is a number the kernel keeps for the whole
# life of the process, so a query's faults are the difference of two readings.
# Where the platform has no such file the reading is absent, never zero.

from std.pathlib import Path


struct FaultCount(Copyable, Movable):
    """Minor and major page faults of a process, in total or as a difference."""

    var minor: Int64
    var major: Int64

    def __init__(out self, minor: Int64, major: Int64):
        self.minor = minor
        self.major = major

    def minus(self, earlier: FaultCount) -> FaultCount:
        """This reading less an `earlier` one: the faults between them."""
        return FaultCount(self.minor - earlier.minor, self.major - earlier.major)


# Fields of /proc/<pid>/stat counted from the one after the command name
# (state is the first of them): proc(5) numbers minflt as field 10 and majflt as
# field 12, and state as field 3.
comptime _MINFLT_AFTER_COMM: Int = 7
comptime _MAJFLT_AFTER_COMM: Int = 9


def _count_of(token: String) -> Int64:
    """The non-negative number `token` spells, or -1 when it is not one."""
    var b = token.as_bytes()
    if len(b) == 0 or len(b) > 18:
        return Int64(-1)
    var v = Int64(0)
    for i in range(len(b)):
        if b[i] < 0x30 or b[i] > 0x39:
            return Int64(-1)
        v = v * 10 + Int64(Int(b[i]) - 0x30)
    return v


def parse_stat_faults(text: String) -> Optional[FaultCount]:
    """The minor and major faults in the text of a `/proc/<pid>/stat` line, or
    nothing when the line is not one. The command name is in parentheses and may
    hold spaces and parentheses itself, so the fields are counted from the last
    closing parenthesis."""
    var b = text.as_bytes()
    var close = -1
    for i in range(len(b)):
        if b[i] == 0x29:
            close = i
    if close < 0:
        return Optional[FaultCount]()
    var fields = List[String]()
    var start = close + 1
    for i in range(close + 1, len(b) + 1):
        if i == len(b) or b[i] == 0x20 or b[i] == 0x0A:
            if i > start:
                fields.append(String(text[byte=start:i]))
            start = i + 1
    if len(fields) <= _MAJFLT_AFTER_COMM:
        return Optional[FaultCount]()
    var minor = _count_of(fields[_MINFLT_AFTER_COMM])
    var major = _count_of(fields[_MAJFLT_AFTER_COMM])
    if minor < 0 or major < 0:
        return Optional[FaultCount]()
    return Optional[FaultCount](FaultCount(minor, major))


def read_stat_faults(path: String) -> Optional[FaultCount]:
    """The faults in the stat file at `path`, or nothing when it cannot be read
    or is not a stat line (a process that has gone, a platform with no /proc)."""
    try:
        return parse_stat_faults(Path(path).read_text())
    except:
        return Optional[FaultCount]()
