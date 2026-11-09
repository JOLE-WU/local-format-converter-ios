#!/usr/bin/env bash
#
# 在 macOS runner 上下载 FFmpegKit v6.0 的 iOS arm64 动态 frameworks，
# 校验「WMA 解码器 + libmp3lame 编码器」确实存在，并规范化 @rpath install name。
#
# 必须用 full / audio / full-gpl 变体：https / min 变体不含 libmp3lame（无法编码 MP3）。
# 产物：Frameworks/flat/*.framework（被 .gitignore 忽略，不入库）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$ROOT/.ffmpeg-download"
OUT="$ROOT/Frameworks/flat"
mkdir -p "$TMP" "$OUT"
rm -rf "${TMP:?}/"* "${OUT:?}/"*

# 按优先级尝试；均为 FFmpegKit v6.0 官方 iOS xcframework 的镜像。
# audio 变体最小（41MB）且含 libmp3lame + 原生 WMA 解码，作为首选。
SOURCES=(
  "https://github.com/werddomain/ffmpeg-kit/releases/download/v6.0/ffmpeg-kit-audio-6.0-ios-xcframework.zip"
  "https://github.com/werddomain/ffmpeg-kit/releases/download/v6.0/ffmpeg-kit-full-gpl-6.0-ios-xcframework.zip"
  "https://github.com/werddomain/ffmpeg-kit/releases/download/v6.0/ffmpeg-kit-full-6.0-ios-xcframework.zip"
  "https://github.com/NooruddinLakhani/ffmpeg-kit-ios-full-gpl/archive/refs/tags/latest.zip"
)
NAMES=(
  "FFmpegKit v6.0 / audio (最小且含 lame)"
  "FFmpegKit v6.0 / full-gpl"
  "FFmpegKit v6.0 / full"
  "FFmpegKit v6.0 / full-gpl (NooruddinLakhani 镜像)"
)

FRAMEWORKS=(ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale)

verify_codecs() {
  local bin="$OUT/libavcodec.framework/libavcodec"
  [ -f "$bin" ] || return 1
  # 用 Python 直接读二进制字节判断：macOS 的 strings 配合 `grep -q` 会因管道被提前
  # 关闭而输出 "failed to flush output"，在 pipefail 下造成假的「缺失」判断。
  python3 - "$bin" <<'PYCHECK'
import sys
data = open(sys.argv[1], "rb").read()
has_mp3 = b"libmp3lame" in data
has_wma = any(k in data for k in (b"wmav2", b"wmapro", b"wmalossless", b"wmavoice"))
print(f"     libmp3lame(MP3 编码)={int(has_mp3)}   WMA 解码={int(has_wma)}   ({len(data)} 字节)")
sys.exit(0 if (has_mp3 and has_wma) else 1)
PYCHECK
}

verify_frameworks() {
  local n
  for n in "${FRAMEWORKS[@]}"; do
    [ -f "$OUT/$n.framework/$n" ] || { echo "     缺少 $n.framework"; return 1; }
  done
  return 0
}

# 只保留真机 arm64 slice 的 .framework（兼容不同 zip 目录布局）
extract_arm64_frameworks() {
  local src="$1" fw dest base
  while IFS= read -r fw; do
    # 排除 simulator / maccatalyst 变体
    case "$fw" in *simulator*|*maccatalyst*) continue;; esac
    # 路径里必须出现 ios-arm64 这类真机 slice 标识
    case "$fw" in *ios-arm64*|*ios-arm64e*) ;; *) continue;; esac
    base="$(basename "$fw")"
    dest="$OUT/$base"
    [ -d "$dest" ] && continue
    cp -R "$fw" "$dest"
  done < <(find "$src" -type d -name '*.framework' 2>/dev/null || true)
}

# 动态库的 LC_ID_DYLIB 与互相依赖统一改成 @rpath，否则运行时 dyld 找不到
normalize_install_names() {
  local n fw bin dep base
  for n in "${FRAMEWORKS[@]}"; do
    fw="$OUT/$n.framework"; bin="$fw/$n"
    [ -f "$bin" ] || continue
    install_name_tool -id "@rpath/$n.framework/$n" "$bin" 2>/dev/null || true
    while IFS= read -r dep; do
      case "$dep" in
        *libav*.framework/*|*libsw*.framework/*|*ffmpegkit.framework/*)
          base="$(basename "$(dirname "$dep")" .framework)"
          install_name_tool -change "$dep" "@rpath/$base.framework/$base" "$bin" 2>/dev/null || true
          ;;
      esac
    done < <(otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}')
  done
  # 仅诊断输出，任何失败都不影响结果（静态库下 otool -D 可能失败）
  echo "     install name 示例:"
  { otool -D "$OUT/libavcodec.framework/libavcodec" 2>/dev/null | tail -1 | sed 's/^/       /'; } || true
}

for idx in "${!SOURCES[@]}"; do
  echo "=== 源 $((idx+1)): ${NAMES[$idx]} ==="
  if ! curl -fsSL --retry 2 --connect-timeout 20 --max-time 600 "${SOURCES[$idx]}" -o "$TMP/bundle.zip"; then
    echo "  ! 下载失败，尝试下一个源"; continue
  fi
  echo "  下载完成: $(du -h "$TMP/bundle.zip" | cut -f1)"
  rm -rf "$TMP/x"; mkdir -p "$TMP/x"
  if ! unzip -q -o "$TMP/bundle.zip" -d "$TMP/x"; then
    echo "  ! 解压失败，尝试下一个源"; continue
  fi
  rm -rf "${OUT:?}/"*; mkdir -p "$OUT"
  extract_arm64_frameworks "$TMP/x"
  echo "  已提取: $(ls -1 "$OUT" | tr '\n' ' ')"
  if ! verify_frameworks; then
    echo "  ! framework 不完整，尝试下一个源"; continue
  fi
  echo "  -> 校验编解码器:"
  if ! verify_codecs; then
    echo "  ! 该包缺少 WMA/MP3 支持，尝试下一个源"; continue
  fi
  # 二进制类型诊断：动态库(Mach-O dylib)需 embed + @rpath，静态库(ar archive)
  # 已静态链接进主程序、embed 多余但无害。工程两种都兼容。
  kind="$(file -b "$OUT/libavcodec.framework/libavcodec")"
  echo "  二进制类型: ${kind}"
  normalize_install_names
  echo "✅ 采用 ${NAMES[$idx]}"
  echo "=== 总体积 ==="; du -sh "$OUT"
  exit 0
done

echo "❌ 所有源都无法同时提供 WMA 解码与 MP3 编码，构建中止" >&2
exit 1
