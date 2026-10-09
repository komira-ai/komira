# The komira-test/node worker runtime with nothing beside its library file:
# no node, no worker script. init starts the admission worker, so it must
# fail, ERR_INTERNAL with posix_spawn's reason and the path it tried, and
# return no table.
#
# Defect caught: a failed posix_spawn taken for a started worker (the proxy
# then talks to a channel whose other end no process holds).
#
# Mutant planted: channel.c, kudfw_spawn ignoring posix_spawn's status
# (`if (rc != 0)` made `if (0)`): red, init fails with ERR_INSTANCE_LOST
# ("the worker was already reaped", from the HELLO) instead of posix_spawn's
# reason.

from std.testing import assert_true

from komira_udf_spike_abi.runtime import UdfRuntime


def main() raises:
    var why = String("")
    try:
        var rt = UdfRuntime.open("./node_worker.so")
        rt.shutdown()
        why = "opened"
    except e:
        why = String(e)
    assert_true(why.startswith("UDF_RUNTIME_INIT: ./node_worker.so: ERR_INTERNAL posix_spawn "), why)
    assert_true(why.endswith("/node_worker/node/bin/node: No such file or directory"), why)
    print("test_no_node: ok")
