# =============================================================================
# test_log_tls_key_exhaustion.mojo — `create_worker_id_key` RAISES when the
# process has no pthread key left, instead of handing back a bogus key.
#
# Its own process, because it takes every key there is. Every key it took is
# given back before it asserts, and a key can be created again afterwards.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_log.engine.worker_id_tls import (
    create_worker_id_key,
    delete_worker_id_key,
)


def test_running_out_of_keys_raises() raises:
    var keys = List[UInt64]()
    var refused = False
    var message = String("")
    # PTHREAD_KEYS_MAX is 1024 on glibc and 512 on macOS.
    for _ in range(4096):
        try:
            keys.append(create_worker_id_key())
        except e:
            refused = True
            message = String(e)
            break
    var taken = len(keys)
    for i in range(taken):
        _ = delete_worker_id_key(keys[i])
    assert_true(refused, "4096 keys were handed out: the failure was hidden")
    assert_true(taken > 0, "some keys were available")
    assert_equal(message, String("pthread_key_create failed"))
    var again = create_worker_id_key()
    assert_equal(Int(delete_worker_id_key(again)), 0, "keys are back")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
