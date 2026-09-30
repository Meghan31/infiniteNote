import Foundation

// MARK: - Library Backup: file container
//
// The `.infinitenote` file layout — plain Foundation, streamed one entry at a
// time so a big library never has to fit in memory:
//
//     "INOTEBK1"                      8-byte magic
//     UInt32 LE  manifest length      followed by the manifest JSON
//     repeated:  UInt16 LE path length, path (UTF-8),
//                UInt64 LE data length, data
//     UInt16 LE  0                    end marker — missing = truncated file
//
// Readers only ever write entries the manifest references (paths validated in
// BackupManifest.validatedFilePaths), so a hostile file can't write elsewhere.

enum BackupContainer {
    static let fileExtension = "infinitenote"
    static let magic = Data("INOTEBK1".utf8)

    private static let maxManifestBytes = 256 * 1024 * 1024
    private static let maxPathBytes = 1024
    private static let maxEntryBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private static let chunkBytes = 4 * 1024 * 1024

    // MARK: Write

    static func write(manifestJSON: Data, files: [(path: String, source: URL)], to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard manifestJSON.count <= maxManifestBytes,
              fm.createFile(atPath: destination.path, contents: nil) else { throw BackupError.writeFailed }

        let handle = try FileHandle(forWritingTo: destination)
        var isClosed = false
        defer { if !isClosed { try? handle.close() } }

        try handle.write(contentsOf: magic)
        try handle.write(contentsOf: littleEndian(UInt32(manifestJSON.count)))
        try handle.write(contentsOf: manifestJSON)

        for file in files {
            let pathData = Data(file.path.utf8)
            guard !pathData.isEmpty, pathData.count <= maxPathBytes else { throw BackupError.writeFailed }
            try autoreleasepool {
                let data = try Data(contentsOf: file.source, options: .mappedIfSafe)
                try handle.write(contentsOf: littleEndian(UInt16(pathData.count)))
                try handle.write(contentsOf: pathData)
                try handle.write(contentsOf: littleEndian(UInt64(data.count)))
                try handle.write(contentsOf: data)
            }
        }
        try handle.write(contentsOf: littleEndian(UInt16(0)))   // end marker
        try handle.synchronize()
        try handle.close()
        isClosed = true
    }

    // MARK: Read

    /// Reads the manifest, hands it to `wantedPaths` (which decodes + validates
    /// it and returns the container paths it references), then streams each
    /// referenced entry into `root/<path>`. Unreferenced entries are skipped.
    /// Throws if the file isn't a backup, is truncated, or lacks a referenced file.
    @discardableResult
    static func extract(
        from source: URL,
        into root: URL,
        wantedPaths: (Data) throws -> Set<String>
    ) throws -> Data {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }

        let head = try? read(handle, exactly: magic.count)
        guard let head, head == magic else { throw BackupError.notABackup }

        let manifestLength = Int(try readUInt32(handle))
        guard manifestLength > 0, manifestLength <= maxManifestBytes else {
            throw BackupError.damaged("bad manifest size")
        }
        guard let manifestJSON = try read(handle, exactly: manifestLength) else { throw BackupError.incomplete }

        var remaining = try wantedPaths(manifestJSON)
        let fm = FileManager.default

        while true {
            let pathLength = Int(try readUInt16(handle))
            if pathLength == 0 { break }   // end marker
            guard pathLength <= maxPathBytes,
                  let pathData = try read(handle, exactly: pathLength),
                  let path = String(data: pathData, encoding: .utf8) else {
                throw BackupError.damaged("bad entry")
            }
            let dataLength = try readUInt64(handle)
            guard dataLength <= maxEntryBytes else { throw BackupError.damaged("entry too large") }

            if remaining.remove(path) != nil {
                let destination = root.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try copy(from: handle, byteCount: dataLength, to: destination)
            } else {
                try handle.seek(toOffset: try handle.offset() + dataLength)
            }
        }
        guard remaining.isEmpty else { throw BackupError.incomplete }
        return manifestJSON
    }

    // MARK: Helpers

    private static func copy(from handle: FileHandle, byteCount: UInt64, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw BackupError.writeFailed }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var remaining = byteCount
        while remaining > 0 {
            try autoreleasepool {
                let size = Int(min(remaining, UInt64(chunkBytes)))
                guard let chunk = try handle.read(upToCount: size), !chunk.isEmpty else {
                    throw BackupError.incomplete
                }
                try output.write(contentsOf: chunk)
                remaining -= UInt64(chunk.count)
            }
        }
    }

    /// Reads exactly `count` bytes. Returns nil only when the file ends before
    /// ANY byte could be read; a partial read throws `.incomplete`.
    private static func read(_ handle: FileHandle, exactly count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let wanted = min(count - buffer.count, chunkBytes)
            guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        if buffer.isEmpty { return nil }
        guard buffer.count == count else { throw BackupError.incomplete }
        return buffer
    }

    private static func readUInt16(_ handle: FileHandle) throws -> UInt16 {
        UInt16(truncatingIfNeeded: try readInteger(handle, byteCount: 2))
    }

    private static func readUInt32(_ handle: FileHandle) throws -> UInt32 {
        UInt32(truncatingIfNeeded: try readInteger(handle, byteCount: 4))
    }

    private static func readUInt64(_ handle: FileHandle) throws -> UInt64 {
        try readInteger(handle, byteCount: 8)
    }

    /// Little-endian unsigned integer of `byteCount` bytes.
    private static func readInteger(_ handle: FileHandle, byteCount: Int) throws -> UInt64 {
        guard let bytes = try read(handle, exactly: byteCount) else { throw BackupError.incomplete }
        var value: UInt64 = 0
        for (shift, byte) in bytes.enumerated() {
            value |= UInt64(byte) << (8 * UInt64(shift))
        }
        return value
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
