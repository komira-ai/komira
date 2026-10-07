# The installed-environment run test's program for a per_library archive
# (native_run.sh B1, BUCK :installed_log_run_test): komira_log as its conda
# package installs it, whose holder cells (lib/libkomira_log_holder.a, linked
# with -lkomira_log_holder) are this program's own, and whose other C
# (komira_libc's, komira_metrics') is libkomira_native.so.1's. Installing a
# filter stores its address in the holder; `is_installed` reads it back.
import komira_log as log
from komira_log import EnvFilter, init_logging_with, is_installed
from native_util import report


def main() raises:
    var before = is_installed()
    init_logging_with(EnvFilter(String("info")))
    var ok = report("komira_log_holder_install", not before and is_installed(), "installed before: " + String(before) + ", after: " + String(is_installed()))
    log.info["installed_log: a line through the installed komira_log", "installed_log"]()
    print("RESULT", "PASS" if ok else "FAIL", flush=True)
