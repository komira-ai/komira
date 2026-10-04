# =============================================================================
# komira_agent/tests/test_heartbeat_proto_roundtrip.mojo
# =============================================================================
#
# The heartbeat proto-binary encode->decode IDENTITY gate
# for the GENERATED supervisor.proto heartbeat messages, driven through the SAME
# `komira_proto_codec` protobuf-binary entry points (`encode_proto` / `decode_proto`)
# the supervisor agent + the job-manager heartbeat handler now use on the wire.
#
# The job manager's end-to-end test proves the binary path works through the
# real HTTP server; THIS proves the generated
# `SupervisorHeartbeat` / `HeartbeatResponse` / `FailureReport` survive a round
# trip field-for-field (encode and decode are independent code paths, so a
# round-trip is a real correctness signal — not just "it compiles").
#
# Coverage:
#   * SupervisorHeartbeat with ALL fields set (incl. optional progress/message
#     + the nested FailureReport + the JobPhase enum) -> identity.
#   * SupervisorHeartbeat with the optionals ABSENT -> they decode back to None.
#   * HeartbeatResponse(cancel=true) and (cancel=false) -> identity.
#   * FailureReport (the nested forensics message) on its own -> identity,
#     including the repeated `stderr_tail`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import encode_proto, decode_proto

# The GENERATED supervisor.proto messages (komira_supervisor_proto) and the
# broker routing messages they carry (komira_broker_proto).
from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat,
    HeartbeatResponse,
    FailureReport,
    JobPhase,
)
from komira_broker_proto.broker import (
    NodeLoad,
    ClusterConfig,
    BrokerClusterMap,
    NodeEndpoint,
    PartitionLeader,
)


def test_supervisor_heartbeat_all_fields_roundtrip() raises:
    """A SupervisorHeartbeat with every field set — required job_id/phase/
    pod_name + optional progress/message + a nested FailureReport — survives
    encode->decode identity over the protobuf-binary backend."""
    var stderr_tail = List[String]()
    stderr_tail.append(String("thread panicked at boom"))
    stderr_tail.append(String("note: run with RUST_BACKTRACE=1"))
    var failure = FailureReport(
        Optional[Int32](Int32(7)),  # exit_code
        Optional[Int32](Int32(9)),  # signal
        stderr_tail^,  # stderr_tail (repeated)
        Optional[String](String("panicked at boom")),  # panic_message
        Optional[String](String("child exited non-zero")),  # reason
        Optional[UInt64](UInt64(123456789)),  # last_record_offset
    )

    var hb = SupervisorHeartbeat(
        String("11111111-2222-3333-4444-555555555555"),  # job_id
        JobPhase(JobPhase.JOB_PHASE_FAILED),  # phase
        String("komira-job-abc123"),  # pod_name
        Optional[UInt32](UInt32(42)),  # progress
        Optional[String](String("processing batch 7")),  # message
        Optional[FailureReport](failure^),  # failure
        Optional[String](),  # node_id (M6, job-only: absent)
        Optional[NodeLoad](),  # load (M6, job-only: absent)
        List[UInt32](),  # owned_partitions (M6, job-only: empty)
        Optional[String](),  # advertised_host (peer-routing, job-only: absent)
        Optional[UInt32](),  # advertised_port (peer-routing, job-only: absent)
    )

    var bytes = encode_proto[SupervisorHeartbeat](hb)
    assert_true(len(bytes) > 0, "non-empty wire bytes")
    var back = decode_proto[SupervisorHeartbeat](bytes^)

    assert_equal(
        back.job_id,
        String("11111111-2222-3333-4444-555555555555"),
        "job_id",
    )
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_FAILED, "phase enum")
    assert_equal(back.pod_name, String("komira-job-abc123"), "pod_name")
    assert_true(Bool(back.progress), "progress present")
    assert_equal(back.progress.value(), UInt32(42), "progress value")
    assert_true(Bool(back.message), "message present")
    assert_equal(
        back.message.value(), String("processing batch 7"), "message value"
    )

    assert_true(Bool(back.failure), "failure present")
    ref fr = back.failure.value()
    assert_true(Bool(fr.exit_code), "exit_code present")
    assert_equal(fr.exit_code.value(), Int32(7), "exit_code value")
    assert_true(Bool(fr.signal), "signal present")
    assert_equal(fr.signal.value(), Int32(9), "signal value")
    assert_equal(len(fr.stderr_tail), 2, "two stderr_tail lines")
    assert_equal(
        fr.stderr_tail[0], String("thread panicked at boom"), "stderr_tail[0]"
    )
    assert_equal(
        fr.stderr_tail[1],
        String("note: run with RUST_BACKTRACE=1"),
        "stderr_tail[1]",
    )
    assert_true(Bool(fr.panic_message), "panic_message present")
    assert_equal(
        fr.panic_message.value(), String("panicked at boom"), "panic_message"
    )
    assert_true(Bool(fr.reason), "reason present")
    assert_equal(
        fr.reason.value(), String("child exited non-zero"), "reason"
    )
    assert_true(Bool(fr.last_record_offset), "last_record_offset present")
    assert_equal(
        fr.last_record_offset.value(),
        UInt64(123456789),
        "last_record_offset value",
    )
    print("  test_supervisor_heartbeat_all_fields_roundtrip: PASS")


