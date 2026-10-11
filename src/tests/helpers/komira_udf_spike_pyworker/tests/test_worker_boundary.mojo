# The worker boundary's checks, case by case (native/probe_codec.c,
# native/probe_boundary.c, native/probe_fake.c): what the engine side
# refuses from a worker, what a worker refuses from the engine at HELLO, and
# the engine's channel against a scripted fake worker.
#
# What it proves, and the defect each part catches:
#   - codec: the engine decodes a good reply and refuses a copy with each
#     defect a worker could write: a short prefix, no continuation marker,
#     metadata past the payload, length 0 or not a multiple of 8, a root
#     offset out of range, a body past the payload, the version absent or
#     V4, the header type absent or Schema, no header, a compressed batch, a
#     values buffer or a validity bitmap shorter than the column, a buffer
#     past the body, a misaligned values buffer, a null count over the
#     length, a column length other than the batch's, two columns, two
#     nodes, an absent nodes or buffers vector, a 1-byte bitmap for 9 rows,
#     a root 2 bytes before the end of a message that ends there, a payload
#     cut into its metadata; a bitmap away from body offset 0 read there; each
#     8-byte number and each offset with a high byte set, a field offset
#     past its table (a check deleted or loosened, a field read one byte
#     short or long); pyarrow's own batches (another flatbuffer layout)
#     decoded with every value and null;
#   - the writer's bytes for 30 one-field schemas, two of several fields
#     and 18 batches equal tests/ipc_golden.txt, which test_kudf_ipc reads
#     with pyarrow (a writer change that alters any byte); widths, refused
#     formats, a 65th column refused; slices re-based at offsets 0 .. 17
#     and no byte read past a column's buffers (an unreadable page after
#     them); the control-body reader past its end;
#   - HELLO to a real worker: DESCRIBE before it and after a refused one
#     refused; the wire version, the ABI major and the ABI minor each off by
#     one refused with ERR_ABI; the same versions taken, the worker
#     answering with its own three and its pid (section 5.2: any difference
#     is refused, and nothing is served before HELLO);
#   - HELLO from a fake worker off in the wire version, the major or the
#     minor, short, or refusing: refused by the engine; a good one taken;
#   - replies from a fake worker, to a request and to a call: without the
#     magic, answering another request, an op other than OK or ERROR, a
#     payload in the heap with no shared memory, outside the heap, over
#     2 GiB, or cut by an end of file: each refused and the channel dead; a
#     clock read the worker reports before it answers forwarded once;
#   - the channel against a scripted fake worker: where each batch's slot
#     goes as slots are held and released (holes reused lowest first,
#     adjacent free slots joined, a full heap sending inline and logged
#     once, room again logged once, at most 64 slots, the release ring
#     wrapping, ids outside the table ignored); clock reads in the control
#     page; the cancel flag set and CANCEL sent with the call's id, then
#     cleared; replies at the heap's last byte and one past; a send
#     interrupted by signals and a reply read 7 bytes at a time arriving
#     whole; a closed peer (end of file, a refused write); close waiting for
#     a worker that is not its child to exit, and killing one deaf to
#     SHUTDOWN after 2 s.
#
# Mutants planted: the operator sweep of the pull request ran every mutant
# of ipc_codec.c and proxy_channel.c against this file (its table names
# each one this file kills).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue
from komira_udf_spike_abi.contract import ERR_ABI
from komira_udf_spike_pyworker.drive import probe_boundary
from komira_udf_spike_pyworker.report import num, text

