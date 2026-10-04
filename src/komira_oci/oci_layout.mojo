# =============================================================================
# oci_layout.mojo — read the image digest out of a
#   LOCAL OCI layout's `index.json`, instead of asking a registry for it.
# =============================================================================
#
# THE IDEA, AND WHY IT IS BETTER THAN ASKING A REGISTRY. The usual answer to
# "what is the digest of this image?" is `crane digest <ref>` — a NETWORK CALL
# that reports whatever the registry is currently serving for
# that reference. That is a weak provenance claim in two distinct ways:
#
#   * it is a claim about the REGISTRY's present state, not about the artifact
#     the build produced. A tag repointed between build and stage changes the
#     answer, and nothing in the pipeline notices.
#   * it requires the registry to be reachable and the caller to be
#     authenticated merely to learn a fact that was already determined, locally,
#     at build time.
#
# `rules_oci`'s pusher does the better thing: an OCI image layout on disk already
# contains `index.json`, whose `manifests[]` descriptor carries the digest the
# build computed over the bytes it wrote. Reading it is offline, unauthenticated,
# and describes THE ARTIFACT rather than a registry's opinion of a name.
#
# So: where a local layout exists, prefer this. `OciCopier` still verifies every
# byte it moves independently (see `oci_digest.verify_digest`); this module gives
# the pipeline an EXPECTED digest to hold the copy to that was never sourced from
# the thing being checked.
#
# Deliberately NOT a filesystem reader: this takes the `index.json` TEXT. The
# caller owns the read, which keeps this module dependency-free, trivially
# testable, and usable against a layout that lives in a tarball, a CAS, or a
# build-action output rather than a directory.
# =============================================================================

from komira_json import parse_json_value

from .oci_digest import validate_digest_format


def layout_image_digest(index_json: String) raises -> String:
    """The digest of the single image an OCI layout's `index.json` describes.

    RAISES when the layout does not describe EXACTLY ONE image. That strictness
    is the point: a `stage` promotes one artifact, and an `index.json` carrying
    two manifests is either a multi-image bundle (which the caller must
    disambiguate) or a build bug. Silently taking `manifests[0]` would stage a
    coin-flip.

    Note this reads the descriptor's `digest` field — the value the BUILD wrote —
    and validates its shape, but does not and cannot verify it against blob
    bytes it was not given. It is an EXPECTED digest, and its job is to be
    compared against what a copy independently computes."""
    var doc = parse_json_value(index_json)
    if not doc.has(String("manifests")):
        raise Error(
            String(
                "oci: layout index.json has no 'manifests' array — this is not an"
                " OCI image index"
            )
        )
    var arr = doc.get(String("manifests"))
    var n = arr.array_len()
    if n == 0:
        raise Error(
            String(
                "oci: layout index.json describes ZERO images — nothing to stage"
            )
        )
    if n != 1:
        raise Error(
            String("oci: layout index.json describes ")
            + String(n)
            + String(
                " images. A stage promotes exactly one artifact; refusing to"
                " guess which. Select the image by platform or annotation before"
                " staging."
            )
        )
    var entry = arr.element_at(0)
    if not entry.has(String("digest")):
        raise Error(
            String(
                "oci: layout index.json manifest descriptor has no 'digest'"
                " field"
            )
        )
    var digest = entry.get(String("digest")).as_string()
    validate_digest_format(digest, String("layout index.json"))
    return digest^
