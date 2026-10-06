"""`pinned_file`: one sha256-pinned download.

The download runs on the client and the bytes are uploaded to the remote CAS
like any other input; it is the only client-side operation in this repo.

With the sha256 and the size (`size_bytes`) both stated, the download is
deferred: buck2 contacts the URL only when the remote CAS lacks the blob or
the file is written to local disk. Without a size, buck2 would send a HEAD
request on every fresh daemon to learn it (and a GET when the server sends no
Content-Length), so an upstream outage would fail builds whose outputs are
cached; the size is therefore required. A wrong size is never silent: the
remote cache holds no blob of that (sha256, size), and the download fails
(`DownloadSizeMismatch`) whenever it runs.
"""

load("@komira//tools/build/lint:doc_tree.bzl", "declares_docs")

def _pinned_file_impl(ctx):
    # A fixed path, stated: buck2 may otherwise give a download a
    # content-based path, which it can only compute before downloading from a
    # sha1 and a Content-Length, and GitHub's archive downloads send no
    # Content-Length (the aws-lc and s2n-tls archives fail that way).
    out = ctx.actions.declare_output(ctx.attrs.out or ctx.label.name, has_content_based_path = False)
    ctx.actions.download_file(
        out.as_output(),
        ctx.attrs.url,
        sha256 = ctx.attrs.sha256,
        size_bytes = ctx.attrs.size_bytes,
        is_executable = ctx.attrs.executable,
    )
    if ctx.attrs.executable:
        # An executable pin runs as itself (`$(exe ...)`, `buck2 run`).
        return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]
    return [DefaultInfo(default_output = out)]

pinned_file_rule = rule(
    impl = _pinned_file_impl,
    attrs = {
        "executable": attrs.bool(default = False),
        "out": attrs.option(attrs.string(), default = None),
        "sha256": attrs.string(),
        # The file's length in bytes, required: see the module docstring.
        "size_bytes": attrs.int(),
        "url": attrs.string(),
    },
)

# Each rule and macro a BUCK file calls declares its package's doc_tree
# (tools/build/lint/doc_tree.bzl), so no BUCK file names one.
pinned_file = declares_docs(pinned_file_rule)