def test_supervisor_heartbeat_optionals_absent_roundtrip() raises:
    """A RUNNING heartbeat with NO optional fields — progress/message/failure
    decode back to None; required job_id/phase/pod_name still set."""
    var hb = SupervisorHeartbeat(
        String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String("pod-xyz"),
        None,  # progress
        None,  # message
        None,  # failure
        None,  # node_id (M6)
        None,  # load (M6)
        List[UInt32](),  # owned_partitions (M6)
        None,  # advertised_host (peer-routing)
        None,  # advertised_port (peer-routing)
    )
    var bytes = encode_proto[SupervisorHeartbeat](hb)
    var back = decode_proto[SupervisorHeartbeat](bytes^)

    assert_equal(
        back.job_id, String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "job_id"
    )
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_RUNNING, "phase RUNNING")
    assert_equal(back.pod_name, String("pod-xyz"), "pod_name")
    assert_false(Bool(back.progress), "absent progress -> None")
    assert_false(Bool(back.message), "absent message -> None")
    assert_false(Bool(back.failure), "absent failure -> None")
    # M6: a plain job heartbeat carries no node identity / load / partitions.
    assert_false(Bool(back.node_id), "absent node_id -> None")
    assert_false(Bool(back.load), "absent load -> None")
    assert_equal(len(back.owned_partitions), 0, "empty owned_partitions")
    print("  test_supervisor_heartbeat_optionals_absent_roundtrip: PASS")


def test_heartbeat_response_roundtrip() raises:
    """HeartbeatResponse(cancel) round-trips for both true and false (M6 fields
    empty — the JOB-only response shape)."""
    var yes = HeartbeatResponse(True, List[UInt32](), None, None, List[Int64]())
    var yb = encode_proto[HeartbeatResponse](yes)
    var yback = decode_proto[HeartbeatResponse](yb^)
    assert_true(yback.cancel, "cancel=true round-trips")
    assert_equal(len(yback.assigned_partitions), 0, "empty assigned_partitions")
    assert_false(Bool(yback.cluster), "absent cluster -> None")
    assert_false(Bool(yback.broker_cluster), "absent broker_cluster -> None")
    assert_equal(
        len(yback.assigned_generations), 0, "empty assigned_generations"
    )

    var no = HeartbeatResponse(False, List[UInt32](), None, None, List[Int64]())
    var nb = encode_proto[HeartbeatResponse](no)
    var nback = decode_proto[HeartbeatResponse](nb^)
    assert_false(nback.cancel, "cancel=false round-trips")
    print("  test_heartbeat_response_roundtrip: PASS")


