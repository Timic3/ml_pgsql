/* The "server executable": contains no Lua. Like mta-server64 loading deathmatch.so, it
 * dlopen()s the library that holds Lua + the module manager with RTLD_NOW | RTLD_LOCAL, so
 * Lua symbols never reach the global scope and a module has to find them itself. */
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char** argv)
{
    char        path[PATH_MAX];
    const char* lib = getenv("MLPG_FAKEHOST");
    if (!lib)
    {
        ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - 32);
        if (n <= 0)
            return 2;
        path[n] = '\0';
        char* slash = strrchr(path, '/');
        strcpy(slash ? slash + 1 : path, "libfakehost.so");
        lib = path;
    }
    void* handle = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!handle)
    {
        fprintf(stderr, "cannot load %s: %s\n", lib, dlerror());
        return 2;
    }
    int (*entry)(int, char**) = (int (*)(int, char**))dlsym(handle, "fakehost_main");
    if (!entry)
    {
        fprintf(stderr, "fakehost_main not found\n");
        return 2;
    }
    /* deathmatch.so stays loaded until exit (symbolized leak reports need it mapped) */
    return entry(argc, argv);
}
