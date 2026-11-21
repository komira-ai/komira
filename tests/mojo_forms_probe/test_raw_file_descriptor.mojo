# `RawFileDescriptor`, the name 1.2 gives `FileDescriptor`.
from std.io import RawFileDescriptor


def main() raises:
    print("raw file descriptor ok", file=RawFileDescriptor(2))
