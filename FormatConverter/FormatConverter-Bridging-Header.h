//
//  让 Swift 能调用 FFmpegBridge.m 中的 C 函数。
//  这里直接声明函数原型，不 import 任何头文件，避免头文件搜索路径带来的编译问题。
//

int fc_ffmpeg_run(const char *inputPath, const char *outputPath, const char *options);
