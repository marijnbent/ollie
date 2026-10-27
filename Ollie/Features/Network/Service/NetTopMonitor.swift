import AppKit
import Foundation
import Darwin

@MainActor
public final class NetTopMonitor {
    public var onSample: (([AppUsage], Date, Date) -> Void)?
    public var onError: ((String) -> Void)?
    private var reader: Task<Void, Never>?
    private var lifetime: FileHandle?
    private var processExit: ProcessExit?
    private var knownProcesses: [Int32: (String, MonitoredApp)] = [:]
    private var knownPaths: [String: MonitoredApp] = [:]

    private enum Event: Sendable {
        case output(Data)
        case error(Data)
        case exit(Int32)
    }

    public init() {}

    deinit {
        reader?.cancel()
        try? lifetime?.close()
        processExit?.wait()
    }

    public func start() {
        stop()
        let process = Process()
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            onError?("Could not open the traffic collector’s output terminal.")
            return
        }
        var settings = termios()
        tcgetattr(slave, &settings)
        cfmakeraw(&settings)
        tcsetattr(slave, TCSANOW, &settings)
        let output = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let errors = Pipe()
        let lifetime = Pipe()
        let (events, continuation) = AsyncStream<Event>.makeStream()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let supervisor = """
        /usr/bin/nettop "$@" <&1 &
        collector=$!
        { read -r lifetime; kill -KILL "$collector" 2>/dev/null; } <&0 &
        watcher=$!
        trap 'kill -KILL "$collector" "$watcher" 2>/dev/null; wait "$collector" "$watcher" 2>/dev/null' EXIT
        trap 'exit' HUP INT TERM
        wait "$collector"
        """
        process.arguments = [
            "-c", supervisor, "ollie-nettop", "-P", "-d", "-L", "0", "-n", "-x",
            "-J", "bytes_in,bytes_out", "-s", "1", "-t", "external"
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        process.standardInput = lifetime.fileHandleForReading
        process.standardOutput = terminal
        process.standardError = errors
        output.readabilityHandler = { handle in
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 { continuation.yield(.output(Data(bytes.prefix(count)))) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { continuation.yield(.error(data)) }
        }
        do {
            let exit = try process.runObservingExit { process in
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }
            self.processExit = exit
            self.lifetime = lifetime.fileHandleForWriting
            try? terminal.close()
            try? lifetime.fileHandleForReading.close()
        } catch {
            output.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            onError?(error.localizedDescription)
            return
        }
        reader = Task { [weak self] in
            var decoder = NetTopDecoder()
            var previous: Date?
            var errorText = ""
            defer {
                output.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                try? lifetime.fileHandleForWriting.close()
                try? output.close()
            }
            do {
                for await event in events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .output(let data):
                        for frame in try decoder.append(data, at: Date()) {
                            let now = frame.date
                            let apps = self?.resolve(frame.rows) ?? []
                            if let previous, now.timeIntervalSince(previous) > 0.1, now.timeIntervalSince(previous) < 10 {
                                self?.onSample?(apps, previous, now)
                            }
                            previous = now
                        }
                    case .error(let data):
                        errorText = String((errorText + String(decoding: data, as: UTF8.self)).suffix(2000))
                    case .exit(let status):
                        throw MonitorError.stopped(errorText.isEmpty ? "nettop exited (\(status))." : errorText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            } catch {
                if !Task.isCancelled { self?.onError?(error.localizedDescription) }
            }
        }
    }

    public func stop() {
        reader?.cancel()
        reader = nil
        try? lifetime?.close()
        processExit?.wait()
        lifetime = nil
        processExit = nil
        knownProcesses = [:]
    }

    private func resolve(_ rows: [ProcessTraffic]) -> [AppUsage] {
        var totals: [String: AppUsage] = [:]
        var current: [Int32: (String, MonitoredApp)] = [:]
        for row in rows {
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(row.pid, &pathBuffer, UInt32(pathBuffer.count))
            let app: MonitoredApp
            if length > 0 {
                let path = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                app = identify(path: path, fallback: row.name)
            } else if let known = knownProcesses[row.pid], known.0 == row.name {
                app = known.1
            } else {
                app = MonitoredApp(id: "process:\(row.name)", name: row.name, path: "")
            }
            current[row.pid] = (row.name, app)
            let traffic = (totals[app.id]?.traffic ?? Traffic()) + row.traffic
            totals[app.id] = AppUsage(app: app, traffic: traffic)
        }
        knownProcesses = current
        return Array(totals.values)
    }

    private func identify(path: String, fallback: String) -> MonitoredApp {
        if let known = knownPaths[path] { return known }
        let app: MonitoredApp
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.lowerBound]) + ".app"
            let bundle = Bundle(path: appPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            app = MonitoredApp(id: bundle?.bundleIdentifier.map { "bundle:\($0)" } ?? "path:\(appPath)", name: name, path: appPath)
        } else {
            app = MonitoredApp(id: "path:\(path)", name: fallback, path: path)
        }
        if knownPaths.count > 4096 { knownPaths.removeAll() }
        knownPaths[path] = app
        return app
    }
}
