# =============================================================================
# tests/test_h2_many_sequential_requests_no_wedge.mojo
# =============================================================================
#
# FALSIFIER — the web-content-conformer h2 CONNECTION-LONGEVITY wedge.
#
# BUG CLASS — unbounded per-connection state growth + never-replenished
# connection SEND window on a LONG-LIVED, REUSED h2 connection:
#
#   `GcpWebFrontend._publish` mirrors a built web bundle store->serving by
#   issuing ~1867 SEQUENTIAL small-body POST `rewrite_object` calls, ALL on the
#   ONE pooled in-process h2 connection to GCS (H2ClientPool reuses the same
#   H2ClientConnectionState across every request — the fd-count=1 multiplex
#   invariant). Two per-connection resources are NEVER reset/pruned per request:
#
#     (D) `H2ClientConnectionState.streams` + `response_header_lists` +
#         `response_body_buffers` are APPENDED to by `create_stream` on every
#         request and NEVER pruned when a stream closes. After N requests the
#         `streams` List holds N entries, so `find_stream_idx` (a LINEAR scan,
#         called per inbound frame) is O(N) and the whole run is O(N^2); the
#         retained per-stream header/body byte Lists also pin O(N) heap. Per-
#         request servicing time climbs SUPERLINEARLY with N until one
#         `drive_h2_streams_to_completion` call spends its whole 120s wall
#         budget in that busywork and raises
#         `HttpError[TIMEOUT]: h2 driver wall-clock deadline exceeded` — the
#         reported symptom (a partial publish of 110+ objects lands first, then
#         one request "stops making END_STREAM progress").
#
#     (latent) `SendFlowController.conn_send_window` is charged DOWN on every
#         request body byte (`consume` decrements the connection window as well
#         as the per-stream window) and is ONLY ever replenished by an inbound
#         server WINDOW_UPDATE(stream_id=0). The recv-side replenish fix
#         credits only the RECV connection window; nothing
#         client-side ever grows the SEND connection window. Against a server
#         that declines to grow it, cumulative request bodies drive
#         `conn_send_window` to <=0, after which `can_send` returns 0, the next
#         request's body can never be framed, END_STREAM is never sent, and the
#         drive wedges. Latent here (GCS does send WINDOW_UPDATE(0)), but a real
#         wedge against a stricter peer — fixed in the same pass.
#
# This falsifier drives the EXACT in-process request/response cycle the
# production pool driver runs (encode request HEADERS+DATA -> feed a synthesized
# server response into `process_received_frames` -> extract) N=2000 times on ONE
# reused `H2ClientConnectionState`, then asserts the per-connection invariants
# that the fix must uphold:
#
#   1. EVERY request completes (END_STREAM seen) — no wedge, no lost request.
#   2. The retained `streams` / `response_header_lists` / `response_body_buffers`
#      stay BOUNDED (a small constant), NOT ~2000 — proving closed-stream state
#      is pruned. FAILS ON CURRENT CODE: pre-fix these grow to N=2000.
#   3. `conn_send_window` never drifts to <=0 across the run — proving the
#      connection send window is not monotonically depleted. FAILS ON CURRENT
#      CODE if a body-carrying variant is run without the send-window fix.
#
# Deterministic: single-process, no TLS, no threads, no sockets. Uses the same
# raw-bytes drive as `test_L2_h2_client_flow_control.mojo`. The end-to-end
# transport proof (real drive_h2_streams_to_completion over many requests with a
# tight wall bound) lives in the driver sibling below.
#
# before the fix.
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http.client.header_map import HeaderMap
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.codec.h2.frame import (
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
    encode_window_update_frame,
    SettingsEntry,
)


# The number of sequential requests to drive on ONE reused connection. Chosen >
# the production ~1867 so this test is a strict superset of the failing shape.
comptime _N_REQUESTS: Int = 2000

