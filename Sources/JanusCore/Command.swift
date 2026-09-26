import Foundation

/// Runs a command line tool and collects what it said.
///
/// A GUI app launched from Finder inherits a bare `PATH`, so everything here is
/// invoked by absolute path and nothing is resolved through a shell.
public enum Command {

    public struct Result {
        public let status: Int32
        public let output: String
        public var succeeded: Bool { status == 0 }
    }

    /// - Parameter input: fed to the tool's standard input and then closed.
    ///   Used for secrets, which have no business being on a command line where
    ///   `ps` shows them to every process on the Mac.
    @discardableResult
    public static func run(_ tool: String,
                           _ arguments: [String],
                           input: Data? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        try process.run()

        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }

        // Drained before waiting: a full pipe stalls a process still writing to it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }
}

/// How much room something takes up.
public enum DiskUsage {

    /// Size of a directory tree in bytes, or zero if it is not there.
    ///
    /// Uses `du` rather than walking the tree in Foundation: these directories run
    /// to hundreds of thousands of small files, and the difference is the
    /// difference between a menu that opens and one that hangs.
    public static func bytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        guard let result = try? Command.run("/usr/bin/du", ["-sk", url.path]),
              result.succeeded
        else { return 0 }
        return kilobytes(fromDuOutput: result.output) * 1024
    }

    /// `du -sk` answers with "<size><tab><path>", and the size is in kilobytes.
    static func kilobytes(fromDuOutput output: String) -> Int64 {
        let firstLine = output.split(separator: "\n").first ?? ""
        let field = firstLine.split(separator: "\t").first ?? ""
        return Int64(field.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    public static func describe(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
