# =============================================================================
# test_supervisor_field_numbers.mojo
# =============================================================================
#
# THE FIELD-NUMBER CENSUS for `komira.supervisor.v1`, stated as WIRE BYTES.
#
# A proto field number is what is stored and sent. Renumbering a field or an
# enum value is legal to protoc and compiles clean; a heartbeat from a node
# built before the change does not fail to parse, it decodes as the WRONG
# field or phase. Nothing in the toolchain objects, so this file is the guard.
#
# HOW EACH MESSAGE IS PINNED, as in komira_broker_proto's census: a byte
# stream is written by hand, field by field, with the number and wire type
# the proto declares and a value no other field of that message holds; it is
# decoded and every field is read back BY NAME (catches two fields of one
# wire type swapping numbers); then the decoded message is encoded again and
# must give the hand-written bytes back (catches a field moved to an unused
# number, and a changed wire type). Fields are written in declaration order,
# each repeated element as its own record, and every implicit-presence field
# holds a non-zero value, so the comparison does not depend on whether an
# encoder writes zero values. The bytes are a LITERAL restatement of the
# proto: deriving them from the generated code would agree with it by
# construction.
#
# Pinned: JobPhase 0..10 by number and by name; FailureReport 1..6;
# SupervisorHeartbeat 1..11, with 8 the imported `komira.broker.v1.NodeLoad`;
# HeartbeatResponse 1..5, with 3 and 4 the imported ClusterConfig and
# BrokerClusterMap. And the additive rule the proto states: a plain job
# heartbeat (fields 1..6 only) and a plain response (field 1 only) decode
# with every multi-node field unset or empty.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto
from komira_supervisor_proto.supervisor import (
    FailureReport,
    HeartbeatResponse,
    JobPhase,
    SupervisorHeartbeat,
)


