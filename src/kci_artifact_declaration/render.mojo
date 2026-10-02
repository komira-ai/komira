# =============================================================================
# kci_artifact_declaration/render.mojo -- the argv kci runs to build one
#   artifact into one output directory.
# =============================================================================
#
#   [executable] + build_system.args + artifact.args
#
# with `{out_dir}` substituted in every arg (never in the executable, which
# the validator holds to a program name or an absolute path). A PURE
# function: it creates no directory and runs nothing; `kci build` owns both.
# It expects a validated value (`parse_artifact_declarations` returns only
# those) and refuses an unknown artifact, an undeclared build system and an
# out_dir that is not an absolute path, so a wrong call cannot run a build
# against a relative directory.
#
# Owned values only; no pointer.
# =============================================================================

from kci_artifact_declaration_proto.artifact_declaration import ArtifactDeclarations

from .contract import substitute_out_dir
from .validate import find_artifact, find_build_system


def render_build_argv(
    decls: ArtifactDeclarations, artifact: String, out_dir: String
) raises -> List[String]:
    """The argv that builds the artifact named `artifact` into `out_dir`."""
    if not out_dir.startswith(String("/")):
        raise Error(
            String("out_dir '")
            + out_dir
            + String("' is not an absolute path")
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
    var argv = List[String]()
    argv.append(b.executable.copy())
    for k in range(len(b.args)):
        argv.append(substitute_out_dir(b.args[k], out_dir))
    for k in range(len(a.args)):
        argv.append(substitute_out_dir(a.args[k], out_dir))
    return argv^
