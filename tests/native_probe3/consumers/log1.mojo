# Probe 3's program for LOG1: komira_log's holder through the JIT object
# (`mojo run`, -lkomira_log_holder_jit) or the archive (`mojo build`,
# -lkomira_log_holder): install a configuration, read it back, log a line.
from komira_log import EnvFilter, info, init_logging_with, is_installed
from p3util import report


def main() raises:
    var before = is_installed()
    init_logging_with(EnvFilter(String("info")))
    var after = is_installed()
    info["probe3 LOG1 line"]()
    var ok = report("log_install_and_read", (not before) and after, "is_installed before " + String(before) + ", after " + String(after))
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
