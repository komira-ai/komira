/*
 * The six entry points of zstd 1.5.7's lib/common/zstd_common.c, built in its
 * place. Upstream's file includes zstd_internal.h, which defines ZSTD_isError
 * as a macro (`#define ZSTD_isError ERR_isError`), and then `#undef`s it to
 * define the function; that `#undef` also drops the renaming of the prefix
 * header (`#define ZSTD_isError komira_zstd_isError`), so the function was
 * defined unprefixed. This file includes only the headers that declare the
 * functions, so every name it defines is renamed like the rest of the
 * library. The bodies are upstream's, line for line.
 *
 * Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
 * BSD-3-Clause (LICENSE of the zstd archive), as the rest of zstd here.
 */

#include "common/error_private.h"
#include "zstd.h"

unsigned ZSTD_versionNumber(void) { return ZSTD_VERSION_NUMBER; }

const char* ZSTD_versionString(void) { return ZSTD_VERSION_STRING; }

unsigned ZSTD_isError(size_t code) { return ERR_isError(code); }

const char* ZSTD_getErrorName(size_t code) { return ERR_getErrorName(code); }

ZSTD_ErrorCode ZSTD_getErrorCode(size_t code) { return ERR_getErrorCode(code); }

const char* ZSTD_getErrorString(ZSTD_ErrorCode code) { return ERR_getErrorString(code); }
