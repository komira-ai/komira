# =============================================================================
# oci_ref.mojo — the OCI image REFERENCE type + the
#   media-type vocabulary of the OCI distribution / Docker manifest schemas.
# =============================================================================
#
# WHY A PARSED TYPE AND NOT A `String`. Every leg of a registry-to-registry copy
# needs the ref's THREE independent parts on DIFFERENT lines of the wire:
#   * the REGISTRY host goes in the `Host:` header / the TLS SNI,
#   * the REPOSITORY goes in the `/v2/<repository>/…` path,
#   * the REFERENCE (a `sha256:…` digest, or a tag) is the last path segment.
# Passing the joined `String` around and re-splitting it at each call site is how
# a copy silently addresses the wrong repository. `parse_oci_ref` splits ONCE,
# fails loud on a malformed ref, and hands back a value whose fields cannot be
# mis-assembled.
#
# `is_digest` is the type-level guarantee `stage` actually depends on: a
# CONTENT-ADDRESSED copy is only meaningful from a by-digest source. A caller
# that hands `copy_by_digest` a by-TAG source has made a category error, and the
# copier refuses it by reading this flag rather than by re-parsing a String.
#
# Encapsulation: plain owned `String`/`Bool` fields. No pointer crosses the
# boundary; no wildcard origin.
# =============================================================================

from .oci_digest import validate_digest_format


# =============================================================================
# §1 — the media-type vocabulary.
# =============================================================================
#
# A registry copy must send an `Accept` that names EVERY schema it can handle,
# and must PUT a manifest back under the EXACT `Content-Type` the source served
# it as — the manifest digest covers the bytes, but the registry validates the
# bytes against the declared type, and a `Content-Type` swap makes an otherwise
# byte-identical PUT fail (or, worse, be stored under a type that changes how a
# puller resolves it).
#
# BOTH vocabularies are listed because a real registry serves both: images built
# by Docker/kaniko carry the `vnd.docker.distribution.*` types, images built by
# the OCI toolchain carry `vnd.oci.image.*`. A client that accepts only one of
# the two families gets a 404 from the other half of the world.

comptime MEDIA_TYPE_OCI_INDEX: String = "application/vnd.oci.image.index.v1+json"
comptime MEDIA_TYPE_OCI_MANIFEST: String = "application/vnd.oci.image.manifest.v1+json"
comptime MEDIA_TYPE_DOCKER_MANIFEST_LIST: String = "application/vnd.docker.distribution.manifest.list.v2+json"
comptime MEDIA_TYPE_DOCKER_MANIFEST: String = "application/vnd.docker.distribution.manifest.v2+json"


def manifest_accept_header() -> String:
    """The `Accept` a manifest GET must send: ALL four manifest schemas.

    ⚠ ORDER IS NOT PREFERENCE — a registry serving a multi-arch image returns the
    INDEX whenever the index type is acceptable, so listing the index types at
    all is what makes the manifest-list case reachable. A client that omits them
    silently gets served a single child manifest on some registries and a 404 on
    others; either way the copy loses the other architectures."""
    return (
        MEDIA_TYPE_OCI_INDEX
        + String(",")
        + MEDIA_TYPE_OCI_MANIFEST
        + String(",")
        + MEDIA_TYPE_DOCKER_MANIFEST_LIST
        + String(",")
        + MEDIA_TYPE_DOCKER_MANIFEST
    )


def media_type_is_index(media_type: String) -> Bool:
    """True iff `media_type` names a manifest LIST / image INDEX — i.e. a
    manifest whose `manifests[]` entries are themselves manifests to be copied,
    NOT blobs.

    This one predicate is the whole difference between a copy that moves a
    multi-arch image and a copy that moves one architecture and silently drops
    the rest. Matched by PREFIX so a `; charset=utf-8` suffix (which some
    registries append) does not defeat the check."""
    return media_type.startswith(MEDIA_TYPE_OCI_INDEX) or media_type.startswith(
        MEDIA_TYPE_DOCKER_MANIFEST_LIST
    )


