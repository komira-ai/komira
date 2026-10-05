# Compute Engine's Operation is its own message
# (google.cloud.compute.v1.Operation), not google.longrunning.Operation: its
# state is the `status` enum (PENDING, RUNNING, DONE), a failure is the
# `error.errors` list inside an otherwise successful (HTTP 200) answer, with
# `httpErrorStatusCode` and `httpErrorMessage` beside it, and there is no
# `done` flag, `metadata` or `response`. A caller following an operation
# waits for status DONE and then reads `error`: DONE alone is not success.
#
# The bodies are written from the Compute Engine v1 Operation reference
# (`status`, `error.errors[].{code,message,errorDetails}`, `warnings`) and
# decoded with komira_proto_codec's lenient reader, as the generated client
# decodes every response; nothing is sent.
from std.testing import assert_equal, assert_false, assert_true

from komira_gcp_compute.compute import Operation, Operation_Status
from komira_proto_codec.codec import decode_json_lenient


def test_status_names_map_to_the_enum() raises:
    var pending = decode_json_lenient[Operation](String('{"status":"PENDING"}'))
    var running = decode_json_lenient[Operation](String('{"status":"RUNNING"}'))
    var done = decode_json_lenient[Operation](String('{"status":"DONE"}'))
    assert_true(pending.status.value() == Operation_Status(Operation_Status.PENDING))
    assert_true(running.status.value() == Operation_Status(Operation_Status.RUNNING))
    assert_true(done.status.value() == Operation_Status(Operation_Status.DONE))
    assert_equal(done.status.value().json_name(), "DONE")


def test_a_status_added_later_reads_as_the_zero_value() raises:
    # proto3 JSON: an enum name this pin does not know is the zero value,
    # UNDEFINED_STATUS, never DONE.
    var op = decode_json_lenient[Operation](String('{"status":"PAUSED"}'))
    assert_true(
        op.status.value() == Operation_Status(Operation_Status.UNDEFINED_STATUS)
    )


def test_a_failed_operation_is_done_with_an_error() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"kind":"compute#operation","name":"operation-1700-abc",'
            + '"operationType":"insert","status":"DONE","progress":100,'
            + '"httpErrorStatusCode":403,"httpErrorMessage":"FORBIDDEN",'
            + '"error":{"errors":[{"code":"QUOTA_EXCEEDED",'
            + '"message":"Quota CPUS exceeded.  Limit: 24.0 in region us-central1.",'
            + '"errorDetails":[{"quotaInfo":{"metricName":"compute.googleapis.com/cpus",'
            + '"limitName":"CPUS-per-project-region","dimensions":{"region":"us-central1"},'
            + '"limit":24}}]}]}}'
        )
    )
    assert_true(op.status.value() == Operation_Status(Operation_Status.DONE))
    assert_equal(op.http_error_status_code.value(), 403)
    assert_equal(op.http_error_message.value(), "FORBIDDEN")
    ref errors = op.error.value().errors
    assert_equal(len(errors), 1)
    assert_equal(errors[0].code.value(), "QUOTA_EXCEEDED")
    ref quota = errors[0].error_details[0].quota_info.value()
    assert_equal(quota.metric_name.value(), "compute.googleapis.com/cpus")
    assert_equal(quota.limit.value(), 24.0)
    assert_equal(quota.dimensions["region"], "us-central1")


def test_a_successful_operation_has_no_error() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"operation-1700-abc","status":"DONE","progress":100,'
            + '"targetId":"4417","warnings":[{"code":"DISK_SIZE_LARGER_THAN_IMAGE_SIZE",'
            + '"message":"The resized disk is larger than the image size.",'
            + '"data":[{"key":"disk","value":"job-vm-1"}]}]}'
        )
    )
    assert_false(op.error)
    assert_false(op.http_error_status_code)
    assert_equal(op.target_id.value(), UInt64(4417))
    assert_equal(len(op.warnings), 1)
    assert_equal(op.warnings[0].code.value(), "DISK_SIZE_LARGER_THAN_IMAGE_SIZE")
    assert_equal(op.warnings[0].data[0].key.value(), "disk")


def test_a_longrunning_shaped_body_carries_no_state_here() raises:
    # google.longrunning's `done`, `metadata` and `response` are not fields
    # of this message: the lenient reader skips them, so such a body has no
    # status at all. A caller reads `status`, never `done`.
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"operations/abc","done":true,'
            + '"metadata":{"@type":"type.googleapis.com/google.protobuf.Empty"},'
            + '"response":{}}'
        )
    )
    assert_equal(op.name.value(), "operations/abc")
    assert_false(op.status)
    assert_false(op.error)


def main() raises:
    test_status_names_map_to_the_enum()
    test_a_status_added_later_reads_as_the_zero_value()
    test_a_failed_operation_is_done_with_an_error()
    test_a_successful_operation_has_no_error()
    test_a_longrunning_shaped_body_carries_no_state_here()
    print("OK")
