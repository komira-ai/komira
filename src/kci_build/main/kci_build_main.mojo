# The `kci_build` binary: `kci build` on its own, until the kci binary
# dispatches its `build` verb to the same `build_main`.

from std.sys import argv, exit

from kci_build import build_main


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    exit(build_main(args))
