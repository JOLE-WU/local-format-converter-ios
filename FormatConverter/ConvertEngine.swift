import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

// MARK: - 数据模型

enum MediaKind: String {
    case video, audio, image, unknown
}

struct FormatSpec {
    let id: String
    let title: String
    let ext: String
    let group: Int          // 0 视频 / 1 音频 / 2 图片
    let uti: String?
}

enum ConvertError: LocalizedError {
    case unreadable
    case unsupported
    case sessionUnavailable
    case exportFailed(String)
    case audioFailed(String)
    case imageFailed
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:          return "无法读取该文件，可能是不支持的编码或受 DRM 保护"
        case .unsupported:         return "这种源文件类型暂不支持"
        case .sessionUnavailable:  return "无法创建导出会话，请换一种目标格式"
        case .exportFailed(let m): return "导出失败：\(m)"
        case .audioFailed(let m):  return "音频转换失败：\(m)"
        case .imageFailed:         return "图片转换失败，请换一种目标格式"
        case .ffmpegFailed(let m): return "FFmpeg 转换失败：\(m)"
        }
    }
}

// MARK: - 转换引擎（全部本地，零联网）
//
// 双引擎：
//   · 系统 AVFoundation / ImageIO：处理 iOS 原生可解码格式，轻量、硬件加速
//   · 内置 FFmpeg 动态库：处理 iOS 原生不支持的 WMA/ASF/FLAC/OGG/MKV/AVI 等，
//     并提供 iOS 缺失的 MP3 编码器（libmp3lame）

final class ConvertEngine {

    static let shared = ConvertEngine()
    private init() {}

