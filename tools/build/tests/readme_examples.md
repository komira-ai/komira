# Test 38: README examples

The checks of [test 38](README.md#38-readme-examples), run by
[`run_tests.sh`](run_tests.sh).

A library's `README.md` examples are a welded test, `[tests][readme]`
([README examples](../mojo/README.md#readme-examples)).
[`functional/readme_examples/ok`](functional/readme_examples/ok/BUCK) builds a
README using every form (hidden lines before and after, a hoisted decorated
struct, a triple-quoted string, an example in a list item, a `~~~~` fence
quoting ```` ``` ````) and its marker is a PASS line;
[`functional/readme_examples/none`](functional/readme_examples/none/BUCK), a
README with no example, builds and its marker reads `NO EXAMPLE`, so nothing
was compiled or run. [`negative/readme_examples`](negative/readme_examples/raises/BUCK)
plants three defects, each of which must fail naming its README line: an
example that raises (`README.md:13: FAILED`, while the other example still
runs), one that does not compile (the compiler quotes the line, ending
`# README.md:9`) and a `mojo skip` fence (refused at `README.md:3`).
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
`unowned_base` too, which does not reach `unowned` (the compiler quotes
`# README.md:7`).
[`negative/readme_examples/readme_keyword`](negative/readme_examples/readme_keyword/BUCK)
fails loading, per `-c readme_keyword.case=`, for `readme = True` in a
package with no README.md and for a `readme` that is not True or False.

```sh
./buck2 build tests//functional/readme_examples/...
./buck2 build tests//negative/readme_examples/unowned:unowned_base   # must fail: README.md:7
./buck2 build -c readme_keyword.case=true_without_readme tests//negative/readme_examples/readme_keyword:kw   # must fail: holds no README.md
./buck2 build tests//negative/readme_examples/raises:raises   # must fail: README.md:13: FAILED
./buck2 build tests//negative/readme_examples/relative_link:relative_link   # must fail: README.md:11: greet.mojo: a relative link
```
