#!/usr/bin/env python3
"""校验打包出的 .ipa 是否满足侧载要求（未签名、结构正确、动态库齐全、元数据完整）。"""
import plistlib
import sys
import zipfile

IPA = "FormatConverter.ipa"
errors = []

# 侧载重签时会随整个 bundle 一并签名的 FFmpeg 动态库
FRAMEWORKS = ["ffmpegkit", "libavcodec", "libavdevice", "libavfilter",
              "libavformat", "libavutil", "libswresample", "libswscale"]

with zipfile.ZipFile(IPA) as z:
    names = z.namelist()
    plist_path = "Payload/FormatConverter.app/Info.plist"
    if plist_path not in names:
        print("缺少 Payload/FormatConverter.app/Info.plist")
        sys.exit(1)

    info = plistlib.loads(z.read(plist_path))
    exe = info.get("CFBundleExecutable", "")
    exe_path = f"Payload/FormatConverter.app/{exe}"

    print("=== Info.plist ===")
    for key in ("CFBundleDisplayName", "CFBundleIdentifier", "CFBundleExecutable",
                "CFBundlePackageType", "MinimumOSVersion", "CFBundleShortVersionString"):
        print(f"  {key}: {info.get(key)}")

    if info.get("CFBundlePackageType") != "APPL":
        errors.append("CFBundlePackageType 不是 APPL")
    if not exe:
        errors.append("缺少 CFBundleExecutable")
    if exe_path not in names:
        errors.append(f"缺少可执行文件 {exe_path}")

    # 侧载关键：不能带签名
    signed = [n for n in names if "_CodeSignature" in n or "embedded.mobileprovision" in n]
    if signed:
        errors.append(f"残留签名文件: {signed}")

    # 可执行文件应为 Mach-O（magic 0xFEEDFACF = arm64）
    if exe_path in names:
        head = z.read(exe_path)[:4]
        if head in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
            print("  主程序架构: Mach-O arm64 ✓")
        else:
            errors.append(f"可执行文件不是 Mach-O: {head.hex()}")

    # 内置 FFmpeg 库必须全部嵌入（动态库运行时 dyld 需要；静态库多余但无害）
    # 允许两种格式：Mach-O fat/瘦二进制 (cafebabe / cffaedfe) 或静态库归档 !<arch>
    print("=== 内置 FFmpeg 库 ===")
    fw_dir = "Payload/FormatConverter.app/Frameworks/"
    macho_magics = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
    for fw in FRAMEWORKS:
        bin_path = f"{fw_dir}{fw}.framework/{fw}"
        present = bin_path in names
        print(f"  {fw}.framework: {'✓' if present else '✗ 缺失'}")
        if not present:
            errors.append(f"缺少嵌入库 {fw}.framework")
        else:
            head = z.read(bin_path)[:8]
            if not (head[:4] in macho_magics or head.startswith(b"!<arch>")):
                errors.append(f"{fw}.framework 二进制格式异常: {head.hex()}")

    # 校验 libavcodec 里确实带 WMA 解码器与 MP3 编码器
    codec_path = f"{fw_dir}libavcodec.framework/libavcodec"
    if codec_path in names:
        blob = z.read(codec_path)
        has_wma = b"wmav2" in blob or b"wmapro" in blob
        has_mp3 = b"libmp3lame" in blob
        print(f"  WMA 解码器: {'✓' if has_wma else '✗'}   MP3(libmp3lame) 编码: {'✓' if has_mp3 else '✗'}")
        if not has_wma:
            errors.append("libavcodec 缺少 WMA 解码器")
        if not has_mp3:
            errors.append("libavcodec 缺少 libmp3lame MP3 编码器")

    print(f"  IPA 内文件数: {len(names)}")

if errors:
    print("\n=== 校验失败 ===")
    for e in errors:
        print("  ✗", e)
    sys.exit(1)
print("\n=== 校验通过：未签名 arm64 IPA，内含 FFmpeg(WMA→MP3)，可用于侧载重签名 ===")