def _varint(mut b: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        b.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    b.append(UInt8(x))


def _uint(mut b: List[UInt8], field: Int, v: UInt64):
    """A varint record: tag (wire type 0), then the value."""
    _varint(b, UInt64(field << 3))
    _varint(b, v)


def _int(mut b: List[UInt8], field: Int, v: Int64):
    """A proto `int32`/`int64` record: a negative value is two's complement
    over 64 bits."""
    _uint(b, field, UInt64(v))


def _str(mut b: List[UInt8], field: Int, s: String):
    """A length-delimited record (wire type 2) holding `s`."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(s.byte_length()))
    for c in s.as_bytes():
        b.append(c)


def _msg(mut b: List[UInt8], field: Int, m: List[UInt8]):
    """A length-delimited record (wire type 2) holding an encoded message."""
    _varint(b, UInt64((field << 3) | 2))
    _varint(b, UInt64(len(m)))
    for i in range(len(m)):
        b.append(m[i])


def _hex(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += hex(Int(b[i])) + " "
    return out


def _same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(_hex(got), _hex(want), what + ": re-encode differs from the hand-written bytes")


def _failure() -> List[UInt8]:
    """FailureReport with every field set."""
    var b = List[UInt8]()
    _int(b, 1, 137)
    _int(b, 2, 9)
    _str(b, 3, "line one")
    _str(b, 3, "line two")
    _str(b, 4, "index out of range")
    _str(b, 5, "killed by signal")
    _uint(b, 6, 4_000_000_001)
    return b^


def test_job_phase_numbers() raises:
    """Every JobPhase value by number AND by name: the number is what is
    sent, and the correspondence with a job store is by name."""
    var names = List[String]()
    names.append("JOB_PHASE_UNSPECIFIED")
    names.append("JOB_PHASE_PENDING")
    names.append("JOB_PHASE_ASSIGNED")
    names.append("JOB_PHASE_RUNNING")
    names.append("JOB_PHASE_COMPLETED")
    names.append("JOB_PHASE_FAILED")
    names.append("JOB_PHASE_RECONCILING")
    names.append("JOB_PHASE_CANCELLED")
    names.append("JOB_PHASE_DRAINING")
    names.append("JOB_PHASE_CREATING")
    names.append("JOB_PHASE_SUPERVISOR_ABSENT")
    for n in range(len(names)):
        assert_equal(JobPhase(n).json_name(), names[n], "JobPhase " + String(n))
        assert_equal(JobPhase.from_json_name(names[n]).value, n, names[n])
    assert_equal(JobPhase.JOB_PHASE_RECONCILING, 6)
    assert_equal(JobPhase.JOB_PHASE_SUPERVISOR_ABSENT, 10)


def test_failure_report() raises:
    """FailureReport: 1 exit_code, 2 signal, 3 stderr_tail (repeated),
    4 panic_message, 5 reason, 6 last_record_offset."""
    var b = _failure()
    var f = decode_proto[FailureReport](b.copy())
    assert_equal(f.exit_code.value(), Int32(137))
    assert_equal(f.signal.value(), Int32(9))
    assert_equal(len(f.stderr_tail), 2)
    assert_equal(f.stderr_tail[0], "line one")
    assert_equal(f.stderr_tail[1], "line two")
    assert_equal(f.panic_message.value(), "index out of range")
    assert_equal(f.reason.value(), "killed by signal")
    assert_equal(f.last_record_offset.value(), UInt64(4_000_000_001))
    _same(encode_proto(f), b, "FailureReport")


def test_supervisor_heartbeat() raises:
    """SupervisorHeartbeat: 1 job_id, 2 phase, 3 pod_name, 4 progress,
    5 message, 6 failure, 7 node_id, 8 load (komira.broker.v1.NodeLoad),
    9 owned_partitions (repeated), 10 advertised_host, 11 advertised_port."""
    var load = List[UInt8]()
    _uint(load, 1, 500)
    _uint(load, 2, 2)
    _uint(load, 3, 8)
    var b = List[UInt8]()
    _str(b, 1, "job-0001")
    _uint(b, 2, 5)  # JOB_PHASE_FAILED
    _str(b, 3, "worker-a")
    _uint(b, 4, 42)
    _str(b, 5, "exited")
    _msg(b, 6, _failure())
    _str(b, 7, "node-3")
    _msg(b, 8, load)
    _uint(b, 9, 4)
    _uint(b, 9, 7)
    _str(b, 10, "broker-3")
    _uint(b, 11, 9093)
    var h = decode_proto[SupervisorHeartbeat](b.copy())
    assert_equal(h.job_id, "job-0001")
    assert_equal(h.phase.value, JobPhase.JOB_PHASE_FAILED)
    assert_equal(h.pod_name, "worker-a")
    assert_equal(h.progress.value(), UInt32(42))
    assert_equal(h.message.value(), "exited")
    assert_equal(h.failure.value().exit_code.value(), Int32(137))
    assert_equal(h.node_id.value(), "node-3")
    assert_equal(h.load.value().records_served, UInt64(500))
    assert_equal(h.load.value().partition_count, UInt32(2))
    assert_equal(h.load.value().reported_partition_total.value(), UInt32(8))
    assert_equal(len(h.owned_partitions), 2)
    assert_equal(h.owned_partitions[0], UInt32(4))
    assert_equal(h.owned_partitions[1], UInt32(7))
    assert_equal(h.advertised_host.value(), "broker-3")
    assert_equal(h.advertised_port.value(), UInt32(9093))
    _same(encode_proto(h), b, "SupervisorHeartbeat")


def test_plain_job_heartbeat() raises:
    """A heartbeat with fields 1..3 only (a plain job supervisor) decodes with
    every optional and multi-node field unset or empty, and re-encodes to
    the same three records."""
    var b = List[UInt8]()
    _str(b, 1, "job-0002")
    _uint(b, 2, 3)  # JOB_PHASE_RUNNING
    _str(b, 3, "worker-b")
    var h = decode_proto[SupervisorHeartbeat](b.copy())
    assert_equal(h.phase.value, JobPhase.JOB_PHASE_RUNNING)
    assert_false(Bool(h.progress))
    assert_false(Bool(h.failure))
    assert_false(Bool(h.node_id))
    assert_false(Bool(h.load))
    assert_equal(len(h.owned_partitions), 0)
    assert_false(Bool(h.advertised_host))
    assert_false(Bool(h.advertised_port))
    _same(encode_proto(h), b, "plain SupervisorHeartbeat")


def test_heartbeat_response() raises:
    """HeartbeatResponse: 1 cancel, 2 assigned_partitions (repeated),
    3 cluster (komira.broker.v1.ClusterConfig), 4 broker_cluster
    (komira.broker.v1.BrokerClusterMap), 5 assigned_generations (repeated
    int64, parallel to field 2)."""
    var cluster = List[UInt8]()
    _uint(cluster, 1, 16)
    _uint(cluster, 2, 2)
    var endpoint = List[UInt8]()
    _int(endpoint, 1, 3)
    _str(endpoint, 2, "broker-3")
    _uint(endpoint, 3, 9093)
    var leader = List[UInt8]()
    _uint(leader, 1, 4)
    _int(leader, 2, 3)
    var routing = List[UInt8]()
    _msg(routing, 1, endpoint)
    _msg(routing, 2, leader)
    var b = List[UInt8]()
    _uint(b, 1, 1)
    _uint(b, 2, 4)
    _uint(b, 2, 9)
    _msg(b, 3, cluster)
    _msg(b, 4, routing)
    _int(b, 5, 11)
    _int(b, 5, 12)
    var r = decode_proto[HeartbeatResponse](b.copy())
    assert_true(r.cancel)
    assert_equal(len(r.assigned_partitions), 2)
    assert_equal(r.assigned_partitions[1], UInt32(9))
    assert_equal(r.cluster.value().total_partitions, UInt32(16))
    assert_equal(r.cluster.value().node_count, UInt32(2))
    assert_equal(len(r.broker_cluster.value().nodes), 1)
    assert_equal(r.broker_cluster.value().nodes[0].port, UInt32(9093))
    assert_equal(r.broker_cluster.value().leaders[0].partition_id, UInt32(4))
    assert_equal(len(r.assigned_generations), 2)
    assert_equal(r.assigned_generations[0], Int64(11))
    assert_equal(r.assigned_generations[1], Int64(12))
    _same(encode_proto(r), b, "HeartbeatResponse")

    # A plain job-leg response: cancel only, nothing assigned.
    var plain = List[UInt8]()
    _uint(plain, 1, 1)
    var p = decode_proto[HeartbeatResponse](plain.copy())
    assert_true(p.cancel)
    assert_equal(len(p.assigned_partitions), 0)
    assert_false(Bool(p.cluster))
    assert_false(Bool(p.broker_cluster))
    assert_equal(len(p.assigned_generations), 0)
    _same(encode_proto(p), plain, "plain HeartbeatResponse")


def main() raises:
    print("test_supervisor_field_numbers: the komira.supervisor.v1 wire census")
    test_job_phase_numbers()
    test_failure_report()
    test_supervisor_heartbeat()
    test_plain_job_heartbeat()
    test_heartbeat_response()
    print("ALL komira.supervisor.v1 FIELD-NUMBER TESTS PASSED")
