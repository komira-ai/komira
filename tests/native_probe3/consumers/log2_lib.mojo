# Probe 3's Mojo shared library for LOG2, linked with -lkomira_log_holder (the
# archive): its own holder cells, read and installed through these exports.
from komira_log import EnvFilter, init_logging_with, is_installed


@export
def probe3_log_installed() abi("C") -> Int32:
    return Int32(1) if is_installed() else Int32(0)


@export
def probe3_log_install() abi("C"):
    init_logging_with(EnvFilter(String("info")))
