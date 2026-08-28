//
//  Diagnostics.swift
//
//  We have no Xcode Organizer, no TestFlight crash logs, and no debugger on
//  the device. If the app dies, the only evidence that will ever exist is what
//  we wrote to disk ourselves before it went down.
//
//  Two files live in Documents/ (visible in the Files app because Info.plist
//  sets UIFileSharingEnabled):
//
//      session.log   — the run happening right now
//      previous.log  — the run before it
//
//  The rotation is the point. When a build crashes you relaunch it, and the
//  crash you care about is sitting in previous.log rather than being
//  overwritten by the run you just started.
//

import Foundation
import Darwin
import UIKit

// Raw file descriptor for the crash path. A signal handler may not allocate,
// take locks, or call into Foundation, so it cannot use FileHandle — it needs
// a descriptor that was already open before anything went wrong.
private nonisolated(unsafe) var crashFD: Int32 = -1

private func writeStatic(_ fd: Int32, _ text: StaticString) {
    // StaticString points at storage baked into the binary, so handing it to
    // write(2) allocates nothing and is safe in a signal handler.
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

private func signalName(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGSEGV: return "SIGSEGV (bad memory access)"
    case SIGABRT: return "SIGABRT (abort — often a failed assertion or uncaught C++ exception)"
    case SIGBUS:  return "SIGBUS (misaligned or invalid address)"
    case SIGILL:  return "SIGILL (illegal instruction)"
    case SIGFPE:  return "SIGFPE (arithmetic fault)"
    case SIGTRAP: return "SIGTRAP (trap — often a Swift runtime precondition failure)"
    default:      return "unknown signal"
    }
}

private let fatalSignalHandler: @convention(c) (Int32) -> Void = { sig in
    if crashFD >= 0 {
        writeStatic(crashFD, "\n=== FATAL SIGNAL: ")
        writeStatic(crashFD, signalName(sig))
        writeStatic(crashFD, " ===\n")

        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let count = frames.withUnsafeMutableBufferPointer { buffer in
            backtrace(buffer.baseAddress, Int32(buffer.count))
        }
        frames.withUnsafeMutableBufferPointer { buffer in
            // backtrace_symbols_fd writes straight to the descriptor without
            // allocating, which is why it is the only symbolisation call
            // usable from here.
            backtrace_symbols_fd(buffer.baseAddress, count, crashFD)
        }
        fsync(crashFD)
    }

    // Restore the default action and re-raise, so the OS still records the
    // crash normally rather than us swallowing it.
    signal(sig, SIG_DFL)
    raise(sig)
}

enum Diagnostics {

    private static let ioQueue = DispatchQueue(label: "com.mangachan.diagnostics")
    private static var handle: FileHandle?

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var currentLogURL: URL { documentsURL.appendingPathComponent("session.log") }
    static var previousLogURL: URL { documentsURL.appendingPathComponent("previous.log") }

    /// Call once, as early in launch as possible — before Metal setup, so that
    /// a failure inside renderer initialisation still lands in the log.
    static func bootstrap() {
        rotateLogs()
        openLog()
        installHandlers()
        writeHeader()
    }

    private static func rotateLogs() {
        let fm = FileManager.default
        try? fm.removeItem(at: previousLogURL)
        if fm.fileExists(atPath: currentLogURL.path) {
            try? fm.moveItem(at: currentLogURL, to: previousLogURL)
        }
    }

    private static func openLog() {
        let fm = FileManager.default
        fm.createFile(atPath: currentLogURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: currentLogURL)

        // Keep an independent descriptor for the signal handler. It must not
        // share state with FileHandle, whose internals are not signal-safe.
        crashFD = open(currentLogURL.path, O_WRONLY | O_APPEND)
    }

    private static func installHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            Diagnostics.log("=== UNCAUGHT EXCEPTION ===")
            Diagnostics.log("name: \(exception.name.rawValue)")
            Diagnostics.log("reason: \(exception.reason ?? "none")")
            for frame in exception.callStackSymbols {
                Diagnostics.log("  \(frame)")
            }
            Diagnostics.flush()
        }

        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, fatalSignalHandler)
        }
    }

    private static func writeHeader() {
        let device = UIDevice.current
        log("Manga-Chan starting")
        log("build: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")"
            + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        log("device: \(device.model), \(device.systemName) \(device.systemVersion)")
        log("engine: \(String(cString: core_build_info()))")
        log("processors: \(ProcessInfo.processInfo.processorCount)")
        log("physical memory: \(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)) MB")
        log("log file: \(currentLogURL.path)")
    }

    static func log(_ message: String) {
        let stamp = Self.timestampFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        // Also goes to the console, which is useful in the Simulator on CI.
        print(line, terminator: "")
        ioQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            handle?.write(data)
        }
    }

    static func flush() {
        ioQueue.sync {
            try? handle?.synchronize()
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
