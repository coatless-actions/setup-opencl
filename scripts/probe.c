/*
 * Minimal OpenCL device probe.
 *
 * Invoked with no arguments -- the only way the action calls it, and the
 * only form tests/probe-contract.sh asserts -- this prints key=value lines
 * consumed by the action's verify step, then exits 0 unconditionally. (The
 * private --kernel-check mode this re-executes itself in is the exception:
 * it reports the round trip's outcome as its exit status.)
 * This measures; it does not enforce. The action decides
 * whether a zero device count -- or a device that cannot run a kernel -- is
 * fatal, because that answer depends on the 'runtime', 'verify' and
 * 'require-kernel' inputs.
 *
 * Compiled against the flags the action just exported, so a successful run
 * proves the exported contract works -- a stronger assertion than asking a
 * pre-built clinfo whether it found something.
 *
 * Enumerating a device is not evidence that the device works. Intel's
 * oclcpuexp runtime on Windows reports a healthy fp64 CPU device and then
 * dies with 0xC0000005 inside common_clang64.dll the moment anything asks it
 * to compile a kernel -- every key below except 'kernel' was true of a runner
 * on which nothing could actually run. 'kernel' is the one key here produced
 * by executing something: clCreateProgramWithSource through
 * clEnqueueReadBuffer, with the bytes that come back compared against the
 * arithmetic the kernel was supposed to perform. Comparing, not just checking
 * status codes -- the sibling setup-clblast action has a measured case where
 * a GEMM returns success and leaves the output buffer holding garbage, so a
 * status code is not proof that a result exists.
 */

#define CL_TARGET_OPENCL_VERSION 300
/* clCreateCommandQueue is deprecated from OpenCL 2.0 onward but is the only
 * queue constructor an OpenCL 1.2 platform has, and this action supports
 * several (Apple's framework, and ubuntu-22.04's PoCL 1.8). Silence the
 * deprecation rather than dropping the call: without it the probe cannot
 * create a queue at all on those platforms. CL_SILENCE_DEPRECATION is
 * Apple's spelling of the same thing.
 *
 * Both are guarded: install-macos.sh already puts -DCL_SILENCE_DEPRECATION in
 * the cppflags it exports for Apple's framework, and redefining a macro the
 * command line already set is a warning on every run of that leg. */
#ifndef CL_USE_DEPRECATED_OPENCL_1_2_APIS
#  define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#endif
#ifndef CL_SILENCE_DEPRECATION
#  define CL_SILENCE_DEPRECATION
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CL/cl.h>

#if !defined(_WIN32)
#  include <errno.h>
#  include <signal.h>
#  include <unistd.h>
#  include <sys/wait.h>
#  define PROBE_CAN_FORK 1
#endif

#define MAX_PLATFORMS 16
#define MAX_DEVICES   16

/* One work-item per element. Small enough that no runtime can refuse the
 * launch for want of resources, large enough that a runtime which launches
 * the wrong number of work-items is caught. */
#define PROBE_ELEMENTS 64

/* Written into the buffer before the launch. A value no correct run can
 * produce, so reading it back afterwards is positive evidence that the kernel
 * never wrote anything -- which turns "wrong number" into "nothing ran" in
 * the diagnostic, the difference between suspecting the arithmetic and
 * knowing the launch did nothing. */
#define PROBE_SENTINEL (-987654321)

/* Ceiling on the isolated round trip, POSIX only (see probe_kernel_isolated).
 * A broken runtime can hang instead of crashing, and a probe that never
 * returns burns a job's entire time budget for no information. Building this
 * one trivial kernel is a second or two even on a cold PoCL cache, so this is
 * orders of magnitude of headroom and can only fire on a genuine hang. */
#define PROBE_TIMEOUT_SECONDS 120

/* Argument that puts this program in child mode: run the round trip, report
 * the answer as an exit status, print nothing on stdout. Not a public
 * interface -- the probe re-executes itself with it (see
 * probe_kernel_isolated) and nothing else should. */
#define PROBE_CHILD_FLAG "--kernel-check"

/* Child exit status meaning "this process never became the probe": execv
 * failed, so the answer is unknown rather than false, and the parent runs the
 * round trip itself instead of reporting a failure that was never observed.
 * 127 is the shell's own convention for the same condition. */
#define PROBE_EXEC_FAILED 127

