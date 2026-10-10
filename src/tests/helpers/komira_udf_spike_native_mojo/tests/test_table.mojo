# The Mojo native UDF library's table, called in-process (no dlopen): the
# library's own checks, before the conformance suite runs its shared library
# through the native runtime (src/tests/helpers/komira_udf_spike_native).
#
# What it proves and the defect each part catches:
#   - native_init refuses a host of another ABI major with ERR_ABI and a
#     message, and writes no handle (a library that binds to any host);
#   - the table it returns is ABI 1.0, covers every entry, and has no
#     memory_report entry, matching the features describe reports (a table
#     entry left unset, or a feature bit and an entry that disagree);
#   - describe reports what the native runtime requires of a library:
#     runtime_id komira/native, NATIVE, hosting 0, CONTEXT_PER_THREAD, no
#     thread_affine, global_lock 0, IN_PROCESS (a library the runtime would
#     refuse to load), and exactly its descriptor version 0, its seven
#     shapes and the CPU (a field reported wrong that no runtime checks);
#   - validate accepts a fixture's own signature and refuses an unknown entry
#     (ERR_DESCRIPTOR) and a wrong signature (ERR_UNSUPPORTED), each with a
#     message (a validate that accepts anything);
#   - a ROW read set of two distinct names is accepted and one naming a field
#     twice is refused with ERR_UNSUPPORTED (a read set whose names cannot
#     bind one column each).
# Mutants planted: native_init not comparing the host's abi_major: red ("init
# accepted ABI major 2"); the read set's duplicate-name check never firing:
# red ("a read set naming a field twice was accepted").

from std.sys import size_of
from std.testing import assert_equal, assert_false, assert_true

from komira_udf_spike_abi._cabi import CUdfRuntime, Word
from komira_udf_spike_abi._host import _Arena, counts, host_data_of, make_host, new_error, new_host_data, schema_of, take_error
from komira_udf_spike_abi._table import (
    memory_report_present,
    new_caps,
    new_spec,
    read_caps,
    required_size,
    slot_value,
    t_describe,
    t_shutdown,
    t_validate,
    table_abi,
    table_size,
)
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.values import ColumnType, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_native_mojo import native_init


def _validate(mut arena: _Arena, t: Word, rt: Word, host: Word, entry: String, arg_type: Int) raises -> Int32:
    return _validate_args(arena, t, rt, host, SHAPE_SCALAR, entry, [ColumnType(arg_type, True)], List[String]())


def _validate_args(
    mut arena: _Arena, t: Word, rt: Word, host: Word, shape: UInt32, entry: String,
    arg_types: List[ColumnType], names: List[String],
) raises -> Int32:
    var hd = host_data_of(host)
    var args = schema_of(arena, arg_types, names, True, hd)
    var result = schema_of(arena, [ColumnType(TYPE_INT64, True)], List[String](), False, hd)
    var spec = new_spec(
        arena, shape, FORM_BUNDLE, entry, 0, List[UInt8](), args, result, Word.null(), NULL_MANUAL,
        IMMUTABLE, "", List[String](), List[List[UInt8]](),
    )
    var err = new_error(arena)
    var rc = t_validate(t, rt, spec, err)
    if rc != OK:
        var e = take_error(err)
        assert_true(e.message != "", "status " + status_name(rc) + " without a message")
    return rc


def main() raises:
    var arena = _Arena()

    var other = make_host(arena, ABI_MAJOR + 1, new_host_data(arena))
    var slot = arena.word(8)
    var err = new_error(arena)
    var refused = Word(native_init(other.p, slot.p, err.p))
    assert_true(refused.is_null(), "init accepted ABI major 2")
    var e = take_error(err)
    assert_equal(e.code, ERR_ABI)
    assert_true(e.message != "")
    assert_true(slot_value(slot).is_null(), "a refused init wrote a handle")

    var host = make_host(arena, ABI_MAJOR, new_host_data(arena))
    var t = Word(native_init(host.p, slot.p, new_error(arena).p))
    assert_false(t.is_null())
    var rt = slot_value(slot)
    assert_equal(table_abi(t), ABI_MAJOR)
    assert_equal(table_size(t), size_of[CUdfRuntime]())
    assert_true(table_size(t) >= required_size())
    assert_false(memory_report_present(t))

    var c = new_caps(arena)
    assert_equal(t_describe(t, rt, c), OK)
    var caps = read_caps(c)
    assert_equal(caps.runtime_id, "komira/native")
    assert_equal(caps.runtime_abi, "abi1")
    # max_descriptor_version, shapes, threading, thread_affine, transports,
    # hosting, devices, features, udf_class, global_lock
    assert_equal(caps.words[2], CONTEXT_PER_THREAD)
    assert_equal(caps.words[3], 0)
    assert_true(caps.words[4] & TRANSPORT_IN_PROCESS != 0)
    assert_equal(caps.words[5], HOSTING_NONE)
    assert_equal(caps.words[7], 0, "a feature bit without its entry")
    assert_equal(caps.words[8], CLASS_NATIVE)
    assert_equal(caps.words[9], 0)
    assert_true(caps.words[1] & SHAPE_SCALAR != 0)
    assert_equal(caps.words[0], 0, "max_descriptor_version")
    assert_equal(
        caps.words[1],
        SHAPE_SCALAR | SHAPE_ROW | SHAPE_MAP_BATCHES_COLUMN | SHAPE_MAP_BATCHES_FRAME | SHAPE_AGG_PLAIN
        | SHAPE_AGG_MERGEABLE | SHAPE_STEP,
        "shapes",
    )
    assert_equal(caps.words[4], TRANSPORT_IN_PROCESS, "transports")
    assert_equal(caps.words[6], DEVICE_CPU, "devices")

    assert_equal(_validate(arena, t, rt, host, "double", TYPE_INT64), OK)
    assert_equal(_validate(arena, t, rt, host, "no_such_function", TYPE_INT64), ERR_DESCRIPTOR)
    assert_equal(_validate(arena, t, rt, host, "double", TYPE_FLOAT64), ERR_UNSUPPORTED)
    var two: List[ColumnType] = [ColumnType(TYPE_INT64, True), ColumnType(TYPE_INT64, True)]
    assert_equal(_validate_args(arena, t, rt, host, SHAPE_ROW, "pick", two, ["a", "b"]), OK, "a read set of a and b")
    assert_equal(
        _validate_args(arena, t, rt, host, SHAPE_ROW, "pick", two, ["a", "a"]),
        ERR_UNSUPPORTED,
        "a read set naming a field twice was accepted",
    )

    t_shutdown(t, rt)
    # Every block the library reserved (its table, its runtime handle, the
    # strings describe reports) is returned by shutdown.
    assert_equal(counts(host_data_of(host)).reserved_bytes, 0, "shutdown kept host-reserved bytes")
    arena.free_all()
    print("test_table: ok")
