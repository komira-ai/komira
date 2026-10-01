"""`kci_bundle`/output_dispatch.mojo — the ONE shared
`output_format -> (extraction, marker, scheme)` dispatch table.

THE SINGLE SHARED TRUTH. The BUILD
stage has TWO invocation surfaces that MUST agree on how each artifact's output
shape is extracted, which stdout marker carries its digest, and which digest scheme
addresses it:

  1. the OPERATOR verb (the release CLI's build verb, in-operator-process) — parses
     the marker off the recipe's stdout and pins the digest.
  2. the PIPELINE POD (a detached Cloud Run Job) — the job manager stamps the
     artifact descriptor (incl. `output_format`) into the job's config, the
     pod build extracts the SAME shape + emits the SAME marker + phones the digest
     home.

If those two surfaces read DIFFERENT tables they DRIFT — the whole point is
ONE table. This module IS that table, keyed on the proto `OutputFormat` INT
(0/1/2/3) so it stays a pure, dependency-light leaf (no transport, no proto struct
needed to consume — the caller passes the int it already holds). Both surfaces
import from HERE. The resolver dispatches on the `BuildTarget.output_format`
(this table), NOT the manifest node-kind fork.

FOUR OUTPUT SHAPES:
  * IMAGE            -> OCI: nothing extracted (the final stage IS the image),
                       marker `PUSHED_IMAGE_DIGEST=`, scheme `sha256:` (a full
                       `<registry>/<app>@sha256:…` pullable ref), Artifact Registry.
  * LIBRARY_ARTIFACT -> extract the `output` file(s) from a build stage, marker
                       `PUSHED_IMAGE_DIGEST=` (the artifact content digest rides the
                       same OCI-marker slot as an OCI artifact), scheme `sha256:`.
  * STATIC_TARGZ     -> extract the `output` dir + tar.gz it as ONE artifact, marker
                       `PUSHED_CONTENT_DIGEST=`, scheme `content-sha256:`, GCS
                       content store.
  * FILE             -> extract the SINGLE file at `output`, marker
                       `PUSHED_CONTENT_DIGEST=`, scheme `content-sha256:`, GCS
                       content store. The GENERIC file shape — the
                       bytes are opaque here; WHAT the file is belongs to the
                       artifact's ROLE, not to this enum.

⚠ THE (marker, scheme) PAIR IS NOT A KEY. As of FILE, `content-sha256:` addresses
TWO shapes. `scheme_for` is a function; the INVERSE is not. See
`output_format_for_digest`.

Mojo 1.0.0b2 (def-only). Pure — no I/O, no transport, unit-testable in isolation.
"""


# =============================================================================
# §1 — the OutputFormat INT ordinals (mirror the proto `OutputFormat` enum values
#      in app_bundle.proto; kept as `Int` here so this leaf needs no proto import).
# =============================================================================
comptime OUTPUT_FORMAT_IMAGE: Int = 0
"""The Dockerfile's final stage IS the OCI image (docker-image). The DEFAULT."""
comptime OUTPUT_FORMAT_LIBRARY_ARTIFACT: Int = 1
"""Extract `output` from a build stage (mojo-library: .mojopkg/binary)."""
comptime OUTPUT_FORMAT_STATIC_TARGZ: Int = 2
"""Extract `output` dir, package as one .tar.gz (static-files)."""
comptime OUTPUT_FORMAT_FILE: Int = 3
"""★ THE GENERIC FILE SHAPE. Extract the SINGLE file at `output`
and land its bytes VERBATIM in the GCS content store. Digest = `content-sha256:`
over the file bytes.

⛔ GENERIC ON PURPOSE — there is no `OUTPUT_FORMAT_TEMPLATE`. The first consumer
is a deploy template published beside a managed app's image, but WHAT a file
means belongs to the artifact's ROLE, not to the OUTPUT-SHAPE vocabulary. A
TEMPLATE arm would be followed by POLICY / SBOM / OPENAPI arms whose
(extraction, marker, scheme) triples are byte-identical.

⚠ NOT `LIBRARY_ARTIFACT`, though both extract a file: LIBRARY_ARTIFACT rides the
OCI marker/scheme into Artifact Registry, FILE rides `content-sha256:` into the
GCS content store. Same extraction, different DESTINATION STORE."""


