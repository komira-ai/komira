/* libkcovprobe.so.1: the library kcov_check.sh `cases` puts in a probe's own
 * lib/, with a decoy of the same name on LD_LIBRARY_PATH. Built again with
 * -Dkcov_probe=kcov_glibc_named as a libm.so.6 of the probe's own. The
 * constructor puts it in the loader's LD_DEBUG=libs record: glibc writes
 * "calling init: <path>" only for an object that has initialisers. */
static volatile int kcov_probe_ready;

__attribute__((constructor)) static void kcov_probe_init(void)
{
	kcov_probe_ready = 42;
}

int kcov_probe(void)
{
	return kcov_probe_ready;
}
