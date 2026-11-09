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

1. 打开 App，选择来源（**可多次叠加选择，互不覆盖**）：
   - **「选择文件（可多选）」**：一次勾选多个文件；
   - **「选择整个文件夹（含所有子文件夹）」**：选中一个文件夹后，App 会**递归收集里面所有可识别的文件**（含各级子文件夹），界面上会显示总数与类型统计、以及文件清单预览。
2. 选择目标格式：
   - **「⭐ 自动匹配」（默认，推荐用于混合文件夹）**：视频→MP4、音频→MP3、图片→JPG，一次把文件夹里的内容全部转掉；
   - 或手动指定**单一格式**（如 `MP3`）：此时不适用于该文件类型的条目会**自动跳过**并计入统计，不会让整批中断。
3. 「③ 开始批量转换」：串行逐个处理（避免 FFmpeg 并发与内存峰值），进度条显示整体进度，可随时「停止当前批次」（当前文件转完后生效）。
4. 结束后显示 `成功 / 跳过 / 失败` 统计与失败明细；点「分享 / 保存全部结果」一次性分享所有产物，或到
   「文件 → 我的 iPhone → 格式转换器 → **Converted → 批量_日期时间**」取出（已开启文件共享）。

> 每次批量转换单独建一个结果目录，同名文件自动追加序号，**不会互相覆盖**。
> 文件夹按扩展名识别类型，隐藏文件与无法识别的类型会自动忽略；受 DRM 保护的文件会在该项标记失败，不影响其余条目。
> 选择文件夹使用系统 `UIDocumentPicker` 的 security-scoped 访问，App 会在整个批次期间持有该权限。

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
  RootViewController.swift      UI + 文件夹递归选择 / 串行批量队列 / 进度与取消（UIKit 纯代码）
  ConvertEngine.swift           双引擎转换逻辑（AVFoundation/ImageIO + FFmpeg 调度）
                                + 文件夹扫描、自动匹配格式、批次输出目录
  FFmpegBridge.h / .m           ObjC 桥接：进程内同步调用 FFmpegKit
  FormatConverter-Bridging-Header.h
  Info.plist / Assets.xcassets
scripts/fetch-ffmpeg.sh           CI 下载/校验/规范化 FFmpeg 动态库
.github/workflows/build-ipa.yml  macOS 出包流水线
verify.py                        IPA 校验
```
