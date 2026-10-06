import Foundation

// The native app owns its backend so Finder/Dock events reach AppKit directly.
final class Backend {
    let process = Process()
    let commands = Pipe()
    let events = Pipe()
    func start() throws {
        process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("translator-server")
        process.arguments = ["--native-hosted"]
        process.standardOutput = commands
        process.standardInput = events
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func send(_ data: Data) {
        try? events.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }
    func stop() {
        try? events.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
var backend: Backend?
