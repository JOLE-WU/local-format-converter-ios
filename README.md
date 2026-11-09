# 格式转换器（侧载用 unsigned IPA）

一个**完全离线**的 iOS 本地文件格式转换器，全部转换在设备本机完成，不联网、不上传任何文件。
基于系统自带的 `AVFoundation` / `ImageIO`，无任何第三方依赖。

## 支持范围

| 源文件 | 可转出 |
|---|---|
| 视频 (MP4 / MOV / M4V / 3GP…) | MP4、MOV、M4V（可重编码压缩：最高/中等/较低/720p/480p）、M4A 音轨、WAV / AIFF / CAF 音轨 |
| 音频 (M4A / MP3 / AAC / WAV / AIFF / CAF…) | M4A (AAC)、WAV / AIFF / CAF (16-bit PCM) |
| 图片 (JPEG / PNG / HEIC / TIFF / GIF / BMP / WebP…) | JPEG、PNG、HEIC、TIFF、GIF、BMP |

> **这是 iOS 原生能力的边界**：MKV / AVI / FLAC / WebM / OGG 等格式 iOS 系统不提供解码器，
> 任何纯原生 App 都无法处理，需要先用桌面工具（如 ffmpeg）转成 MP4 / M4A。
> 想要「全格式」需要编译进 FFmpeg 静态库，体积和复杂度都会大幅上升。

## 侧载步骤

本仓库产出的是**未签名 IPA**（`CODE_SIGNING_ALLOWED=NO`），需要用你自己的 Apple ID 重签名后安装：

1. 下载 `FormatConverter.ipa`（Actions Artifact，或仓库 `dist/` 目录）。
2. 任选一种侧载工具：
   - **Sideloadly**（Windows / macOS）：拖入 IPA，填 Apple ID，点 Start；装好后到
     「设置 → 通用 → VPN 与设备管理」信任开发者证书。
   - **AltStore / SideStore**：导入 IPA 后用 Apple ID 签名安装。
   - **爱思助手 / 牛蛙助手** 等：选择 IPA 并签名。
3. 免费 Apple ID 签名有效期 **7 天**，到期重新签一次即可；付费开发者账号为 1 年。

## 使用

1. 打开 App →「选择要转换的文件」（从「文件」App 选取）。
2. 选目标格式 → 视频转视频时可选画质 →「开始转换」。
3. 完成后点「分享 / 保存转换结果」直接分享；
   或到「文件 → 我的 iPhone → 格式转换器 → Converted」取出（已开启文件共享）。

## 构建（GitHub Actions）

- `macos-latest` runner，`xcodebuild -sdk iphoneos CODE_SIGNING_ALLOWED=NO clean build`
- 打包为 `Payload/FormatConverter.app` 的 zip，去掉签名残留
- `verify.py` 校验 bundle 结构与 Mach-O arm64
- 产物：Actions Artifact `FormatConverter-unsigned-ipa` + 回推 `dist/FormatConverter.ipa`

推送到 `main` 自动触发，也可在 Actions 页手动 `workflow_dispatch`。

## 工程结构

```
FormatConverter.xcodeproj/        工程文件 + shared scheme
FormatConverter/
  App.swift                     @main AppDelegate / SceneDelegate
  RootViewController.swift      UI（UIKit 纯代码）
  ConvertEngine.swift           转换引擎（AVFoundation + ImageIO）
  Info.plist / Assets.xcassets
.github/workflows/build-ipa.yml  macOS 出包流水线
verify.py                        IPA 校验
```