def test_supervisor_heartbeat_m6_fields_roundtrip() raises:
    """A BROKER-NODE heartbeat (M6): node_id + a NodeLoad + a non-empty
    owned_partitions list survive encode->decode identity. This is the wire the
    co-located supervisor+broker node sends every cycle (D1, Option-C relay)."""
    var owned = List[UInt32]()
    owned.append(UInt32(0))
    owned.append(UInt32(2))
    owned.append(UInt32(4))
    var hb = SupervisorHeartbeat(
        String("99999999-8888-7777-6666-555555555555"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String("komira-broker-node-1"),
        None,  # progress
        None,  # message
        None,  # failure
        Optional[String](String("node-1")),  # node_id
        Optional[NodeLoad](
            NodeLoad(UInt64(123456), UInt32(3), Optional[UInt32]())
        ),  # load
        owned^,  # owned_partitions
        Optional[String](String("broker-1.svc")),  # advertised_host (#10)
        Optional[UInt32](UInt32(19092)),  # advertised_port (#11)
    )
    var bytes = encode_proto[SupervisorHeartbeat](hb)
    var back = decode_proto[SupervisorHeartbeat](bytes^)

    assert_true(Bool(back.node_id), "node_id present")
    assert_equal(back.node_id.value(), String("node-1"), "node_id value")
    assert_true(Bool(back.load), "load present")
    ref ld = back.load.value()
    assert_equal(ld.records_served, UInt64(123456), "records_served")
    assert_equal(ld.partition_count, UInt32(3), "partition_count")
    assert_equal(len(back.owned_partitions), 3, "owned_partitions count")
    assert_equal(back.owned_partitions[0], UInt32(0), "owned[0]")
    assert_equal(back.owned_partitions[1], UInt32(2), "owned[1]")
    assert_equal(back.owned_partitions[2], UInt32(4), "owned[2]")
    # BROKER-PEER-ROUTING #10/#11 — the advertised endpoint round-trips.
    assert_true(Bool(back.advertised_host), "advertised_host present")
    assert_equal(
        back.advertised_host.value(), String("broker-1.svc"), "advertised_host"
    )
    assert_true(Bool(back.advertised_port), "advertised_port present")
    assert_equal(
        back.advertised_port.value(), UInt32(19092), "advertised_port"
    )
    print("  test_supervisor_heartbeat_m6_fields_roundtrip: PASS")


def test_heartbeat_response_m6_assignment_roundtrip() raises:
    """The ASSIGNMENT reply (M6): the JM pushes back assigned_partitions + a
    ClusterConfig. The node reconciles the diff in-process. Round-trips
    field-for-field."""
    var assigned = List[UInt32]()
    assigned.append(UInt32(1))
    assigned.append(UInt32(3))
    # lease generations POSITIONALLY PARALLEL to assigned.
    var gens = List[Int64]()
    gens.append(Int64(7))  # generation for pid 1
    gens.append(Int64(2))  # generation for pid 3
    var resp = HeartbeatResponse(
        False,
        assigned^,
        Optional[ClusterConfig](ClusterConfig(UInt32(6), UInt32(3))),
        None,  # broker_cluster (absent — assignment-only reply)
        gens^,  # assigned_generations
    )
    var b = encode_proto[HeartbeatResponse](resp)
    var back = decode_proto[HeartbeatResponse](b^)
    assert_false(back.cancel, "cancel=false")
    assert_equal(len(back.assigned_partitions), 2, "assigned count")
    assert_equal(back.assigned_partitions[0], UInt32(1), "assigned[0]")
    assert_equal(back.assigned_partitions[1], UInt32(3), "assigned[1]")
    assert_true(Bool(back.cluster), "cluster present")
    ref cc = back.cluster.value()
    assert_equal(cc.total_partitions, UInt32(6), "total_partitions")
    assert_equal(cc.node_count, UInt32(3), "node_count")
    # the lease generations round-trip POSITIONALLY PARALLEL.
    assert_equal(len(back.assigned_generations), 2, "assigned_generations count")
    assert_equal(back.assigned_generations[0], Int64(7), "gen[0] (pid 1)")
    assert_equal(back.assigned_generations[1], Int64(2), "gen[1] (pid 3)")
    print("  test_heartbeat_response_m6_assignment_roundtrip: PASS")


def test_heartbeat_response_broker_cluster_roundtrip() raises:
    """BROKER-PEER-ROUTING: the cluster-wide routing map (field #4) — every live
    broker's NodeEndpoint + the per-partition leader (incl. a NO_LEADER -1) —
    round-trips field-for-field over the protobuf-binary backend. This is the
    wire shape the coordinator pushes so a vanilla single-bootstrap client gets a
    COMPLETE Metadata from any one broker."""
    var nodes = List[NodeEndpoint]()
    nodes.append(NodeEndpoint(Int32(1), String("broker-1"), UInt32(19092)))
    nodes.append(NodeEndpoint(Int32(2), String("broker-2"), UInt32(29092)))
    var leaders = List[PartitionLeader]()
    leaders.append(PartitionLeader(UInt32(0), Int32(1)))
    leaders.append(PartitionLeader(UInt32(1), Int32(2)))
    leaders.append(PartitionLeader(UInt32(2), Int32(-1)))  # NO_LEADER
    var resp = HeartbeatResponse(
        False,
        List[UInt32](),
        None,
        Optional[BrokerClusterMap](BrokerClusterMap(nodes^, leaders^)),
        List[Int64](),  # assigned_generations
    )
    var b = encode_proto[HeartbeatResponse](resp)
    var back = decode_proto[HeartbeatResponse](b^)
    assert_true(Bool(back.broker_cluster), "broker_cluster present")
    ref bc = back.broker_cluster.value()
    assert_equal(len(bc.nodes), 2, "2 node endpoints")
    assert_equal(bc.nodes[0].node_id, Int32(1), "node[0].id")
    assert_equal(bc.nodes[0].host, String("broker-1"), "node[0].host")
    assert_equal(bc.nodes[0].port, UInt32(19092), "node[0].port")
    assert_equal(bc.nodes[1].node_id, Int32(2), "node[1].id")
    assert_equal(len(bc.leaders), 3, "3 partition leaders")
    assert_equal(bc.leaders[0].partition_id, UInt32(0), "leader[0].pid")
    assert_equal(bc.leaders[0].leader_node_id, Int32(1), "leader[0].node")
    assert_equal(bc.leaders[2].leader_node_id, Int32(-1), "leader[2] NO_LEADER")
    print("  test_heartbeat_response_broker_cluster_roundtrip: PASS")


def test_failure_report_standalone_roundtrip() raises:
    """The nested FailureReport message round-trips on its own (empty
    stderr_tail + a subset of the optionals)."""
    var fr = FailureReport(
        Optional[Int32](Int32(-1)),  # exit_code (killed by signal => -1 style)
        None,  # signal
        List[String](),  # stderr_tail (empty)
        None,  # panic_message
        Optional[String](String("oom")),  # reason
        None,  # last_record_offset
    )
    var bytes = encode_proto[FailureReport](fr)
    var back = decode_proto[FailureReport](bytes^)
    assert_true(Bool(back.exit_code), "exit_code present")
    assert_equal(back.exit_code.value(), Int32(-1), "exit_code value")
    assert_false(Bool(back.signal), "signal absent")
    assert_equal(len(back.stderr_tail), 0, "empty stderr_tail")
    assert_false(Bool(back.panic_message), "panic_message absent")
    assert_true(Bool(back.reason), "reason present")
    assert_equal(back.reason.value(), String("oom"), "reason value")
    assert_false(Bool(back.last_record_offset), "last_record_offset absent")
    print("  test_failure_report_standalone_roundtrip: PASS")


def main() raises:
    print("test_heartbeat_proto_roundtrip — heartbeat proto-binary gate")
    test_supervisor_heartbeat_all_fields_roundtrip()
    test_supervisor_heartbeat_optionals_absent_roundtrip()
    test_heartbeat_response_roundtrip()
    test_failure_report_standalone_roundtrip()
    test_supervisor_heartbeat_m6_fields_roundtrip()
    test_heartbeat_response_m6_assignment_roundtrip()
    test_heartbeat_response_broker_cluster_roundtrip()
    print("ALL HEARTBEAT PROTO-BINARY ROUND-TRIP TESTS PASSED")
