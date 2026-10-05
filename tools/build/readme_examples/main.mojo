"""The README examples tool: a README's ```mojo examples as a program.

    tool generate --readme <README.md> --display <name> --package <import name>
                  --links allow|refuse --out <program.mojo> --count <file>
        Writes the program that runs every example to --out, and the number
        of examples to --count. With no example, --out holds a comment
        saying so and --count `0`: the caller compiles and runs nothing.
        --links refuse: refuse a relative link (a README that ships in its
        package). Every flag is required.
    tool map --program <program.mojo> --package <import name> --display <name> --report <file>
        Prints the report with each `readme_<package>.mojo:<L>` naming a
        copied line rewritten to `<display>:<n>`.

Exit status: 0; 1 when the README is refused (each reason on its own line,
naming `<display>:<line>`); 2 on bad usage or a file it cannot read.
"""

from std.sys import argv, exit
from readme_examples.examples import extract_examples
from readme_examples.program import generate_program, map_report


def _usage(why: String):
    print("readme-examples: " + why)
    print(
        "usage: tool generate --readme F --display NAME --package NAME --links allow|refuse --out F --count F\n"
        + "       tool map --program F --package NAME --display NAME --report F"
    )
    exit(2)


def _flags(args: List[String], names: List[String]) -> List[String]:
    """The value of each flag in `names`, every one required, none twice."""
    var values = List[String](length=len(names), fill=String(""))
    var seen = List[Bool](length=len(names), fill=False)
    var i = 2
    while i < len(args):
        var a = args[i]
        var value = String("")
        var name = a
        var eq = a.find("=")
        if eq >= 0:
            name = String(a[byte=0:eq])
            value = String(a[byte = eq + 1 :])
        elif i + 1 < len(args):
            value = args[i + 1]
            i += 1
        else:
            _usage(a + " needs a value")
        var found = -1
        for k in range(len(names)):
            if "--" + names[k] == name:
                found = k
        if found < 0:
            _usage("unknown flag " + name)
        if seen[found]:
            _usage(name + " given twice")
        seen[found] = True
        values[found] = value
        i += 1
    for k in range(len(names)):
        if not seen[k] or values[k].byte_length() == 0:
            _usage("--" + names[k] + " is required")
    return values^


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _write(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def main() raises:
    var raw = argv()
    var args = List[String]()
    for i in range(len(raw)):
        args.append(String(raw[i]))
    if len(args) < 2:
        _usage("no subcommand")
    var cmd = args[1]
    if cmd == "generate":
        var v = _flags(args, ["readme", "display", "package", "links", "out", "count"])
        if v[3] != "allow" and v[3] != "refuse":
            _usage("--links is allow or refuse, not " + v[3])
        var text = String("")
        try:
            text = _read(v[0])
        except e:
            print("readme-examples: cannot read " + v[0] + ": " + String(e))
            exit(2)
        try:
            var examples = extract_examples(text, v[1], v[3] == "refuse")
            if len(examples) == 0:
                _write(v[4], "# " + v[1] + " holds no ```mojo example: nothing to compile or run.\n")
            else:
                _write(v[4], generate_program(examples, v[2], v[1]))
            _write(v[5], String(len(examples)) + "\n")
        except e:
            print(String(e))
            exit(1)
    elif cmd == "map":
        var v = _flags(args, ["program", "package", "display", "report"])
        try:
            print(map_report(_read(v[3]), _read(v[0]), v[1], v[2]), end="")
        except e:
            print("readme-examples: " + String(e))
            exit(2)
    else:
        _usage("unknown subcommand " + cmd)
