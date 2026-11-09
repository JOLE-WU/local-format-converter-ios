import UIKit
import UniformTypeIdentifiers

// MARK: - 批量任务模型

private struct BatchItem {
    let url: URL
    let kind: MediaKind
}

/// 一次批量转换的全部状态（串行执行，避免 FFmpeg 并发、内存峰值与进度回调互相覆盖）
private final class BatchRun {
    let items: [BatchItem]
    let directory: URL
    let quality: Int
    let singleFormat: FormatSpec?
    var index = 0
    var ok = 0
    var skipped = 0
    var failed = 0
    var outputs: [URL] = []
    var failures: [String] = []
    var cancelled = false
    var finished = false

    init(items: [BatchItem], directory: URL, quality: Int, singleFormat: FormatSpec?) {
        self.items = items
        self.directory = directory
        self.quality = quality
        self.singleFormat = singleFormat
    }
}

// MARK: - 主界面

final class RootViewController: UIViewController, UIDocumentPickerDelegate {

    // MARK: 状态

    private enum PickKind { case files, folder }
    private var pendingPick: PickKind = .files

    private var items: [BatchItem] = []
    private var scopeURLs: [URL] = []          // 需要持有 security-scoped 权限的文件夹
    private var autoMode = true
    private var selectedFormat: FormatSpec?
    private var outputs: [URL] = []
    private var batchDir: URL?
    private var busy = false
    private var currentRun: BatchRun?

    // MARK: UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let infoLabel = UILabel()
    private let pickFileButton = UIButton(type: .system)
    private let pickFolderButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    private let qualityLabel = UILabel()
    private let qualityControl = UISegmentedControl(items: ["最高", "中等", "较低", "720p", "480p"])
    private let convertButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let shareButton = UIButton(type: .system)
    private let noteLabel = UILabel()

