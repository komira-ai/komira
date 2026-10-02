# The `kci_publish` binary: `kci publish` on its own, until the kci binary
# dispatches its `publish` verb to the same `publish_main`.

from std.sys import argv, exit

from kci_publish import publish_main


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    exit(publish_main(args))
