#include "add.h"

#ifndef __AVX2__
#error "compiled without AVX2: the toolchain's target_cpu (x86-64-v3) was not applied"
#endif

int komira_example_add(int a, int b) { return a + b; }
