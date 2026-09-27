//
//  ConsoleMirror.swift
//  leanring-buddy
//
//  Mirrors everything the app prints to ~/Library/Logs/Sounder/console.log while
//  still showing it in Xcode's console. Lets the log be read without Xcode
//  (for support and for the demo's "what left the machine" slide).
//

import Foundation

enum ConsoleMirror {
    static let logFileURL: URL = {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sounder", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appendingPathComponent("console.log")
    }()

    private static var pipe: Pipe?
    private static var originalStandardOutput: Int32 = -1

    /// Redirects stdout through a pipe; a background reader writes each chunk to
    /// both the original stdout (Xcode console) and the log file.
    static func start() {
        guard pipe == nil else { return }
        // Line-buffer stdout so prints arrive promptly even when not attached to a terminal.
        setvbuf(stdout, nil, _IOLBF, 0)

        let mirrorPipe = Pipe()
        originalStandardOutput = dup(STDOUT_FILENO)
        dup2(mirrorPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(mirrorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        pipe = mirrorPipe

        let logFileURL = Self.logFileURL
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logFileURL)
        logHandle?.seekToEndOfFile()
        let header = "\n===== Sounder launched \(Date()) =====\n".data(using: .utf8)!
        logHandle?.write(header)

        let savedStandardOutput = originalStandardOutput
        mirrorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            chunk.withUnsafeBytes { buffer in
                _ = write(savedStandardOutput, buffer.baseAddress, buffer.count)
            }
            logHandle?.write(chunk)
        }
    }
}
