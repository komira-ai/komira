# =============================================================================
# komira_crypto/internal — private implementation primitives shared across
# the package's field-arithmetic and FFI-backed implementations.
# =============================================================================
#
# Modules here MUST NOT be imported by anything outside `komira_crypto`.
#
# Packaging and pointer rules:
#   * Filename basenames have no dots (a dotted `.mojoc` basename is
#     unimportable).
#   * Public function signatures take/return scalars + TrivialRegisterPassable
#     PODs only; ZERO UnsafePointer / wildcard origins / unsafe_from_address.
# =============================================================================
