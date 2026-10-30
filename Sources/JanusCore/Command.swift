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