# =============================================================================
# §2 — the extraction-strategy ordinals (WHAT is pulled out of the build).
# =============================================================================
comptime EXTRACTION_NONE: Int = 0
"""Nothing extracted — the image IS the output (IMAGE)."""
comptime EXTRACTION_FILE: Int = 1
"""Extract the file(s) at `output` from a build stage (LIBRARY_ARTIFACT)."""
comptime EXTRACTION_TARGZ_DIR: Int = 2
"""Extract the dir at `output`, package as ONE .tar.gz (STATIC_TARGZ)."""


# =============================================================================
# §3 — the CONVERGED stdout markers. ONE marker slot
#      per shape; every recipe's terminal digest step emits its shape's marker and
#      every parser reads it — the two surfaces cannot drift.
# =============================================================================
comptime MARKER_PUSHED_IMAGE_DIGEST: String = "PUSHED_IMAGE_DIGEST="
"""The OCI / library-artifact digest marker (`<registry>/<app>@sha256:…`, LAST
match wins). Shared with the release CLI's build resolver (`kci_build_resolver`)
and `komira_factory_build`."""
comptime MARKER_PUSHED_CONTENT_DIGEST: String = "PUSHED_CONTENT_DIGEST="
"""The static-files content-digest marker (`content-sha256:…`, FIRST match).
Shared with the release CLI's build resolver (`kci_build_resolver`)."""


# =============================================================================
# §4 — the digest SCHEME prefixes (HOW the artifact is addressed).
# =============================================================================
comptime SCHEME_OCI_SHA256: String = "sha256:"
"""OCI manifest digest — a full pullable `<registry>/<app>@sha256:…` ref (IMAGE /
LIBRARY_ARTIFACT)."""
comptime SCHEME_CONTENT_SHA256: String = "content-sha256:"
"""A content digest over the artifact bytes, GCS content store (STATIC_TARGZ over
the tarball; FILE over the single file). Distinct from the OCI scheme so the two
never cross-parse — but NOT distinct BETWEEN the two content shapes, which is why
`output_format_for_digest` cannot tell them apart."""


# =============================================================================
# §5 — the shared dispatch functions. Each maps an `output_format` INT to one facet
#      of the (extraction, marker, scheme) contract. A caller derives ALL three off
#      the SAME int, so the operator verb + the pod path route identically.
# =============================================================================
def output_format_is_known(output_format: Int) -> Bool:
    """True iff `output_format` is one of the four shipped shapes (0/1/2/3). Guards
    a fail-loud on an out-of-range descriptor (a proto from a NEWER writer)."""
    return (
        output_format == OUTPUT_FORMAT_IMAGE
        or output_format == OUTPUT_FORMAT_LIBRARY_ARTIFACT
        or output_format == OUTPUT_FORMAT_STATIC_TARGZ
        or output_format == OUTPUT_FORMAT_FILE
    )


def extraction_for(output_format: Int) raises -> Int:
    """The EXTRACTION strategy for `output_format` (EXTRACTION_* ordinal). IMAGE
    extracts nothing (the image IS the output); LIBRARY_ARTIFACT and FILE each
    extract the single file at `output`; STATIC_TARGZ extracts a dir + tar.gz's it.
    An unknown format is fail-loud."""
    if output_format == OUTPUT_FORMAT_IMAGE:
        return EXTRACTION_NONE
    if output_format == OUTPUT_FORMAT_LIBRARY_ARTIFACT:
        return EXTRACTION_FILE
    if output_format == OUTPUT_FORMAT_STATIC_TARGZ:
        return EXTRACTION_TARGZ_DIR
    if output_format == OUTPUT_FORMAT_FILE:
        # SAME extraction as LIBRARY_ARTIFACT — one file at `output`. The two
        # shapes differ in DESTINATION STORE (see `scheme_for`), not in what is
        # pulled out of the build.
        return EXTRACTION_FILE
    raise Error(
        String("output_dispatch: unknown output_format ordinal ")
        + String(output_format)
        + String(" (expected 0=IMAGE / 1=LIBRARY_ARTIFACT / 2=STATIC_TARGZ / 3=FILE)")
    )


