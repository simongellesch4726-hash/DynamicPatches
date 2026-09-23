#import <Foundation/Foundation.h>
#import <roothide.h>
#include <dobby.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSMutableSet<NSString *> *gFixedPaths;
static NSLock *gFixedPathsLock;

static BOOL fixedPathMatches(NSString *candidate)
{
    if (!candidate || ![candidate hasPrefix:@"/var/"])
        return NO;

    [gFixedPathsLock lock];
    BOOL matched = NO;
    for (NSString *fixedPath in gFixedPaths) {
        if ([candidate isEqualToString:fixedPath] ||
            [candidate hasPrefix:[fixedPath stringByAppendingString:@"/"]]) {
            matched = YES;
            break;
        }
    }
    [gFixedPathsLock unlock];
    return matched;
}

static const char *redirectFixedPath(const char *path)
{
    if (!path || !gFixedPaths)
        return path;

    NSString *candidate = [NSString stringWithUTF8String:path];
    if (!fixedPathMatches(candidate))
        return path;

    const char *converted = jbroot(path);
    return converted ?: path;
}

/*
 * The compat layer must only rewrite absolute paths that were explicitly
 * classified by RootHidePatcher. Relative paths are intentionally untouched.
 */
static const char *redirectIfFixed(const char *path)
{
    return redirectFixedPath(path);
}

static int (*orig_open)(const char *, int, ...) = NULL;
static int new_open(const char *path, int flags, ...)
{
    path = redirectIfFixed(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return orig_open(path, flags, mode);
    }
    return orig_open(path, flags);
}

static int (*orig_openat)(int, const char *, int, ...) = NULL;
static int new_openat(int dirfd, const char *path, int flags, ...)
{
    path = redirectIfFixed(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return orig_openat(dirfd, path, flags, mode);
    }
    return orig_openat(dirfd, path, flags);
}

static int (*orig_creat)(const char *, mode_t) = NULL;
static int new_creat(const char *path, mode_t mode)
{
    return orig_creat(redirectIfFixed(path), mode);
}

static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static FILE *new_fopen(const char *path, const char *mode)
{
    return orig_fopen(redirectIfFixed(path), mode);
}

static FILE *(*orig_freopen)(const char *, const char *, FILE *) = NULL;
static FILE *new_freopen(const char *path, const char *mode, FILE *stream)
{
    return orig_freopen(redirectIfFixed(path), mode, stream);
}

static int (*orig_access)(const char *, int) = NULL;
static int new_access(const char *path, int mode)
{
    return orig_access(redirectIfFixed(path), mode);
}

static int (*orig_stat)(const char *, struct stat *) = NULL;
static int new_stat(const char *path, struct stat *st)
{
    return orig_stat(redirectIfFixed(path), st);
}

static int (*orig_lstat)(const char *, struct stat *) = NULL;
static int new_lstat(const char *path, struct stat *st)
{
    return orig_lstat(redirectIfFixed(path), st);
}

static int (*orig_mkdir)(const char *, mode_t) = NULL;
static int new_mkdir(const char *path, mode_t mode)
{
    return orig_mkdir(redirectIfFixed(path), mode);
}

static int (*orig_rmdir)(const char *) = NULL;
static int new_rmdir(const char *path)
{
    return orig_rmdir(redirectIfFixed(path));
}

static int (*orig_unlink)(const char *) = NULL;
static int new_unlink(const char *path)
{
    return orig_unlink(redirectIfFixed(path));
}

static int (*orig_remove)(const char *) = NULL;
static int new_remove(const char *path)
{
    return orig_remove(redirectIfFixed(path));
}

static int (*orig_rename)(const char *, const char *) = NULL;
static int new_rename(const char *from, const char *to)
{
    return orig_rename(redirectIfFixed(from), redirectIfFixed(to));
}

static int (*orig_symlink)(const char *, const char *) = NULL;
static int new_symlink(const char *target, const char *linkpath)
{
    /*
     * The target may intentionally be a system/rootfs path. Only redirect
     * values explicitly classified by the manifest.
     */
    return orig_symlink(redirectIfFixed(target), redirectIfFixed(linkpath));
}

static ssize_t (*orig_readlink)(const char *, char *, size_t) = NULL;
static ssize_t new_readlink(const char *path, char *buf, size_t size)
{
    return orig_readlink(redirectIfFixed(path), buf, size);
}

static void installHook(void *symbol, void *replacement, void **original)
{
    if (!*original)
        DobbyHook(symbol, replacement, original);
}

static void loadFixedPathManifest(const char *binaryPath)
{
    if (!binaryPath)
        return;

    NSString *manifestPath = [NSString stringWithFormat:@"%s.roothidepaths", binaryPath];
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:manifestPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if (!contents.length)
        return;

    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *path = [line stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([path hasPrefix:@"/var/"] && path.length > 5)
            [paths addObject:path];
    }];

    if (!paths.count)
        return;

    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        gFixedPathsLock = [[NSLock alloc] init];
    });

    [gFixedPathsLock lock];
    if (!gFixedPaths)
        gFixedPaths = [NSMutableSet set];
    [gFixedPaths unionSet:paths];
    [gFixedPathsLock unlock];

    dobby_enable_near_branch_trampoline();

    installHook((void *)open, (void *)new_open, (void **)&orig_open);
    installHook((void *)openat, (void *)new_openat, (void **)&orig_openat);
    installHook((void *)creat, (void *)new_creat, (void **)&orig_creat);
    installHook((void *)fopen, (void *)new_fopen, (void **)&orig_fopen);
    installHook((void *)freopen, (void *)new_freopen, (void **)&orig_freopen);
    installHook((void *)access, (void *)new_access, (void **)&orig_access);
    installHook((void *)stat, (void *)new_stat, (void **)&orig_stat);
    installHook((void *)lstat, (void *)new_lstat, (void **)&orig_lstat);
    installHook((void *)mkdir, (void *)new_mkdir, (void **)&orig_mkdir);
    installHook((void *)rmdir, (void *)new_rmdir, (void **)&orig_rmdir);
    installHook((void *)unlink, (void *)new_unlink, (void **)&orig_unlink);
    installHook((void *)remove, (void *)new_remove, (void **)&orig_remove);
    installHook((void *)rename, (void *)new_rename, (void **)&orig_rename);
    installHook((void *)symlink, (void *)new_symlink, (void **)&orig_symlink);
    installHook((void *)readlink, (void *)new_readlink, (void **)&orig_readlink);
}

extern "C"
__attribute__((visibility("default")))
void InitPatches(const char *path, void *header, uint64_t slide)
{
    (void)header;
    (void)slide;
    loadFixedPathManifest(path);
}
