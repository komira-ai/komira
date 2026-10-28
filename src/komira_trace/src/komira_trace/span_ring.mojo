# =============================================================================
# span_ring.mojo -- the per-worker ring of compact `SpanPacket`s
# =============================================================================
#
# The tracer's hot path writes one 32-byte `SpanPacket` per OPEN and one per
# CLOSE into a per-worker single-producer / single-consumer ring. The ring
# itself is the generic `komira_spsc_ring.SpscRing[T]`; this
# module only names its span instance. The drain (single thread) reads packets,
# joins matching OPEN + CLOSE pairs by `span_id`, and rebuilds `SpanRecord`s for
# the JSONL exporter.
# =============================================================================

from komira_spsc_ring.spsc_ring import SpscRing

from komira_trace.span_packet import SpanPacket


comptime SpanPacketRing = SpscRing[SpanPacket]
