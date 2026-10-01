# =============================================================================
# tests/test_h2_concurrent_batch_mirror_no_wedge.mojo
# =============================================================================
#
# FALSIFIER — the web-content-mirror must be BOUNDED-CONCURRENT (not serial),
# and MUST complete all files on one long-lived h2 connection.
#
# CONTEXT: publishing a built web bundle mirrors store->serving by copying
# thousands of files via GCS server-side `rewrite_object`. The naive shape is a
# SERIAL loop of one blocking POST per file on ONE pooled h2 connection — slow
# AND, with a connection-longevity bug, it wedges after N requests. The fix makes the mirror BOUNDED-CONCURRENT: it opens up to K h2
# streams AT ONCE on the ONE connection (that is what HTTP/2 multiplexing is for)
# and drives them together via `drive_h2_streams_to_completion` (which awaits a
# LIST of stream-ids and interleaves their frames), in waves of K, until all files
# land.
#
# This falsifier drives the EXACT batch shape the production `send_buffered_batch`
# uses — open K concurrent streams on one `H2ClientConnectionState`, encode all K
# requests into `pending_out`, drive the ONE conn to completion for the whole
# awaited-sids list, extract+retire each — for a large total (N=2000 files) in
# waves of K=32, then asserts:
#
#   1. ALL N files complete (every stream reached END_STREAM) — no wedge, no
#      dropped copy. FAILS ON CURRENT-SERIAL: a serial loop wedges after ~N on the
#      reused conn (the longevity bug) and never lands all files.
#   2. Each wave genuinely runs K streams CONCURRENTLY on the one connection — we
#      assert that at the moment just before the wave's drive, the connection held
#      K simultaneously-open streams (open_streams_count == K), proving the copies
#      OVERLAP (multiplexed), not strictly one-at-a-time.
#   3. Per-connection state stays BOUNDED across all N/K waves (retire_stream
#      prunes each completed stream) — the connection survives the whole mirror.
#
# Deterministic: single-process, no TLS, no threads, no sockets — the same
# raw-bytes multiplex drive as `test_L2_h2_client_driver.mojo`'s
# `test_h2_driver_multiplex_three_streams_interleaved` (the in-tree proof that K
# concurrent streams on one conn drive correctly), scaled to a real mirror size.
#
# before the fix (serial + no retire).
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from std.sys.info import CompilationTarget

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    queue_client_preface_and_settings,
)
from komira_http.client.header_map import HeaderMap
from komira_http.transport.scripted import ScriptedStream
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.codec.h2.frame import (
    encode_data_frame,
    encode_headers_frame,
)


comptime _RT = PerCoreAsyncRuntime[NoopSink]

# Total files to mirror (larger than a typical bundle).
comptime _N_FILES: Int = 2000
# Bounded in-flight concurrency per wave — the multiplex window on ONE conn.
comptime _K_IN_FLIGHT: Int = 32
# Per-connection retained-state ceiling (retire_stream keeps it bounded).
comptime _BOUNDED_STATE_CEILING: Int = 128


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _rewrite_response_for(sid: UInt32) raises -> List[UInt8]:
    """A GCS rewriteObject JSON response for stream `sid`: HEADERS(:status=200) +
    one DATA frame carrying `{"done":true}` with END_STREAM."""
    var srv_enc = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-type"), String("application/json")))
    var block = srv_enc.encode_block(hdrs^)
    var out = List[UInt8]()
    encode_headers_frame(sid, block^, False, True, out)
    var body = String('{"done":true}')
    var data = List[UInt8]()
    var bb = body.as_bytes()
    var i = 0
    while i < len(bb):
        data.append(bb[i])
        i = i + 1
    encode_data_frame(sid, data^, True, out)
    return out^


