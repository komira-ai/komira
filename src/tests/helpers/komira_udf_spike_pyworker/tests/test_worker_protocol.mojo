# A real worker (pyworker/komira_udf_pyworker.py) driven message by message,
# without the proxy (native/probe_worker.c): what it answers to requests the
# proxy never sends.
#
# What it proves, and the defect each part catches:
#   - DESCRIBE's ten numbers, each as section 4.2 lists them (a capability
#     word changed);
#   - an unknown op refused with ERR_UNSUPPORTED; CANCEL for a call already
#     answered gets no reply (the next reply answers the next request);
#     UNLOAD and CLOSE_* of unknown ids taken; OPEN_INSTANCE naming no
#     context or no UDF, CALL_BATCH naming no instance, OPEN_CONTEXT on the
#     zygote, FORK on a context worker or without its socket: each
#     refused with ERR_INTERNAL and its reason; every ERROR with row and
#     group -1 (a dispatch arm that serves the wrong op, a check deleted);
#   - LOAD and VALIDATE with one defect each: the form, each way the entry
#     can break its grammar, a descriptor version over 0 or bytes in
#     version 0, a VALUE without exactly one payload code object, code
#     objects for a BUNDLE, a shape outside SCALAR and MAP_BATCHES_COLUMN,
#     65 arguments, no result or two, a body
#     cut short, schemas that do not parse, a module that fails at import,
#     VALUE payloads that are not a function, not a pickle, whose hints do
#     not resolve or do not bind, a payload file missing: each refused with
#     its status (ERR_DESCRIPTOR, ERR_UNSUPPORTED, ERR_LOAD, ERR_INTERNAL)
#     and reason; 64 arguments, an int32 argument or result and a good
#     VALUE taken (any of these checks deleted, or a bound moved by one);
#   - a batch the worker cannot read, and one column for two arguments:
#     refused as the engine's batch;
#   - HELLO announcing shared memory without its file refused, and HELLO
#     without the shared region refused (every worker has one); payloads
#     past the heap's end refused, while one ending exactly at the end is
#     read (a bound moved by one); a header without the magic ends the
#     worker with exit 1; end
#     of file before and after HELLO ends it with exit 0, and so does
#     SHUTDOWN within a second with the socket still open; a worker started
#     with a role it does not know exits 1 before HELLO, and the engine
#     says so.
#
# Mutants planted: the operator sweep of the pull request ran every mutant
# of komira_udf_pyworker.py against this file (its table names each one
# this file kills).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import ERR_DESCRIPTOR, ERR_INTERNAL, ERR_LOAD, ERR_UNSUPPORTED
from komira_udf_spike_pyworker.drive import probe_worker
from komira_udf_spike_pyworker.report import num, text


def got(r: JsonValue, name: String, status: Int, reason: String) raises:
    var c = r.get(name)
    var said = name + ": status " + String(num(c, "status")) + ", " + text(c, "message")
    assert_equal(num(c, "status"), status, said)
    assert_true(reason in text(c, "message"), said)
    if status > 0:
        assert_equal(num(c, "value"), 0, name + ": an ERROR's row and group are -1")


