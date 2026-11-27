# The probe the native runtime's tests read (native/probe.c), held to what
# it should count on the system the test runs on: on Linux dl_iterate_phdr,
# mallinfo2 and /proc/self/fd; on macOS dyld's image count, the malloc
# zones' bytes in use and /dev/fd. The other tests of this package compare
# the probe's readings before and after the runtime acts; this one checks
# the readings themselves, with no runtime.
#
# What it proves, and the defect each part catches:
#   - loaded objects: dlopen of a library not yet loaded raises the count,
#     and a second dlopen of the same file leaves it as it is (a count that
#     never moves; one that counts handles rather than objects).
#   - heap in use: 8 MiB held from malloc raises it by at least 8 MiB, and
#     freeing them lowers it by at least 8 MiB (a figure that leaves out large
#     blocks, or reads one zone or arena of several).
#   - open descriptors: a dup adds exactly one and its close takes it away
#     (a count of the wrong directory, or of entries that are not
#     descriptors).
#   - descriptor 0: closed, the probe reads it closed; restored, open; and
#     a descriptor 0 that is not the runtime's private copy of a library
#     is never read as one. That it reads the copy itself as one is
#     test_stdin_closed's case, on both systems.
#   - private copies and the path bound: the count of copies the runtimes
#     hold reads (0 or more, never the unreadable -1), and PATH_MAX is at
#     least 1024, the smallest system value.

from std.ffi import OwnedDLHandle, external_call
from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_native.code import (
    close_stdin,
    heap_in_use,
    loaded_objects,
    open_fds,
    path_max,
    private_copies,
    stdin_is_library_copy,
    stdin_open,
)

comptime MIB = 1 << 20


def _loaded_objects() raises:
    var before = loaded_objects()
    var first = OwnedDLHandle("./native_c.so")
    var after = loaded_objects()
    assert_true(after > before, "dlopen of a new library: " + String(before) + " objects, then " + String(after))
    var second = OwnedDLHandle("./native_c.so")
    assert_equal(loaded_objects(), after, "a second dlopen of a loaded library changed the count")
    _ = first^
    _ = second^


def _heap_in_use() raises:
    var before = heap_in_use()
    assert_true(before > 0, "heap in use: " + String(before))
    assert_equal(external_call["komira_udf_spike_heap_hold", Int64](Int64(8 * MIB)), 1, "malloc of 8 MiB")
    var held = heap_in_use()
    external_call["komira_udf_spike_heap_drop", NoneType]()
    var dropped = heap_in_use()
    assert_true(held - before >= 8 * MIB, "8 MiB held: " + String(before) + " bytes, then " + String(held))
    assert_true(held - dropped >= 8 * MIB, "8 MiB freed: " + String(held) + " bytes, then " + String(dropped))


def _open_fds() raises:
    var before = open_fds()
    assert_true(before >= 0, "the descriptor directory was not readable")
    var fd = external_call["dup", Int32](Int32(2))
    assert_true(fd >= 0, "dup of descriptor 2")
    assert_equal(open_fds(), before + 1, "a dup did not add one descriptor")
    assert_equal(external_call["close", Int32](fd), 0, "close of the dup")
    assert_equal(open_fds(), before, "a close did not take its descriptor away")


def _stdin() raises:
    assert_true(stdin_open(), "descriptor 0 is closed before the test")
    assert_false(stdin_is_library_copy(), "descriptor 0 read as the library's private copy")
    var saved = external_call["dup", Int32](Int32(0))
    assert_true(saved >= 0, "dup of descriptor 0")
    assert_true(close_stdin(), "close of descriptor 0")
    assert_false(stdin_open(), "descriptor 0 read as open after its close")
    assert_equal(external_call["dup2", Int32](saved, Int32(0)), 0, "descriptor 0 restored")
    assert_equal(external_call["close", Int32](saved), 0, "close of the saved descriptor")
    assert_true(stdin_open(), "descriptor 0 read as closed after it was restored")
    assert_false(stdin_is_library_copy(), "descriptor 0 read as the library's private copy")


def _private_copies() raises:
    assert_true(private_copies() >= 0, "the scratch directory was not readable")


def _path_max() raises:
    assert_true(path_max() >= 1024, "PATH_MAX: " + String(path_max()))


def main() raises:
    _loaded_objects()
    _heap_in_use()
    _open_fds()
    _stdin()
    _private_copies()
    _path_max()
    print("test_probe: ok")
