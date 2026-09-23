#include "Patches.h"
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>

#define LOG(...) NSLog(@"AutoPatches: " __VA_ARGS__)

static __thread bool gAutoPathGuard = false;

static bool isExcludedRootfsPath(const char *path)
{
    if (!path) return true;

    static const char *const excluded[] = {
        "/var/mobile",
        "/private/var/mobile",
        "/var/db",
        "/private/var/db",
        "/var/run",
        "/private/var/run",
        "/var/folders",
        "/private/var/folders",
        "/var/containers",
        "/private/var/containers",
        NULL
    };

    for (const char *const *p = excluded; *p; ++p) {
        size_t n = strlen(*p);
        if (strncmp(path, *p, n) == 0 && (path[n] == '\0' || path[n] == '/'))
            return true;
    }

    return false;
}

static bool isJailbreakPathCandidate(const char *path)
{
    if (!path || path[0] != '/')
        return false;

    if (isExcludedRootfsPath(path))
        return false;

    static const char *const prefixes[] = {
        "/var/jb",
        "/private/var/jb",
        "/var/tmp",
        "/private/var/tmp",
        "/var/log",
        "/private/var/log",
        "/var/cache",
        "/private/var/cache",
        "/var/lib",
        "/private/var/lib",
        "/var/empty",
        "/private/var/empty",
        "/var/config",
        "/private/var/config",
        NULL
    };

    for (const char *const *p = prefixes; *p; ++p) {
        size_t n = strlen(*p);
        if (strncmp(path, *p, n) == 0 && (path[n] == '\0' || path[n] == '/'))
            return true;
    }

    return false;
}

static const char *autoConvertPath(const char *path)
{
    if (!path || !isJailbreakPathCandidate(path) || gAutoPathGuard)
        return path;

    gAutoPathGuard = true;
    const char *converted = jbroot(path);
    gAutoPathGuard = false;

    if (converted && strcmp(converted, path) != 0)
        LOG(@"path: %s -> %s", path, converted);

    return converted ? converted : path;
}

/*
 * AutoPatches deliberately handles filesystem API boundaries rather than
 * rewriting arbitrary string storage. This catches C-string paths whose
 * consumer/register cannot be safely inferred from a strings-only scan.
 */

static int (*orig_open)(const char *, int, ...) = NULL;
static int new_open(const char *path, int flags, ...)
{
    const char *p = autoConvertPath(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = va_arg(ap, int);
        va_end(ap);
        return orig_open(p, flags, mode);
    }

    return orig_open(p, flags);
}

static int (*orig_openat)(int, const char *, int, ...) = NULL;
static int new_openat(int fd, const char *path, int flags, ...)
{
    /*
     * Only transform absolute paths. Relative paths are interpreted against
     * fd and cannot safely be classified without knowing what fd represents.
     */
    const char *p = path;
    if (path && path[0] == '/')
        p = autoConvertPath(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = va_arg(ap, int);
        va_end(ap);
        return orig_openat(fd, p, flags, mode);
    }

    return orig_openat(fd, p, flags);
}

static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static FILE *new_fopen(const char *path, const char *mode)
{
    return orig_fopen(autoConvertPath(path), mode);
}

static FILE *(*orig_freopen)(const char *, const char *, FILE *) = NULL;
static FILE *new_freopen(const char *path, const char *mode, FILE *stream)
{
    return orig_freopen(autoConvertPath(path), mode, stream);
}

static int (*orig_stat)(const char *, struct stat *) = NULL;
static int new_stat(const char *path, struct stat *st)
{
    return orig_stat(autoConvertPath(path), st);
}

static int (*orig_lstat)(const char *, struct stat *) = NULL;
static int new_lstat(const char *path, struct stat *st)
{
    return orig_lstat(autoConvertPath(path), st);
}

static int (*orig_access)(const char *, int) = NULL;
static int new_access(const char *path, int mode)
{
    return orig_access(autoConvertPath(path), mode);
}

static int (*orig_unlink)(const char *) = NULL;
static int new_unlink(const char *path)
{
    return orig_unlink(autoConvertPath(path));
}

static int (*orig_rmdir)(const char *) = NULL;
static int new_rmdir(const char *path)
{
    return orig_rmdir(autoConvertPath(path));
}

static int (*orig_mkdir)(const char *, mode_t) = NULL;
static int new_mkdir(const char *path, mode_t mode)
{
    return orig_mkdir(autoConvertPath(path), mode);
}

static int (*orig_chdir)(const char *) = NULL;
static int new_chdir(const char *path)
{
    return orig_chdir(autoConvertPath(path));
}

