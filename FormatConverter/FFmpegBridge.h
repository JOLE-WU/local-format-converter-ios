#ifndef FCFFmpegBridge_h
#define FCFFmpegBridge_h

/*
 * 进程内同步执行 FFmpeg（iOS 禁止启动子进程，因此必须以静态库形式链入）。
 *
 * inputPath  : 源文件 UTF-8 路径
 * outputPath : 目标文件 UTF-8 路径（扩展名决定 ffmpeg 的封装格式）
 * options    : 空格分隔的 ffmpeg 参数，不包含任何路径，例如
 *              "-vn -c:a libmp3lame -q:a 2"
 *
 * 返回 0 仅表示调用结束；转换是否成功请检查输出文件是否生成。
 */
int fc_ffmpeg_run(const char *inputPath, const char *outputPath, const char *options);

#endif /* FCFFmpegBridge_h */
