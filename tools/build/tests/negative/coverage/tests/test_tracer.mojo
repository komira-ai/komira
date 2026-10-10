# Fails when a tracer is attached (TracerPid in /proc/self/status is not 0):
# green in the release gate, red when kcov runs it (test 43). The red shows
# that kcov traced the test and passed its exit status on.
from tracer import one
from std.testing import assert_equal


def main() raises:
    assert_equal(one(), 1, "the library value, read back")
    var status = String("")
    with open(String("/proc/self/status"), "r") as f:
        status = f.read()
    var found = False
    # Split on "\n" only: the pinned Mojo's splitlines() also splits at the
    # tab after "TracerPid:".
    for line in status.split("\n"):
        var l = String(line)
        if l.startswith(String("TracerPid:")):
            found = True
            var v = String(l.split(":")[1].strip())
            if v != String("0"):
                raise Error(String("test_tracer: traced, TracerPid ") + v)
    if not found:
        raise Error(String("test_tracer: no TracerPid line in /proc/self/status"))
