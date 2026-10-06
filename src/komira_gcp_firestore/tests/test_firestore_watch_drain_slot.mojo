# =============================================================================
# test_firestore_watch_drain_slot.mojo — `ListenClientSlot`, the part of the
#   live Listen sessions that runs after the dial, over a ScriptedStream.
# =============================================================================
#
# The live source dials TLS and hands the client to a `ListenClientSlot`.
# Here the client runs over scripted server bytes instead, so the slot's own
# logic is reached offline:
#   * a trailers-only `grpc-status: 3` open: no session, last end 3, its text.
#     Catches: a failed open escaping as a raise (the watch dies) or recorded
#     with no status.
#   * an open that stalls before any head: last end UNKNOWN. Catches: a
#     raise with no recorded status read as "no end" (-1), which the drain
#     would return as an idle success.
#   * a good cold open, a poll, an end with `grpc-status: 7`: the events come
#     through, the end is seen, and closing keeps 7 as the last end.
#   * a resuming open (`open_after`) opens a session.
#   * with no session, `poll_ended` is True.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedStream

from komira_protobuf.writer import pb_write_message_field, pb_write_varint_field

from komira_gcp_firestore.firestore_listen_proto import TCT_CURRENT
from komira_gcp_firestore.firestore_listen_client import (
    FirestoreListenClient,
    encode_grpc_envelope,
)
from komira_gcp_firestore.firestore_watch_drain import ListenClientSlot

comptime _SID = UInt32(1)


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _headers(
    mut hpack: HpackEncoder,
    var fields: List[HpackHeader],
    end_stream: Bool,
    mut out: List[UInt8],
):
    var block = hpack.encode_block(fields^)
    encode_headers_frame(
        _SID, block^, end_stream=end_stream, end_headers=True, out=out
    )


def _settings(mut out: List[UInt8]):
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)


def _grpc_head(mut hpack: HpackEncoder, mut out: List[UInt8]):
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("content-type"), String("application/grpc")))
    _headers(hpack, h^, False, out)


def _target_change_envelope() -> List[UInt8]:
    var tc = List[UInt8]()
    pb_write_varint_field(tc, 1, UInt64(TCT_CURRENT))
    var resp = List[UInt8]()
    pb_write_message_field(resp, 2, tc)
    return encode_grpc_envelope(resp^)


def _client(
    var script: List[UInt8], pending_after_script: Int = 0
) -> FirestoreListenClient[ScriptedStream]:
    var shared = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(script^, shared)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    if pending_after_script > 0:
        stream.set_pending_after_script(pending_after_script)
    return FirestoreListenClient[ScriptedStream](
        stream^, String("firestore.googleapis.com"), String("fake-token")
    )


def _docs() -> List[String]:
    var d = List[String]()
    d.append(String("projects/p/databases/d/documents/c/doc0"))
    return d^


def _adopt(
    mut slot: ListenClientSlot[ScriptedStream],
    mut reactor: Reactor[NoopSink],
    var client: FirestoreListenClient[ScriptedStream],
    resume_secs: Int64 = 0,
):
    slot.adopt_and_open(
        client^, reactor, String("projects/p/databases/d"), _docs(), 1,
        resume_secs, Int64(0),
    )


def test_a_failed_open_is_the_last_end() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("grpc-status"), String("3")))
    h.append(HpackHeader(String("grpc-message"), String("bad%20target")))
    _headers(hpack, h^, True, out)
    var reactor = _make_reactor()
    var slot = ListenClientSlot[ScriptedStream]()
    _adopt(slot, reactor, _client(out^))
    assert_false(slot.is_open())
    assert_equal(slot.last_end_code(), 3)
    assert_true(
        slot.last_end_text().startswith(String("[grpc:3] bad target")),
        slot.last_end_text(),
    )


def test_a_stalled_open_is_unknown() raises:
    var out = List[UInt8]()
    _settings(out)  # SETTINGS, then silence: no head ever comes
    var reactor = _make_reactor()
    var slot = ListenClientSlot[ScriptedStream]()
    _adopt(slot, reactor, _client(out^, pending_after_script=1_000_000))
    assert_false(slot.is_open())
    assert_equal(slot.last_end_code(), 2)
    assert_true(
        String("stalled before response head") in slot.last_end_text(),
        slot.last_end_text(),
    )


def test_a_session_runs_and_its_end_is_kept() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var t = List[HpackHeader]()
    t.append(HpackHeader(String("grpc-status"), String("7")))
    _headers(hpack, t^, True, out)
    var reactor = _make_reactor()
    var slot = ListenClientSlot[ScriptedStream]()
    _adopt(slot, reactor, _client(out^))
    assert_true(slot.is_open())
    var n = 0
    for _ in range(8):
        n += len(slot.poll(reactor, 500_000))
        if slot.poll_ended():
            break
    assert_equal(n, 1)
    assert_true(slot.poll_ended())
    slot.close_after_end()
    assert_false(slot.is_open())
    assert_equal(slot.last_end_code(), 7)
    assert_true(slot.last_end_text().startswith(String("[grpc:7]")))


def test_a_resuming_open_opens() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    var reactor = _make_reactor()
    var slot = ListenClientSlot[ScriptedStream]()
    # Held open after the head: a head followed by EOF is a closed stream.
    _adopt(
        slot,
        reactor,
        _client(out^, pending_after_script=1_000_000),
        resume_secs=Int64(1_700_000_000),
    )
    assert_true(slot.is_open())
    assert_equal(slot.last_end_code(), -1)


def test_no_session_reads_as_ended() raises:
    var slot = ListenClientSlot[ScriptedStream]()
    assert_true(slot.poll_ended())
    slot.close_after_end()  # nothing to keep
    assert_equal(slot.last_end_code(), -1)


def main() raises:
    print("test_firestore_watch_drain_slot")
    test_a_failed_open_is_the_last_end()
    test_a_stalled_open_is_unknown()
    test_a_session_runs_and_its_end_is_kept()
    test_a_resuming_open_opens()
    test_no_session_reads_as_ended()
    print("ALL PASS")
