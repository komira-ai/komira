# The channel a worker is given (proxy/channel.c: kudfw_channel_open, then
# kudfw_request and kudfw_spawn over it), read through proxy/channel_probe.c
# with no worker process, on the system the test runs on: on Linux a
# SOCK_CLOEXEC socket pair and a memfd; on macOS a socket pair marked with
# fcntl and an unlinked file in the scratch directory. It starts no worker,
# so it needs nothing staged beside it.
#
# What it proves, and the defect each part catches:
#   - both ends of the socket pair and the cancel file are close-on-exec (a
#     worker started by another engine thread would hold this channel's end
#     open, so this worker's end of file would never come).
#   - the cancel file is 4096 bytes and has no name in the file system
#     (a file left behind in the scratch directory, or one too short for the
#     word); its word reads 0 before any cancel, and the word the engine
#     writes is the word the worker's copy of the descriptor reads (a cancel
#     the worker never sees).
#   - a request and its reply cross the pair: the worker's end reads the
#     wire's magic, the op sent, request id 1 and the head plus the body as
#     the payload length, and the engine gets the OK reply.
#   - a request after the worker's end closed is ERR_INSTANCE_LOST with the
#     message "komira udf worker lost: the worker was already reaped", and
#     this process lives on (a send that raises SIGPIPE ends it).
#   - starting a program that does not exist is ERR_INTERNAL and leaves no
#     descriptor open (the socket pair or the cancel file kept on that path).

from std.ffi import external_call
from std.testing import assert_equal

from komira_udf_spike_abi.contract import ERR_INSTANCE_LOST, ERR_INTERNAL
from komira_udf_spike_node_worker.watchdog import arm_watchdog


def _cancel_stat(which: Int) -> Int:
    return Int(external_call["kudfw_probe_cancel_stat", Int64](Int64(which)))


def _cancel_word(write: Bool, word: Int) -> Int:
    return Int(external_call["kudfw_probe_cancel_word", Int64](Int64(1 if write else 0), Int64(word)))


def _open_fds() -> Int:
    return Int(external_call["kudfw_probe_open_fds", Int64]())


def main() raises:
    arm_watchdog()
    assert_equal(Int(external_call["kudfw_probe_channel_cloexec", Int64]()), 3, "close-on-exec descriptors of 3")
    assert_equal(_cancel_stat(0), 4096, "the cancel file's size")
    assert_equal(_cancel_stat(1), 0, "the cancel file's names in the file system")
    assert_equal(_cancel_word(False, 0), 0, "the cancel word before a cancel")
    assert_equal(_cancel_word(True, 0x0102030405060708), 0x0102030405060708, "the cancel word the worker reads")
    assert_equal(Int(external_call["kudfw_probe_round_trip", Int64]()), 0, "a request and its reply")
    assert_equal(
        Int(external_call["kudfw_probe_peer_closed", Int64]()),
        Int(ERR_INSTANCE_LOST),
        "a request after the worker's end closed (0: another message)",
    )
    var before = _open_fds()
    assert_equal(Int(external_call["kudfw_probe_spawn_missing", Int64]()), Int(ERR_INTERNAL), "a missing program")
    assert_equal(_open_fds(), before, "descriptors left open by a failed start")
    print("test_channel: ok")
