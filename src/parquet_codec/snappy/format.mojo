# =============================================================================
# Snappy format constants
# =============================================================================
#
# The tag types and `kMaximumTagLength` are the Mojo decoder's
# (`decompress.mojo`) view of the Snappy format.
#
# `kSlopBytes` is the output-buffer slop a page decoder adds when it sizes the
# destination of a compressed page (the Mojo decoder may write up to
# kSlopBytes past the logical decoded length, so its fast paths can do
# unconditional 16/64-byte writes).
#
# Reference: google/snappy snappy-internal.h (tag types, kMaximumTagLength)
# and snappy.cc (kSlopBytes).
# =============================================================================


# --- Tag types (lowest 2 bits of tag byte) ---
# snappy-internal.h:385-390
comptime LITERAL: Int = 0
comptime COPY_1_BYTE_OFFSET: Int = 1
comptime COPY_2_BYTE_OFFSET: Int = 2
comptime COPY_4_BYTE_OFFSET: Int = 3


# --- Decompressor tuning constants ---
# snappy-internal.h:391: COPY_4_BYTE_OFFSET needs tag + 4-byte offset = 5 bytes.
comptime kMaximumTagLength: Int = 5

# snappy.cc:88 — amount of overshoot the decompressor is allowed to write past
# the logical end of the current element. Enables unconditional 16/64-byte
# writes in the fast path. A page decoder that allocates
# `uncompressed_size + kSlopBytes` of output lets the Mojo decoder use its
# 16-byte-store fast paths up to the end; the C decoder does not need it.
comptime kSlopBytes: Int = 64
