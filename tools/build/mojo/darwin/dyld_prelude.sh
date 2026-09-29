# Prepended to gate_runner.sh and launch.sh in the macOS toolchain. dyld reads
# DYLD_LIBRARY_PATH, not LD_LIBRARY_PATH, and searches it by leaf name for
# @rpath install names too. $2 is the compiler closure in both scripts; its
# lib/ holds the runtime libraries a built binary loads.
case "$2" in
    /*) DYLD_LIBRARY_PATH="$2/lib" ;;
    *) DYLD_LIBRARY_PATH="$PWD/$2/lib" ;;
esac
export DYLD_LIBRARY_PATH