/* Deliberately trivial: this measures whether the runtime can compile and
 * execute anything at all, not how fast it is. Each work-item writes a value
 * derived from its own global id, so a runtime that runs no work-items, or
 * the wrong number of them, fails the comparison just as surely as one that
 * computes the wrong arithmetic. Not const-qualified at the outer level:
 * clCreateProgramWithSource takes const char **, and a pointer to a
 * const-qualified pointer does not convert to that. */
static const char *KERNEL_SOURCE =
    "__kernel void probe_fill(__global int *out)\n"
    "{\n"
    "    int i = (int)get_global_id(0);\n"
    "    out[i] = i * 3 + 7;\n"
    "}\n";

/* Version strings may contain newlines; they would corrupt the key=value
 * contract and, downstream, $GITHUB_OUTPUT. */
static void flatten(char *s)
{
    for (; *s != '\0'; s++)
    {
        if (*s == '\n' || *s == '\r') { *s = ' '; }
    }
}

static void copy_into(char *dest, size_t dest_size, const char *src)
{
    size_t i = 0;
    for (; src[i] != '\0' && i + 1 < dest_size; i++) { dest[i] = src[i]; }
    dest[i] = '\0';
}

/* The first device the loader offers, by the same rule main()'s enumeration
 * loop uses for device-name/platform-version/fp64: the first device of the
 * first platform that yields one. Keep the two in agreement -- 'kernel'
 * describing a different device than 'device-name' would be worse than not
 * reporting it at all. Returns NULL when there is nothing to run on. */
static cl_device_id find_first_device(void)
{
    cl_platform_id platforms[MAX_PLATFORMS];
    cl_uint num_platforms = 0;
    cl_uint i;

    if (clGetPlatformIDs(MAX_PLATFORMS, platforms, &num_platforms) != CL_SUCCESS)
    {
        return NULL;
    }

    for (i = 0; i < num_platforms && i < MAX_PLATFORMS; i++)
    {
        cl_device_id device = NULL;
        cl_uint num_devices = 0;

        if (clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, 1,
                           &device, &num_devices) == CL_SUCCESS
            && num_devices > 0 && device != NULL)
        {
            return device;
        }
    }

    return NULL;
}

/* clCreateCommandQueueWithProperties is OpenCL 2.0+. Apple's framework does
 * not declare it at all, hence the #ifdef; the Khronos headers always declare
 * it even when the platform behind the loader is 1.2 (ubuntu-22.04's PoCL
 * 1.8), where routing it through the ICD dispatch table is at best an error
 * and at worst a null call, hence the runtime version check as well. The
 * deprecated 1.2 constructor exists on every platform this action supports,
 * so it is the fallback for both cases. */
static cl_command_queue create_queue(cl_context ctx, cl_device_id device, cl_int *err)
{
#ifdef CL_VERSION_2_0
    char version[128] = "";

    /* CL_DEVICE_VERSION is "OpenCL <major>.<minor> <vendor text>", so this
     * asks "is the device 1.x?" and nothing more. */
    if (clGetDeviceInfo(device, CL_DEVICE_VERSION,
                        sizeof version, version, NULL) == CL_SUCCESS
        && strncmp(version, "OpenCL 1.", 9) != 0)
    {
        cl_command_queue queue =
            clCreateCommandQueueWithProperties(ctx, device, NULL, err);
        if (queue != NULL && *err == CL_SUCCESS) { return queue; }
        /* A non-NULL handle alongside a failure status is not supposed to
         * happen, but this whole file exists because runtimes misbehave;
         * releasing it costs nothing and dropping it would leak a queue. */
        if (queue != NULL) { clReleaseCommandQueue(queue); }
        fprintf(stderr, "probe: clCreateCommandQueueWithProperties failed"
                        " (err=%d); falling back to clCreateCommandQueue\n",
                (int) *err);
    }
#endif
    return clCreateCommandQueue(ctx, device, 0, err);
}

/* Printed to stderr, never stdout: stdout carries the key=value contract and
 * a multi-line compiler log dropped into it would poison $GITHUB_OUTPUT. The
 * log is the single most useful diagnostic a runtime that cannot compile ever
 * produces, so it is worth the allocation to print it in full rather than
 * truncating it into a fixed buffer. */
