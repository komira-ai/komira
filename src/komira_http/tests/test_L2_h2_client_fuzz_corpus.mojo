"""L2 h2 client fuzz corpus harness.

Reads each .frame fixture under
`tests/fuzz_corpus/h2_client/` and feeds it through
`decode_frame` + `process_received_frames`, asserting the expected
RFC 9113 protocol-error outcome.

This is the persistent-corpus version of the inline frame-fuzz
tests in `test_L2_h2_client_flow_control.mojo`. Each seed is one raw
HTTP/2 frame (9-byte header plus payload) under
`tests/fuzz_corpus/h2_client/`.

Seeds:
  * settings_ack_with_payload.frame
  * data_on_stream_0.frame
  * zero_increment_window_update_stream.frame
  * zero_increment_window_update_conn.frame

To add a new seed: add the frame file, declare it as test data, and
add an expected-outcome assertion below.
"""
from std.pathlib import Path

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    process_received_frames,
)
from komira_http.codec.h2.frame import (
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    H2_ERR_PROTOCOL_ERROR,
    decode_frame,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _resolve_corpus_dir() raises -> String:
    """The fuzz corpus directory, declared as this test's data and staged at
    its repository path under the test's working directory."""
    return String("src/komira_http/tests/fuzz_corpus/h2_client")


def _read_frame_file(dir_path: String, name: String) raises -> List[UInt8]:
    var path = dir_path + String("/") + name
    var bytes = Path(path).read_bytes()
    return bytes^


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_seed_settings_ack_with_payload_rejected() raises:
    """SETTINGS-ACK with non-empty payload → FRAME_SIZE_ERROR per
    RFC 9113 §6.5. The seed encodes a 6-byte ACK frame (illegal: ACK
    must be empty)."""
    print("  test_seed_settings_ack_with_payload_rejected...")
    var dir_path = _resolve_corpus_dir()
    var bytes = _read_frame_file(
        dir_path, String("settings_ack_with_payload.frame"),
    )
    var res = decode_frame(Span(bytes), 16384)
    if res.is_ok():
        raise Error(
            "settings_ack_with_payload: must NOT decode OK (RFC 9113 §6.5)"
        )
    print("    OK — SETTINGS-ACK-with-payload rejected")


def test_seed_data_on_stream_0_rejected() raises:
    """DATA on stream 0 → PROTOCOL_ERROR per RFC 9113 §6.1."""
    print("  test_seed_data_on_stream_0_rejected...")
    var dir_path = _resolve_corpus_dir()
    var bytes = _read_frame_file(
        dir_path, String("data_on_stream_0.frame"),
    )
    var res = decode_frame(Span(bytes), 16384)
    if res.is_ok():
        raise Error(
            "data_on_stream_0: must be rejected (RFC 9113 §6.1 PROTOCOL_ERROR)"
        )
    print("    OK — DATA-on-stream-0 rejected")


def test_seed_zero_increment_window_update_stream_rejected() raises:
    """Zero-increment WINDOW_UPDATE on stream 3 → STREAM error per
    RFC 9113 §6.9.1."""
    print("  test_seed_zero_increment_window_update_stream_rejected...")
    var dir_path = _resolve_corpus_dir()
    var bytes = _read_frame_file(
        dir_path, String("zero_increment_window_update_stream.frame"),
    )
    var res = decode_frame(Span(bytes), 16384)
    if res.is_ok():
        raise Error(
            "zero-increment on stream must be split error"
        )
    if res.is_connection_error:
        raise Error(
            "zero-increment on stream should be PER-STREAM error"
        )
    if res.error_code != H2_ERR_PROTOCOL_ERROR:
        raise Error("error_code should be PROTOCOL_ERROR")
    print("    OK — zero-increment WINDOW_UPDATE on stream → stream-error")


def test_seed_zero_increment_window_update_conn_rejected() raises:
    """Zero-increment WINDOW_UPDATE on stream 0 → CONNECTION error per
    RFC 9113 §6.9.1."""
    print("  test_seed_zero_increment_window_update_conn_rejected...")
    var dir_path = _resolve_corpus_dir()
    var bytes = _read_frame_file(
        dir_path, String("zero_increment_window_update_conn.frame"),
    )
    var res = decode_frame(Span(bytes), 16384)
    if res.is_ok():
        raise Error("zero-increment on stream 0 should not decode OK")
    if not res.is_connection_error:
        raise Error(
            "zero-increment on stream 0 should be CONNECTION error"
        )
    print("    OK — zero-increment WINDOW_UPDATE on conn → connection-error")


def test_integration_seed_triggers_client_goaway() raises:
    """Integration: feed settings_ack_with_payload seed through
    `process_received_frames`; expect a GOAWAY frame staged in
    `pending_out`. Same shape as inline test but reading from
    the persistent corpus."""
    print("  test_integration_seed_triggers_client_goaway...")
    var dir_path = _resolve_corpus_dir()
    var bytes = _read_frame_file(
        dir_path, String("settings_ack_with_payload.frame"),
    )
    var client = H2ClientConnectionState()
    client.append_recv_bytes(Span(bytes))
    _ = process_received_frames(client)
    var out_bytes = client.take_out_bytes()
    if len(out_bytes) == 0:
        raise Error(
            "expected GOAWAY in pending_out after corpus seed"
        )
    var res = decode_frame(Span(out_bytes), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error("outbound GOAWAY should decode OK")
    if res.frame.header.kind != FRAME_GOAWAY:
        raise Error(
            "expected GOAWAY; got kind=" + String(Int(res.frame.header.kind))
        )
    print("    OK — corpus seed triggers client GOAWAY emission")


def main() raises:
    print("== L2 h2 client fuzz corpus ==")
    test_seed_settings_ack_with_payload_rejected()
    test_seed_data_on_stream_0_rejected()
    test_seed_zero_increment_window_update_stream_rejected()
    test_seed_zero_increment_window_update_conn_rejected()
    test_integration_seed_triggers_client_goaway()
    print("== L2 fuzz corpus PASSED (5 tests, 4 seeds) ==")