    /// 转换结果统一放在「文件 App → 我的 iPhone → 格式转换器 → Converted」
    static var outputDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let imageExts: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]

    private static let audioExts: Set<String> =
        ["m4a", "mp3", "aac", "wav", "aif", "aiff", "aifc", "caf", "alac", "au", "snd", "m4b",
         "wma", "asf", "flac", "ogg", "oga", "opus", "mka", "ape", "wv", "tta",
         "amr", "ac3", "eac3", "dts", "mp2", "ra", "rm"]

    private static let videoExts: Set<String> =
        ["mp4", "mov", "m4v", "3gp", "3g2", "mts", "m2ts", "ts",
         "mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "vob", "rmvb", "divx"]

    /// iOS 原生无法解码、必须交给内置 FFmpeg 的扩展名
    private static let ffmpegInputExts: Set<String> =
        ["wma", "asf", "flac", "ogg", "oga", "opus", "mka", "ape", "wv", "tta",
         "amr", "ac3", "eac3", "dts", "mp2", "ra", "rm", "rmvb",
         "mkv", "avi", "webm", "flv", "wmv", "mpg", "mpeg", "vob", "divx"]

    /// iOS 原生无法编码、必须交给 FFmpeg 的目标格式
    private static let ffmpegOutputIds: Set<String> = ["mp3", "flac"]

    func detect(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ConvertEngine.imageExts.contains(ext) { return .image }
        if ConvertEngine.videoExts.contains(ext) { return .video }
        if ConvertEngine.audioExts.contains(ext) { return .audio }
        let asset = AVURLAsset(url: url)
        if !asset.tracks(withMediaType: .video).isEmpty { return .video }
        if !asset.tracks(withMediaType: .audio).isEmpty { return .audio }
        return .unknown
    }

    /// 根据源文件类型给出可以转出的格式
    func availableFormats(for kind: MediaKind) -> [FormatSpec] {
        switch kind {
        case .video:
            return [
                FormatSpec(id: "mp4",  title: "MP4 视频",     ext: "mp4",  group: 0, uti: nil),
                FormatSpec(id: "mov",  title: "MOV 视频",     ext: "mov",  group: 0, uti: nil),
                FormatSpec(id: "m4v",  title: "M4V 视频",     ext: "m4v",  group: 0, uti: nil),
                FormatSpec(id: "m4a",  title: "M4A 音频",     ext: "m4a",  group: 1, uti: nil),
                FormatSpec(id: "mp3",  title: "MP3 音频",     ext: "mp3",  group: 1, uti: nil),
                FormatSpec(id: "wav",  title: "WAV 音频",     ext: "wav",  group: 1, uti: nil),
                FormatSpec(id: "flac", title: "FLAC 无损",    ext: "flac", group: 1, uti: nil),
                FormatSpec(id: "aiff", title: "AIFF 音频",    ext: "aiff", group: 1, uti: nil),
                FormatSpec(id: "caf",  title: "CAF 音频",     ext: "caf",  group: 1, uti: nil),
            ]
        case .audio:
            return [
                FormatSpec(id: "m4a",  title: "M4A (AAC)",    ext: "m4a",  group: 1, uti: nil),
                FormatSpec(id: "mp3",  title: "MP3",          ext: "mp3",  group: 1, uti: nil),
                FormatSpec(id: "wav",  title: "WAV (PCM)",    ext: "wav",  group: 1, uti: nil),
                FormatSpec(id: "flac", title: "FLAC 无损",    ext: "flac", group: 1, uti: nil),
                FormatSpec(id: "aiff", title: "AIFF (PCM)",   ext: "aiff", group: 1, uti: nil),
                FormatSpec(id: "caf",  title: "CAF (PCM)",    ext: "caf",  group: 1, uti: nil),
            ]
        case .image:
            return [
                FormatSpec(id: "jpg",  title: "JPEG", ext: "jpg",  group: 2, uti: UTType.jpeg.identifier),
                FormatSpec(id: "png",  title: "PNG",  ext: "png",  group: 2, uti: UTType.png.identifier),
                FormatSpec(id: "heic", title: "HEIC", ext: "heic", group: 2, uti: UTType.heic.identifier),
                FormatSpec(id: "tiff", title: "TIFF", ext: "tiff", group: 2, uti: UTType.tiff.identifier),
                FormatSpec(id: "gif",  title: "GIF",  ext: "gif",  group: 2, uti: UTType.gif.identifier),
                FormatSpec(id: "bmp",  title: "BMP",  ext: "bmp",  group: 2, uti: UTType.bmp.identifier),
            ]
        case .unknown:
            return []
        }
    }

    /// 源文件的可读描述
    func describe(_ url: URL) -> String {
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.doubleValue ?? 0
        let sizeText = Self.byteText(Int64(size))
        let kind = detect(url)
        var lines: [String] = ["名称：\(name)", "大小：\(sizeText)"]

        switch kind {
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let secs = CMTimeGetSeconds(asset.duration)
            if secs.isFinite && secs > 0 {
                lines.append("时长：\(Self.timeText(secs))")
            }
            let v = asset.tracks(withMediaType: .video)
            let a = asset.tracks(withMediaType: .audio)
            if let t = v.first {
                let s = t.naturalSize
                lines.append("视频：\(Int(s.width))×\(Int(s.height))")
            }
            if a.first != nil { lines.append("音轨：有") }
            lines.append("类型：\(kind == .video ? "视频" : "音频")")
            if Self.ffmpegInputExts.contains(url.pathExtension.lowercased()) {
                lines.append("解码：内置 FFmpeg（系统无此解码器）")
            }
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                lines.append("尺寸：\(w)×\(h)")
            }
            lines.append("类型：图片")
        case .unknown:
            lines.append("类型：未识别（系统可能无法解码）")
        }
        return lines.joined(separator: "\n")
    }

    private static func timeText(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    private static func byteText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private static func destination(_ source: URL, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let df = DateFormatter()
        df.dateFormat = "HHmmss"
        let name = "\(base)_转\(ext.uppercased())_\(df.string(from: Date())).\(ext)"
        let url = outputDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    // MARK: - 主入口

    func convert(source: URL,
                 kind: MediaKind,
                 format: FormatSpec,
                 quality: Int,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        let dest = Self.destination(source, ext: format.ext)

        // 源是 iOS 原生解不了的格式，或目标是 iOS 原生编不了的格式 → 走 FFmpeg
        let needFFmpeg = ConvertEngine.ffmpegInputExts.contains(source.pathExtension.lowercased())
                      || ConvertEngine.ffmpegOutputIds.contains(format.id)
        if needFFmpeg {
            let options = Self.ffmpegOptions(for: format)
            convertViaFFmpeg(source: source, dest: dest, options: options,
                             progress: progress, completion: completion)
            return
        }

        switch format.group {
        case 2:
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.convertImage(source: source, dest: dest, format: format)
                    self.done(.success(dest), progress: progress, completion: completion)
                } catch {
                    self.done(.failure(error), progress: progress, completion: completion)
                }
            }
        case 0:
            self.exportVideo(source: source, dest: dest, format: format, quality: quality,
                             progress: progress, completion: completion)
        case 1 where format.id == "m4a":
            self.exportM4A(source: source, dest: dest, progress: progress, completion: completion)
        case 1:
            // WAV / AIFF / CAF：视频源先抽出 m4a，再统一做 PCM 重编码
            self.prepareAudioSource(source: source, kind: kind, progress: progress) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .failure(let e):
                    self.done(.failure(e), progress: progress, completion: completion)
                case .success(let audio):
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try self.writePCM(audio: audio, dest: dest) { p in
                                DispatchQueue.main.async { progress(0.35 + p * 0.65) }
                            }
                            self.done(.success(dest), progress: progress, completion: completion)
                        } catch {
                            self.done(.failure(error), progress: progress, completion: completion)
                        }
                    }
                }
            }
        default:
            done(.failure(ConvertError.unsupported), progress: progress, completion: completion)
        }
    }

    // MARK: - FFmpeg 路径（进程内同步执行）

    /// 生成 ffmpeg 参数（不含任何路径，路径由桥接层单独传入，避免空格被拆）
    private static func ffmpegOptions(for format: FormatSpec) -> String {
        switch format.id {
        case "mp3":            return "-vn -c:a libmp3lame -q:a 2"
        case "flac":           return "-vn -c:a flac"
        case "m4a":            return "-vn -c:a aac -b:a 192k"
        case "wav", "caf":     return "-vn -c:a pcm_s16le"
        case "aiff":           return "-vn -c:a pcm_s16be"
        // 视频：ffmpeg-only 源（MKV/AVI/WebM…）统一重编码为兼容性最好的 MPEG-4 + AAC
        case "mp4", "m4v", "mov":
            return "-c:v mpeg4 -q:v 5 -c:a aac -b:a 128k -pix_fmt yuv420p"
        default:               return "-vn -c:a aac -b:a 192k"
        }
    }

    private var ffmpegTimer: Timer?

    private func convertViaFFmpeg(source: URL, dest: URL, options: String,
                                  progress: @escaping (Double) -> Void,
                                  completion: @escaping (Result<URL, Error>) -> Void) {
        try? FileManager.default.removeItem(at: dest)

        // FFmpegKit 同步执行，没有内建进度回调；用一个平滑的估计进度避免界面卡在 0
        DispatchQueue.main.async {
            self.ffmpegTimer?.invalidate()
            var p = 0.05
            self.ffmpegTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                p = min(0.9, p + 0.02)
                progress(p)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = source.path.withCString { sp in
                dest.path.withCString { dp in
                    options.withCString { op in
                        fc_ffmpeg_run(sp, dp, op)
                    }
                }
            }
            let fm = FileManager.default
            let ok: Bool = {
                guard let attr = try? fm.attributesOfItem(atPath: dest.path),
                      let n = attr[.size] as? NSNumber else { return false }
                return n.int64Value > 1024
            }()
            DispatchQueue.main.async {
                self.ffmpegTimer?.invalidate()
                self.ffmpegTimer = nil
                if ok {
                    self.done(.success(dest), progress: progress, completion: completion)
                } else {
                    try? fm.removeItem(at: dest)
                    self.done(.failure(ConvertError.ffmpegFailed("未生成输出文件，源文件可能损坏、受 DRM 保护或该编码不可用")),
                              progress: progress, completion: completion)
                }
            }
        }
    }

    private func done(_ result: Result<URL, Error>,
                      progress: @escaping (Double) -> Void,
                      completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.main.async {
            if case .success = result { progress(1.0) }
            completion(result)
        }
    }

    // MARK: - 视频 / M4A：AVAssetExportSession

    private var progressTimer: Timer?

    private func exportVideo(source: URL, dest: URL, format: FormatSpec, quality: Int,
                             progress: @escaping (Double) -> Void,
                             completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: source)
        let preset: String
        switch quality {
        case 0: preset = AVAssetExportPresetHighestQuality
        case 1: preset = AVAssetExportPresetMediumQuality
        case 2: preset = AVAssetExportPresetLowQuality
        case 3: preset = AVAssetExportPreset1280x720
        default: preset = AVAssetExportPreset640x480
        }
        let fileType: AVFileType
        switch format.id {
        case "mov": fileType = .mov
        case "m4v": fileType = .m4v
        default:    fileType = .mp4
        }
        runExport(asset: asset, dest: dest, preset: preset, fileType: fileType,
                  progress: progress, completion: completion)
    }

    private func exportM4A(source: URL, dest: URL,
                           progress: @escaping (Double) -> Void,
                           completion: @escaping (Result<URL, Error>) -> Void) {
        runExport(asset: AVURLAsset(url: source), dest: dest,
                  preset: AVAssetExportPresetAppleM4A, fileType: .m4a,
                  progress: progress, completion: completion)
    }

    private func runExport(asset: AVAsset, dest: URL, preset: String, fileType: AVFileType,
                           progress: @escaping (Double) -> Void,
                           completion: @escaping (Result<URL, Error>) -> Void) {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            done(.failure(ConvertError.sessionUnavailable), progress: progress, completion: completion)
            return
        }
        session.outputURL = dest
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            let p = Double(session.progress)
            DispatchQueue.main.async { progress(p * 0.98) }
        }

        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                self?.progressTimer?.invalidate()
                self?.progressTimer = nil
                switch session.status {
                case .completed:
                    self?.done(.success(dest), progress: progress, completion: completion)
                case .failed:
                    self?.done(.failure(ConvertError.exportFailed(session.error?.localizedDescription ?? "未知错误")),
                               progress: progress, completion: completion)
                case .cancelled:
                    self?.done(.failure(ConvertError.exportFailed("已取消")),
                               progress: progress, completion: completion)
                default:
                    self?.done(.failure(ConvertError.exportFailed("状态异常")),
                               progress: progress, completion: completion)
                }
            }
        }
    }

    // MARK: - PCM 音频（WAV / AIFF / CAF）

    private func prepareAudioSource(source: URL, kind: MediaKind,
                                    progress: @escaping (Double) -> Void,
                                    completion: @escaping (Result<URL, Error>) -> Void) {
        if kind == .audio {
            completion(.success(source))
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc_audio_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: tmp)
        runExport(asset: AVURLAsset(url: source), dest: tmp,
                  preset: AVAssetExportPresetAppleM4A, fileType: .m4a,
                  progress: { p in DispatchQueue.main.async { progress(p * 0.35) } }) { result in
            switch result {
            case .success: completion(.success(tmp))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    private func writePCM(audio: URL, dest: URL, progress: @escaping (Double) -> Void) throws {
        let src: AVAudioFile
        do { src = try AVAudioFile(forReading: audio) }
        catch { throw ConvertError.audioFailed(error.localizedDescription) }

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: src.processingFormat.sampleRate,
                                            channels: src.processingFormat.channelCount,
                                            interleaved: true) else {
            throw ConvertError.audioFailed("无法建立 PCM 格式")
        }
        let dst: AVAudioFile
        do { dst = try AVAudioFile(forWriting: dest, settings: dstFormat.settings) }
        catch { throw ConvertError.audioFailed(error.localizedDescription) }

        guard let converter = AVAudioConverter(from: src.processingFormat, to: dst.processingFormat) else {
            throw ConvertError.audioFailed("无法建立转换器")
        }
        let capacity: AVAudioFrameCount = 8192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: capacity) else {
            throw ConvertError.audioFailed("无法分配缓冲区")
        }
        let total = Double(src.length)
        while src.framePosition < src.length {
            do { try src.read(into: inputBuffer, frameCount: capacity) }
            catch { throw ConvertError.audioFailed(error.localizedDescription) }
            if inputBuffer.frameLength == 0 { break }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: dst.processingFormat, frameCapacity: capacity) else {
                throw ConvertError.audioFailed("无法分配输出缓冲区")
            }
            var convError: NSError?
            var provided = false
            let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if provided {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if status == .error {
                throw ConvertError.audioFailed(convError?.localizedDescription ?? "转换错误")
            }
            if outputBuffer.frameLength > 0 {
                do { try dst.write(from: outputBuffer) }
                catch { throw ConvertError.audioFailed(error.localizedDescription) }
            }
            if total > 0 { progress(min(1.0, Double(src.framePosition) / total)) }
        }
    }

    // MARK: - 图片：ImageIO

    private func convertImage(source: URL, dest: URL, format: FormatSpec) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let uti = format.uti,
              let dst = CGImageDestinationCreateWithURL(dest as CFURL, uti as CFString, 1, nil) else {
            throw ConvertError.imageFailed
        }
        var props: [CFString: Any] = [:]
        if format.id == "jpg" || format.id == "heic" {
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(dst, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw ConvertError.imageFailed }
    }
}
