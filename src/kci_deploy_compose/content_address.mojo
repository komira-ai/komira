# =============================================================================
# kci_deploy_compose/content_address.mojo — the SHA-256 content-address of a
#   synthesized FullManifest (synth-once).
# =============================================================================
#
# WHAT THIS IS. A FullManifest is synthesized ONCE at run create/plan and PINNED
# into the run's rows content-addressed (desired-state producers materialize
# once, content-addressed). This function computes that address: the SHA-256
# over the manifest's CANONICAL protobuf-binary encoding. The pinned copy is what
# the deployer consumes; a mid-flight redeploy of the deploying system therefore
# cannot silently change desired state (the address would change, and the run
# reads its pinned rows).
#
# THE PREIMAGE INVARIANT. The `FullManifest.content_address` field is itself
# part of the message, so hashing the message with the field already stamped
# would be self-referential. The preimage is therefore the manifest encoded with
# `content_address` CLEARED (empty). This function is self-contained +
# idempotent: it copies the manifest, zeroes `content_address`, encodes, and
# hashes — so `content_address(m)` returns the SAME value whether or not `m`
# already carries a stamped address. That makes stamp-then-verify a stable
# invariant (see the golden test) and makes the whole synth deterministic.
#
# DETERMINISM IS LOAD-BEARING. `encode_proto` is a pure function of the struct,
# so the same manifest in yields byte-identical bytes + hash out. The one
# ordering hazard — the `ConfigSpec.values` map — is handled at the SYNTH site
# (compose_api inserts config keys in a deterministic bundle-order), and this
# function hashes whatever ordered bytes the encoder produced; two identical
# compositions hash identically.
#
# Encapsulation: value-typed FullManifest in, String out; `raises` on an encode
# fault. ZERO UnsafePointer, ZERO wildcard origin.
# =============================================================================

from komira_proto_codec import encode_proto
from komira_crypto.sha256 import sha256
from komira_crypto.hex import hex_lower_array_32

from kci_manifest_proto.full_manifest import FullManifest


# The address is prefixed `sha256:` so the algorithm is self-describing on the
# wire (matches the image-digest `sha256:...` convention used throughout the
# deploy stack) and a future algorithm swap is unambiguous.
comptime CONTENT_ADDRESS_ALGO_PREFIX: String = "sha256:"


def content_address(manifest: FullManifest) raises -> String:
    """The SHA-256 content-address of a FullManifest (synth-once).

    The preimage is the manifest's protobuf-binary encoding with the
    `content_address` field CLEARED (the field cannot address itself). The
    result is `sha256:` + lowercase-hex(SHA-256(preimage)) — a 71-char string
    (7-char prefix + 64 hex chars). Idempotent: stamping the result back into
    `manifest.content_address` and re-calling yields the identical value.
    """
    var preimage = manifest.copy()
    preimage.content_address = String("")
    var bytes = encode_proto[FullManifest](preimage)
    var digest = sha256(Span[UInt8](bytes))
    return CONTENT_ADDRESS_ALGO_PREFIX + hex_lower_array_32(digest)