def marker_for(output_format: Int) raises -> String:
    """The converged stdout MARKER prefix the recipe emits + the parser reads for
    `output_format`. IMAGE / LIBRARY_ARTIFACT ride `PUSHED_IMAGE_DIGEST=`;
    STATIC_TARGZ rides `PUSHED_CONTENT_DIGEST=`. An unknown format is fail-loud."""
    if output_format == OUTPUT_FORMAT_IMAGE:
        return MARKER_PUSHED_IMAGE_DIGEST
    if output_format == OUTPUT_FORMAT_LIBRARY_ARTIFACT:
        return MARKER_PUSHED_IMAGE_DIGEST
    if output_format == OUTPUT_FORMAT_STATIC_TARGZ:
        return MARKER_PUSHED_CONTENT_DIGEST
    if output_format == OUTPUT_FORMAT_FILE:
        return MARKER_PUSHED_CONTENT_DIGEST
    raise Error(
        String("output_dispatch: unknown output_format ordinal ")
        + String(output_format)
        + String(" (expected 0=IMAGE / 1=LIBRARY_ARTIFACT / 2=STATIC_TARGZ / 3=FILE)")
    )


def scheme_for(output_format: Int) raises -> String:
    """The digest SCHEME prefix that addresses `output_format`'s artifact. IMAGE /
    LIBRARY_ARTIFACT are OCI `sha256:`; STATIC_TARGZ is `content-sha256:`. An
    unknown format is fail-loud."""
    if output_format == OUTPUT_FORMAT_IMAGE:
        return SCHEME_OCI_SHA256
    if output_format == OUTPUT_FORMAT_LIBRARY_ARTIFACT:
        return SCHEME_OCI_SHA256
    if output_format == OUTPUT_FORMAT_STATIC_TARGZ:
        return SCHEME_CONTENT_SHA256
    if output_format == OUTPUT_FORMAT_FILE:
        return SCHEME_CONTENT_SHA256
    raise Error(
        String("output_dispatch: unknown output_format ordinal ")
        + String(output_format)
        + String(" (expected 0=IMAGE / 1=LIBRARY_ARTIFACT / 2=STATIC_TARGZ / 3=FILE)")
    )


def routes_to_oci(output_format: Int) raises -> Bool:
    """True iff `output_format`'s digest rides the OCI marker/scheme (IMAGE +
    LIBRARY_ARTIFACT) — the resolver's OCI `BuildResolver` arm. False routes to the
    content-sha256 arm (STATIC_TARGZ -> the `WebContentResolver`). This is the ONE
    predicate that replaces the node-kind fork with the output_format dispatch."""
    return scheme_for(output_format) == SCHEME_OCI_SHA256


def output_format_for_digest(digest: String) -> Int:
    """The TRANSPORT ARM a build-once DIGEST addresses, reported as an
    `OUTPUT_FORMAT_*`, by INSPECTING its scheme prefix.

    ⛔ THIS IS NOT THE INVERSE OF `scheme_for`, AND SINCE `OUTPUT_FORMAT_FILE` IT
    CANNOT BE. `scheme_for` maps two shapes (STATIC_TARGZ, FILE) onto the ONE
    `content-sha256:` prefix, so the prefix does not identify a shape and no
    reader of a bare digest can recover one. What this function returns for a
    content digest is therefore the CONTENT-STORE ARM's representative shape
    (STATIC_TARGZ, for compatibility with every existing caller), and the ONLY
    property callers may rely on is the one they actually use:

        routes_to_oci(output_format_for_digest(d)) — the transport arm.

    Anything that needs the SHAPE must read the typed `output_format` off the
    artifact descriptor, never sniff the digest. (The release CLI's stage verb
    routes on the artifact's role, not on the digest.)
      * `content-sha256:<OUT>` -> `OUTPUT_FORMAT_STATIC_TARGZ` (the GCS content-store
        leg — a web dist tree; `routes_to_oci` is False, so stage records the content
        ref, NEVER a crane copy).
      * `sha256:…` (or a `<registry>/<app>@sha256:…` full ref) -> `OUTPUT_FORMAT_IMAGE`
        (the OCI crane-copy leg — existing behavior, unchanged).
    A bare digest matching NEITHER scheme defaults to IMAGE (the plain OCI case). Pure string dispatch; the SSOT for the stage router so the
    CLI never re-derives the scheme->format mapping."""
    if digest.startswith(SCHEME_CONTENT_SHA256):
        return OUTPUT_FORMAT_STATIC_TARGZ
    # `sha256:` OR a `<registry>/<app>@sha256:…` full ref both address an OCI image.
    return OUTPUT_FORMAT_IMAGE
