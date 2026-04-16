/*
 * profraw_flush_preload.c — OCP-compliant LD_PRELOAD library
 *
 * Purpose:
 *   Ensures LLVM profraw data is written to disk even when the process
 *   terminates via _Exit() or _exit(), which bypass atexit() handlers.
 *
 *   This replaces the previous approach of patching FuzzerLoop.cpp inline,
 *   keeping the SGFuzz core source code identical to upstream SGFuzz-master.
 *
 * How it works:
 *   1. Interposes _Exit() and _exit() via LD_PRELOAD.
 *   2. Before forwarding to the real libc function, calls
 *      __llvm_profile_write_file() if the symbol is available (weak linkage).
 *   3. Falls through to the real _Exit()/_exit() so the process exits normally.
 *
 * Usage:
 *   # Build:
 *   gcc -shared -fPIC -o profraw_flush_preload.so profraw_flush_preload.c -ldl
 *
 *   # Run the fuzzer with profraw flush:
 *   LD_PRELOAD=/path/to/profraw_flush_preload.so ./testOnDemandRTSPServer ...
 *
 * Open-Closed Principle:
 *   This file is a NEW extension file.  It does NOT modify any existing
 *   SGFuzz or libFuzzer source code.  The profraw flush behavior is injected
 *   purely at runtime via the dynamic linker's LD_PRELOAD mechanism.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>

/* ---------- weak reference to LLVM profile runtime ---------- */

/*
 * __llvm_profile_write_file() is provided by the LLVM profile runtime
 * (compiler-rt) when the binary is built with -fprofile-instr-generate.
 * We declare it as a weak symbol so this preload library works even when
 * the binary was NOT built with profiling (the pointer is simply NULL).
 */
extern int __llvm_profile_write_file(void) __attribute__((weak));

/* Guard against recursive calls (e.g. _Exit called from a signal handler
 * that fires during our own flush). */
static volatile int flush_in_progress = 0;

static void flush_profraw(const char *caller_name) {
    if (flush_in_progress)
        return;
    flush_in_progress = 1;

    if (__llvm_profile_write_file) {
        /* Best-effort stderr message; may not appear if fd 2 is closed. */
        fprintf(stderr,
                "[profraw_flush_preload] flushing LLVM profile data before %s()\n",
                caller_name);
        __llvm_profile_write_file();
    }
}

/* ---------- _Exit() interposer ---------- */

typedef void (*real_Exit_t)(int status);

void _Exit(int status) {
    flush_profraw("_Exit");

    /* Forward to the real libc _Exit(). */
    real_Exit_t real_Exit = (real_Exit_t)dlsym(RTLD_NEXT, "_Exit");
    if (real_Exit) {
        real_Exit(status);
    }
    /* Fallback — should never reach here. */
    _exit(status);
}

/* ---------- _exit() interposer ---------- */

typedef void (*real_exit_t)(int status);

void _exit(int status) {
    flush_profraw("_exit");

    /* Forward to the real libc _exit(). */
    real_exit_t real__exit = (real_exit_t)dlsym(RTLD_NEXT, "_exit");
    if (real__exit) {
        real__exit(status);
    }
    /* Absolute fallback — use the syscall directly. */
    syscall(SYS_exit_group, status);
    __builtin_unreachable();
}
