# =============================================================================
# komira_job_supervisor/main/job_supervisor_main.mojo: the job supervisor
# binary. Everything is `run_entrypoint` (entrypoint.mojo, whose header lists
# the flags and the exit status); this file only hands it the arguments.
# =============================================================================

from std.sys import argv, exit

from komira_job_supervisor import run_entrypoint


def main():
    var all = argv()
    var args = List[String]()
    for i in range(1, len(all)):
        args.append(String(all[i]))
    exit(run_entrypoint(args))
