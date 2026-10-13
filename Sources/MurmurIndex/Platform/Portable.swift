// What every platform shares of the platform layer: the shapes the engine asks for, and where Murmur keeps its files.
// Platform/Apple and Platform/Portable implement the same names.
import Foundation

/// A file's own facts, as the crawl records them (`FileSystem.info`).
struct FileInfo {
    let isRegular: Bool   // not a link, device or socket
    let size: Int64
    let mtime: Double     // seconds since 1970, with the fraction the file system keeps
    let inode: UInt64
    let device: UInt64
    /// A cloud placeholder whose contents would be downloaded on read (never read).
    let dataless: Bool
}

#if !canImport(Darwin)
/// Darwin's `autoreleasepool`: elsewhere there's no Objective-C runtime and nothing to drain, so the body just runs.
@discardableResult
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

/// Where Murmur keeps its own files on each OS: the model and the index.
public enum AppPaths {
    /// macOS: ~/Library/Application Support/Murmur. Windows: %LOCALAPPDATA%\Murmur. Linux: $XDG_DATA_HOME/murmur-engine, or
    /// ~/.local/share/murmur.
    public static var applicationSupport: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Murmur")
        #elseif os(Windows)
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local).appendingPathComponent("Murmur")
        }
        return home.appendingPathComponent("AppData/Local/Murmur")
        #else
        if let data = environment["XDG_DATA_HOME"], !data.isEmpty {
            return URL(fileURLWithPath: data).appendingPathComponent("murmur")
        }
        return home.appendingPathComponent(".local/share/murmur")
        #endif
    }

    /// The default index folder (".noindex" keeps Spotlight out of it on a Mac).
    public static var defaultIndex: URL {
        #if os(macOS)
        return applicationSupport.appendingPathComponent("index.noindex")
        #else
        return applicationSupport.appendingPathComponent("index")
        #endif
    }
}
