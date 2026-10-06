# komira_log's holder accessors are visibility("hidden") by design (one
# engine per library; src/komira_log/engine/_log_holder_shim.c), so a shared
# object cannot export them. komira_log's Mojo code calls them by name; this
# program does the same, and must fail to link against libkomira_native.so.1.
from std.ffi import external_call


def main():
    var v = external_call["komira_log_holder_get", UInt]()
    print("RESULT komira_log_holder_get resolved, returned", v, flush=True)
