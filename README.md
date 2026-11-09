# 格式转换器（侧载用 unsigned IPA）

一个**完全离线**的 iOS 本地文件格式转换器，全部转换在设备本机完成，不联网、不上传任何文件。
采用**双引擎**：系统 `AVFoundation` / `ImageIO` 处理原生格式，内置 `FFmpeg` 动态库补齐 iOS 缺失的编解码器
（WMA 解码、MP3 编码等）。

## 支持范围

| 源文件 | 可转出 |
|---|---|
| 音频：WMA / ASF / FLAC / OGG / Opus / M4A / MP3 / WAV / AIFF / CAF / AC3 … | **MP3**（libmp3lame）、M4A(AAC)、WAV / AIFF / CAF (PCM)、FLAC |
| 视频：MP4 / MOV / M4V / MKV / AVI / WebM / FLV / WMV / MPG … | MP4、MOV、M4V（可重编码压缩）、MP3 / M4A / WAV / FLAC 音轨 |
| 图片：JPEG / PNG / HEIC / TIFF / GIF / BMP / WebP … | JPEG、PNG、HEIC、TIFF、GIF、BMP |

> **WMA → MP3 已支持**：iOS 系统既不提供 WMA 解码器、也不提供 MP3 编码器，
> 因此这一转换完全由内置的 FFmpeg（`wmav2` / `wmapro` 解码 + `libmp3lame` 编码）在进程内完成。
> iOS 沙盒禁止启动子进程，FFmpeg 以动态库形式链入而非外部命令行。

**边界**：
- 受 **DRM 保护**的 WMA（部分早期付费音乐）任何工具都无法转换；
- 视频转码统一用 `mpeg4 + aac`，保证兼容性，但不是 H.264/HEVC；
- 转换进度为估算值（FFmpeg 同步执行，无内建进度回调）。

## ⚠️ 许可证

内置的 FFmpeg 动态库为 **GPL** 构建（含 `libmp3lame`）。
本工程仅用于**个人侧载自用**，**不适合上架 App Store**（GPL 与 App Store 分发条款冲突）。
二进制不入库，由 CI 构建时下载。

## 侧载步骤

本仓库产出的是**未签名 IPA**（`CODE_SIGNING_ALLOWED=NO`），内含 8 个 FFmpeg 动态库，
需要用你自己的 Apple ID 对**整个 bundle 重签名**后安装：

1. 下载 `FormatConverter.ipa`（Actions Artifact，或仓库 `dist/` 目录）。
2. 任选一种侧载工具（都会连同 `Frameworks/` 里的动态库一起签名）：
   - **Sideloadly**（Windows / macOS）：拖入 IPA，填 Apple ID，点 Start；
   - **AltStore / SideStore**：导入 IPA 后签名安装；
   - **爱思助手 / 牛蛙助手** 等：选择 IPA 并签名。
3. 装好后到「设置 → 通用 → VPN 与设备管理」信任开发者证书。
4. 免费 Apple ID 签名有效期 **7 天**，到期重签；付费开发者账号为 1 年。

> 若安装后秒退，多为动态库未随 bundle 正确重签——换用 Sideloadly（默认递归签名 Frameworks）即可。

## 使用

1. 打开 App →「选择要转换的文件」（从「文件」App 选取，或直接从「文件」分享到本 App）。
2. 选目标格式（如 `MP3`）→「开始转换」。
3. 完成后点「分享 / 保存转换结果」；
   或到「文件 → 我的 iPhone → 格式转换器 → Converted」取出（已开启文件共享）。

## 构建（GitHub Actions）

- `macos-latest` runner；`scripts/fetch-ffmpeg.sh` 下载 FFmpegKit v6.0 的 iOS **arm64 动态 frameworks**：
  - 自动校验 `libavcodec` 内确有 **WMA 解码器 + libmp3lame MP3 编码器**，不满足则回退备用源；
  - 用 `install_name_tool` 把动态库 install name 规范化为 `@rpath/...`；
  - 产物放在 `Frameworks/flat/`（不入库）。
- `xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO clean build`，链接并 embed 8 个动态库；
- 打包 `Payload/FormatConverter.app`，清除所有签名残留；
- `verify.py` 校验：未签名、主程序 arm64、8 个动态库齐全且为 Mach-O、WMA/MP3 编解码器存在；
- 产物：Actions Artifact `FormatConverter-unsigned-ipa` + 回推 `dist/FormatConverter.ipa`。

推送到 `main` 自动触发，也可在 Actions 页手动 `workflow_dispatch`。

## 工程结构

```
FormatConverter.xcodeproj/        工程文件 + shared scheme（含 Embed Frameworks 阶段）
FormatConverter/
  App.swift                     @main AppDelegate / SceneDelegate
  RootViewController.swift      UI（UIKit 纯代码）
  ConvertEngine.swift           双引擎转换逻辑（AVFoundation/ImageIO + FFmpeg 调度）
  FFmpegBridge.h / .m           ObjC 桥接：进程内同步调用 FFmpegKit
  FormatConverter-Bridging-Header.h
  Info.plist / Assets.xcassets
scripts/fetch-ffmpeg.sh           CI 下载/校验/规范化 FFmpeg 动态库
.github/workflows/build-ipa.yml  macOS 出包流水线
verify.py                        IPA 校验
```
