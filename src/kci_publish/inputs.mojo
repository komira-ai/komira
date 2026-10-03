# =============================================================================
# src/kci_publish/inputs.mojo -- contract step 0.1 and 0.2: the release
#   directory `kci build` left, checked member by member over the bytes on
#   disk, before anything is read from a channel.
# =============================================================================
#
# `load_release(decls, dir)` refuses (RAISES once, listing every refusal):
#   - `dir` is not a directory;
#   - an entry of `dir` that is neither a declared artifact's directory nor
#     `release.json` (nothing undeclared ships);
#   - a declared artifact with no `<dir>/<name>/` (every declared artifact
#     ships: a partial release cannot publish);
#   - each member's own refusals: `kci_release_set.verify_member`, the SAME
#     function `kci build` ran when the build finished (one manifest, its name
#     the declaration's, bare `file`/`metadata`, nothing else at the top, the
#     file's sha256 and size, the conda metadata agreeing with the manifest);
#   - `release.json` missing, unparsable, or not exactly what the members
#     recompute to under the identity it records (revision, platform; the
#     set hash holds both). It is a commit marker and a convenience, never
#     an authority: everything publish uses is recomputed from the member
#     directories. Whether that identity is the one this run publishes
#     (--revision-id, the action's platform) is the flow's check.
#
# Contract 0.6 holds structurally: `verify_member` reads only inside the
# member's own directory (bare names), and this file reads nothing else but
# `release.json`.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from std.os import listdir
from std.os.path import isdir

from kci_artifact_declaration_proto.artifact_declaration import ArtifactDeclarations
from kci_release_set.member import ReleaseMember, verify_member
from kci_release_set.release_manifest import (
    RELEASE_MANIFEST_NAME,
    ReleaseIdentity,
    ReleaseManifest,
    read_release_manifest,
    release_manifest_of,
)


struct LoadedRelease(Copyable, Movable):
    """Every member, verified, in declaration-file order, and the release
    manifest they recompute to under the recorded identity (its `set_hash`
    is the recomputed one; `revision`, `platform` and `produced_by` are
    `release.json`'s).

    Layout: owned values only. No pointer field."""

    var dir: String
    var members: List[ReleaseMember]
    var recomputed: ReleaseManifest

    def __init__(
        out self,
        var dir: String,
        var members: List[ReleaseMember],
        var recomputed: ReleaseManifest,
    ):
        self.dir = dir^
        self.members = members^
        self.recomputed = recomputed^

    def set_hash(self) -> String:
        return self.recomputed.set_hash.copy()


def _slash(dir: String) -> String:
    if dir.endswith(String("/")):
        return dir.copy()
    return dir + String("/")


def _refuse_all(refusals: List[String]) raises:
    raise Error(
        String("kci publish: the release directory is refused:\n  ")
        + String("\n  ").join(refusals)
    )


def load_release(decls: ArtifactDeclarations, dir: String) raises -> LoadedRelease:
    """Contract steps 0.1 and 0.2 (see the file header)."""
    if not isdir(dir):
        raise Error(
            String("kci publish: the release directory '") + dir + String("' is not a directory")
        )
    var base = _slash(dir)
    var refusals = List[String]()
    var entries = listdir(dir)
    var has_release_json = False
    for i in range(len(entries)):
        var entry = String(entries[i])
        if entry == String(RELEASE_MANIFEST_NAME):
            has_release_json = True
            continue
        var declared = False
        for j in range(len(decls.artifacts)):
            if decls.artifacts[j].name == entry:
                declared = True
        if not declared:
            refusals.append(
                String("'")
                + entry
                + String("' is in the release directory but no artifact of that name is declared")
            )
    var members = List[ReleaseMember]()
    for j in range(len(decls.artifacts)):
        var name = decls.artifacts[j].name.copy()
        var member_dir = base + name
        if not isdir(member_dir):
            refusals.append(
                String("artifact '")
                + name
                + String("' is declared but the release directory holds no '")
                + name
                + String("/'")
            )
            continue
        try:
            members.append(verify_member(name, member_dir))
        except e:
            refusals.append(String(e))
    if not has_release_json:
        refusals.append(
            String("the release directory holds no ")
            + String(RELEASE_MANIFEST_NAME)
            + String(": kci build writes it last, so the build did not finish")
        )
    if len(refusals) > 0:
        _refuse_all(refusals)
    var recorded = read_release_manifest(base + String(RELEASE_MANIFEST_NAME))
    var identity = ReleaseIdentity(
        recorded.revision.copy(),
        recorded.platform.copy(),
        recorded.produced_by_run_id.copy(),
        recorded.produced_by_attempt,
    )
    var recomputed = release_manifest_of(members, identity)
    if recorded.set_hash != recomputed.set_hash or not recorded.same_as(recomputed):
        refusals.append(
            String(RELEASE_MANIFEST_NAME)
            + String(" is not what the member directories recompute to (it says set hash ")
            + recorded.set_hash
            + String(", the members give ")
            + recomputed.set_hash
            + String("): the directory changed after kci build finished")
        )
        _refuse_all(refusals)
    return LoadedRelease(dir.copy(), members^, recomputed^)
