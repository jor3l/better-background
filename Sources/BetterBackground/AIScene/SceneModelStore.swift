import AppKit
import Foundation

/// Downloads and installs the Stable Diffusion model used by the AI scene, on first use.
///
/// The model is Stable Diffusion 1.5 converted to Core ML with ControlNet support, plus the Depth
/// ControlNet, both from the coreml-community collection on Hugging Face (CreativeML OpenRAIL-M
/// licence). Nothing is bundled with the app; the files land in
/// ~/Library/Application Support/BetterBackground/Models/<variant>.
@MainActor
final class SceneModelStore: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(label: String, fraction: Double, detail: String)
        case installing(String)
        case ready
        case failed(String)
    }

    /// One downloadable model. `width` x `height` is what we expect; the real size is read from the model.
    struct Variant {
        let id: String
        let title: String
        let baseURL: URL
        let controlNetURL: URL
        let downloadBytes: Int64
    }

    static let defaultVariant = Variant(
        id: "sd15-cn-original-768x512",
        title: "Stable Diffusion 1.5 + Depth ControlNet (768 × 512)",
        baseURL: URL(string: "https://huggingface.co/coreml-community/coreml-stable-diffusion-v1-5_cn/resolve/main/original/768x512/stable-diffusion-_v1-5_original_768x512_cn.zip")!,
        controlNetURL: URL(string: "https://huggingface.co/coreml-community/ControlNet-Models-For-Core-ML/resolve/main/CN/Depth.zip")!,
        downloadBytes: 6_260_000_000
    )

    static let controlNetName = "Depth"

    @Published private(set) var state: State = .notInstalled
    /// Folder holding TextEncoder/ControlledUnet/VAE models, vocab.json, merges.txt and controlnet/Depth.mlmodelc.
    @Published private(set) var modelFolder: URL?
    /// Generation size in pixels (width, height), read from the installed model.
    @Published private(set) var imageSize: (width: Int, height: Int) = (768, 512)

    let variant = SceneModelStore.defaultVariant
    private var task: Task<Void, Never>?
    private let customFolderKey = "aiScene.customModelFolder"

    static var modelsRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "BetterBackground/Models", directoryHint: .isDirectory)
    }

    var installFolder: URL { Self.modelsRoot.appending(path: variant.id, directoryHint: .isDirectory) }

    var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    init() {
        refresh()
    }

    /// Looks for an installed model (a folder the user picked, or our own download).
    func refresh() {
        if let path = UserDefaults.standard.string(forKey: customFolderKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if Self.isComplete(url) { adopt(url); return }
        }
        if Self.isComplete(installFolder) { adopt(installFolder); return }
        modelFolder = nil
        if !isBusy { state = .notInstalled }
    }

    private func adopt(_ url: URL) {
        modelFolder = url
        if let size = Self.imageSize(of: url) { imageSize = size }
        state = .ready
    }

    static func isComplete(_ url: URL) -> Bool {
        let fm = FileManager.default
        let needed = ["TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "VAEEncoder.mlmodelc", "vocab.json", "merges.txt",
                      "controlnet/\(controlNetName).mlmodelc"]
        guard needed.allSatisfy({ fm.fileExists(atPath: url.appending(path: $0).path) }) else { return false }
        return fm.fileExists(atPath: url.appending(path: "ControlledUnet.mlmodelc").path)
            || fm.fileExists(atPath: url.appending(path: "ControlledUnetChunk1.mlmodelc").path)
    }

    // MARK: - Download

    func download() {
        guard !isBusy else { return }
        let variant = self.variant
        let folder = installFolder
        task = Task { [weak self] in
            do {
                try await self?.install(variant, into: folder)
                self?.refresh()
            } catch is CancellationError {
                self?.state = .notInstalled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .notInstalled
    }

    /// Lets the user point at a model folder they already have (any SD 1.5 "_cn" Core ML model
    /// with controlnet/Depth.mlmodelc inside).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Core ML Stable Diffusion folder with ControlledUnet.mlmodelc and controlnet/Depth.mlmodelc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Self.isComplete(url) {
            UserDefaults.standard.set(url.path, forKey: customFolderKey)
            adopt(url)
        } else {
            state = .failed("That folder is missing some model files (it needs ControlledUnet, TextEncoder, VAEEncoder, VAEDecoder, vocab.json, merges.txt and controlnet/Depth.mlmodelc).")
        }
    }

    func revealInFinder() {
        guard let modelFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([modelFolder])
    }

    /// Deletes our downloaded copy (never a folder the user picked).
    func deleteDownloadedModel() {
        try? FileManager.default.removeItem(at: installFolder)
        UserDefaults.standard.removeObject(forKey: customFolderKey)
        refresh()
    }

    private func install(_ variant: Variant, into folder: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)

        let free = (try? Self.modelsRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let needed: Int64 = 12_000_000_000
        if free < needed {
            throw Self.error("The AI scene model needs about 12 GB free while it installs (about 5 GB once installed). Only \(Self.bytes(free)) is free.")
        }

        let staging = Self.modelsRoot.appending(path: ".staging-\(variant.id)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 1. Base model.
        let baseZip = staging.appending(path: "base.zip")
        try await fetch(variant.baseURL, to: baseZip, label: "Downloading Stable Diffusion (1 of 2)")
        state = .installing("Unpacking Stable Diffusion…")
        let baseDir = staging.appending(path: "base", directoryHint: .isDirectory)
        try await Self.unzip(baseZip, to: baseDir)
        try? fm.removeItem(at: baseZip)
        guard let baseRoot = Self.findFolder(containing: "TextEncoder.mlmodelc", under: baseDir) else {
            throw Self.error("The downloaded model doesn't contain TextEncoder.mlmodelc.")
        }
        // The plain Unet is only used without ControlNet; drop it to save ~1.7 GB.
        try? fm.removeItem(at: baseRoot.appending(path: "Unet.mlmodelc"))
        try? fm.removeItem(at: baseRoot.appending(path: "UnetChunk1.mlmodelc"))
        try? fm.removeItem(at: baseRoot.appending(path: "UnetChunk2.mlmodelc"))
        try? fm.removeItem(at: baseRoot.appending(path: "SafetyChecker.mlmodelc"))
        try Task.checkCancellation()

        // 2. Depth ControlNet. The zip holds one model per resolution; keep the one matching the base.
        let cnZip = staging.appending(path: "depth.zip")
        try await fetch(variant.controlNetURL, to: cnZip, label: "Downloading Depth ControlNet (2 of 2)")
        state = .installing("Unpacking Depth ControlNet…")
        let cnDir = staging.appending(path: "controlnet", directoryHint: .isDirectory)
        try await Self.unzip(cnZip, to: cnDir)
        try? fm.removeItem(at: cnZip)

        let size = Self.imageSize(of: baseRoot) ?? (768, 512)
        let candidates = Self.findModels(under: cnDir)
        guard let match = Self.pickControlNet(candidates, width: size.width, height: size.height) else {
            throw Self.error("The Depth ControlNet download has no model for \(size.width) × \(size.height).")
        }
        let cnTarget = baseRoot.appending(path: "controlnet", directoryHint: .isDirectory)
        try fm.createDirectory(at: cnTarget, withIntermediateDirectories: true)
        try fm.moveItem(at: match, to: cnTarget.appending(path: "\(Self.controlNetName).mlmodelc"))

        guard Self.isComplete(baseRoot) else {
            throw Self.error("The downloaded model is missing files (needs ControlledUnet, VAEEncoder, VAEDecoder, TextEncoder, vocab.json and merges.txt).")
        }
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: baseRoot, to: folder)
    }

    /// Downloads with progress; resumes after dropped connections a few times.
    private func fetch(_ url: URL, to destination: URL, label: String) async throws {
        state = .downloading(label: label, fraction: 0, detail: "Starting…")
        var resumeData: Data?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            let downloader = Downloader()
            downloader.onProgress = { [weak self] written, total in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    let fraction = total > 0 ? Double(written) / Double(total) : 0
                    self.state = .downloading(label: label, fraction: fraction,
                                              detail: "\(Self.bytes(written)) of \(total > 0 ? Self.bytes(total) : "?")")
                }
            }
            do {
                let file = try await withTaskCancellationHandler {
                    try await downloader.run(url: url, resumeData: resumeData)
                } onCancel: {
                    downloader.cancel()
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                return
            } catch let error as URLError where attempt < 4 && error.code != .cancelled {
                resumeData = error.downloadTaskResumeData
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw Self.error("The download kept failing. Check your connection and try again.")
    }

    // MARK: - Files

    private static func unzip(_ zip: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, folder.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw SceneModelStore.error("Could not unpack \(zip.lastPathComponent).")
            }
        }.value
    }

    nonisolated static func findFolder(containing name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appending(path: name).path) { return root }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in e {
            if url.pathExtension == "mlmodelc" { e.skipDescendants(); continue }
            if fm.fileExists(atPath: url.appending(path: name).path) { return url }
        }
        return nil
    }

    nonisolated static func findModels(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "mlmodelc" {
            out.append(url)
            e.skipDescendants()
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The ControlNet whose image input is width x height; falls back to a name match.
    nonisolated static func pickControlNet(_ models: [URL], width: Int, height: Int) -> URL? {
        for m in models {
            if let shape = inputShape(of: m, named: "controlnet_cond"), shape.count >= 2,
               shape[shape.count - 1] == width, shape[shape.count - 2] == height {
                return m
            }
        }
        if let m = models.first(where: { $0.lastPathComponent.contains("\(width)x\(height)") }) { return m }
        return models.count == 1 ? models[0] : nil
    }

    /// Generation size from the Unet's latent input (8 pixels per latent cell).
    nonisolated static func imageSize(of folder: URL) -> (width: Int, height: Int)? {
        for name in ["ControlledUnet.mlmodelc", "ControlledUnetChunk1.mlmodelc", "Unet.mlmodelc"] {
            if let shape = inputShape(of: folder.appending(path: name), named: "sample"), shape.count == 4 {
                return (shape[3] * 8, shape[2] * 8)
            }
        }
        if let shape = inputShape(of: folder.appending(path: "VAEEncoder.mlmodelc"), named: nil), shape.count == 4 {
            return (shape[3], shape[2])
        }
        return nil
    }

    /// Reads an input's shape from a compiled model's metadata.json without loading the model.
    nonisolated static func inputShape(of model: URL, named name: String?) -> [Int]? {
        guard let data = try? Data(contentsOf: model.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]] = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { [$0] } ?? [])
        for entry in entries {
            guard let inputs = entry["inputSchema"] as? [[String: Any]] else { continue }
            for input in inputs where name == nil || (input["name"] as? String) == name {
                if let shape = input["shape"] as? String, let ints = parseInts(shape), !ints.isEmpty { return ints }
                if let shape = input["shape"] as? [Int] { return shape }
                if let type = input["formattedType"] as? String, let ints = parseInts(type), ints.count >= 2 {
                    // "MultiArray (Float16 2 × 4 × 64 × 96)": the dimensions are the last numbers.
                    return Array(ints.suffix(4))
                }
            }
        }
        return nil
    }

    nonisolated private static func parseInts(_ s: String) -> [Int]? {
        var out: [Int] = []
        var current = ""
        for ch in s {
            if ch.isNumber { current.append(ch) } else if !current.isEmpty { out.append(Int(current)!); current = "" }
        }
        if !current.isEmpty { out.append(Int(current)!) }
        return out.isEmpty ? nil : out
    }

    nonisolated static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "BetterBackground.AIScene", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// One URLSession download with progress callbacks.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()
    private var lastReport: TimeInterval = 0

    func run(url: URL, resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60 * 60 * 6
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastReport > 0.25 else { return }
        lastReport = now
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(SceneModelStore.error("The model server answered \(http.statusCode).")))
            return
        }
        // The temporary file is deleted when this method returns, so move it first.
        let keep = FileManager.default.temporaryDirectory.appending(path: "bb-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            finish(.success(keep))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
