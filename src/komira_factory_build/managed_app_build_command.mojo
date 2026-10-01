# =============================================================================
# komira_factory_build/managed_app_build_command.mojo — the build-output MARKER
#   contract and its ONE parser.
# =============================================================================
#
# A build that pushes an image reports the result on its terminal stdout. Every
# build channel — the operator's local build-and-push script and the in-pod
# build-flow — speaks the SAME marker contract, and every reader parses it with
# the ONE parser below (`parse_pushed_build_result`), so the channels cannot
# drift apart.
#
#   * NAME  : `PUSHED_IMAGE_DIGEST=` — carries the FULL pullable by-digest ref
#             `<registry>/<app>@sha256:…` (DEPLOY pulls the ref, NOT the bare sha).
#   * COMPANION : `KOMIRA_BUILD_DIGEST_IS_FAKE=<0|1>` — the channel-independent
#             is_fake gate (1 = a content-sha256 fallback that DEPLOY cannot pull).
#   * MATCH : LAST match wins (a rebuild / summary re-echo of either line wins).
#
# The digest the BUILD stage reports is the digest the DEPLOY stage deploys: the
# pipeline records the parsed ref on the run (per-run, never on a catalog
# record) and the deploy step renders it as the served image.
#
# ENCAPSULATION: pure value transformations — no pointers, no cloud, no I/O.
# Flat String / Optional / Bool / Int32 value structs, no byte-slab.
# =============================================================================


# The stdout marker the push tail prints the pushed by-digest ref on (the line the
# BUILD-stage completion handler parses into the run's digest).
comptime PUSHED_DIGEST_MARKER: String = "PUSHED_IMAGE_DIGEST="

# The stdout marker the build scripts print the is_fake gate on (0 = a real pullable
# OCI manifest digest; 1 = the content-sha256 fallback DEPLOY cannot pull). Absent /
# unset is read as 0 (a channel that does not stamp it never emits a fake digest —
# a `crane digest` always yields a real manifest digest).
comptime PUSHED_DIGEST_IS_FAKE_MARKER: String = "KOMIRA_BUILD_DIGEST_IS_FAKE="


# =============================================================================
# §1 — the CANONICAL {digest, is_fake, media_type} result. `media_type` is part
#      of the typed OUTPUT; the two-arg ctor still works (media_type defaults to
#      the OCI manifest media type).
# =============================================================================
comptime OCI_MANIFEST_MEDIA_TYPE: String = (
    "application/vnd.oci.image.manifest.v1+json"
)
"""The default artifact media type — an OCI image manifest (the IMAGE / crane-append
/ kaniko path). `PushedBuildResult.media_type` surfaces it on the OUTPUT value."""


# =============================================================================
# §1a — the typed TERMINAL STATUS. The ONE signal a build supervisor reports for
#       BOTH a SUCCESS (digest, status=SUCCESS) and a FAILURE (error_message,
#       status=FAILURE). A typed Int32 pair, not a loose environment variable.
#       The build-side supervisor POSTs `status` as a bare JSON int (0=SUCCESS,
#       1=FAILURE) to the build-result endpoint; the receiver's completion hook
#       joins on it.
# =============================================================================
comptime BUILD_RESULT_SUCCESS: Int32 = 0
"""The build SUCCEEDED: `PushedBuildResult` carries a real pullable `digest`
(is_fake=False) and an empty `error_message`. The receiver records the digest and
advances the run to DEPLOY."""
comptime BUILD_RESULT_FAILURE: Int32 = 1
"""The build FAILED: `PushedBuildResult` carries NO real digest (digest may be
None / empty) and a non-empty `error_message` (the failure reason). The receiver
marks the run FAILED and moves it to a clean terminal state, so a failed build
never hangs."""


