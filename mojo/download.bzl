"""`pinned_file`: one sha256-pinned download.

The download runs on the client and the bytes are uploaded to the remote CAS
like any other input; it is the only client-side operation in this repo.
"""

def _pinned_file_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.out or ctx.label.name)
    ctx.actions.download_file(
        out.as_output(),
        ctx.attrs.url,
        sha256 = ctx.attrs.sha256,
        is_executable = ctx.attrs.executable,
    )
    return [DefaultInfo(default_output = out)]

pinned_file = rule(
    impl = _pinned_file_impl,
    attrs = {
        "executable": attrs.bool(default = False),
        "out": attrs.option(attrs.string(), default = None),
        "sha256": attrs.string(),
        "url": attrs.string(),
    },
)
