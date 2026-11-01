# Written by kci: the native install check `load` (row 4 of docs/design/native_packaging.md).
# Each installed shared library is opened with RTLD_NOW, so an undefined symbol fails at load.
from std.ffi import OwnedDLHandle, RTLD


def main() raises:
    var paths: List[String] = [
        String("/env/lib/libkomira_example_native.so.1")
    ]
    var failed = 0
    for i in range(len(paths)):
        try:
            _ = OwnedDLHandle(paths[i], RTLD.NOW | RTLD.LOCAL)
            print("LOADED " + paths[i])
        except e:
            failed += 1
            print("FAILED " + paths[i] + ": " + String(e))
    if failed > 0:
        raise Error(String(failed) + " of " + String(len(paths)) + " shared libraries did not load")
