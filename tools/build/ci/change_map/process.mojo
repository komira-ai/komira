"""One process, run to its end, its two streams captured separately.

The command line is built from quoted words (`quote`) and run with libc's
`system`; the streams go to two files. This file is the only place that does.
"""

from std.ffi import external_call
from std.os import getenv, remove
from std.pathlib import Path
from std.time import perf_counter_ns

from buildtools.bytes import substr


def quote(arg: String) -> String:
    """`arg` as one word of a POSIX shell command line."""
    var out = String("'")
    var start = 0
    for i in range(arg.byte_length()):
        if arg.as_bytes()[i] == UInt8(39):
            out += substr(arg, start, i) + String("'\\''")
            start = i + 1
    out += String(arg[byte=start:]) + String("'")
    return out^


struct Captured(Movable):
    """How a process ended and what it wrote."""

    var exit_code: Int
    var signaled: Bool
    var stdout: String
    var stderr: String

    def __init__(out self, exit_code: Int, signaled: Bool, var stdout: String, var stderr: String):
        self.exit_code = exit_code
        self.signaled = signaled
        self.stdout = stdout^
        self.stderr = stderr^

    def ok(self) -> Bool:
        return self.exit_code == 0 and not self.signaled


def run_captured(program: String, args: List[String]) raises -> Captured:
    """Run `program args...` to its end, its two streams in two files that
    are read back and removed. Every word is quoted, so no argument is read as
    shell syntax; the program is searched in PATH, and one that is not there
    ends with exit 127. Inherits the environment and the directory."""
    var dir = getenv("TMPDIR")
    if dir.byte_length() == 0:
        dir = String("/tmp")
    var stem = dir + String("/affected_") + String(Int(external_call["getpid", Int32]())) + String("_") + String(Int(perf_counter_ns()))
    var out_path = stem + String(".out")
    var err_path = stem + String(".err")
    var cmd = quote(program)
    for i in range(len(args)):
        cmd += String(" ") + quote(args[i])
    cmd += String(" </dev/null >") + quote(out_path) + String(" 2>") + quote(err_path)
    var status = Int(external_call["system", Int32](cmd.as_c_string_slice().unsafe_ptr()))
    if status < 0:
        raise Error(String("cannot start '") + program + String("'"))
    var out_text = String("")
    var err_text = String("")
    try:
        out_text = Path(out_path).read_text()
        err_text = Path(err_path).read_text()
    except e:
        raise Error(String("cannot read the output of '") + program + String("': ") + String(e))
    try:
        remove(out_path)
        remove(err_path)
    except:
        pass
    var signal = status & 0x7F
    return Captured((status >> 8) & 0xFF, signal != 0, out_text^, err_text^)


def lines_of(text: String) -> List[String]:
    """The non-empty lines of `text`."""
    var out = List[String]()
    var parts = text.split(String("\n"))
    for i in range(len(parts)):
        var line = String(parts[i])
        if line.endswith(String("\r")):
            line = substr(line, 0, line.byte_length() - 1)
        if line.byte_length() > 0:
            out.append(line)
    return out^
