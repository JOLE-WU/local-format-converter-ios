#import <Foundation/Foundation.h>
#import "FFmpegBridge.h"

/*
 * 这里刻意不 #import <ffmpegkit/FFmpegKit.h>，而是在本文件内声明用到的最小接口：
 * 避免 CI 上因 framework 头文件/module map 搜索路径差异导致编译失败。
 * 符号在链接期由 -framework ffmpegkit 提供，签名与 FFmpegKit 6.0 一致。
 */
@interface FFmpegKit : NSObject
+ (id)executeWithArguments:(NSArray *)arguments;
@end

int fc_ffmpeg_run(const char *inputPath, const char *outputPath, const char *options) {
    @autoreleasepool {
        NSString *inPath  = [NSString stringWithUTF8String:(inputPath  ? inputPath  : "")];
        NSString *outPath = [NSString stringWithUTF8String:(outputPath ? outputPath : "")];
        NSString *opts    = [NSString stringWithUTF8String:(options    ? options    : "")];

        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        // 用数组传参而非拼接字符串，避免文件名中的空格被误拆
        [arguments addObjectsFromArray:@[@"-y", @"-hide_banner", @"-loglevel", @"error", @"-i", inPath]];
        for (NSString *token in [opts componentsSeparatedByString:@" "]) {
            if (token.length > 0) {
                [arguments addObject:token];
            }
        }
        [arguments addObject:outPath];

        // 同步执行，返回时转码已完全结束
        [FFmpegKit executeWithArguments:arguments];
        return 0;
    }
}