static void print_build_log(cl_program program, cl_device_id device)
{
    size_t length = 0;
    char *log = NULL;

    if (clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG,
                              0, NULL, &length) != CL_SUCCESS || length == 0)
    {
        fprintf(stderr, "probe: the build failed and CL_PROGRAM_BUILD_LOG"
                        " could not be read\n");
        return;
    }

    log = (char *) malloc(length + 1);
    if (log == NULL)
    {
        fprintf(stderr, "probe: the build failed and its %lu-byte log could"
                        " not be allocated\n", (unsigned long) length);
        return;
    }

    if (clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG,
                              length, log, NULL) == CL_SUCCESS)
    {
        log[length] = '\0';
        fprintf(stderr, "probe: CL_PROGRAM_BUILD_LOG follows\n%s\n", log);
    }
    else
    {
        fprintf(stderr, "probe: the build failed and CL_PROGRAM_BUILD_LOG"
                        " could not be read\n");
    }

    free(log);
}

/* The whole round trip: context, queue, program, build, kernel, buffer,
 * launch, finish, read back, compare. Returns 1 only when the numbers that
 * came back are the numbers the kernel was supposed to write.
 *
 * Every handle starts NULL and is released only if it was actually created,
 * so the single exit path can neither leak nor release something that does
 * not exist. A leak in a probe would be sloppy; passing a NULL handle to a
 * runtime that is already misbehaving would be fatal. */
static int run_kernel_check(void)
{
    cl_device_id device = NULL;
    cl_context ctx = NULL;
    cl_command_queue queue = NULL;
    cl_program program = NULL;
    cl_kernel kernel = NULL;
    cl_mem buffer = NULL;
    cl_int err = CL_SUCCESS;
    cl_int host[PROBE_ELEMENTS];
    size_t global_size = PROBE_ELEMENTS;
    int ok = 0;
    int i;

    device = find_first_device();
    if (device == NULL)
    {
        /* No device: nothing to run on. Not an error here -- main() reports
         * device-count separately and the action decides what that means. */
        return 0;
    }

    ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err);
    if (ctx == NULL || err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clCreateContext failed (err=%d)\n", (int) err);
        ctx = NULL;
        goto done;
    }

    queue = create_queue(ctx, device, &err);
    if (queue == NULL || err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: could not create a command queue (err=%d)\n",
                (int) err);
        queue = NULL;
        goto done;
    }

    program = clCreateProgramWithSource(ctx, 1, &KERNEL_SOURCE, NULL, &err);
    if (program == NULL || err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clCreateProgramWithSource failed (err=%d)\n",
                (int) err);
        program = NULL;
        goto done;
    }

    err = clBuildProgram(program, 1, &device, NULL, NULL, NULL);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clBuildProgram failed (err=%d)\n", (int) err);
        print_build_log(program, device);
        goto done;
    }

    kernel = clCreateKernel(program, "probe_fill", &err);
    if (kernel == NULL || err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clCreateKernel failed (err=%d)\n", (int) err);
        kernel = NULL;
        goto done;
    }

    buffer = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof host, NULL, &err);
    if (buffer == NULL || err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clCreateBuffer failed (err=%d)\n", (int) err);
        buffer = NULL;
        goto done;
    }

    for (i = 0; i < PROBE_ELEMENTS; i++) { host[i] = PROBE_SENTINEL; }
    err = clEnqueueWriteBuffer(queue, buffer, CL_TRUE, 0, sizeof host, host,
                               0, NULL, NULL);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clEnqueueWriteBuffer failed (err=%d)\n",
                (int) err);
        goto done;
    }

    err = clSetKernelArg(kernel, 0, sizeof(cl_mem), &buffer);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clSetKernelArg failed (err=%d)\n", (int) err);
        goto done;
    }

    /* NULL local work size: let the runtime pick a work-group shape it can
     * actually satisfy rather than guessing one it may reject. */
    err = clEnqueueNDRangeKernel(queue, kernel, 1, NULL, &global_size, NULL,
                                 0, NULL, NULL);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clEnqueueNDRangeKernel failed (err=%d)\n",
                (int) err);
        goto done;
    }

    /* Enqueue is asynchronous, so its success says nothing about execution.
     * A runtime that fails during execution reports it here or not at all. */
    err = clFinish(queue);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clFinish failed (err=%d)\n", (int) err);
        goto done;
    }

    err = clEnqueueReadBuffer(queue, buffer, CL_TRUE, 0, sizeof host, host,
                              0, NULL, NULL);
    if (err != CL_SUCCESS)
    {
        fprintf(stderr, "probe: clEnqueueReadBuffer failed (err=%d)\n",
                (int) err);
        goto done;
    }

    /* The point of the whole exercise. Integers, so the comparison is exact
     * and there is no tolerance to argue about: either the device computed
     * i * 3 + 7 for every i or it did not. */
    ok = 1;
    for (i = 0; i < PROBE_ELEMENTS; i++)
    {
        if (host[i] != (cl_int) (i * 3 + 7))
        {
            fprintf(stderr, "probe: wrong result at element %d: expected %d,"
                            " got %d%s\n",
                    i, i * 3 + 7, (int) host[i],
                    host[i] == PROBE_SENTINEL
                        ? " (the seeded sentinel -- the kernel never wrote"
                          " anything)"
                        : "");
            ok = 0;
            break;
        }
    }

