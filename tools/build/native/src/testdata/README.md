# The archives prefix_tool's cases read

[`../cli_test.zig`](../cli_test.zig) reads two static archives of the same two
C files, one of each kind the tool reads
([the README](../../README.md#prefix_tool)):

| archive | layout | members |
|---|---|---|
| `elf_x86_64.a` | System V (GNU `/` symbol table, `//` long names) | x86_64 ELF objects |
| `macho_arm64.a` | BSD (`__.SYMDEF` symbol table, `#1/<n>` names) | arm64 Mach-O objects |

The members are [`fixture_one.c`](fixture_one.c), one symbol of each kind the
reader tells apart (a common symbol, data, a hidden function, a weak
definition, a static function, an undefined and a weak undefined reference),
and [`fixture_second_member.c`](fixture_second_member.c), whose name is longer
than an ar header holds. Both archives must give the same names, the same
header and the same check verdicts.

They were made with zig 0.15.2 (the release of `:zig_next`), in a scratch
directory, each object compiled for its target and archived without
timestamps:

    zig cc -target x86_64-linux-gnu -O1 -fcommon -fno-ident -g0 -c <file>.c -o <file>.o
    zig ar --format=gnu rcsD elf_x86_64.a fixture_one.o fixture_second_member.o

    zig cc -target aarch64-macos -O1 -fcommon -fno-ident -g0 -c <file>.c -o <file>.o
    zig ar --format=darwin rcsD macho_arm64.a fixture_one.o fixture_second_member.o

A change to either C file remakes both archives in the same commit.