comptime GOLDEN = 52
"""The writer's messages compared: 30 one-field schemas, 2 of several
fields, 20 batches."""


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
    refused(r, "version_absent", "not metadata version V5")
    refused(r, "version_v4", "not metadata version V5")
    refused(r, "header_type_absent", "not a record batch")
    refused(r, "header_type_schema", "not a record batch")
    refused(r, "header_absent", "not a record batch")
    refused(r, "compressed", "a compressed record batch")
    refused(r, "uncompressed_moved", "decoded")
    refused(r, "nodes_absent", "not one primitive column")
    refused(r, "buffers_absent", "not one primitive column")
    refused(r, "two_nodes", "not one primitive column")
    refused(r, "validity_short_9_rows", "validity bitmap is shorter than the column")
    refused(r, "validity_at_160", "decoded", 0)
    assert_equal(num(r.get("validity_at_160"), "value"), 0, "a bitmap at body offset 160: the nulls and values")
    refused(r, "root_two_before_end", "flatbuffer is malformed")
    assert_equal(num(r.get("root_two_before_end"), "value"), 0, "the no-rows message ends at its metadata")
    refused(r, "payload_cut_into_meta", "metadata length outside the payload")
    for k in ["body_len_high"]:
        refused(r, k, "the body length runs past the payload")
    for k in ["batch_length_high", "node_length_high"]:
        refused(r, k, "the column's length is not the batch's")
    refused(r, "nulls_high", "the column's null count is outside")
    for k in ["validity_offset_high", "validity_length_high", "values_offset_high", "values_length_high"]:
        refused(r, k, "a buffer runs past the body")
    refused(r, "root_high", "the message flatbuffer is malformed")
    for k in [
        "header_offset_high",
        "nodes_offset_high",
        "buffers_offset_high",
        "nodes_count_high",
        "batch_soffset_high",
        "field_offset_high",
        "field_past_table",
    ]:
        refused(r, k, "the record batch flatbuffer is malformed")
    refused(r, "table_size_high", "decoded")
    refused(r, "version_high_byte", "not metadata version V5")
    for k in ["prefix_only", "meta_zero", "meta_unaligned"]:
        refused(r, k, "a metadata length outside the payload")
    refused(r, "meta_exact", "decoded")
    assert_equal(num(r.get("rebase_shifts"), "status"), 0, "every slice written")
    assert_equal(num(r.get("rebase_shifts"), "value"), 0, "slices read back wrong")
    assert_equal(num(r.get("rebase_page_end"), "status"), 0, "every slice at a page end written")
    assert_equal(num(r.get("rebase_page_end"), "value"), 0, "slices at a page end read back wrong")
    assert_equal(num(r.get("rd_str_past_end"), "status"), 1)
    assert_equal(text(r.get("rd_str_past_end"), "message"), "NULL")
    assert_equal(num(r.get("rd_i64_short"), "status"), 1)
    assert_equal(num(r.get("rd_str_null"), "status"), 0, "a NULL string is not an error")
    var g = r.get("golden")
    assert_equal(text(g, "message"), "{}", "the writer's bytes differ from tests/ipc_golden.txt (name hex|...)")
    assert_equal(num(g, "value"), GOLDEN, "messages compared, none wrong")
    assert_equal(num(g, "status"), GOLDEN, "lines in tests/ipc_golden.txt")
    assert_equal(num(r.get("widths"), "value"), 0, "pyw_format_width")
    var refused_fmts: List[String] = ["", "ll", "+s", "tdD", "d:5,2", "(no format)"]
    for i in range(6):
        var c = r.get("schema_refused_" + String(i))
        assert_equal(num(c, "status"), 1, "a schema of format '" + refused_fmts[i] + "' written")
        assert_equal(text(c, "message"), refused_fmts[i])
        assert_equal(num(c, "value"), 0, "bytes written for a refused format")
    assert_equal(num(r.get("over_64_columns"), "value"), 0, "65 columns: nothing sized or written")
    assert_equal(num(r.get("64_columns"), "value"), 11, "64 columns are sized and written")
    assert_equal(num(r.get("rd_short_zero"), "status"), 11, "short reads mark the reader bad")
    assert_equal(num(r.get("rd_short_zero"), "value"), 0, "a short read gives 0")
    assert_equal(num(r.get("rd_at_page_end"), "value"), 0, "reads ending at a page edge")
    assert_equal(text(r.get("no_rows_tight"), "message"), "decoded", "a batch of no rows ending at its metadata")
    var pa = r.get("pyarrow")
    assert_equal(num(pa, "status"), 40, "batches in pyarrow_batches/batches.txt")
    assert_equal(num(pa, "value"), 0, text(pa, "message"))

    r = probe_boundary("hello", ".")
    for k in ["worker_describe_first", "worker_describe_refused"]:
        refused(r, k, "before HELLO", Int(ERR_ABI))
    for k in ["worker_wire", "worker_major", "worker_minor"]:
        refused(r, k, "any difference is refused", Int(ERR_ABI))
    refused(r, "worker_same", "OK wire 1 ABI 1.0", 0)
    refused(r, "worker_describe_after", "komira-test/python-worker", 0)
    assert_equal(num(r.get("worker_same"), "value"), 1, "the worker's pid in its HELLO")

    r = probe_boundary("faults", "")
    refused(r, "engine_hello_good", "HELLO taken", 0)
    for k in ["engine_hello_wire", "engine_hello_major", "engine_hello_minor"]:
        refused(r, k, "any difference is refused")
    for k in ["engine_hello_wire", "engine_hello_major", "engine_hello_minor", "engine_hello_short", "engine_hello_refused"]:
        assert_equal(num(r.get(k), "value"), 1, k + ": the channel is dead after a refused HELLO")
    refused(r, "engine_hello_short", "a malformed OK")
    refused(r, "engine_hello_refused", "this fake worker refuses")
    refused(r, "reply_ok", "a reply taken", 0)
    assert_equal(num(r.get("reply_ok"), "value"), 1600, "16 bytes")
    refused(r, "reply_magic", "without the protocol's magic")
    refused(r, "reply_other_id", "answers no request")
    refused(r, "reply_wrong_op", "a reply of op 10, not OK or ERROR")
    refused(r, "reply_heap_without_shm", "outside the worker-to-engine heap")
    refused(r, "reply_outside_heap", "outside the worker-to-engine heap")
    refused(r, "reply_over_2gib", "over 2 GiB")
    refused(r, "reply_eof_in_payload", "closed its control channel")
    refused(r, "call_ok", "a reply taken", 0)
    assert_equal(num(r.get("call_ok"), "value"), 1605, "16 bytes, no clock read, 5 worker ns")
    refused(r, "call_clock_then_ok", "a reply taken", 0)
    assert_equal(num(r.get("call_clock_then_ok"), "value"), 1615, "16 bytes, one clock read forwarded, 5 worker ns")
    refused(r, "call_other_id", "answers no request")
    refused(r, "call_wrong_op", "a reply of op 10, not OK or ERROR")
    for k in [
        "reply_magic",
        "reply_other_id",
        "reply_wrong_op",
        "reply_outside_heap",
        "reply_over_2gib",
        "reply_eof_in_payload",
        "call_other_id",
        "call_wrong_op",
    ]:
        assert_equal(num(r.get(k), "value"), 1, k + ": the channel is dead after it")

    r = probe_boundary("fake", "")
    assert_equal(num(r.get("slots"), "value"), 0, "slots: " + text(r.get("slots"), "message"))
    assert_equal(num(r.get("slots_ring_wrap"), "value"), 0, text(r.get("slots_ring_wrap"), "message"))
    refused(r, "clock_shm", "", 0)
    assert_equal(num(r.get("clock_shm"), "value"), 3, "three clock reads in the control page, three now_ns")
    refused(r, "cancel_shm", "", 0)
    assert_equal(num(r.get("cancel_shm"), "value"), 0, "the flag set, then CANCEL with the call's id and no payload")
    refused(r, "cancel_cleared", "", 0)
    assert_equal(num(r.get("cancel_cleared"), "value"), 0, "the cancel flag cleared before the next call")
    for k in ["heap_start", "heap_last_bytes"]:
        refused(r, k, "taken", 0)
        assert_equal(num(r.get(k), "value"), 16, k + ": the 16 bytes the fake wrote")
    for k in ["heap_one_past", "heap_offset_at_end"]:
        refused(r, k, "outside the worker-to-engine heap", -1)
    for k in ["heap_empty_at_end", "heap_empty_past_end"]:
        refused(r, k, "taken", 0)
        assert_equal(num(r.get(k), "value"), 0)
    refused(r, "partial_send", "", 0)
    assert_equal(num(r.get("partial_send"), "value"), 1, "every byte of an interrupted send arrived in order")
    refused(r, "partial_recv", "", 0)
    assert_equal(num(r.get("partial_recv"), "value"), 1000, "every byte of a reply read 7 at a time")
    refused(r, "eof_before_reply", "worker 0 closed its control channel", -1)
    refused(r, "dead_channel", "worker 0 closed its control channel", -1)
    refused(r, "write_refused", "the control channel refused a write", -1)
    for k in ["eof_before_reply", "dead_channel", "write_refused"]:
        assert_equal(num(r.get(k), "value"), 1, k + ": the channel is dead")
    refused(r, "slots_heap_size", "", 0)
    assert_equal(num(r.get("slots_heap_size"), "value"), 0, text(r.get("slots_heap_size"), "message"))
    refused(r, "dead_not_sent", "without the protocol's magic", -11)
    assert_equal(num(r.get("dead_not_sent"), "value"), 1, "a request on a dead channel is not sent")
    refused(r, "reply_exactly_2gib", "closed its control channel", -1)
    refused(r, "heap_reply_no_shm", "outside the worker-to-engine heap", -1)
    refused(r, "close_releases", "", 0)
    assert_equal(num(r.get("close_releases"), "value"), 0, "SHUTDOWN sent bare; descriptors and mapping released")
    refused(r, "reap_exits", "exited", 0)
    var ms = num(r.get("reap_exits"), "value")
    assert_true(ms >= 250 and ms < 1500, "close waited for a worker that exits 300 ms after SHUTDOWN: " + String(ms))
    refused(r, "reap_ignores", "killed", 0)
    ms = num(r.get("reap_ignores"), "value")
    assert_true(ms >= 1900 and ms < 4000, "close killed a worker deaf to SHUTDOWN after 2 s: " + String(ms))
    print("test_worker_boundary: ok")
