"""The `uv publish` capture of kci_pkg_upload's fidelity fixtures, as build
actions (tests/fidelity/README.md).

Both rules run `uv_fidelity` (tests/fidelity/main.zig) with the pinned uv
(komira//third_party/uv), so the loopback recorder binds 127.0.0.1 inside
the action, on the worker. `uv_fidelity_capture`'s output is the fixture
directory; `uv_fidelity_check` captures the same way and compares with the
committed fixtures, and has an output only when they agree.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _out(dep):
    return dep[DefaultInfo].default_outputs[0]

def _capture_impl(ctx):
    out = ctx.actions.declare_output("fidelity", dir = True)
    ctx.actions.run(
        cmd_args(ctx.attrs.tool[RunInfo], "capture", "--uv", _out(ctx.attrs.uv), "--out", out.as_output()),
        category = "uv_fidelity_capture",
    )
    return [DefaultInfo(default_output = out)]

_uv_fidelity_capture = rule(
    impl = _capture_impl,
    doc = "Runs the pinned `uv publish` at a loopback recorder for each probe wheel: a directory of `<case>.whl`, `<case>.METADATA` and `<case>.request`.",
    attrs = {
        "tool": attrs.exec_dep(providers = [RunInfo], doc = "`:uv_fidelity`, tests/fidelity/main.zig built."),
        "uv": attrs.exec_dep(doc = "The pinned uv executable, komira//third_party/uv:uv_dist[uv]."),
    },
)

def _check_impl(ctx):
    committed = ctx.actions.copied_dir("committed", {f.basename: f for f in ctx.attrs.fixtures})
    out = ctx.actions.declare_output(ctx.label.name + ".passed")
    ctx.actions.run(
        cmd_args(
            ctx.attrs.tool[RunInfo],
            "check",
            "--uv",
            _out(ctx.attrs.uv),
            "--fixtures",
            committed,
            "--out",
            out.as_output(),
        ),
        category = "uv_fidelity_check",
    )
    return [DefaultInfo(default_output = out)]

_uv_fidelity_check = rule(
    impl = _check_impl,
    doc = "Captures as `uv_fidelity_capture` does and compares with the committed fixtures, byte for byte (a `.request` after its random boundary is normalised); fails with a diff summary when they differ.",
    attrs = {
        "fixtures": attrs.list(attrs.source(), doc = "The committed fixtures, every `<case>.<ext>` the capture writes."),
        "tool": attrs.exec_dep(providers = [RunInfo], doc = "`:uv_fidelity`, tests/fidelity/main.zig built."),
        "uv": attrs.exec_dep(doc = "The pinned uv executable, komira//third_party/uv:uv_dist[uv]."),
    },
)

def _uv_fidelity_targets(tool, uv, fixtures, exec_compatible_with):
    """`:uv_fidelity_capture` and `:uv_fidelity_check`, declared only when
    the build is given `-c komira.uv_fidelity=true`: both need the uv
    download and run uv, so no `//...` build, derived unit or pull-request
    check builds them."""
    if read_config("komira", "uv_fidelity", "false").strip() != "true":
        return
    _uv_fidelity_capture(
        name = "uv_fidelity_capture",
        exec_compatible_with = exec_compatible_with,
        tool = tool,
        uv = uv,
    )
    _uv_fidelity_check(
        name = "uv_fidelity_check",
        exec_compatible_with = exec_compatible_with,
        fixtures = fixtures,
        tool = tool,
        uv = uv,
    )

uv_fidelity_targets = declares_docs(_uv_fidelity_targets)
