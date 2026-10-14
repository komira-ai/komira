# Prepended to launch.sh in the macOS toolchain (darwin.bzl, dyld_script). dyld reads
# DYLD_LIBRARY_PATH, not LD_LIBRARY_PATH, and searches it by leaf name for
# @rpath install names too. $2 is the compiler closure in launch.sh; its
# lib/ holds the runtime libraries a built binary loads.
case "$2" in
    /*) DYLD_LIBRARY_PATH="$2/lib" ;;
    *) DYLD_LIBRARY_PATH="$PWD/$2/lib" ;;
esac
export DYLD_LIBRARY_PATH
