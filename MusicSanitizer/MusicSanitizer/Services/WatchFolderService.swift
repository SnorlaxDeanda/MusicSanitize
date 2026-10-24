import Foundation
import AppKit
import UserNotifications

// MARK: - Watch Folder State (shared singleton)

@MainActor
class WatchFolderState: ObservableObject {
    static let shared = WatchFolderState()

    @Published var isEnabled       = false
    @Published var watchURL: URL?
    @Published var autoFix         = true
    @Published var sendNotifications = true
    @Published var processedCount  = 0

    private var watcher: WatchFolderService?
    private var settings: ScanSettings?

    func chooseFolder(settings: ScanSettings) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch This Folder"
        panel.message = "Choose a folder to monitor for new music files"

        // Defer @Published mutations until after the panel's dismissal
        // finishes its SwiftUI view update (same race as AppState folder pick).
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchURL = url
            self.settings = settings
            if self.isEnabled { self.start(url: url, settings: settings) }
        }
    }

    func start(url: URL, settings: ScanSettings) {
        self.settings = settings
        watcher?.stop()
        let w = WatchFolderService(
            url: url,
            settings: settings,
            autoFix: autoFix,
            notify: sendNotifications
        ) { [weak self] count in
            Task { @MainActor [weak self] in
                self?.processedCount += count
            }
        }
        watcher = w
        w.start()
        requestNotificationPermission()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Watch Folder Service (FSEvents-based)

class WatchFolderService {
    private let url: URL
    private let settings: ScanSettings
    private let autoFix: Bool
    private let notify: Bool
    private let onProcessed: (Int) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.musicsanitizer.watchfolder", qos: .utility)
    private var pendingURLs: Set<URL> = []
    private var debounceTimer: Timer?

    private let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "aac", "aiff", "aif", "wav", "ogg", "wma"]

    init(url: URL, settings: ScanSettings, autoFix: Bool, notify: Bool, onProcessed: @escaping (Int) -> Void) {
        self.url = url
        self.settings = settings
        self.autoFix = autoFix
        self.notify = notify
        self.onProcessed = onProcessed
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo else { return }
            let service = Unmanaged<WatchFolderService>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            service.handleEvents(paths: Array(paths.prefix(numEvents)))
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,          // latency in seconds
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )

        if let stream = stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handleEvents(paths: [String]) {
        let newAudioFiles = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !newAudioFiles.isEmpty else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            newAudioFiles.forEach { self.pendingURLs.insert($0) }

            // Debounce — wait for file copy to finish (1.5s after last event)
            DispatchQueue.main.async {
                self.debounceTimer?.invalidate()
                self.debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                    self.processPending()
                }
            }
        }
    }

    private func processPending() {
        let toProcess = pendingURLs
        pendingURLs.removeAll()

        Task {
            let tagService = TagService()
            var processed = 0

            for fileURL in toProcess {
                // Short delay to ensure file is fully written
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard let (tags, duration, fileSize) = try? await tagService.readTags(from: fileURL) else { continue }
                let format = AudioFormat.from(extension: fileURL.pathExtension)
                let file = AudioFile(url: fileURL, tags: tags, format: format,
                                     fileSize: fileSize, duration: duration)

                if autoFix {
                    let fixService = FixService(settings: settings)
                    _ = try? await fixService.applyFixes(
                        to: [file], root: fileURL.deletingLastPathComponent()
                    ) { _, _ in }
                    processed += 1
                }
            }

            if processed > 0 {
                onProcessed(processed)
                if notify { sendNotification(count: processed) }
            }
        }
    }

    private func sendNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Music Sanitizer"
        content.body = "Processed \(count) new file\(count == 1 ? "" : "s")"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    deinit { stop() }
}
