# A stand-in at /komira/bin/supervisor until the job supervisor's binary
# takes its place (BUCK, `SUPERVISOR`). It supervises nothing: it says so and
# exits 2, so an image built with it can never pass for a supervised run.

from std.sys import exit


def main():
    print("komira base image: this /komira/bin/supervisor is a stand-in that supervises nothing")
    exit(2)
