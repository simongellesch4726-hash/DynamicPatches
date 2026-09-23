#import <Foundation/Foundation.h>
#import <roothide.h>
#include <dobby.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static NSMutableSet<NSString *> *gFixedPaths;

static const char *redirectFixedPath(const char *path)
{
    if (!path || !gFixedPaths) return path;

    NSString *candidate = [NSString stringWithUTF8String:path];
    if (!candidate) return path;

    BOOL matched = NO;
    for (NSString *fixedPath in gFixedPaths) {
        if ([candidate isEqualToString:fixedPath] ||
            [candidate hasPrefix:[fixedPath stringByAppendingString:@"/"]]) {
            matched = YES;
            break;
        }
    }
    if (!matched) return path;

    const char *converted = jbroot(path);
    return converted ? converted : path;
}

static int (*orig_open)(const char *, int, ...) = NULL;
static int new_open(const char *path, int flags, ...)
{
    path = redirectFixedPath(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = va_arg(ap, int);
        va_end(ap);
        return orig_open(path, flags, mode);
    }

    return orig_open(path, flags);
}

static int (*orig_openat)(int, const char *, int, ...) = NULL;
static int new_openat(int dirfd, const char *path, int flags, ...)
{
    path = redirectFixedPath(path);

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = va_arg(ap, int);
        va_end(ap);
        return orig_openat(dirfd, path, flags, mode);
    }

    return orig_openat(dirfd, path, flags);
}

static FILE *(*orig_fopen)(const char *, const char *) = NULL;
static FILE *new_fopen(const char *path, const char *mode)
{
    return orig_fopen(redirectFixedPath(path), mode);
}

static FILE *(*orig_freopen)(const char *, const char *, FILE *) = NULL;
static FILE *new_freopen(const char *path, const char *mode, FILE *stream)
{
    return orig_freopen(redirectFixedPath(path), mode, stream);
}

static void loadFixedPathManifest(const char *binaryPath)
{
    if (!binaryPath) return;

    NSString *manifestPath = [NSString stringWithFormat:@"%s.roothidepaths", binaryPath];
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:manifestPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if (!contents.length) return;

    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    [contents enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *path = [line stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([path hasPrefix:@"/var/"] && path.length > 5) {
            [paths addObject:path];
        }
    }];

    if (!paths.count) return;
    if (!gFixedPaths)
        gFixedPaths = [NSMutableSet set];
    [gFixedPaths unionSet:paths];

    dobby_enable_near_branch_trampoline();

    if (!orig_open)
        DobbyHook((void *)open, (void *)new_open, (void **)&orig_open);
    if (!orig_openat)
        DobbyHook((void *)openat, (void *)new_openat, (void **)&orig_openat);
    if (!orig_fopen)
        DobbyHook((void *)fopen, (void *)new_fopen, (void **)&orig_fopen);
    if (!orig_freopen)
        DobbyHook((void *)freopen, (void *)new_freopen, (void **)&orig_freopen);
}

extern "C"
__attribute__((visibility("default")))
void InitPatches(const char *path, void *header, uint64_t slide)
{
    (void)header;
    (void)slide;

    loadFixedPathManifest(path);
}
