"""The directories a branch coverage build of a mojo_library links and runs
from (README.md; tools/build/mojo/coverage_branch.bzl)."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/toolchains/llvm_branch:defs.bzl", "LlvmBranchInfo", "RAW_PROFILE_VERSION")

def _branch_dir_impl(ctx):
    llvm = ctx.attrs.llvm[LlvmBranchInfo]

    # Two directories, as cov_link and cov_run are two: each action's key
    # holds only what it reads, so an edit of the run script (or of
    # raw_version) re-keys no link, and one of the link script no run's
    # inputs but the binary it links. (A projection of one directory would
    # not: an action given `dir.project(p)` is keyed on the whole directory,
    # as measured remotely.)
    link = ctx.actions.copied_dir("cov_branch_link", {
        "cov_branch_link.sh": ctx.attrs.link_script,
        "llvm/runtime/libclang_rt.profile-x86_64.a": llvm.runtime,
        "lld": llvm.lld_dir,
    })
    run = ctx.actions.copied_dir("cov_branch_run", {
        "cov_branch_run.sh": ctx.attrs.run_script,
        "llvm": llvm.tools_dir,
        "raw_version": ctx.actions.write("cov_branch_raw_version", "{}\n".format(RAW_PROFILE_VERSION)),
    })
    return [DefaultInfo(default_outputs = [link, run], sub_targets = {
        "link": [DefaultInfo(default_output = link)],
        "run": [DefaultInfo(default_output = run)],
    })]

_cov_branch_dir = rule(
    impl = _branch_dir_impl,
    doc = "The two directories a branch coverage build of a mojo_library links and runs from (tools/build/mojo/coverage_branch.bzl), its default outputs in this order: `[link]`, `cov_branch_link.sh` (`link_script`) with `lld/` (Mojo's lld, of `llvm`, an llvm_branch_tool) and `llvm/runtime/` (the profile runtime); and `[run]`, `cov_branch_run.sh` (`run_script`) with `llvm/` (llvm-profdata and its libraries) and `raw_version`, the raw profile version every run requires (RAW_PROFILE_VERSION of toolchains/llvm_branch/defs.bzl). Each script finds the others beside itself.",
    attrs = {
        "link_script": attrs.source(default = "komira//tools/build/coverage/branch:cov_branch_link.sh"),
        "llvm": attrs.exec_dep(providers = [LlvmBranchInfo], default = "komira//tools/build/toolchains/llvm_branch:llvm_branch"),
        "run_script": attrs.source(default = "komira//tools/build/coverage/branch:cov_branch_run.sh"),
    },
)

cov_branch_dir = declares_docs(_cov_branch_dir)