# The pruned-state ceiling. After the fix, closed-stream state is retired, so at
# any point the retained `streams` List holds only the in-flight stream(s) plus
# at most a small tombstone slack — NEVER O(N). We assert it stays well under
# this ceiling across the whole run. Pre-fix it grows to _N_REQUESTS.
comptime _BOUNDED_STATE_CEILING: Int = 64


def _synthesize_server_response(
    sid: UInt32, status: String, body: String
) raises -> List[UInt8]:
    """A complete server-side h2 response for stream `sid`:
    HEADERS(:status, end_stream=False) + one DATA frame carrying `body`
    with END_STREAM. Mirrors a GCS rewriteObject JSON response
    (`{"done": true, ...}`)."""
    var srv_enc = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), status))
    hdrs.append(HpackHeader(String("content-type"), String("application/json")))
    var block = srv_enc.encode_block(hdrs^)
    var resp = List[UInt8]()
    encode_headers_frame(sid, block^, False, True, resp)
    var data = List[UInt8]()
    var bb = body.as_bytes()
    var i = 0
    while i < len(bb):
        data.append(bb[i])
        i = i + 1
    encode_data_frame(sid, data^, True, resp)
    return resp^


def test_many_sequential_requests_do_not_wedge_or_grow_unbounded() raises:
    """FALSIFIER: drive _N_REQUESTS sequential small-body POSTs on ONE reused
    H2ClientConnectionState. Assert every request completes AND the retained
    per-connection state stays bounded (pruned), NOT O(N).

    FAILS ON CURRENT CODE: `create_stream` appends to `streams` /
    `response_header_lists` / `response_body_buffers` on every request and
    nothing prunes them on close, so after _N_REQUESTS the `streams` List holds
    _N_REQUESTS entries (>> _BOUNDED_STATE_CEILING) and `find_stream_idx`
    degrades to O(N^2). before the fix.
    """
    print("  test_many_sequential_requests_do_not_wedge_or_grow_unbounded...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()

    # A small JSON metadata body, exactly like the rewriteObject POST body.
    var req_body = String('{"contentType":"text/html","cacheControl":"no-cache"}')

    var completed = 0
    var max_streams_len_seen = 0
    var max_hdr_lists_len_seen = 0
    var max_body_bufs_len_seen = 0

    var r = 0
    while r < _N_REQUESTS:
        # ---- Encode the request on a fresh stream (the production shape). ----
        var sid = client.allocate_client_stream_id()
        _ = client.create_stream(sid)

        var req_headers = HeaderMap()
        req_headers.append(String("authorization"), String("Bearer tok"))
        encode_request_headers_to_frames(
            client, sid,
            String("POST"), String("https"),
            String("storage.googleapis.com"),
            String("/storage/v1/b/src/o/x/rewriteTo/b/dst/o/y"),
            req_headers^, False,  # body follows -> not end_stream on headers
        )
        # Stage the request body (drives conn_send_window down via consume).
        var body_bytes = List[UInt8]()
        var rb = req_body.as_bytes()
        var bi = 0
        while bi < len(rb):
            body_bytes.append(rb[bi])
            bi = bi + 1
        encode_request_data_frame(client, sid, body_bytes^, True)
        # Discard the outbound request bytes — this test drives the INBOUND
        # dispatch + state lifecycle, not the wire.
        _ = client.take_out_bytes()

        # ---- Feed the synthesized server response for THIS stream. ----
        var resp = _synthesize_server_response(
            sid, String("200"), String('{"done":true}')
        )
        client.append_recv_bytes(Span(resp))
        _ = process_received_frames(client)

        # ---- The request must have completed (END_STREAM seen). ----
        var idx = client.find_stream_idx(sid)
        if idx < 0:
            # Post-fix: the stream may already be RETIRED (pruned) once its
            # response was extractable — that is the DESIRED bounded-state
            # behavior, not a failure. We extract below to confirm the body.
            pass
        else:
            if not client.streams[idx].end_stream_seen:
                raise Error(
                    "FALSIFIER: request " + String(r) + " (stream "
                    + String(Int(sid)) + ") did NOT reach END_STREAM — the"
                    " reused h2 connection wedged mid-run (the ~1867-request"
                    " web-publish longevity stall)."
                )
            # Extract + retire the completed stream's state (the fix's prune
            # hook — frees the per-stream header/body Lists + drops the entry).
            var resp_tuple = extract_response_for_stream(client, sid)
            assert_equal(
                Int(resp_tuple[0]), 200,
                "response status must be 200 for request " + String(r),
            )
            client.retire_stream(sid)

        completed = completed + 1

        # ---- Track the retained-state high-water marks across the run. ----
        var sl = len(client.streams)
        if sl > max_streams_len_seen:
            max_streams_len_seen = sl
        var hl = len(client.response_header_lists)
        if hl > max_hdr_lists_len_seen:
            max_hdr_lists_len_seen = hl
        var bl = len(client.response_body_buffers)
        if bl > max_body_bufs_len_seen:
            max_body_bufs_len_seen = bl

        r = r + 1

    # ---- INVARIANT 1: every request completed. ----
    assert_equal(
        completed, _N_REQUESTS,
        "every one of the " + String(_N_REQUESTS) + " sequential requests must"
        " complete on the reused connection",
    )

    # ---- INVARIANT 2: retained per-connection state stayed BOUNDED. ----
    # Pre-fix these grow to _N_REQUESTS. Post-fix they stay under the ceiling
    # because closed-stream state is retired.
    if max_streams_len_seen > _BOUNDED_STATE_CEILING:
        raise Error(
            "FALSIFIER: H2ClientConnectionState.streams grew to "
            + String(max_streams_len_seen) + " entries over " + String(_N_REQUESTS)
            + " sequential requests (ceiling " + String(_BOUNDED_STATE_CEILING)
            + "). Closed-stream state is NOT pruned -> find_stream_idx is O(N),"
            " per-request time climbs superlinearly, and the reused connection"
            " eventually crosses the 120s h2 drive wall bound (the web-publish"
            " longevity wedge). retire_stream must prune closed-stream state."
        )
    if max_hdr_lists_len_seen > _BOUNDED_STATE_CEILING:
        raise Error(
            "FALSIFIER: response_header_lists grew to "
            + String(max_hdr_lists_len_seen) + " (ceiling "
            + String(_BOUNDED_STATE_CEILING) + ") — retained header state not"
            " pruned on stream close."
        )
    if max_body_bufs_len_seen > _BOUNDED_STATE_CEILING:
        raise Error(
            "FALSIFIER: response_body_buffers grew to "
            + String(max_body_bufs_len_seen) + " (ceiling "
            + String(_BOUNDED_STATE_CEILING) + ") — retained body-byte state"
            " not pruned on stream close."
        )

    # ---- INVARIANT 3: connection send window never depleted to <=0. ----
    # Nothing in this deterministic harness feeds the client an inbound
    # WINDOW_UPDATE(0), so the ONLY thing that keeps conn_send_window positive
    # across _N_REQUESTS small bodies is the send-window fix (client-side
    # replenish on stream retire / a per-connection body-window that resets).
    # Pre-fix: after ~1236 requests of ~53-byte bodies conn_send_window <= 0.
    var csw = Int(client.send_fc.conn_send_window)
    if csw <= 0:
        raise Error(
            "FALSIFIER: conn_send_window drifted to " + String(csw)
            + " (<=0) after " + String(_N_REQUESTS) + " request bodies with NO"
            " server WINDOW_UPDATE(0). The connection send window is charged"
            " down per request and never replenished client-side -> the next"
            " request's body can never be framed -> END_STREAM never sent ->"
            " wedge. The send-window fix must keep it positive across a long"
            " sequence of sequential requests."
        )

    print(
        "    OK — " + String(_N_REQUESTS) + " sequential requests all completed;"
        " retained streams high-water=" + String(max_streams_len_seen)
        + " (<= " + String(_BOUNDED_STATE_CEILING) + "); conn_send_window="
        + String(csw) + " (> 0). No longevity wedge."
    )


def test_pre_fix_mechanism_wedges_without_retire() raises:
    """MECHANISM PROOF (the "reproduce-before-fix" companion): drive the SAME
    sequential-request cycle but DELIBERATELY skip `retire_stream` (the exact
    pre-fix code path — nothing pruned closed-stream state, nothing healed the
    send window). Assert the two wedge conditions DO occur, proving the
    falsifier above is genuine and not tautological:

      * `streams` GROWS to N (the O(N) find_stream_idx / O(N^2) run degradation).
      * `conn_send_window` DEPLETES to <=0 (the send-window exhaustion) well
        before N requests.

    This is what production did on the pooled conn before the fix: retire_stream
    did not exist, so the pool driver never pruned or healed. Confirms both
    mechanisms are real. before the fix.
    """
    print("  test_pre_fix_mechanism_wedges_without_retire...")

    var client = H2ClientConnectionState()
    queue_client_preface_and_settings(client)
    _ = client.take_out_bytes()

    var req_body = String('{"contentType":"text/html","cacheControl":"no-cache"}')

    var saw_send_window_deplete = False
    var deplete_at = -1
    var r = 0
    while r < _N_REQUESTS:
        var sid = client.allocate_client_stream_id()
        _ = client.create_stream(sid)
        var req_headers = HeaderMap()
        req_headers.append(String("authorization"), String("Bearer tok"))
        encode_request_headers_to_frames(
            client, sid,
            String("POST"), String("https"),
            String("storage.googleapis.com"),
            String("/storage/v1/b/src/o/x/rewriteTo/b/dst/o/y"),
            req_headers^, False,
        )
        var body_bytes = List[UInt8]()
        var rb = req_body.as_bytes()
        var bi = 0
        while bi < len(rb):
            body_bytes.append(rb[bi])
            bi = bi + 1
        # `encode_request_data_frame` only frames what the CURRENT send window
        # permits; once conn_send_window hits <=0 the body cannot be staged —
        # the pre-fix wedge. Detect the first request where that happens.
        var win_before = Int(client.send_fc.conn_send_window)
        encode_request_data_frame(client, sid, body_bytes^, True)
        _ = client.take_out_bytes()
        if win_before <= 0 and not saw_send_window_deplete:
            saw_send_window_deplete = True
            deplete_at = r
        var resp = _synthesize_server_response(
            sid, String("200"), String('{"done":true}')
        )
        client.append_recv_bytes(Span(resp))
        _ = process_received_frames(client)
        # DELIBERATELY do NOT retire_stream — reproduce the pre-fix path.
        r = r + 1

    # MECHANISM 1: unbounded stream growth (no prune).
    assert_equal(
        len(client.streams), _N_REQUESTS,
        "pre-fix mechanism: without retire, streams grows to N — proving the"
        " O(N) find_stream_idx / superlinear degradation is real",
    )
    # MECHANISM 2: send-window exhaustion (no client-side replenish).
    assert_true(
        saw_send_window_deplete,
        "pre-fix mechanism: without retire, conn_send_window must deplete to <=0"
        " during the run (it never gets healed) — proving the send-window wedge"
        " is real",
    )
    var final_win = Int(client.send_fc.conn_send_window)
    assert_true(
        final_win <= 0,
        "pre-fix mechanism: final conn_send_window must be <=0; got "
        + String(final_win),
    )
    print(
        "    OK — pre-fix mechanism reproduced: streams grew to "
        + String(len(client.streams)) + "; conn_send_window depleted to <=0 at"
        " request " + String(deplete_at) + " (final " + String(final_win)
        + "). The fix (retire_stream) prevents BOTH."
    )


def main() raises:
    print("== h2 connection-longevity: many sequential requests must not wedge ==")
    test_many_sequential_requests_do_not_wedge_or_grow_unbounded()
    test_pre_fix_mechanism_wedges_without_retire()
    print("== h2 connection-longevity verified (bounded state, no wedge) ==")
