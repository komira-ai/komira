#!/bin/sh
# The `affected` command of each build system in release/artifacts.textproto,
# until the affected tool (which maps a change to the units it reaches) is
# wired in its place: it reads nothing of the change and answers that the
# change reaches EVERY declared unit, so the per-change check builds all of
# them. That over-approximates and never misses a unit.
#
# kci runs it from the repository's root as
#   sh release/ci/affected_widened.sh <changed files> <units file>
# (kci_artifact's grammar: one verdict line on stdout).
set -eu
if [ "$#" -ne 2 ] || [ ! -f "$1" ] || [ ! -f "$2" ]; then
  echo "usage: affected_widened.sh <changed files> <units file> (both files kci wrote)" >&2
  exit 2
fi
echo "WIDENED every unit: no affected tool is wired yet"
