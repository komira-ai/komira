# Calls the native symbol by name; the package itself carries no native code.
from std.ffi import external_call


def answer() -> Int64:
    return external_call["komira_probe_answer", Int64]()
