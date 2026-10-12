"""The directories (and the classifier) a branch coverage build of a
mojo_library links, runs, annotates and classifies with (README.md;
tools/build/mojo/coverage_branch.bzl)."""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")
load("@komira//tools/build/toolchains/llvm_branch:defs.bzl", "LlvmBranchInfo")

def _branch_dir_impl(ctx):
    llvm = ctx.attrs.llvm[LlvmBranchInfo]

    # Two directories, as cov_link and cov_run are two: each action's key
    # holds only what it reads, so an edit of the tool re-keys no link, and
    # one of the link script no run's inputs but the binary it links. (A
    # projection of one directory would not: an action given
    # `dir.project(p)` is keyed on the whole directory, as measured
    # remotely.) The annotation's directory is a third (the same tool, with
    # lld), and the classifier (a static executable) is given as it is.
    link = ctx.actions.copied_dir("cov_branch_link", {
        "cov_branch_link.sh": ctx.attrs.link_script,
        "llvm/runtime/libclang_rt.profile-x86_64.a": llvm.runtime,
        "lld": llvm.lld_dir,
    })
    tool = ctx.attrs.tool[DefaultInfo].default_outputs[0]
    run = ctx.actions.copied_dir("cov_branch_run", {
        "cov_branch": tool,
        "llvm": llvm.tools_dir,
    })
    annotate = ctx.actions.copied_dir("cov_branch_annotate", {
        "cov_branch": tool,
        "lld": llvm.lld_dir,
        "llvm": llvm.tools_dir,
    })
    classify = ctx.attrs.classify[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_outputs = [link, run, annotate, classify], sub_targets = {
        "annotate": [DefaultInfo(default_output = annotate)],
        "classify": [DefaultInfo(default_output = classify)],
        "link": [DefaultInfo(default_output = link)],
        "run": [DefaultInfo(default_output = run)],
    })]

_cov_branch_dir = rule(
    impl = _branch_dir_impl,
    doc = "The directories and the classifier a branch coverage build of a mojo_library links, runs, annotates and classifies with (tools/build/mojo/coverage_branch.bzl), its default outputs in this order: `[link]`, `cov_branch_link.sh` (`link_script`) with `lld/` (Mojo's lld, of `llvm`, an llvm_branch_tool) and `llvm/runtime/` (the profile runtime); `[run]`, the cov_branch executable (`tool`, whose `run` subcommand the run calls with the raw profile version every run requires, RAW_PROFILE_VERSION of toolchains/llvm_branch/defs.bzl) as `cov_branch`, with `llvm/` (llvm-profdata and its libraries); `[annotate]`, the same executable as `cov_branch` (whose `annotate` subcommand the annotation calls) with `lld/` and `llvm/` (llvm-profdata); and `[classify]`, the cov_branch_classify executable (`classify`). The link script finds its tools (`lld/`, `llvm/`) beside itself, in its own directory; the run and the annotation are given the paths of theirs in their directory; the classifier is a static executable of its own.",
    attrs = {
        "classify": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/branch:cov_branch_classify"),
        "link_script": attrs.source(default = "komira//tools/build/coverage/branch:cov_branch_link.sh"),
        "llvm": attrs.exec_dep(providers = [LlvmBranchInfo], default = "komira//tools/build/toolchains/llvm_branch:llvm_branch"),
        "tool": attrs.exec_dep(providers = [RunInfo], default = "komira//tools/build/coverage/branch:cov_branch_tool"),
    },
)

cov_branch_dir = declares_docs(_cov_branch_dir)