struct PushedBuildResult(Copyable, Movable):
    """The channel-independent build result BOTH the operator's local
    build-and-push channel and the in-pod build-flow channel resolve to, parsed off
    either script's terminal stdout by the ONE canonical parser
    (`parse_pushed_build_result`).

    * `digest`     — the FULL pullable by-digest ref `<registry>/<app>@sha256:…` the
                     LAST `PUSHED_IMAGE_DIGEST=` line carried, or None when the build
                     emitted no digest (a failed / dry-run push).
    * `is_fake`    — the LAST `KOMIRA_BUILD_DIGEST_IS_FAKE=` gate (1 = a content-
                     sha256 fallback DEPLOY cannot pull), or False when the marker is
                     absent (a channel that never stamps it is never fake).
    * `media_type` — the artifact's OCI media type. Defaults to the OCI image
                     manifest type (`OCI_MANIFEST_MEDIA_TYPE`).
    * `status`     — the typed TERMINAL STATUS: `BUILD_RESULT_SUCCESS` (0) or
                     `BUILD_RESULT_FAILURE` (1). This is the ONE signal the supervisor
                     reports for BOTH outcomes. Defaults to SUCCESS in the two- and
                     three-arg ctors and in `parse_pushed_build_result`.
    * `error_message` — the failure reason, populated on FAILURE, empty on SUCCESS.

    A flat value record (Optional[String] + Bool + String + Int32 + String, no
    byte-slab)."""

    var digest: Optional[String]
    var is_fake: Bool
    var media_type: String
    # The typed terminal status + the failure reason. Defaulted to SUCCESS/"" in
    # the two- and three-arg ctors; the `failure` factory sets FAILURE + the message.
    var status: Int32
    var error_message: String

    def __init__(out self, var digest: Optional[String], is_fake: Bool):
        # Two-arg ctor: media_type defaults to the OCI manifest type (the IMAGE /
        # crane-append / kaniko path emits an OCI manifest). A two-arg result is a
        # SUCCESS by construction (no error_message).
        self.digest = digest^
        self.is_fake = is_fake
        self.media_type = OCI_MANIFEST_MEDIA_TYPE
        self.status = BUILD_RESULT_SUCCESS
        self.error_message = String("")

    def __init__(
        out self,
        var digest: Optional[String],
        is_fake: Bool,
        var media_type: String,
    ):
        # Three-arg ctor: an explicit media_type (e.g. a STATIC_TARGZ content
        # artifact carries a different media type than an OCI manifest). Also a
        # SUCCESS by construction (no error_message).
        self.digest = digest^
        self.is_fake = is_fake
        self.media_type = media_type^
        self.status = BUILD_RESULT_SUCCESS
        self.error_message = String("")

    def __init__(
        out self,
        var digest: Optional[String],
        is_fake: Bool,
        var media_type: String,
        status: Int32,
        var error_message: String,
    ):
        # Full ctor: an explicit terminal status + error_message. The `failure`
        # factory routes through this; a SUCCESS caller may also use it.
        self.digest = digest^
        self.is_fake = is_fake
        self.media_type = media_type^
        self.status = status
        self.error_message = error_message^

    @staticmethod
    def failure(var error_message: String) -> PushedBuildResult:
        """A FAILURE terminal: NO real digest (None), is_fake=False, the default
        media type, `status=BUILD_RESULT_FAILURE`, and the failure reason. This is
        what the supervisor resolves to when the build did NOT produce a pullable
        artifact — the receiver's completion hook marks the run FAILED off it."""
        return PushedBuildResult(
            Optional[String](),
            False,
            OCI_MANIFEST_MEDIA_TYPE,
            BUILD_RESULT_FAILURE,
            error_message^,
        )


def parse_pushed_build_result(push_output: String) -> PushedBuildResult:
    """THE ONE parser — resolve every build channel's terminal stdout to the SAME
    `{digest, is_fake}` tuple. Reads the marker contract: the LAST
    `PUSHED_IMAGE_DIGEST=` line (the full pullable by-digest ref) + the LAST
    `KOMIRA_BUILD_DIGEST_IS_FAKE=` line (the is_fake gate, 0/1). LAST match wins on
    BOTH so a rebuild / summary re-echo resolves to the final value.

    A pure value helper (no I/O). The digest is None when no marker line is present;
    is_fake is False when its companion marker is absent (a channel that never
    stamps it emits a real, pullable digest by construction)."""
    var found = Optional[String]()
    var is_fake = False
    var lines = push_output.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        var idx = line.find(PUSHED_DIGEST_MARKER)
        if idx >= 0:
            var start = idx + PUSHED_DIGEST_MARKER.byte_length()
            var val = line[byte=start:]
            # strip trailing CR / spaces (a shell echo may append them).
            var v = val.strip()
            if v.byte_length() > 0:
                found = Optional[String](String(v))
        var fidx = line.find(PUSHED_DIGEST_IS_FAKE_MARKER)
        if fidx >= 0:
            var fstart = fidx + PUSHED_DIGEST_IS_FAKE_MARKER.byte_length()
            var fval = String(line[byte=fstart:].strip())
            # LAST match wins; anything other than "0" (incl. "1") reads as fake.
            is_fake = fval != String("0")
    return PushedBuildResult(found^, is_fake)


# =============================================================================
# §1b — parse_pushed_digest — the digest-only view.
# =============================================================================
def parse_pushed_digest(push_output: String) -> Optional[String]:
    """Parse the by-digest image ref the push tail printed (`PUSHED_IMAGE_DIGEST=
    <repo>/<app>@sha256:...`) out of the push command's stdout. This is the exact
    string the BUILD-stage completion handler records as the run's digest — the
    value the DEPLOY stage renders its served image from. Returns the ref
    (everything after the marker on the LAST matching line, trailing whitespace
    stripped), or None if the push emitted no digest (a failed / dry-run push).

    A thin `.digest` view over the canonical `parse_pushed_build_result` (the ONE
    parser), so digest-only callers and `{digest, is_fake}`-aware callers read the
    SAME LAST-match marker. A pure value helper (no I/O)."""
    var result = parse_pushed_build_result(push_output)
    # Copy the Optional[String] out (it may be None — a failed / dry-run push — so a
    # partial-move `.take()` is unsafe here; Optional[String] is Copyable).
    if result.digest:
        return Optional[String](result.digest.value().copy())
    return Optional[String]()