done:
    if (buffer  != NULL) { clReleaseMemObject(buffer); }
    if (kernel  != NULL) { clReleaseKernel(kernel); }
    if (program != NULL) { clReleaseProgram(program); }
    if (queue   != NULL) { clReleaseCommandQueue(queue); }
    if (ctx     != NULL) { clReleaseContext(ctx); }

    return ok;
}

#ifdef PROBE_CAN_FORK
/* Runs the round trip in a separate process and reports whether it succeeded.
 * Sets *checked when the answer is real; leaves it clear when the child never
 * got far enough to produce one, which tells main() to run the round trip
 * itself rather than report a failure that was never observed.
 *
 * The failure this key exists to catch is not an error code -- it is a
 * segfault inside the runtime's own kernel compiler, killing whatever process
 * called it. Reporting that as kernel=false at all requires surviving it, so
 * it has to happen somewhere other than the process that prints the contract.
 *
 * fork *and exec*, not fork alone. Measured on macOS 26.5.1 arm64 against
 * Apple's OpenCL.framework: a forked child that skips the exec cannot reach
 * MTLCompilerService ("Connection init failed at lookup with error 3"), so
 * clBuildProgram fails with CL_BUILD_PROGRAM_FAILURE on a device that builds
 * the same kernel perfectly well in a process of its own. XPC lookups, and
 * anything else built on CoreFoundation state inherited across a fork, are
 * simply not available to a child that never execs -- and a false kernel=false
 * on a healthy runner is a worse defect than the one this key was added to
 * catch. The exec gives the child a genuinely fresh process image, which is
 * also why it re-enumerates the device instead of being handed a
 * cl_device_id belonging to the parent's loader.
 *
 * A crash and a hang both come back the same way a clean failure does:
 * kernel=false, with the signal named on stderr, which is the diagnostic that
 * was missing for the entire time this defect went unnoticed. Windows has no
 * fork, and the probe does not try to emulate one: there the isolation is the
 * process boundary the action's probe step already has (see action.yml), and
 * that is why the four enumeration keys are printed and flushed before the
 * round trip is attempted on either platform. */