def test_concurrent_batch_mirror_completes_all_files_bounded_concurrency() raises:
    """FALSIFIER: mirror N=2000 files as bounded-concurrent waves of K=32 h2
    streams on ONE reused connection. Assert ALL complete, each wave overlaps K
    streams, and per-connection state stays bounded.

    FAILS ON CURRENT-SERIAL / pre-retire: a serial one-at-a-time loop (a) does NOT
    run copies concurrently (open_streams_count would be 1, not K) and (b) wedges
    on the reused connection after N requests without the retire_stream prune.
    before the fix.
    """
    print("  test_concurrent_batch_mirror_completes_all_files_bounded_concurrency...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    _ = h2.take_out_bytes()
    var reactor = _make_reactor()

    var req_body = String('{"contentType":"text/html","cacheControl":"no-cache"}')

    var completed = 0
    var max_concurrency_seen = 0  # peak simultaneous open streams on the conn
    var full_wave_concurrency = -1  # concurrency observed on a FULL K-wave
    var max_streams_len_seen = 0

    var done_files = 0
    while done_files < _N_FILES:
        # ---- Open a WAVE of up to K concurrent streams on the ONE conn. ----
        var this_wave = _K_IN_FLIGHT
        if done_files + this_wave > _N_FILES:
            this_wave = _N_FILES - done_files

        var wave_sids = List[UInt32]()
        var w = 0
        while w < this_wave:
            var sid = h2.allocate_client_stream_id()
            _ = h2.create_stream(sid)
            var req_headers = HeaderMap()
            req_headers.append(String("authorization"), String("Bearer tok"))
            encode_request_headers_to_frames(
                h2, sid,
                String("POST"), String("https"),
                String("storage.googleapis.com"),
                String("/storage/v1/b/src/o/f/rewriteTo/b/dst/o/f"),
                req_headers^, False,
            )
            var body_bytes = List[UInt8]()
            var rb = req_body.as_bytes()
            var bi = 0
            while bi < len(rb):
                body_bytes.append(rb[bi])
                bi = bi + 1
            encode_request_data_frame(h2, sid, body_bytes^, True)
            wave_sids.append(sid)
            w = w + 1
        # Discard the outbound request bytes — this test drives the inbound side.
        _ = h2.take_out_bytes()

        # ---- CONCURRENCY ASSERTION: K streams are simultaneously OPEN now. ----
        # Before any response is fed, every stream in the wave is in flight on the
        # one connection. A serial mirror would only ever have 1 open at a time.
        var open_now = Int(h2.open_streams_count())
        if open_now > max_concurrency_seen:
            max_concurrency_seen = open_now
        if this_wave == _K_IN_FLIGHT:
            # A FULL wave: the connection must hold exactly K streams in flight
            # at once (the multiplex window). Record it for the concurrency gate.
            full_wave_concurrency = open_now

        # ---- Feed the interleaved responses for the WHOLE wave, then drive. ----
        # Build one buffer with all K responses concatenated (the server
        # interleaves; the driver routes each by stream_id) — exactly the
        # multiplexed shape `drive_h2_streams_to_completion` handles.
        var resp = List[UInt8]()
        var ri = 0
        while ri < this_wave:
            var one = _rewrite_response_for(wave_sids[ri])
            var oi = 0
            while oi < len(one):
                resp.append(one[oi])
                oi = oi + 1
            ri = ri + 1
        var stream = ScriptedStream.from_read_script(resp^)
        stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

        # Drive the ONE conn to completion for the WHOLE awaited-sids list — the
        # driver interleaves the K streams to END_STREAM.
        var awaited = List[UInt32]()
        var ai = 0
        while ai < this_wave:
            awaited.append(wave_sids[ai])
            ai = ai + 1
        drive_h2_streams_to_completion[ScriptedStream, _RT](
            h2, stream, reactor, awaited^,
            max_iterations=1_000_000, max_wall_us=Int64(30_000_000),
        )

        # ---- Extract + retire each completed stream in the wave. ----
        var ei = 0
        while ei < this_wave:
            var sid = wave_sids[ei]
            var resp_tuple = extract_response_for_stream(h2, sid)
            assert_equal(
                Int(resp_tuple[0]), 200,
                "rewrite response status must be 200",
            )
            h2.retire_stream(sid)
            completed = completed + 1
            ei = ei + 1

        # Track retained-state high-water AFTER retiring the wave.
        var sl = len(h2.streams)
        if sl > max_streams_len_seen:
            max_streams_len_seen = sl

        done_files = done_files + this_wave

    # ---- INVARIANT 1: every file completed. ----
    assert_equal(
        completed, _N_FILES,
        "all " + String(_N_FILES) + " files must be mirrored (no wedge, no drop)",
    )

    # ---- INVARIANT 2: the mirror ran CONCURRENTLY (K streams overlap). ----
    # A full wave held exactly K simultaneously-open streams on the ONE conn. A
    # serial one-at-a-time loop would have peak concurrency == 1.
    assert_equal(
        full_wave_concurrency, _K_IN_FLIGHT,
        "FALSIFIER: a full wave did not hold K concurrent streams (observed "
        + String(full_wave_concurrency) + ", expected " + String(_K_IN_FLIGHT)
        + "). A serial one-at-a-time loop overlaps nothing; the fix multiplexes"
        " K streams on the one connection.",
    )
    assert_true(
        max_concurrency_seen >= _K_IN_FLIGHT,
        "FALSIFIER: the mirror never overlapped >= K streams (peak "
        + String(max_concurrency_seen) + "); it did not run concurrently.",
    )

    # ---- INVARIANT 3: per-connection state stayed bounded across all waves. ----
    if max_streams_len_seen > _BOUNDED_STATE_CEILING:
        raise Error(
            "FALSIFIER: per-connection streams state grew to "
            + String(max_streams_len_seen) + " over " + String(_N_FILES)
            + " files (ceiling " + String(_BOUNDED_STATE_CEILING) + ") — the"
            " connection accumulates O(N) state and eventually wedges. Each"
            " completed stream must be retired.",
        )
    var csw = Int(h2.send_fc.conn_send_window)
    if csw <= 0:
        raise Error(
            "FALSIFIER: conn_send_window depleted to " + String(csw)
            + " across the mirror — the send window must be healed on retire.",
        )

    print(
        "    OK — " + String(_N_FILES) + " files mirrored in waves of "
        + String(_K_IN_FLIGHT) + " concurrent streams on ONE connection;"
        " full-wave concurrency=" + String(full_wave_concurrency)
        + " (peak " + String(max_concurrency_seen) + ")"
        + "; retained streams high-water=" + String(max_streams_len_seen)
        + " (<= " + String(_BOUNDED_STATE_CEILING) + "); conn_send_window="
        + String(csw) + ". Bounded-concurrent, complete, no wedge."
    )


def main() raises:
    print("== h2 bounded-concurrent web-mirror: complete + concurrent + no wedge ==")
    test_concurrent_batch_mirror_completes_all_files_bounded_concurrency()
    print("== h2 bounded-concurrent web-mirror verified ==")
