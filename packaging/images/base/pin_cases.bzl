"""Load-time cases of the base pin: a tag is refused, the pinned digests are accepted.

`base_pin_cases()` runs `oci_base_refusals` (tools/build/package/defs.bzl),
the check `oci_base` fails on, over the base this image is built FROM and over
references that name a tag, and fails loading the package (so building
`:komira_base`) if any answer is wrong.
"""

load("@komira//tools/build/package:defs.bzl", "oci_base_refusals")
load("@komira//tools/build/platforms:table.bzl", "row")

_D = "sha256:" + "0" * 64

def _pin(**over):
    base = row("linux-x86_64")["oci_base"]
    kw = {
        "config": base["config"],
        "layer_sizes": base["layer_sizes"],
        "layers": base["layers"],
        "manifest": base["manifest"],
    }
    kw.update(over)
    return kw

# name -> (pins, refused?)
def _cases():
    return {
        "the pinned base": (_pin(), False),
        "manifest by tag": (_pin(manifest = "nonroot"), True),
        "manifest as a tagged reference": (_pin(manifest = "distroless/base-debian12:nonroot"), True),
        "manifest as a reference holding a tag and a digest": (_pin(manifest = "base-debian12:nonroot@" + _D), True),
        "manifest as `latest`": (_pin(manifest = "latest"), True),
        "manifest with a short digest": (_pin(manifest = _D[:-1]), True),
        "manifest with upper-case hex": (_pin(manifest = "sha256:" + "A" * 64), True),
        "config by tag": (_pin(config = "nonroot"), True),
        "a layer by tag": (_pin(layers = ["nonroot"] + row("linux-x86_64")["oci_base"]["layers"][1:]), True),
        "no layers": (_pin(layers = [], layer_sizes = []), True),
    }

def base_pin_cases():
    wrong = []
    for name, (kw, refused) in _cases().items():
        got = oci_base_refusals(**kw)
        if refused and not got:
            wrong.append("{}: accepted, want refused".format(name))
        if not refused and got:
            wrong.append("{}: refused ({}), want accepted".format(name, "; ".join(got)))
    if wrong:
        fail("base pin cases:\n  " + "\n  ".join(wrong))
