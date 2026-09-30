# The same program is built as an executable and as a bundle (launcher +
# lib<name>.so); tests//functional/bundle_parity:parity runs both and compares stdout, stderr
# and exit status byte for byte. argv[1] picks what it exercises.
from std.ffi import external_call
from std.os import getenv
from std.sys import argv, exit


def _self_exe() -> String:
    var link = String("/proc/self/exe")
    var buf = List[UInt8]()
    for _ in range(4096):
        buf.append(UInt8(0))
    var n = external_call["readlink", Int](
        link.as_c_string_slice().unsafe_ptr(), buf.unsafe_ptr(), UInt(4095)
    )
    var out = String("")
    for i in range(n):
        out += chr(Int(buf[i]))
    return out^


def _parent(p: String) -> String:
    var i = p.rfind("/")
    return String(p[byte=:i]) if i > 0 else String("/")


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("probe: no mode")
        return
    var mode = String(args[1])
    if mode == "args":
        for i in range(len(args)):
            print(i, "[" + String(args[i]) + "]")
    elif mode == "env":
        print("env=[" + getenv("KOMIRA_PROBE_ENV", "<unset>") + "]")
    elif mode == "exit3":
        print("before exit")
        exit(3)
    elif mode == "raise":
        print("before raise")
        raise Error("probe raised on purpose")
    elif mode == "buffered":
        for i in range(3000):
            print("line", i)
    elif mode == "abort":
        print("before abort")
        external_call["abort", NoneType]()
    elif mode == "segv":
        print("before SIGSEGV")
        _ = external_call["raise", Int32](Int32(11))
    elif mode == "data":
        var root = _parent(_parent(_self_exe()))
        with open(root + "/share/probe.txt", "r") as f:
            print("data=[" + f.read() + "]")
    else:
        print("probe: unknown mode", mode)
        exit(2)
