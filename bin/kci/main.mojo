# The kci binary: argv to kci_cli.kci_main. Nothing else lives here.

from std.sys import argv, exit

from kci_cli import kci_main


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    exit(kci_main(args))