static DIR *(*orig_opendir)(const char *) = NULL;
static DIR *new_opendir(const char *path)
{
    return orig_opendir(autoConvertPath(path));
}

static int (*orig_remove)(const char *) = NULL;
static int new_remove(const char *path)
{
    return orig_remove(autoConvertPath(path));
}

static int (*orig_rename)(const char *, const char *) = NULL;
static int new_rename(const char *from, const char *to)
{
    return orig_rename(autoConvertPath(from), autoConvertPath(to));
}

static int (*orig_link)(const char *, const char *) = NULL;
static int new_link(const char *from, const char *to)
{
    return orig_link(autoConvertPath(from), autoConvertPath(to));
}

static int (*orig_symlink)(const char *, const char *) = NULL;
static int new_symlink(const char *target, const char *linkpath)
{
    /*
     * The target may intentionally refer to rootfs. Only the destination is
     * considered a jailbreak-owned writable path.
     */
    return orig_symlink(target, autoConvertPath(linkpath));
}

static void installHook(const char *name, void *replacement, void **original)
{
    void *symbol = DobbySymbolResolver(NULL, name);
    if (!symbol) {
        LOG(@"symbol unavailable: %s", name);
        return;
    }

    DobbyHook(symbol, replacement, original);
}

static void installFilesystemHooks(void)
{
    static bool installed = false;
    if (installed)
        return;

    installed = true;
    dobby_enable_near_branch_trampoline();

    installHook("open", (void *)new_open, (void **)&orig_open);
    installHook("openat", (void *)new_openat, (void **)&orig_openat);
    installHook("fopen", (void *)new_fopen, (void **)&orig_fopen);
    installHook("freopen", (void *)new_freopen, (void **)&orig_freopen);
    installHook("stat", (void *)new_stat, (void **)&orig_stat);
    installHook("lstat", (void *)new_lstat, (void **)&orig_lstat);
    installHook("access", (void *)new_access, (void **)&orig_access);
    installHook("unlink", (void *)new_unlink, (void **)&orig_unlink);
    installHook("rmdir", (void *)new_rmdir, (void **)&orig_rmdir);
    installHook("mkdir", (void *)new_mkdir, (void **)&orig_mkdir);
    installHook("chdir", (void *)new_chdir, (void **)&orig_chdir);
    installHook("opendir", (void *)new_opendir, (void **)&orig_opendir);
    installHook("remove", (void *)new_remove, (void **)&orig_remove);
    installHook("rename", (void *)new_rename, (void **)&orig_rename);
    installHook("link", (void *)new_link, (void **)&orig_link);
    installHook("symlink", (void *)new_symlink, (void **)&orig_symlink);
}

static void patchCFStrings(void *header, uint64_t slide)
{
    if (!header)
        return;

    struct mach_header_64 *mh = (struct mach_header_64 *)header;
    if (mh->magic != MH_MAGIC_64)
        return;

    struct load_command *cmd = (struct load_command *)((uint8_t *)mh + sizeof(*mh));

    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if (cmd->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            struct section_64 *sections = (struct section_64 *)((uint8_t *)seg + sizeof(*seg));

            for (uint32_t j = 0; j < seg->nsects; ++j) {
                struct section_64 *sec = &sections[j];

                if (strcmp(sec->sectname, "__cfstring") != 0)
                    continue;

                uint64_t sectionAddress = sec->addr + slide;
                uint64_t sectionSize = sec->size;

                /*
                 * A __CFString object used by RootHide DynamicPatches has
                 * base[2], buffer and length, i.e. 32 bytes on arm64.
                 */
                for (uint64_t off = 0; off + sizeof(__CFString) <= sectionSize; off += sizeof(__CFString)) {
                    __CFString *str = (__CFString *)(sectionAddress + off);
                    const char *oldpath = str->buffer;

                    if (!oldpath || !isJailbreakPathCandidate(oldpath))
                        continue;

                    const char *newpath = autoConvertPath(oldpath);
                    if (newpath == oldpath)
                        continue;

                    str->buffer = newpath;
                    str->length = (UInt32)strlen(newpath);

                    LOG(@"__CFString: %s -> %s", oldpath, newpath);
                }
            }
        }

        cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
    }
}

extern "C"
__attribute__((visibility("default")))
void InitPatches(const char *path, void *header, uint64_t slide)
{
    LOG(@"load %p,%p,%s", header, (void *)slide, path ? path : "(null)");

    /*
     * This module is intentionally package-agnostic. RootHide PatchLoader
     * invokes InitPatches for each Mach-O associated with a .roothidepatch
     * trigger, so the same module can handle converted tweaks without a
     * per-tweak hard-coded address list.
     */
    patchCFStrings(header, slide);
    installFilesystemHooks();
}
