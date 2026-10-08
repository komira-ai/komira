# Loads ./covso_traced.so and calls covso_one, then fails when a tracer is
# attached (TracerPid in /proc/self/status is not 0): green in the shared
# library's gate, red when kcov runs it (test 46). The red shows that kcov ran
# the driver, and that nothing of the shared library waits for that run.
from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./covso_traced.so")
    if lib.call["covso_one", Int32]() != 1:
        raise Error("covso_one() is not 1")
    var status = String("")
    with open(String("/proc/self/status"), "r") as f:
        status = f.read()
    # Split on "\n" only: the pinned Mojo's splitlines() also splits at the
    # tab after "TracerPid:".
    for line in status.split("\n"):
        var l = String(line)
        if l.startswith(String("TracerPid:")):
            var v = String(l.split(":")[1].strip())
            if v != String("0"):
                raise Error(String("covso_traced_driver: traced, TracerPid ") + v)
            return
    raise Error(String("covso_traced_driver: no TracerPid line in /proc/self/status"))
