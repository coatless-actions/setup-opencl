/*
 * Minimal OpenCL device probe.
 *
 * Prints key=value lines consumed by the action's verify step, then exits 0
 * unconditionally. This measures; it does not enforce. The action decides
 * whether a zero device count is fatal, because that answer depends on the
 * 'runtime' and 'verify' inputs.
 *
 * Compiled against the flags the action just exported, so a successful run
 * proves the exported contract works -- a stronger assertion than asking a
 * pre-built clinfo whether it found something.
 */

#define CL_TARGET_OPENCL_VERSION 300

#include <stdio.h>
#include <CL/cl.h>

#define MAX_PLATFORMS 16
#define MAX_DEVICES   16

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

int main(void)
{
    cl_platform_id platforms[MAX_PLATFORMS];
    cl_uint num_platforms = 0;
    cl_uint i, j;

    unsigned total = 0;
    char first_device[256] = "";
    char first_platform[256] = "";
    int first_fp64 = 0;

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

    return 0;
}
