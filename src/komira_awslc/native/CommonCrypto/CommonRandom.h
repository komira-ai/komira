/* A stand-in for the macOS SDK's <CommonCrypto/CommonRandom.h>, which the pinned zig's libc headers do not ship. aws-lc's rand/urandom.c (macOS) includes it for one
 * function and one status constant. The function is the system's: it is left undefined in libawslc.a and the link on macOS resolves it from libSystem. */
#ifndef KOMIRA_AWSLC_COMMONCRYPTO_COMMONRANDOM_H
#define KOMIRA_AWSLC_COMMONCRYPTO_COMMONRANDOM_H

#include <stddef.h>
#include <stdint.h>

typedef int32_t CCRNGStatus;

#define kCCSuccess 0

CCRNGStatus CCRandomGenerateBytes(void *bytes, size_t count);

#endif
