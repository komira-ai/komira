# Probe 3's program for LOG2: a built program and a Mojo shared library (its
# path is the argument ending in /liblog2probe.so), both linked with the
# holder archive. The program installs its configuration; the library must
# still read "not installed" (its own cells), then install its own; the
# program's stays installed.
from std.ffi import OwnedDLHandle
from std.sys import argv
from komira_log import EnvFilter, init_logging_with, is_installed
from p3util import report


def _lib_path() raises -> String:
    var args = argv()
    for i in range(len(args)):
        var a = String(args[i])
        if a.endswith("/liblog2probe.so"):
            return a
    raise Error("no argument names liblog2probe.so")


def main() raises:
    init_logging_with(EnvFilter(String("info")))
    var main_installed = is_installed()
    var lib = OwnedDLHandle(_lib_path())
    var lib_before = lib.call["probe3_log_installed", Int32]()
    lib.call["probe3_log_install", NoneType]()
    var lib_after = lib.call["probe3_log_installed", Int32]()
    var main_after = is_installed()
    var ok = main_installed and lib_before == 0 and lib_after == 1 and main_after
    _ = report(
        "log_one_engine_per_image",
        ok,
        "program installed " + String(main_installed) + "; library before its install " + String(lib_before) + ", after " + String(lib_after) + "; program after " + String(main_after),
    )
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
