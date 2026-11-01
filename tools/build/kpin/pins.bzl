"""Reading a generated lock (pins.lock.bzl) in a BUCK file or a rule.

    load("@komira//tools/build/kpin:pins.bzl", "npm_kwargs", "pin_kwargs")
    load(":pins.lock.bzl", "NPM", "PINS")

    pinned_file(**pin_kwargs(PINS, "zig", "linux-x86_64", name = "zig_linux_x86_64.tar.xz"))
"""

def _need(d, key, what):
    if key not in d:
        fail("pins.lock.bzl has no {}; known: {}".format(what, ", ".join(sorted(d.keys())) or "(none)"))
    return d[key]

def pin_kwargs(pins, pin, platform, **extra):
    """kwargs for `pinned_file` that fetch pin `pin` for `platform` from the `PINS` of a lock; `extra` (name, visibility, ...) is added. The size is passed as `size_bytes`, which `pinned_file` requires."""
    files = _need(_need(pins, pin, "pin `{}`".format(pin))["files"], platform, "file `{}` of pin `{}`".format(platform, pin))
    kw = {"sha256": files["sha256"], "size_bytes": files["size"], "url": files["url"]}
    kw.update(extra)
    return kw

def pin_version(pins, pin):
    """The version of pin `pin`."""
    return _need(pins, pin, "pin `{}`".format(pin))["version"]

def pin_size(pins, pin, platform):
    """The size in bytes of pin `pin` for `platform`."""
    return _need(_need(pins, pin, "pin `{}`".format(pin))["files"], platform, "file `{}` of pin `{}`".format(platform, pin))["size"]

def npm_kwargs(npm, key, **extra):
    """kwargs for `pinned_file` that fetch the npm tarball `name@version` from the `NPM` of a lock; `extra` is added. The sha256 and `size_bytes` are the ones the farm's CAS keys on, not npm's sha512 (which is `npm[key]["sri512"]`)."""
    e = _need(npm, key, "npm package `{}`".format(key))
    kw = {"sha256": e["sha256"], "size_bytes": e["size"], "url": e["url"]}
    kw.update(extra)
    return kw
