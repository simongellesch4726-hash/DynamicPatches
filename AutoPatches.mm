#import <Foundation/Foundation.h>
#include <roothide.h>
#include "dobby.h"

struct __CFString {
    uint64_t base[2];
    const char *buffer;
    UInt32 length;
};

static NSLock *gLock;
static NSMutableDictionary *gRuntime;

static const char *convertCString(NSDictionary *patch, const char *path) {
    if (!path) return path;
    NSString *action = patch[@"action"];
    if ([action isEqualToString:@"jbroot"]) return jbroot(path);
    if ([action isEqualToString:@"rootfs"]) return rootfs(path);
    return path;
}

static void patchHandler(void *address, DobbyRegisterContext *ctx) {
    [gLock lock];
    NSDictionary *patch = gRuntime[@((uint64_t)address)];
    [gLock unlock];
    if (!patch) return;

    if ([patch[@"type"] isEqualToString:@"cstring"]) {
        for (NSNumber *n in patch[@"regs"]) {
            int reg = n.intValue;
            const char *oldPath = (const char *)ctx->general.x[reg];
            const char *newPath = convertCString(patch, oldPath);
            if (newPath) ctx->general.x[reg] = (uint64_t)newPath;
        }
    }
}

static BOOL pathEqual(NSString *a, const char *b) {
    if (!a || !b) return NO;
    return [a isEqualToString:[NSString stringWithUTF8String:b]];
}

static NSArray *loadConfig(const char *targetPath) {
    NSString *path = [NSString stringWithFormat:@"%s.roothidepatch.plist", targetPath];
    NSArray *patches = [NSArray arrayWithContentsOfFile:path];
    if (![patches isKindOfClass:[NSArray class]]) return @[];
    return patches;
}

__attribute__((visibility("default")))
extern "C" void InitPatches(const char *path, void *header, uint64_t slide) {
    @autoreleasepool {
        if (!path) return;

        if (!gLock) gLock = [[NSLock alloc] init];
        if (!gRuntime) gRuntime = [[NSMutableDictionary alloc] init];

        NSArray *patches = loadConfig(path);
        if (!patches.count) return;

        dobby_enable_near_branch_trampoline();

        for (NSDictionary *patch in patches) {
            NSNumber *vaddr = patch[@"vaddr"];
            NSString *type = patch[@"type"];
            if (![vaddr isKindOfClass:[NSNumber class]] || ![type isKindOfClass:[NSString class]]) continue;

            uint64_t address = vaddr.unsignedLongLongValue + slide;

            if ([type isEqualToString:@"__CFString"]) {
                struct __CFString *str = (struct __CFString *)(uintptr_t)address;
                const char *oldPath = str->buffer;
                const char *newPath = convertCString(patch, oldPath);
                if (newPath && newPath != oldPath) {
                    str->buffer = newPath;
                    str->length = (UInt32)strlen(newPath);
                }
                continue;
            }

            if ([type isEqualToString:@"cstring"]) {
                [gLock lock];
                gRuntime[@(address)] = patch;
                [gLock unlock];
                DobbyInstrument((void *)address, patchHandler);
            }
        }
    }
}
