"""Load-time cases of `oci_tree`'s path refusals: what nests is refused, what does not is accepted.

`oci_tree_cases()` runs `oci_tree_refusals` (defs.bzl), the check `oci_tree`
fails on, over path sets whose answer is known, and fails loading this
package if any answer is wrong. Every image build loads the package (its
packer is here), so an image cannot be built while a case is wrong.
"""

load(":defs.bzl", "oci_tree_refusals")

# name -> (bundle paths, file paths, the refusals wanted)
def _cases():
    return {
        "the base image's tree": (["komira/", "opt/kci/"], ["bin/sh"], []),
        "a file inside a bundle": (["komira/"], ["komira/bin/supervisor"], ["`komira/bin/supervisor` is inside `komira/`"]),
        "a bundle inside a bundle": (["opt/", "opt/kci/"], [], ["`opt/kci/` is inside `opt/`"]),
        "a file inside a file": ([], ["a", "a/b"], ["`a/b` is inside `a`"]),
        "a bundle at a file's path": (["bin/"], ["bin"], ["`bin/` is inside `bin`"]),
        "a shared name prefix is not nesting": (["komira/", "komira2/"], ["bin/sh", "bin/sh2", "bin/s"], []),
        "a bundle path without /": (["komira"], [], ["bundle path `komira` must be a plain relative path ending in /"]),
        "an absolute file path": ([], ["/bin/sh"], ["file path `/bin/sh` must be a plain relative path"]),
        "a .. part": (["a/../b/"], ["c/../d"], [
            "bundle path `a/../b/` must be a plain relative path ending in /",
            "file path `c/../d` must be a plain relative path",
        ]),
        "a . part": ([], ["./bin/sh"], ["file path `./bin/sh` must be a plain relative path"]),
        "whiteout names are plain names": ([], ["etc/.wh.ssl", "etc/ssl/certs/.wh..wh..opq"], []),
    }

def oci_tree_cases():
    wrong = []
    for name, (bundles, files, want) in _cases().items():
        got = oci_tree_refusals(bundles, files)
        if got != want:
            wrong.append("{}: got {}, want {}".format(name, got, want))
    if wrong:
        fail("oci_tree cases:\n  " + "\n  ".join(wrong))
