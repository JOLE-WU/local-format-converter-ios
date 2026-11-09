import UIKit
import UniformTypeIdentifiers

final class RootViewController: UIViewController, UIDocumentPickerDelegate {

    // MARK: - 状态

    private var sourceURL: URL?
    private var sourceKind: MediaKind = .unknown
    private var formats: [FormatSpec] = []
    private var selectedFormat: FormatSpec?
    private var outputURL: URL?
    private var busy = false

    // MARK: - UI

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let infoLabel = UILabel()
    private let pickButton = UIButton(type: .system)
    private let formatButton = UIButton(type: .system)
    private let qualityLabel = UILabel()
    private let qualityControl = UISegmentedControl(items: ["最高", "中等", "较低", "720p", "480p"])
    private let convertButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let shareButton = UIButton(type: .system)
    private let noteLabel = UILabel()

    // MARK: - 生命周期

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

        let header = makeLabel("本地格式互转", size: 15, weight: .semibold, color: .secondaryLabel)
        stack.addArrangedSubview(header)

        // 选择文件
        style(pickButton, title: "① 选择要转换的文件", filled: true)
        pickButton.addTarget(self, action: #selector(pickFile), for: .touchUpInside)
        stack.addArrangedSubview(pickButton)
        pickButton.heightAnchor.constraint(equalToConstant: 48).isActive = true

        infoLabel.numberOfLines = 0
        infoLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        infoLabel.textColor = .label
        infoLabel.backgroundColor = .secondarySystemGroupedBackground
        infoLabel.layer.cornerRadius = 10
        infoLabel.clipsToBounds = true
        infoLabel.text = "尚未选择文件"
        infoLabel.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
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

        // 目标格式
        stack.addArrangedSubview(makeLabel("② 选择目标格式", size: 15, weight: .semibold, color: .secondaryLabel))
        style(formatButton, title: "请先选择源文件", filled: false)
        formatButton.addTarget(self, action: #selector(chooseFormat), for: .touchUpInside)
        stack.addArrangedSubview(formatButton)
        formatButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        qualityLabel.text = "画质（仅视频转视频有效）"
        qualityLabel.font = .systemFont(ofSize: 13)
        qualityLabel.textColor = .secondaryLabel
        stack.addArrangedSubview(qualityLabel)
        qualityControl.selectedSegmentIndex = 0
        stack.addArrangedSubview(qualityControl)

        // 开始转换
        style(convertButton, title: "③ 开始转换", filled: true)
        convertButton.addTarget(self, action: #selector(startConvert), for: .touchUpInside)
        stack.addArrangedSubview(convertButton)
        convertButton.heightAnchor.constraint(equalToConstant: 50).isActive = true

        progressView.progress = 0
        stack.addArrangedSubview(progressView)
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "就绪"
        stack.addArrangedSubview(statusLabel)

        style(shareButton, title: "分享 / 保存转换结果", filled: false)
        shareButton.addTarget(self, action: #selector(shareResult), for: .touchUpInside)
        stack.addArrangedSubview(shareButton)
        shareButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        noteLabel.numberOfLines = 0
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .tertiaryLabel
        noteLabel.text = """
        全部转换在本机离线完成，不上传任何文件、不联网。

        支持范围（受 iOS 系统解码能力限制）：
        · 视频：MP4 / MOV / M4V 互转，可重编码压缩、提取音轨
        · 音频：M4A(AAC) / WAV / AIFF / CAF(PCM) 互转
        · 图片：JPEG / PNG / HEIC / TIFF / GIF / BMP 互转
        · MKV / AVI / FLAC / WebM 等 iOS 无法原生解码，需先用桌面工具预处理

        转换结果保存在「文件 → 我的 iPhone → 格式转换器 → Converted」，也可点上方按钮直接分享。
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

    private func refresh() {
        let hasSource = sourceURL != nil
        formatButton.isEnabled = hasSource && !formats.isEmpty && !busy
        convertButton.isEnabled = hasSource && selectedFormat != nil && !busy
        shareButton.isEnabled = outputURL != nil && !busy
        pickButton.isEnabled = !busy
        qualityControl.isEnabled = !busy
        let showQuality = selectedFormat?.group == 0
        qualityControl.alpha = showQuality ? 1 : 0.4
        qualityLabel.alpha = showQuality ? 1 : 0.4

        if let f = selectedFormat {
            formatButton.setTitle("\(f.title)  (. \(f.ext))  ▾", for: .normal)
        } else if hasSource {
            formatButton.setTitle(formats.isEmpty ? "此文件类型无法转换" : "点击选择目标格式  ▾", for: .normal)
        } else {
            formatButton.setTitle("请先选择源文件", for: .normal)
        }
    }

    // MARK: - 选择文件

    @objc private func pickFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        sourceURL = url
        sourceKind = ConvertEngine.shared.detect(url)
        formats = ConvertEngine.shared.availableFormats(for: sourceKind)
        selectedFormat = nil
        outputURL = nil
        infoLabel.text = ConvertEngine.shared.describe(url)
        statusLabel.text = "已选择文件，请选择目标格式"
        progressView.progress = 0
        refresh()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

    // MARK: - 选择格式

    @objc private func chooseFormat() {
        guard !formats.isEmpty else { return }
        let ac = UIAlertController(title: "目标格式", message: "选择要转换成的格式", preferredStyle: .alert)
        for f in formats {
            ac.addAction(UIAlertAction(title: "\(f.title)  (. \(f.ext))", style: .default) { [weak self] _ in
                self?.selectedFormat = f
                self?.outputURL = nil
                self?.statusLabel.text = "准备就绪"
                self?.progressView.progress = 0
                self?.refresh()
            })
        }
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(ac, animated: true)
    }

    // MARK: - 转换

    @objc private func startConvert() {
        guard let src = sourceURL, let f = selectedFormat else { return }
        busy = true
        progressView.progress = 0
        statusLabel.text = "正在转换…"
        refresh()

        ConvertEngine.shared.convert(source: src, kind: sourceKind, format: f,
                                     quality: qualityControl.selectedSegmentIndex,
                                     progress: { [weak self] p in
            self?.progressView.setProgress(Float(p), animated: true)
        }, completion: { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            switch result {
            case .success(let url):
                self.outputURL = url
                self.statusLabel.text = "✅ 转换完成\n\(url.lastPathComponent)"
            case .failure(let e):
                self.outputURL = nil
                self.statusLabel.text = "❌ \(e.localizedDescription)"
            }
            self.refresh()
        })
    }

    // MARK: - 分享

    @objc private func shareResult() {
        guard let url = outputURL else { return }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.popoverPresentationController?.sourceView = shareButton
        ac.popoverPresentationController?.sourceRect = shareButton.bounds
        present(ac, animated: true)
    }
}