def main() raises:
    var r = probe_worker("control", ".")
    got(r, "hello", 0, "OK")
    got(r, "describe", 0, "komira-test/python-worker cp313 0 5 3 1 2 1 1 0 2 1")
    assert_equal(num(r.get("describe"), "value"), 0, "nothing after DESCRIBE's numbers")
    got(r, "unknown_op", Int(ERR_UNSUPPORTED), "op 99 is not served by this worker")
    got(r, "after_cancel", 0, "OK")
    for k in ["unload_unknown", "close_context_unknown", "close_instance_unknown", "open_context"]:
        got(r, k, 0, "OK")
    got(r, "open_instance_no_context", Int(ERR_INTERNAL), "open_instance: no context 77")
    got(r, "open_instance_no_udf", Int(ERR_INTERNAL), "open_instance: no loaded UDF 99")
    got(r, "call_no_instance", Int(ERR_INTERNAL), "call_batch: no instance 4242")
    got(r, "fork_not_zygote", Int(ERR_INTERNAL), "FORK: not a zygote, or no socket came with it")
    got(r, "open_context_on_zygote", Int(ERR_INTERNAL), "OPEN_CONTEXT on a zygote worker")
    got(r, "fork_without_socket", Int(ERR_INTERNAL), "FORK: not a zygote, or no socket came with it")
    for k in ["context_exit", "zygote_exit", "shutdown_exit"]:
        got(r, k, 0, "")

    r = probe_worker("load", ".")
    var d = Int(ERR_DESCRIPTOR)
    var u = Int(ERR_UNSUPPORTED)
    got(r, "form_9", d, "code form is not PACKAGE, BUNDLE or VALUE")
    for k in ["entry_no_colon", "entry_no_module", "entry_no_function", "entry_two_colons"]:
        got(r, k, d, "entry is not <module>:<function>")
    got(r, "descriptor_version_1", d, "descriptor_version is newer than 0")
    got(r, "descriptor_bytes", d, "descriptor version 0 is empty")
    for k in ["value_no_code", "value_role_other", "value_two_codes"]:
        got(r, k, d, "a VALUE needs exactly one code object, role payload")
    got(r, "bundle_with_code", u, "code objects are read only for VALUE")
    got(r, "shape_2", u, "shape is not SCALAR or MAP_BATCHES_COLUMN")
    got(r, "args_65", u, "args is not a struct of at most 64 fields")
    for k in ["result_two", "result_none"]:
        got(r, k, u, "the result type is not int64, int32 or float64")
    for k in ["args_64", "arg_int32", "result_int32"]:
        got(r, k, 0, "OK")
    got(r, "body_cut", Int(ERR_INTERNAL), "a truncated control body")
    got(r, "body_3_bytes", Int(ERR_INTERNAL), "komira_udf_pyworker: error: unpack_from")
    got(r, "schemas_garbled", Int(ERR_INTERNAL), "the spec's schemas:")
    got(r, "module_missing", d, "module udf_no_such_module is not on the runtime's path")
    got(r, "import_fails", Int(ERR_LOAD), "import udf_worker_badimport: RuntimeError")
    got(r, "value_not_function", Int(ERR_LOAD), "the VALUE is a int, not a function")
    got(r, "value_bad_pickle", Int(ERR_LOAD), "deserializing the VALUE:")
    got(r, "value_unresolved_hints", Int(ERR_LOAD), "the type hints do not resolve")
    got(r, "value_bad_signature", Int(ERR_LOAD), "takes_str")
    got(r, "value_good", 0, "OK")
    got(r, "value_missing_file", Int(ERR_LOAD), "code object payload (0000")
    for k in ["load_pair", "load_open_context", "load_open_instance"]:
        got(r, k, 0, "OK")
    got(r, "call_unreadable_batch", Int(ERR_INTERNAL), "the engine's batch: a message without the continuation marker")
    got(r, "call_one_column_for_two", Int(ERR_INTERNAL), "1 columns and 2 buffers; the schema has 2 columns")
    got(r, "load_exit", 0, "")

    r = probe_worker("frame", ".")
    got(r, "hello_shm_no_file", Int(ERR_INTERNAL), "HELLO: shared memory without its file")
    got(r, "hello_no_region", Int(ERR_INTERNAL), "HELLO: no shared region")
    got(r, "shm_hello", 0, "")
    got(r, "heap_end_exact", Int(ERR_INTERNAL), "call_batch: no instance 0")
    for k in ["heap_one_past", "heap_far_past"]:
        got(r, k, Int(ERR_INTERNAL), "a payload outside the engine-to-worker heap")
    assert_equal(num(r.get("bad_magic"), "status"), -1, "a header without the magic was answered")
    assert_equal(num(r.get("bad_magic"), "value"), 1, "a header without the magic: exit 1")
    for k in ["no_region_exit", "shm_exit", "eof_before_hello", "eof_after_hello"]:
        got(r, k, 0, "")
    var sb = r.get("spawn_bad_role")
    assert_equal(num(sb, "status"), -1, text(sb, "message"))
    assert_true("HELLO: UDF_WORKER_CRASHED" in text(sb, "message"), text(sb, "message"))
    assert_true("exited with status 1" in text(sb, "message"), text(sb, "message"))
    assert_equal(num(sb, "value"), 1, "the channel is dead")
    print("test_worker_protocol: ok")
