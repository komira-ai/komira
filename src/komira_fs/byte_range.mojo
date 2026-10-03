# =============================================================================
# komira_fs.byte_range — ByteRange POD
# =============================================================================
# Small POD shared by `FileSystem.read_at` and `FileFormat.read_morsel` /
# decode helpers. Carries an (offset, length) pair into a logical file.
#
# Shape: `Movable + Copyable + ImplicitlyCopyable + Deinitable`
# so it can flow through IoOp + Optional containers without copy-cost
# concerns (16 bytes; trivially copyable scalar pair).
#
# Why a struct (not a tuple): named accessors + future room for additional
# fields (alignment hint, hot/cold tag, etc.) without callsite churn.
# =============================================================================


@fieldwise_init
struct ByteRange(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """Logical (offset, length) range into a file. 16-byte POD; safe to
    pass by value through trait method signatures.

    Field set:
      var offset: Int64   # file offset in bytes (>= 0)
      var length: Int64   # range length in bytes (>= 0)
    """

    var offset: Int64
    var length: Int64

    @always_inline
    def end(self) -> Int64:
        """Returns offset + length. Convenience for callers that want the
        exclusive upper bound."""
        return self.offset + self.length

    @always_inline
    def is_empty(self) -> Bool:
        """True when length == 0. Empty ranges are valid (no-op reads)."""
        return self.length == Int64(0)