    deinit {
        for u in scopeURLs { u.stopAccessingSecurityScopedResource() }
    }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "格式转换器"
        view.backgroundColor = .systemGroupedBackground
        navigationController?.navigationBar.prefersLargeTitles = true
        buildUI()
        refresh()
    }

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -30)
        ])

        stack.addArrangedSubview(makeLabel("① 选择来源（可叠加多次选择）", size: 15, weight: .semibold, color: .secondaryLabel))

        style(pickFileButton, title: "选择文件（可多选）", filled: true)
        pickFileButton.addTarget(self, action: #selector(pickFiles), for: .touchUpInside)
        stack.addArrangedSubview(pickFileButton)
        pickFileButton.heightAnchor.constraint(equalToConstant: 46).isActive = true

        style(pickFolderButton, title: "选择整个文件夹（含所有子文件夹）", filled: true)
        pickFolderButton.backgroundColor = .systemIndigo
        pickFolderButton.addTarget(self, action: #selector(pickFolder), for: .touchUpInside)
        stack.addArrangedSubview(pickFolderButton)
        pickFolderButton.heightAnchor.constraint(equalToConstant: 46).isActive = true

        style(clearButton, title: "清空已选", filled: false)
        clearButton.titleLabel?.font = .systemFont(ofSize: 13)
        clearButton.addTarget(self, action: #selector(clearSelection), for: .touchUpInside)
        stack.addArrangedSubview(clearButton)
        clearButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        infoLabel.numberOfLines = 0
        infoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        infoLabel.textColor = .label
        infoLabel.text = "尚未选择文件"
        let infoPad = UIView()
        infoPad.backgroundColor = .secondarySystemGroupedBackground
        infoPad.layer.cornerRadius = 10
        infoPad.addSubview(infoLabel)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: infoPad.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: infoPad.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: infoPad.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: infoPad.bottomAnchor, constant: -12)
        ])
        stack.addArrangedSubview(infoPad)

        stack.addArrangedSubview(makeLabel("② 选择目标格式", size: 15, weight: .semibold, color: .secondaryLabel))
        style(formatButton, title: "请先选择文件或文件夹", filled: false)
        formatButton.addTarget(self, action: #selector(chooseFormat), for: .touchUpInside)
        stack.addArrangedSubview(formatButton)
        formatButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        qualityLabel.text = "画质（仅视频转视频有效）"
        qualityLabel.font = .systemFont(ofSize: 13)
        qualityLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(qualityLabel)
        qualityControl.selectedSegmentIndex = 0
        stack.addArrangedSubview(qualityControl)

        style(convertButton, title: "③ 开始批量转换", filled: true)
        convertButton.addTarget(self, action: #selector(startConvert), for: .touchUpInside)
        stack.addArrangedSubview(convertButton)
        convertButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        style(cancelButton, title: "停止当前批次（当前文件转完后生效）", filled: false)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 13)
        cancelButton.addTarget(self, action: #selector(cancelConvert), for: .touchUpInside)
        stack.addArrangedSubview(cancelButton)
        cancelButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        progressView.progress = 0
        stack.addArrangedSubview(progressView)
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "就绪"
        stack.addArrangedSubview(statusLabel)

        style(shareButton, title: "分享 / 保存全部结果", filled: false)
        shareButton.addTarget(self, action: #selector(shareResult), for: .touchUpInside)
        stack.addArrangedSubview(shareButton)
        shareButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        noteLabel.numberOfLines = 0
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .tertiaryLabel
        noteLabel.text = """
        全部转换在本机离线完成，不上传任何文件、不联网。

        · 选择文件夹后会自动递归收集里面所有可识别的文件（含子文件夹），可反复叠加选择。
        · 「自动匹配」按文件类型各用默认目标：视频→MP4、音频→MP3、图片→JPG，适合混合文件夹。
        · 若手动指定单一格式，不适用于该文件类型的条目会自动跳过并计入统计。
        · 按扩展名识别；隐藏文件、无法识别的类型会自动忽略。
        · 每次批量转换单独生成一个结果目录，同名文件不会互相覆盖。

        音频：WMA / FLAC / OGG / Opus / M4A / MP3 / WAV / AIFF / CAF 互转（WMA→MP3 可用）
        视频：MP4 / MOV / M4V / MKV / AVI / WebM / FLV 等
        图片：JPEG / PNG / HEIC / TIFF / GIF / BMP 互转

        结果保存在「文件 → 我的 iPhone → 格式转换器 → Converted → 批量_日期时间」，也可直接分享。
        """
        stack.addArrangedSubview(noteLabel)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = 0
        return l
    }

    private func style(_ b: UIButton, title: String, filled: Bool) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.8
        b.layer.cornerRadius = 10
        b.clipsToBounds = true
        if filled {
            b.backgroundColor = .systemBlue
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .disabled)
        } else {
            b.backgroundColor = .secondarySystemGroupedBackground
            b.setTitleColor(.label, for: .normal)
            b.setTitleColor(.tertiaryLabel, for: .disabled)
        }
    }

    // MARK: 界面刷新

    private func refresh() {
        let n = items.count
        pickFileButton.isEnabled = !busy
        pickFolderButton.isEnabled = !busy
        clearButton.isEnabled = n > 0 && !busy
        formatButton.isEnabled = n > 0 && !busy
        convertButton.isEnabled = n > 0 && !busy
        cancelButton.isEnabled = busy
        shareButton.isEnabled = !outputs.isEmpty && !busy
        qualityControl.isEnabled = !busy

        let hasVideo = items.contains { $0.kind == .video }
        let videoTarget = autoMode || (selectedFormat?.group == 0)
        let showQuality = hasVideo && videoTarget
        qualityControl.alpha = showQuality ? 1 : 0.4
        qualityLabel.alpha = showQuality ? 1 : 0.4

        convertButton.setTitle(n > 0 ? "③ 开始批量转换（\(n) 个）" : "③ 开始批量转换", for: .normal)
        shareButton.setTitle(outputs.isEmpty ? "分享 / 保存全部结果" : "分享 / 保存全部结果（\(outputs.count) 个）", for: .normal)

        if items.isEmpty {
            formatButton.setTitle("请先选择文件或文件夹", for: .normal)
        } else if autoMode {
            formatButton.setTitle("⭐ 自动匹配（视频→MP4 / 音频→MP3 / 图片→JPG）  ▾", for: .normal)
        } else if let f = selectedFormat {
            formatButton.setTitle("\(f.title)  (.\(f.ext))  ▾", for: .normal)
        } else {
            formatButton.setTitle("点击选择目标格式  ▾", for: .normal)
        }
        infoLabel.text = summary()
    }

    private func summary() -> String {
        guard !items.isEmpty else { return "尚未选择文件" }
        var v = 0, a = 0, i = 0
        for it in items {
            switch it.kind {
            case .video: v += 1
            case .audio: a += 1
            case .image: i += 1
            case .unknown: break
            }
        }
        var lines = ["已选 \(items.count) 个文件", "视频 \(v) · 音频 \(a) · 图片 \(i)", ""]
        for it in items.prefix(8) {
            lines.append("· \(it.url.lastPathComponent)")
        }
        if items.count > 8 { lines.append("… 其余 \(items.count - 8) 个") }
        return lines.joined(separator: "\n")
    }

    // MARK: 选择来源

    @objc private func pickFiles() {
        pendingPick = .files
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    @objc private func pickFolder() {
        pendingPick = .folder
        // 选文件夹必须 asCopy:false，才能拿到目录本身并递归遍历其内容
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch pendingPick {
        case .files:  addFiles(urls)
        case .folder: addFolders(urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    private func addFiles(_ urls: [URL]) {
        var added: [BatchItem] = []
        var unknown = 0
        for u in urls {
            let k = ConvertEngine.shared.detect(u)
            if k == .unknown { unknown += 1 } else { added.append(BatchItem(url: u, kind: k)) }
        }
        append(added, unknownCount: unknown, from: "文件")
    }

    private func addFolders(_ urls: [URL]) {
        for u in urls {
            if u.startAccessingSecurityScopedResource() { scopeURLs.append(u) }
        }
        statusLabel.text = "正在递归扫描文件夹…"
        let folders = urls
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [BatchItem] = []
            for f in folders {
                for (u, k) in ConvertEngine.shared.scan(folder: f) {
                    found.append(BatchItem(url: u, kind: k))
                }
            }
            DispatchQueue.main.async {
                self?.append(found, unknownCount: 0, from: "文件夹")
            }
        }
    }

    private func append(_ newItems: [BatchItem], unknownCount: Int, from label: String) {
        var seen = Set(items.map { $0.url.path })
        let unique = newItems.filter { seen.insert($0.url.path).inserted }
        items.append(contentsOf: unique)
        outputs.removeAll()
        progressView.progress = 0
        var msg: String
        if unique.isEmpty && unknownCount == 0 {
            msg = "\(label)内没有找到可转换的文件"
        } else {
            msg = "已加入 \(unique.count) 个\(label)"
            if unknownCount > 0 { msg += "，忽略 \(unknownCount) 个无法识别的文件" }
            msg += "，请选择目标格式"
        }
        statusLabel.text = msg
        refresh()
    }

    @objc private func clearSelection() {
        guard !busy else { return }
        for u in scopeURLs { u.stopAccessingSecurityScopedResource() }
        scopeURLs.removeAll()
        items.removeAll()
        outputs.removeAll()
        batchDir = nil
        selectedFormat = nil
        autoMode = true
        progressView.progress = 0
        statusLabel.text = "已清空"
        refresh()
    }

    // MARK: 选择格式

    @objc private func chooseFormat() {
        guard !items.isEmpty else { return }
        var list: [FormatSpec] = []
        var seen = Set<String>()
        for kind in [MediaKind.video, .audio, .image] {
            guard items.contains(where: { $0.kind == kind }) else { continue }
            for f in ConvertEngine.shared.availableFormats(for: kind) where !seen.contains(f.id) {
                seen.insert(f.id)
                list.append(f)
            }
        }
        let ac = UIAlertController(title: "目标格式",
                                   message: "批量转换时，不适用于该文件类型的条目会自动跳过",
                                   preferredStyle: .actionSheet)
        ac.addAction(UIAlertAction(title: "⭐ 自动匹配（视频→MP4 / 音频→MP3 / 图片→JPG）",
                                   style: .default) { [weak self] _ in
            self?.autoMode = true
            self?.selectedFormat = nil
            self?.refresh()
        })
        for f in list {
            ac.addAction(UIAlertAction(title: "\(f.title)  (.\(f.ext))", style: .default) { [weak self] _ in
                self?.autoMode = false
                self?.selectedFormat = f
                self?.refresh()
            })
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.popoverPresentationController?.sourceView = formatButton
        ac.popoverPresentationController?.sourceRect = formatButton.bounds
        present(ac, animated: true)
    }

    // MARK: 批量转换

    @objc private func startConvert() {
        guard !items.isEmpty, !busy else { return }
        let dir = ConvertEngine.makeBatchDirectory()
        let run = BatchRun(items: items, directory: dir, quality: qualityControl.selectedSegmentIndex,
                           singleFormat: autoMode ? nil : selectedFormat)
        batchDir = dir
        currentRun = run
        busy = true
        outputs.removeAll()
        progressView.progress = 0
        statusLabel.text = "准备开始批量转换…"
        refresh()
        runNext(run)
    }

    private func runNext(_ run: BatchRun) {
        if run.finished { return }
        if run.cancelled { finish(run); return }
        if run.index >= run.items.count { finish(run); return }

        let i = run.index
        let total = run.items.count
        let item = run.items[i]
        let target: FormatSpec?
        if let single = run.singleFormat {
            target = ConvertEngine.shared.supports(kind: item.kind, format: single) ? single : nil
        } else {
            target = ConvertEngine.shared.autoFormat(for: item.kind)
        }

        guard let target = target else {
            run.skipped += 1
            run.index += 1
            progressView.setProgress(Float(Double(i + 1) / Double(total)), animated: true)
            statusLabel.text = "(\(i + 1)/\(total)) 跳过 \(item.url.lastPathComponent)（不适用此格式）"
            // 异步推进，避免整批都是「跳过」时同步递归过深
            DispatchQueue.main.async { [weak self] in self?.runNext(run) }
            return
        }

        statusLabel.text = "(\(i + 1)/\(total)) 正在转换\n\(item.url.lastPathComponent) → .\(target.ext)"
        ConvertEngine.shared.convert(
            source: item.url, kind: item.kind, format: target,
            quality: run.quality, outputDirectory: run.directory,
            progress: { [weak self] p in
                DispatchQueue.main.async {
                    self?.progressView.setProgress(Float((Double(i) + p) / Double(total)), animated: true)
                }
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let u):
                    run.ok += 1
                    run.outputs.append(u)
                case .failure(let e):
                    run.failed += 1
                    run.failures.append("\(item.url.lastPathComponent): \(e.localizedDescription)")
                }
                run.index += 1
                self.runNext(run)
            })
    }

    private func finish(_ run: BatchRun) {
        guard !run.finished else { return }
        run.finished = true
        busy = false
        currentRun = nil
        outputs = run.outputs
        if !run.cancelled { progressView.setProgress(1.0, animated: true) }
        var text = run.cancelled ? "⏹ 已停止：" : "✅ 批量完成："
        text += "成功 \(run.ok) · 跳过 \(run.skipped) · 失败 \(run.failed)"
        text += "\n结果目录：Converted/\(run.directory.lastPathComponent)"
        if !run.failures.isEmpty {
            text += "\n失败明细：" + run.failures.prefix(3).joined(separator: "；")
            if run.failures.count > 3 { text += " 等 \(run.failures.count) 项" }
        }
        statusLabel.text = text
        refresh()
    }

    @objc private func cancelConvert() {
        guard let run = currentRun, !run.cancelled else { return }
        run.cancelled = true
        statusLabel.text = "正在停止（当前文件转换完成后结束）…"
    }

    // MARK: 分享

    @objc private func shareResult() {
        guard !outputs.isEmpty else { return }
        let ac = UIActivityViewController(activityItems: outputs, applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = shareButton
        ac.popoverPresentationController?.sourceRect = shareButton.bounds
        present(ac, animated: true)
    }
}
