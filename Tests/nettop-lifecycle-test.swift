import Darwin
import Foundation

@main
@MainActor
struct NetTopLifecycleTests {
    static func main() async throws {
        if CommandLine.arguments.count == 2 {
            let monitor = NetTopMonitor()
            monitor.onSample = { _, _, _ in
                FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: Data())
            }
            monitor.start()
            try await Task.sleep(for: .seconds(30))
            monitor.stop()
            return
        }
        try await stopAndRestart()
        try await releaseOwner()
        try await parentExit()
        print("PASS  network collector lifecycle")
    }

    private static func stopAndRestart() async throws {
        let monitor = NetTopMonitor()
        defer { monitor.stop() }
        var sampled = false
        var error: String?
        monitor.onSample = { _, _, _ in sampled = true }
        monitor.onError = { error = $0 }
        monitor.start()
        try await wait { sampled || error != nil }
        guard error == nil else { throw MonitorError.stopped(error!) }
        for _ in 0..<3 {
            let supervisor = try onlyChild(of: getpid())
            let descendants = try children(of: supervisor)
            monitor.start()
            try require(!exists(supervisor) && descendants.allSatisfy { !exists($0) }, "Restart left a collector running")
            try await wait { try !children(of: try onlyChild(of: getpid()), named: "nettop").isEmpty }
        }
        let supervisor = try onlyChild(of: getpid())
        let collector = try onlyChild(of: supervisor, named: "nettop")
        kill(collector, SIGKILL)
        try await wait { error != nil }
        monitor.stop()
        try require(!exists(supervisor) && !exists(collector), "Stop did not reap the collector")
        print("PASS  live samples, repeated restart, collector failure and synchronous stop")
    }

    private static func releaseOwner() async throws {
        var sampled = false
        var monitor: NetTopMonitor? = NetTopMonitor()
        monitor?.onSample = { _, _, _ in sampled = true }
        monitor?.start()
        try await wait { sampled }
        let supervisor = try onlyChild(of: getpid())
        let descendants = try children(of: supervisor)
        monitor = nil
        try require(!exists(supervisor) && descendants.allSatisfy { !exists($0) }, "Deinitializing left a collector running")
        print("PASS  releasing the monitor reaps its processes")
    }

    private static func parentExit() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        owner.arguments = [marker.path]
        let exit = try owner.runObservingExit()
        defer {
            if owner.isRunning { kill(owner.processIdentifier, SIGKILL) }
            exit.wait()
        }
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let supervisor = try onlyChild(of: owner.processIdentifier)
        let descendants = try children(of: supervisor)
        kill(owner.processIdentifier, SIGKILL)
        exit.wait()
        try await wait { !exists(supervisor) && descendants.allSatisfy { !exists($0) } }
        print("PASS  killing the owner also removes its supervisor and collector")
    }

    private static func children(of parent: Int32, named name: String? = nil) throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)] + (name.map { ["-x", $0] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        let exit = try process.runObservingExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exit.wait()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { Int32($0) }
            .filter { $0 != process.processIdentifier }
    }

    private static func onlyChild(of parent: Int32, named name: String? = nil) throws -> Int32 {
        let children = try children(of: parent, named: name)
        try require(children.count == 1, "Expected one child of \(parent), found \(children)")
        return children[0]
    }

    private static func exists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private static func wait(_ ready: () throws -> Bool) async throws {
        for _ in 0..<400 {
            if try ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MonitorError.stopped("Timed out waiting for collector lifecycle")
    }

    private static func require(_ passed: Bool, _ message: String) throws {
        if !passed { throw MonitorError.stopped(message) }
    }
}
