import Foundation

/// Shared cache for resolved ffmpeg / ffprobe paths.
/// Kept in its own file so tool lookup keeps compiling even if TagService
/// is mid-merge or partially synced.
enum ToolPathCache {
    private static let lock = NSLock()
    private static var _ffmpeg: String?
    private static var _ffprobe: String?

    static var ffmpeg: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _ffmpeg
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _ffmpeg = newValue
        }
    }

    static var ffprobe: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _ffprobe
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _ffprobe = newValue
        }
    }
}