static int probe_kernel_isolated(const char *self, int *checked)
{
    pid_t pid;
    int status = 0;

    *checked = 0;

    /* argv[0] is how the child is re-executed. The action, the contract test,
     * and the README all invoke the probe by path, so this is a full path in
     * every supported case; anything else falls back to running in-process. */
    if (self == NULL || self[0] == '\0')
    {
        fprintf(stderr, "probe: argv[0] is empty, so the kernel round trip"
                        " cannot be isolated; running it in this process\n");
        return 0;
    }

    fflush(stdout);
    fflush(stderr);

    pid = fork();

    if (pid < 0)
    {
        fprintf(stderr, "probe: fork failed (errno=%d); running the kernel"
                        " round trip in this process instead\n", errno);
        return 0;
    }

    if (pid == 0)
    {
        char *const args[] = { (char *) self, (char *) PROBE_CHILD_FLAG, NULL };

        execv(self, args);

        /* Only reachable when execv failed: on success it never returns.
         * _exit, not exit -- between fork and exec, flushing a stdout buffer
         * inherited from the parent would duplicate the parent's output. */
        _exit(PROBE_EXEC_FAILED);
    }

    while (waitpid(pid, &status, 0) < 0)
    {
        if (errno != EINTR)
        {
            fprintf(stderr, "probe: waitpid failed (errno=%d); running the"
                            " kernel round trip in this process instead\n",
                    errno);
            return 0;
        }
    }

    if (WIFEXITED(status) && WEXITSTATUS(status) == PROBE_EXEC_FAILED)
    {
        fprintf(stderr, "probe: could not re-execute '%s' to isolate the"
                        " kernel round trip; running it in this process"
                        " instead\n", self);
        return 0;
    }

    *checked = 1;

    if (WIFSIGNALED(status))
    {
        fprintf(stderr, "probe: the kernel round trip was killed by signal %d"
                        " -- %s. The device enumerates but cannot run a"
                        " kernel.\n",
                WTERMSIG(status),
                WTERMSIG(status) == SIGALRM
                    ? "this probe's own timeout, so the runtime hung rather"
                      " than failing"
                    : "a crash inside the runtime, not in this probe");
        return 0;
    }

    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
#endif

int main(int argc, char **argv)
{
    cl_platform_id platforms[MAX_PLATFORMS];
    cl_uint num_platforms = 0;
    cl_uint i, j;

    unsigned total = 0;
    char first_device[256] = "";
    char first_platform[256] = "";
    int first_fp64 = 0;
    int kernel_ok = 0;
    int kernel_checked = 0;

    /* Child mode: the round trip and nothing else, with the answer in the
     * exit status. Prints no key=value line -- the parent owns the contract
     * and merges this result into it. */
    if (argc > 1 && argv[1] != NULL && strcmp(argv[1], PROBE_CHILD_FLAG) == 0)
    {
#ifdef PROBE_CAN_FORK
        /* Nothing this process produces belongs on stdout, and a runtime that
         * prints its own chatter there would land it in the middle of the
         * parent's key=value contract, which they share. Point stdout at
         * stderr so any such output reaches the job log instead. */
        if (dup2(STDERR_FILENO, STDOUT_FILENO) < 0)
        {
            fprintf(stderr, "probe: could not redirect stdout to stderr"
                            " (errno=%d)\n", errno);
        }
        alarm(PROBE_TIMEOUT_SECONDS);
#endif
        return run_kernel_check() ? 0 : 1;
    }

    if (clGetPlatformIDs(MAX_PLATFORMS, platforms, &num_platforms) != CL_SUCCESS)
    {
        num_platforms = 0;
    }

    for (i = 0; i < num_platforms && i < MAX_PLATFORMS; i++)
    {
        char platform_version[256] = "";
        cl_device_id devices[MAX_DEVICES];
        cl_uint num_devices = 0;

        clGetPlatformInfo(platforms[i], CL_PLATFORM_VERSION,
                          sizeof platform_version, platform_version, NULL);
        flatten(platform_version);

        /* Returns CL_DEVICE_NOT_FOUND when a platform enumerates but exposes
         * no devices -- the exact case this action exists to catch. */
        if (clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_ALL, MAX_DEVICES,
                           devices, &num_devices) != CL_SUCCESS)
        {
            continue;
        }

        for (j = 0; j < num_devices && j < MAX_DEVICES; j++)
        {
            char device_name[256] = "";
            cl_device_fp_config fp64_config = 0;

            clGetDeviceInfo(devices[j], CL_DEVICE_NAME,
                            sizeof device_name, device_name, NULL);
            clGetDeviceInfo(devices[j], CL_DEVICE_DOUBLE_FP_CONFIG,
                            sizeof fp64_config, &fp64_config, NULL);
            flatten(device_name);

            /* Report the first device found: that is the one a consumer using
             * default device selection will actually get. */
            if (total == 0)
            {
                copy_into(first_device, sizeof first_device, device_name);
                copy_into(first_platform, sizeof first_platform, platform_version);
                first_fp64 = (fp64_config != 0);
            }
            total++;
        }
    }

    printf("device-count=%u\n", total);
    printf("device-name=%s\n", first_device);
    printf("platform-version=%s\n", first_platform);
    printf("fp64=%s\n", first_fp64 ? "true" : "false");

    /* Flushed here, before anything risky, and deliberately not at the end.
     * stdout is a pipe when the action captures this output, so it is fully
     * buffered: without this flush a crash during an in-process round trip
     * (the Windows path, which has no fork) would discard four keys that were
     * already known good. With it, the worst a crash can cost is the one key
     * that has not been printed yet, which the action's probe step then fills
     * in as false. */
    fflush(stdout);

#ifdef PROBE_CAN_FORK
    kernel_ok = probe_kernel_isolated(argv[0], &kernel_checked);
#endif

    /* Windows, and the two POSIX cases where the isolated run never happened
     * (fork or exec failed). Nothing protects the process here, which is
     * exactly why the four keys above are already flushed: a crash costs the
     * kernel key alone, and the action's probe step fills that in as false. */
    if (!kernel_checked)
    {
        kernel_ok = run_kernel_check();
    }

    /* False whenever the round trip did not both complete and produce the
     * right numbers -- including when there was no device to run it on. */
    printf("kernel=%s\n", kernel_ok ? "true" : "false");

    return 0;
}
