# Test 38: README examples

The checks of [test 38](README.md#38-readme-examples), run by
[`run_tests.sh`](run_tests.sh).

A library's `README.md` examples are a welded test, `[tests][readme]`
([README examples](../mojo/README.md#readme-examples)): each example is a
program of its own, compiled and run as its own gated test, and the marker
holds one `PASS <target>:README.md:<line>` per example. The programs are
written by the Zig tool
[`//tools/build/readme_examples:tool`](../readme_examples/BUCK), whose
welded unit tests (`:readme_examples_unit`: what an example is, the two
modes, hidden lines, every refusal, line n of a program on README line n,
the runner, the line map and the command line) pass before any README is
read; the targets below check the whole path, the compile and run included.
[`functional/readme_examples/ok`](functional/readme_examples/ok/BUCK) builds a
README using every form (hidden lines, a `mojo module` example declaring a
decorated struct and a triple-quoted string, an example in a list item, a
`~~~~` fence quoting ```` ``` ````) and its marker starts with a PASS line;
[`functional/readme_examples/per_block`](functional/readme_examples/per_block/BUCK)
holds two ```` ```mojo ```` examples that import the same name and declare the
same names (`twice`, `said`), which one shared program could not compile
(redefinition), and
[`functional/readme_examples/module_mode`](functional/readme_examples/module_mode/BUCK)
three ```` ```mojo module ```` examples, each with its own `main` and all
declaring `struct Pair`, hidden lines before the first and the third fenced
inside a list item (so a fence's indent cannot cost it its mode: as a plain
example its struct would land in `main` and not compile): each marker is
exactly one PASS line per example.
[`functional/readme_examples/none`](functional/readme_examples/none/BUCK), a
README with no example, builds and its marker reads `NO EXAMPLE`, so nothing
was compiled or run. [`negative/readme_examples`](negative/readme_examples/raises/BUCK)
plants defects, each of which must fail naming its README line: an example
that raises (`GATED TEST FAILED: <target>:README.md:13`, and no failure
names the other example), one that does not compile (the compiler names
`readme_compile_error_6.mojo:9:11`: line 9 of the program is README line
9), a struct in a plain ```` ```mojo ```` example
([`struct_untagged`](negative/readme_examples/struct_untagged/BUCK): the mode
is the fence tag's alone, so the struct lands in `main`, where the compiler
refuses it, at `readme_struct_untagged_7.mojo:9:5`) and a `mojo skip` fence
(refused at `README.md:3`).
A README that ships (its library has a conda package, which installs it at
`share/doc/<name>/README.md`) refuses a relative link:
[`negative/readme_examples/relative_link`](negative/readme_examples/relative_link/BUCK)
fails naming `README.md:11`, and
[`functional/readme_examples/unshipped`](functional/readme_examples/unshipped/BUCK),
the same README in a library with `conda = False`, builds.
A BUCK file of several libraries says which one a README is about
(`readme`, [tools/build/mojo/readme.bzl](../mojo/readme.bzl)):
[`functional/readme_examples/owner`](functional/readme_examples/owner/BUCK)
declares `owner_base` (`readme = False`) and `owner` (`readme = True`, it
depends on `owner_base`) beside a README that imports `owner`; both build,
`owner`'s marker is a PASS line, and `owner_base` has no `[tests][readme]`.
[`negative/readme_examples/unowned`](negative/readme_examples/unowned/BUCK),
the same package without the keyword, fails: the README is attached to
`unowned_base` too, which does not reach `unowned` (the compiler names
`readme_unowned_base_6.mojo:7:10`, README line 7).
[`negative/readme_examples/readme_keyword`](negative/readme_examples/readme_keyword/BUCK)
fails loading, per `-c readme_keyword.case=`, for `readme = True` in a
package with no README.md and for a `readme` that is not True or False.

```sh
./buck2 build tests//functional/readme_examples/...
./buck2 build tests//negative/readme_examples/unowned:unowned_base   # must fail: readme_unowned_base_6.mojo:7
./buck2 build -c readme_keyword.case=true_without_readme tests//negative/readme_examples/readme_keyword:kw   # must fail: holds no README.md
./buck2 build tests//negative/readme_examples/raises:raises   # must fail: GATED TEST FAILED: ...:README.md:13
./buck2 build tests//negative/readme_examples/compile_error:compile_error   # must fail: readme_compile_error_6.mojo:9:11
./buck2 build tests//negative/readme_examples/struct_untagged:struct_untagged   # must fail: struct inside a function
./buck2 build tests//negative/readme_examples/relative_link:relative_link   # must fail: README.md:11: greet.mojo: a relative link
```
