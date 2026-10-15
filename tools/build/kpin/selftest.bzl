"""Load-time test: the golden lock (what kpin writes, checked byte for byte by lockfmt_test.zig) is Starlark Buck2 loads, and pins.bzl reads it."""

load(":pins.bzl", "npm_kwargs", "pin_kwargs", "pin_size", "pin_version")
load(":example.lock.bzl", EXAMPLE_NPM = "NPM", EXAMPLE_PINS = "PINS")

def _expect(what, got, want):
    if got != want:
        fail("kpin: {}: got {}, want {}".format(what, got, want))

_expect(
    "pin_kwargs",
    pin_kwargs(EXAMPLE_PINS, "zig", "linux-x86_64", name = "zig"),
    {
        "name": "zig",
        "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad",
        "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz",
    },
)
_expect("pin_version", pin_version(EXAMPLE_PINS, "zig"), "0.12.0")
_expect("pin_size", pin_size(EXAMPLE_PINS, "zig", "linux-x86_64"), 45480516)
_expect(
    "npm_kwargs",
    npm_kwargs(EXAMPLE_NPM, "@scope/pkg@2.0.1"),
    {
        "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "url": "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz",
    },
)

SELFTEST = "ok"
