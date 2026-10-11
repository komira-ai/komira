# Loads ./covso_one.so, where the gate (and a coverage run) stages it, and
# calls covso_one (test 43).
from std.ffi import OwnedDLHandle


def main() raises:
    var lib = OwnedDLHandle("./covso_one.so")
    if lib.call["covso_one", Int32]() != 1:
        raise Error("covso_one() is not 1")