# =============================================================================
# §2 — OciImageRef.
# =============================================================================


struct OciImageRef(Copyable, Movable, Deinitable):
    """A parsed OCI image reference: `<registry>/<repository>[@<digest> | :<tag>]`.

    Field layout:
      var registry: String    — the registry HOST (+ optional `:port`), e.g.
                                `europe-docker.pkg.dev`.
      var repository: String  — the FULL repository path under that host, e.g.
                                `example-build/images/app`. On Artifact
                                Registry this is `<project>/<repo>/<image>` —
                                note the GCP project is part of the REPOSITORY,
                                not the host, which is exactly why a
                                cross-project promote is a same-HOST copy.
      var reference: String   — `sha256:<64 hex>` when `is_digest`, else the tag.
      var is_digest: Bool     — True iff `reference` is a content digest.

    Four plain owned fields (String/Bool). No pointer field."""

    var registry: String
    var repository: String
    var reference: String
    var is_digest: Bool

    def __init__(
        out self,
        var registry: String,
        var repository: String,
        var reference: String,
        is_digest: Bool,
    ):
        self.registry = registry^
        self.repository = repository^
        self.reference = reference^
        self.is_digest = is_digest

    def copy(self) -> Self:
        return OciImageRef(
            self.registry.copy(),
            self.repository.copy(),
            self.reference.copy(),
            self.is_digest,
        )

    def render(self) -> String:
        """Re-render the joined ref — the inverse of `parse_oci_ref`, used for
        error messages so a fault names the ref the operator typed."""
        var sep = String("@") if self.is_digest else String(":")
        return self.registry + String("/") + self.repository + sep + self.reference


def parse_oci_ref(image_ref: String) raises -> OciImageRef:
    """Split `<registry>/<repository>[@<digest> | :<tag>]` into its three parts.

    FAIL-LOUD on anything ambiguous. In particular a ref with NO `/` has no
    registry host, and this client deliberately does NOT synthesize the Docker
    Hub default: a ref handed to a stage copy is always fully qualified, and
    inventing a default host for a typo'd ref would send
    credentials to a registry the caller never named.

    The `@` split is taken FIRST and by `rfind`, so a digest's own `:` (as in
    `sha256:…`) can never be mistaken for a tag separator."""
    var slash = image_ref.find(String("/"))
    if slash <= 0:
        raise Error(
            String("oci: malformed image ref '")
            + image_ref
            + String(
                "' — expected <registry-host>/<repository>[@sha256:… | :tag];"
                " no registry host found (this client does not default to Docker"
                " Hub)"
            )
        )
    var registry = String(image_ref[byte=0:slash])
    var rest = String(image_ref[byte=slash + 1 : image_ref.byte_length()])

    var at = rest.rfind(String("@"))
    if at >= 0:
        var repository = String(rest[byte=0:at])
        var digest = String(rest[byte=at + 1 : rest.byte_length()])
        if repository.byte_length() == 0:
            raise Error(
                String("oci: malformed image ref '")
                + image_ref
                + String("' — empty repository before '@'")
            )
        # Validate the digest SHAPE here so a malformed digest is caught at the
        # boundary rather than as a confusing 400 from the registry.
        validate_digest_format(digest, String("image ref '") + image_ref + String("'"))
        return OciImageRef(registry^, repository^, digest^, True)

    var colon = rest.rfind(String(":"))
    if colon > 0:
        var repository2 = String(rest[byte=0:colon])
        var tag = String(rest[byte=colon + 1 : rest.byte_length()])
        return OciImageRef(registry^, repository2^, tag^, False)

    raise Error(
        String("oci: malformed image ref '")
        + image_ref
        + String(
            "' — no '@<digest>' and no ':<tag>'. This client requires an EXPLICIT"
            " reference; it does not default to ':latest' (a stage copy that"
            " silently retargeted 'latest' is how a promote ships the wrong"
            " image)"
        )
    )
