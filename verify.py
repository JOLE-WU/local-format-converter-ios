#!/usr/bin/env python3
"""校验打包出的 .ipa 是否满足侧载要求（未签名、结构正确、元数据齐全）。"""
import plistlib
import sys
import zipfile

IPA = "FormatConverter.ipa"
errors = []

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
            print("  架构: Mach-O arm64 ✓")
        else:
            errors.append(f"可执行文件不是 Mach-O: {head.hex()}")

    print(f"  IPA 内文件数: {len(names)}")

if errors:
    print("\n=== 校验失败 ===")
    for e in errors:
        print("  ✗", e)
    sys.exit(1)
print("\n=== 校验通过：未签名 IPA，可用于侧载重签名 ===")
