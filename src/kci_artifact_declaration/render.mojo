# =============================================================================
# kci_artifact_declaration/render.mojo -- the argv kci runs to build one
#   artifact into one output directory.
# =============================================================================
#
#   [executable] + build_system.args + artifact.args
#
# with every placeholder substituted in every arg (never in the executable,
# which the validator holds to a program name or an absolute path):
# `{out_dir}` is `<release_dir>/<artifact>`, `{release_dir}` the release
# directory, and the four stamp placeholders the `ReleaseStamp`'s values
# (contract.mojo). A PURE function: it creates no directory and runs
# nothing; `kci build` owns both. It expects a validated value
# (`parse_artifact_declarations` returns only those) and refuses an unknown
# artifact, an undeclared build system, and a release_dir that is not an
# absolute path other than `/` or that ends in `/`, so a wrong call cannot
# run a build against a relative directory.
#
# Owned values only; no pointer.
# =============================================================================

from kci_artifact_declaration_proto.artifact_declaration import ArtifactDeclarations

from .contract import BuildValues, ReleaseStamp, substitute_placeholders
from .validate import find_artifact, find_build_system


def render_build_argv(
    decls: ArtifactDeclarations, artifact: String, release_dir: String, stamp: ReleaseStamp
) raises -> List[String]:
    """The argv that builds the artifact named `artifact` into
    `<release_dir>/<artifact>`."""
    if not release_dir.startswith(String("/")) or release_dir.endswith(String("/")):
        raise Error(
            String("release_dir '")
            + release_dir
            + String("' is not an absolute path (other than '/', with no trailing '/')")
        )
    var i = find_artifact(decls, artifact)
    if i < 0:
        raise Error(String("no artifact '") + artifact + String("' is declared"))
    ref a = decls.artifacts[i]
    var j = find_build_system(decls, a.build_system)
    if j < 0:
        raise Error(
            String("artifact '")
            + artifact
            + String("': build_system '")
            + a.build_system
            + String("' is not declared")
        )
    ref b = decls.build_systems[j]
    var values = BuildValues(release_dir + String("/") + artifact, release_dir.copy(), stamp.copy())
    var argv = List[String]()
    argv.append(b.executable.copy())
    for k in range(len(b.args)):
        argv.append(substitute_placeholders(b.args[k], values))
    for k in range(len(a.args)):
        argv.append(substitute_placeholders(a.args[k], values))
    return argv^
