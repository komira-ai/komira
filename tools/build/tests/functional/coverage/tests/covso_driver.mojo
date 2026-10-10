# The driver of covso (test 43): loads ./covso.so, where the gate (and a
# coverage run) stages it, and calls covso_scale only.
from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./covso.so")
    var got = lib.call["covso_scale", Int32](Int32(3))
    if got != 7:
        raise Error("covso_scale(3) = " + String(got))
