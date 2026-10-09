# The worker boundary's checks, one case each (native/probe_boundary.c):
# what the engine side refuses from a worker, and what a worker refuses from
# the engine at HELLO.
#
# What it proves, and the defect each part catches:
#   - codec: the engine decodes a good reply (values, nulls) and refuses a
#     copy with each defect a worker could write: a short prefix, no
#     continuation marker, metadata past the payload, a root offset out of
#     range, a body past the payload, a values buffer or a validity bitmap
#     shorter than the column, a buffer past the body, a misaligned values
#     buffer, a null count over the length, a column length other than the
#     batch's, two columns (any of these checks deleted: a worker's bytes
#     read out of bounds in the engine);
#   - the engine's writer re-bases a sliced column at offsets 0 .. 17 and
#     lengths 1 .. 21, with the null count given or counted (-1): every
#     value and validity bit read back, the spare bits zero (a writer that
#     ignores the offset, shifts a bitmap wrongly, or miscounts nulls);
#   - the control-body reader stops at the end of a body (a string or an
#     i64 past it is an error, not a read);
#   - HELLO to a real worker: the wire version, the ABI major and the ABI
#     minor each off by one are refused with ERR_ABI; the same versions are
#     taken, and the worker answers with its own three and its pid (a
#     worker that ignores the minor, section 5.2: any difference is
#     refused);
#   - HELLO from a fake worker: a reply off in the minor, a short reply and
#     a refusal are refused by the engine with their reasons; a good one is
#     taken (an engine that trusts the worker's versions);
#   - replies from a fake worker: without the magic, answering another
#     request, a payload in the heap with no shared memory, outside the
#     heap, over 2 GiB, or cut by an end of file: each refused and the
#     channel dead (a reply read past the region, or taken for another
#     request).
#
# Mutants planted: ipc_codec.c pyw_ipc_decode_column without the
# `length > blen[1] / width` check: red on values_short.
# komira_udf_pyworker.py hello() comparing the wire version and the ABI
# major only: red on worker_minor. proxy_channel.c hello() not comparing
# the worker's minor: red on engine_hello_minor.

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import ERR_ABI
from komira_udf_spike_python_worker.drive import probe_boundary
from komira_udf_spike_python_worker.report import num, text


def refused(r: JsonValue, name: String, reason: String, status: Int = 1) raises:
    var c = r.get(name)
    assert_equal(num(c, "status"), status, name + ": " + text(c, "message"))
    assert_true(reason in text(c, "message"), name + ": " + text(c, "message"))


def main() raises:
    var r = probe_boundary("codec", "")
    assert_equal(num(r.get("good"), "status"), 0, text(r.get("good"), "message"))
    assert_equal(num(r.get("good"), "value"), 0, "the good reply's values and nulls")
    refused(r, "prefix_short", "shorter than a message prefix")
    refused(r, "continuation", "without the IPC continuation marker")
    refused(r, "meta_past_payload", "metadata length outside the payload")
    refused(r, "root_offset", "flatbuffer is malformed")
    refused(r, "body_truncated", "body length runs past the payload")
    refused(r, "values_short", "values buffer is shorter than the column")
    refused(r, "validity_short", "validity bitmap is shorter than the column")
    refused(r, "buffer_past_body", "a buffer runs past the body")
    refused(r, "misaligned", "not aligned to its width")
    refused(r, "nulls_over_length", "null count is outside")
    refused(r, "node_length", "length is not the batch's")
    refused(r, "two_columns", "not one primitive column")
    assert_equal(num(r.get("rebase_shifts"), "status"), 0, "every slice written")
    assert_equal(num(r.get("rebase_shifts"), "value"), 0, "slices read back wrong")
    assert_equal(num(r.get("rd_str_past_end"), "status"), 1)
    assert_equal(text(r.get("rd_str_past_end"), "message"), "NULL")
    assert_equal(num(r.get("rd_i64_short"), "status"), 1)
    assert_equal(num(r.get("rd_str_null"), "status"), 0, "a NULL string is not an error")

    r = probe_boundary("hello", ".")
    for k in ["worker_wire", "worker_major", "worker_minor"]:
        refused(r, k, "any difference is refused", Int(ERR_ABI))
    refused(r, "worker_same", "OK wire 1 ABI 1.0", 0)
    assert_equal(num(r.get("worker_same"), "value"), 1, "the worker's pid in its HELLO")

    r = probe_boundary("faults", "")
    refused(r, "engine_hello_good", "HELLO taken", 0)
    refused(r, "engine_hello_minor", "any difference is refused")
    refused(r, "engine_hello_short", "a malformed OK")
    refused(r, "engine_hello_refused", "this fake worker refuses")
    refused(r, "reply_ok", "a reply taken", 0)
    assert_equal(num(r.get("reply_ok"), "value"), 16)
    refused(r, "reply_magic", "without the protocol's magic")
    refused(r, "reply_other_id", "answers no request")
    refused(r, "reply_heap_without_shm", "outside the worker-to-engine heap")
    refused(r, "reply_outside_heap", "outside the worker-to-engine heap")
    refused(r, "reply_over_2gib", "over 2 GiB")
    refused(r, "reply_eof_in_payload", "closed its control channel")
    for k in ["reply_magic", "reply_other_id", "reply_outside_heap", "reply_over_2gib", "reply_eof_in_payload"]:
        assert_equal(num(r.get(k), "value"), 1, k + ": the channel is dead after it")
    print("test_worker_boundary: ok")
