#!/bin/sh
# gen_conda_names.sh -- names.bzl, the generated copy of the approved list.
#
# usage: tools/build/package/gen_conda_names.sh packaging/conda/names.tsv > packaging/conda/names.bzl
#
# A BUCK file cannot read a file, and the macro that declares every package
# (conda_set.bzl: conda_release) must know the names when the file is loaded, so
# the approved list reaches it as this module. names.tsv stays the one approval:
# //packaging/conda:names_lint regenerates this output from it and is red when
# the committed names.bzl differs, naming this command.
set -eu
[ "$#" = 1 ] || { echo "usage: gen_conda_names.sh <names.tsv>" >&2; exit 1; }
printf '# Generated from names.tsv by tools/build/package/gen_conda_names.sh. Do not edit:\n'
printf '# edit names.tsv (the approval), then regenerate. names_lint is red on a difference.\n'
printf 'APPROVED = {\n'
awk -F'\t' '/^#/ || /^$/ { next } { printf "    \"%s\": \"%s\",\n", $1, $2 }' "$1"
printf '}\n'
