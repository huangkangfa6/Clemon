import AppKit
import SwiftUI
import Darwin

let appName = "极简状态"
let gib = 1_073_741_824.0
let machTickToNanoseconds: Double = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
    return Double(info.numer) / Double(info.denom)
}()

func sizeText(_ bytes: UInt64) -> String {
    let n = Double(bytes)
    if n >= gib { return String(format: "%.1f GB", n / gib) }
    if n >= 1_048_576 { return String(format: "%.1f MB", n / 1_048_576) }
    if n >= 1024 { return String(format: "%.0f KB", n / 1024) }
    return "\(bytes) B"
}

func speedText(_ bytes: Double, compact: Bool = false) -> String {
    let n = bytes.isFinite ? max(0, bytes) : 0
    if compact {
        let value: Double
        let unit: String
        if n >= 999.5 * 1_048_576 { value = n / gib; unit = "G" }
        else if n >= 999.5 * 1024 { value = n / 1_048_576; unit = "M" }
        else { value = n / 1024; unit = "K" }
        if value >= 999.5 { return "999+" }
        return value >= 10 || unit == "K" ? String(format: "%.0f%@", value, unit) : String(format: "%.1f%@", value, unit)
    }
    if n >= 1_048_576 { return String(format: "%.2f MB/s", n / 1_048_576) }
    return String(format: "%.0f KB/s", n / 1024)
}

struct Reading: Sendable {
    var cpu: Double = 0
    var usedMemory: UInt64 = 0
    var totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    var upload: Double = 0
    var download: Double = 0
    var swap: UInt64 = 0
    var ready = false
    var memoryOK = false
    var cpuOK = false
    var memoryPercent: Double { totalMemory > 0 ? Double(usedMemory) / Double(totalMemory) * 100 : 0 }
}

func menuTitle(_ reading: Reading, compact: Bool) -> String {
    let cpu = reading.cpuOK ? String(format: "%.0f%%", reading.cpu) : "—"
    let memory = reading.memoryOK ? String(format: "%.0f%%", reading.memoryPercent) : "—"
    let upload = reading.ready ? speedText(reading.upload, compact: true) : "—"
    let download = reading.ready ? speedText(reading.download, compact: true) : "—"
    return compact ? "C\(cpu) M\(memory) ↑\(upload) ↓\(download)" : "CPU\(cpu) 内存\(memory) ↑\(upload) ↓\(download)"
}

struct NetworkCount: Sendable {
    var sent: UInt64
    var received: UInt64
}

func networkRate(current: [String: NetworkCount], previous: [String: NetworkCount], elapsed: Double) -> (Double, Double) {
    guard elapsed > 0 && elapsed.isFinite else { return (0, 0) }
    var up = 0.0, down = 0.0
    for (name, value) in current {
        guard let before = previous[name] else { continue }
        if value.sent >= before.sent { up += Double(value.sent - before.sent) / elapsed }
        if value.received >= before.received { down += Double(value.received - before.received) / elapsed }
    }
    return (up, down)
}

struct ProcessSnapshot: Sendable {
    var parent: Int32
    var time: UInt64
    var memory: UInt64
    var started: UInt64
}

struct AppUsage: Identifiable, Sendable {
    let id: String
    let pid: Int32
    let started: UInt64
    let name: String
    var cpu: Double
    var memory: UInt64
    @MainActor var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }
}

func processStart(_ pid: Int32) -> UInt64? {
    var bsd = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
    return bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec
}

@MainActor func applicationForQuit(_ usage: AppUsage) -> NSRunningApplication? {
    guard usage.pid != getpid(), processStart(usage.pid) == usage.started,
          let app = NSRunningApplication(processIdentifier: usage.pid), !app.isTerminated,
          app.activationPolicy == .regular, app.bundleIdentifier != "com.apple.finder" else { return nil }
    return app
}

final class Sampler {
    private var previousTicks: [UInt64]?
    private var previousNetwork: [String: NetworkCount] = [:]
    private var previousProcesses: [Int32: ProcessSnapshot] = [:]
    private var previousTime: Double?
    private let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
    private var lastCPU: Double?
    private let pageSize = UInt64(max(1, sysconf(_SC_PAGESIZE)))

    func sample(includeApps: Bool = false) -> (Reading, [AppUsage]) {
        var result = Reading()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        var cpuInfo = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuReturn = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuReturn == KERN_SUCCESS {
            let ticks = [UInt64(cpuInfo.cpu_ticks.0), UInt64(cpuInfo.cpu_ticks.1), UInt64(cpuInfo.cpu_ticks.2), UInt64(cpuInfo.cpu_ticks.3)]
            if let before = previousTicks {
                let delta = zip(ticks, before).map { ($0 &- $1) & 0xffff_ffff }
                let all = delta.reduce(0, +)
                if all > 0 { lastCPU = Double(all - delta[2]) / Double(all) * 100 }
                if let cpu = lastCPU { result.cpu = cpu; result.cpuOK = true }
            }
            previousTicks = ticks
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmReturn = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmReturn == KERN_SUCCESS {
            // Activity Monitor-style used memory: exclude file cache and purgeable pages.
            let occupied = Int64(vm.active_count) + Int64(vm.inactive_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count)
            let reusable = Int64(vm.external_page_count) + Int64(vm.purgeable_count)
            result.usedMemory = min(result.totalMemory, UInt64(max(0, occupied - reusable)) * pageSize)
            result.memoryOK = true
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { result.swap = swap.xsu_used }

        let network = networkCounts()
        (result.upload, result.download) = networkRate(current: network, previous: previousNetwork, elapsed: elapsed)
        previousNetwork = network
        previousTime = now
        result.ready = elapsed > 0 && result.cpuOK && result.memoryOK

        var apps: [AppUsage] = []
        if includeApps {
            let snapshots = processSnapshots()
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != "com.apple.finder" && !$0.isTerminated
            }
            let appIDs = Set(running.map(\.processIdentifier))
            var totals: [Int32: (UInt64, Double)] = [:]
            for (pid, process) in snapshots {
                var current = pid
                var visited = Set<Int32>()
                while current > 1 && !appIDs.contains(current) && !visited.contains(current) {
                    visited.insert(current)
                    current = snapshots[current]?.parent ?? 0
                }
                guard appIDs.contains(current) else { continue }
                var cpu = 0.0
                if elapsed > 0, let before = previousProcesses[pid], before.started == process.started, process.time >= before.time {
                    cpu = Double(process.time - before.time) * machTickToNanoseconds / 1_000_000_000 / elapsed / Double(coreCount) * 100
                }
                let old = totals[current] ?? (0, 0)
                totals[current] = (old.0 + process.memory, old.1 + cpu)
            }
            apps = running.map { app in
                let value = totals[app.processIdentifier] ?? (0, 0)
                let identity = "\(app.processIdentifier)-\(snapshots[app.processIdentifier]?.started ?? 0)"
                return AppUsage(id: identity, pid: app.processIdentifier, started: snapshots[app.processIdentifier]?.started ?? 0, name: app.localizedName ?? "应用", cpu: min(100, value.1), memory: value.0)
            }
            previousProcesses = snapshots
        } else {
            previousProcesses = [:]
        }
        return (result, apps)
    }

    private func networkCounts() -> [String: NetworkCount] {
        // IFLIST2 exposes 64-bit counters; getifaddrs uses counters that can wrap at 4 GB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        let success = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &length, nil, 0) }
        guard success == 0 else { return [:] }
        var counts: [String: NetworkCount] = [:]
        var names: [UInt32: String] = [:]
        if let first = if_nameindex() {
            defer { if_freenameindex(first) }
            var cursor = first
            while cursor.pointee.if_index != 0 {
                if let name = cursor.pointee.if_name { names[cursor.pointee.if_index] = String(cString: name) }
                cursor = cursor.advanced(by: 1)
            }
        }
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + 4 <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= 4, offset + messageLength <= length else { break }
                let type = raw[offset + 3]
                if type == RTM_IFINFO2, messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = names[UInt32(info.ifm_index)] {
                        if name.hasPrefix("en"), (info.ifm_flags & IFF_UP) != 0 {
                            counts[name] = NetworkCount(sent: info.ifm_data.ifi_obytes, received: info.ifm_data.ifi_ibytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return counts
    }

    private func processSnapshots() -> [Int32: ProcessSnapshot] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, capacity) }
        guard count > 0 else { return [:] }
        var result: [Int32: ProcessSnapshot] = [:]
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            result[pid] = ProcessSnapshot(parent: Int32(bsd.pbi_ppid), time: hasTask ? task.pti_total_user + task.pti_total_system : 0, memory: hasTask ? task.pti_resident_size : 0, started: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
        }
        return result
    }
}

enum JunkCategory: String, CaseIterable, Sendable {
    case cache = "应用缓存", logs = "旧日志", build = "构建缓存", installers = "旧安装包", large = "下载大文件"
    case orphan = "应用残留候选", startup = "失效启动项", receipt = "安装记录 · 仅查看"
}

struct ScanRoot: Sendable {
    let url: URL
    let name: String
    let category: JunkCategory
    var owner: String? = nil
    var allowedNames: Set<String> = []
}

struct CacheFile: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let relativePath: String
    let size: UInt64
    let modified: Date
    let scope: ScanRoot
    let includeRecent: Bool
    var isSelectable: Bool { scope.category != .receipt }
}

struct CacheScan: Sendable {
    var files: [CacheFile] = []
    var skipped = 0
    var limited = false
    var examined = 0
    var candidateCount = 0
    var candidateBytes: UInt64 = 0
}

struct FileGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let files: [CacheFile]
}

func fileGroups(_ files: [CacheFile]) -> [FileGroup] {
    var grouped: [String: [CacheFile]] = [:]
    for file in files {
        var title = file.scope.name
        let relative = String(file.url.path.dropFirst(file.scope.url.path.count + 1))
        let parts = relative.split(separator: "/")
        if file.scope.url == CacheScanner.root || file.scope.name == "用户日志" {
            if parts.count > 1 { title += " / " + parts[0] }
        }
        grouped[title, default: []].append(file)
    }
    return grouped.map { FileGroup(id: "folder:" + ($0.value.first?.scope.category.rawValue ?? "") + ":" + $0.key, title: $0.key, files: $0.value) }.sorted {
        $0.files.reduce(0) { $0 + $1.size } > $1.files.reduce(0) { $0 + $1.size }
    }
}

enum CacheScanner {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    static let minimumAge: TimeInterval = 14 * 86400
    static let maxFiles = 800

    static func validForTrash(_ file: CacheFile, runningIDs: [String], now: Date = Date()) -> Bool {
        guard file.isSelectable, let fresh = eligible(file.url, runningIDs: runningIDs, now: now, scope: file.scope, includeRecent: file.includeRecent, revalidateApplication: true),
              FileManager.default.isWritableFile(atPath: file.url.deletingLastPathComponent().path) else { return false }
        return fresh.modified == file.modified && fresh.size == file.size
    }

    static func roots() -> [ScanRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let manager = FileManager.default
        var paths = [ScanRoot(url: root, name: "用户缓存", category: .cache),
                     ScanRoot(url: home.appendingPathComponent("Library/Logs"), name: "用户日志", category: .logs),
                     ScanRoot(url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), name: "Xcode DerivedData", category: .build, owner: "com.apple.dt.Xcode"),
                     ScanRoot(url: home.appendingPathComponent("Downloads"), name: "下载", category: .installers),
                     ScanRoot(url: home.appendingPathComponent("Downloads"), name: "下载", category: .large),
                     ScanRoot(url: home.appendingPathComponent("Library/LaunchAgents"), name: "用户登录启动项", category: .startup),
                     ScanRoot(url: URL(fileURLWithPath: "/private/var/db/receipts"), name: "系统安装记录", category: .receipt)]
        var installed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for folder in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            if let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
                var examined = 0
                for case let url as URL in walker {
                    examined += 1
                    if examined > 10000 { break }
                    if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { installed.insert(id); walker.skipDescendants() }
                }
            }
        }
        func missingNames(at directory: URL, preferences: Bool) -> Set<String> {
            let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return Set(entries.compactMap { url in
                let name = url.lastPathComponent
                let id = preferences && name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
                guard !id.hasPrefix("com.apple."), id.range(of: "^[A-Za-z][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+){2,}$", options: .regularExpression) != nil,
                      !installed.contains(id), !installed.contains(where: { id.hasPrefix($0 + ".") }),
                      !(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { manager.fileExists(atPath: $0.path) } ?? false) else { return nil }
                return name
            })
        }
        let preferences = home.appendingPathComponent("Library/Preferences")
        let missingPreferences = missingNames(at: preferences, preferences: true)
        let missingCaches = missingNames(at: root, preferences: false)
        if !missingPreferences.isEmpty { paths.append(ScanRoot(url: preferences, name: "未找到对应应用的偏好设置", category: .orphan, allowedNames: missingPreferences)) }
        if !missingCaches.isEmpty { paths.append(ScanRoot(url: root, name: "未找到对应应用的缓存", category: .orphan, allowedNames: missingCaches)) }
        for containerName in ["Containers", "Group Containers"] {
            let containers = home.appendingPathComponent("Library/" + containerName)
            for container in (try? manager.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
                guard let values = try? container.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                for suffix in ["Data/Library/Caches", "Library/Caches", "Caches"] {
                    paths.append(ScanRoot(url: container.appendingPathComponent(suffix), name: container.lastPathComponent + " · 缓存", category: .cache, owner: container.lastPathComponent))
                }
                for suffix in ["Data/Library/Logs", "Library/Logs"] {
                    paths.append(ScanRoot(url: container.appendingPathComponent(suffix), name: container.lastPathComponent + " · 日志", category: .logs, owner: container.lastPathComponent))
                }
            }
        }
        let browsers = [("Google/Chrome", "Chrome", "com.google.Chrome"), ("Microsoft Edge", "Edge", "com.microsoft.edgemac"), ("BraveSoftware/Brave-Browser", "Brave", "com.brave.Browser"), ("Chromium", "Chromium", "org.chromium.Chromium")]
        for (folder, label, owner) in browsers {
            let base = home.appendingPathComponent("Library/Application Support/" + folder)
            for profile in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                guard profile.lastPathComponent == "Default" || profile.lastPathComponent.hasPrefix("Profile ") else { continue }
                for suffix in ["Cache", "Code Cache", "GPUCache", "DawnCache"] {
                    paths.append(ScanRoot(url: profile.appendingPathComponent(suffix), name: label + " · " + profile.lastPathComponent + " · " + suffix, category: .cache, owner: owner))
                }
            }
        }
        var seen = Set<String>()
        return paths.filter {
            var isDirectory: ObjCBool = false
            let key = $0.url.path + ":" + $0.category.rawValue
            return manager.fileExists(atPath: $0.url.path, isDirectory: &isDirectory) && isDirectory.boolValue && seen.insert(key).inserted
        }.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    static func eligible(_ url: URL, runningIDs: [String], now: Date, scope: ScanRoot? = nil, includeRecent: Bool = false, revalidateApplication: Bool = false) -> CacheFile? {
        let scope = scope ?? ScanRoot(url: root, name: "用户缓存", category: .cache)
        let path = url.standardizedFileURL.path
        let rootPath = scope.url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/"), url.resolvingSymlinksInPath().path == path else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        let lower = relative.lowercased()
        if scope.category == .orphan {
            guard let name = relative.split(separator: "/").first.map(String.init), scope.allowedNames.contains(name) else { return nil }
            let id = name.hasSuffix(".plist") ? String(name.dropLast(6)) : name
            if revalidateApplication, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), FileManager.default.fileExists(atPath: app.path) { return nil }
        }
        guard !runningIDs.contains(where: { lower.contains($0.lowercased()) }) else { return nil }
        if let owner = scope.owner, runningIDs.contains(where: { owner.lowercased().contains($0.lowercased()) || $0.lowercased().contains(owner.lowercased()) }) { return nil }
        var freshURL = URL(fileURLWithPath: path)
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .contentAccessDateKey, .fileSizeKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let modified = values.contentModificationDate else { return nil }
        let minAge: TimeInterval = scope.category == .receipt || (scope.category == .cache && includeRecent) ? 0 : scope.category == .large ? 30 * 86400 : minimumAge
        guard now.timeIntervalSince(modified) >= minAge else { return nil }
        if minAge > 0 && scope.category != .startup, let accessed = values.contentAccessDate, now.timeIntervalSince(accessed) < minAge { return nil }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size > 0 else { return nil }
        if scope.category == .installers && !["dmg", "pkg"].contains(url.pathExtension.lowercased()) { return nil }
        if scope.category == .large && (size < 100 * 1024 * 1024 || ["dmg", "pkg"].contains(url.pathExtension.lowercased())) { return nil }
        if scope.category == .startup {
            guard url.pathExtension == "plist", let data = try? Data(contentsOf: freshURL),
                  let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  let command = (dictionary["Program"] as? String) ?? (dictionary["ProgramArguments"] as? [String])?.first,
                  command.hasPrefix("/"), !FileManager.default.fileExists(atPath: command) else { return nil }
        }
        if scope.category == .receipt && !["plist", "bom"].contains(url.pathExtension.lowercased()) { return nil }
        return CacheFile(url: url, relativePath: scope.name + "/" + relative, size: size, modified: modified, scope: scope, includeRecent: includeRecent)
    }

    static func scan(runningIDs: [String], includeRecent: Bool = false, testRoots: [ScanRoot]? = nil, itemLimit: Int = 150_000, timeLimit: Double = 30, rootTimeLimit: Double = 5) -> CacheScan {
        var result = CacheScan()
        let manager = FileManager.default
        let now = Date()
        let started = ProcessInfo.processInfo.systemUptime
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        var examined = 0
        var candidates = 0
        var seen = Set<String>()
        var topByCategory: [JunkCategory: [CacheFile]] = [:]
        for scope in testRoots ?? roots() {
        if ProcessInfo.processInfo.systemUptime - started > timeLimit || examined >= itemLimit { result.limited = true; break }
        if let owner = scope.owner, runningIDs.contains(where: { owner.lowercased().contains($0.lowercased()) || $0.lowercased().contains(owner.lowercased()) }) { continue }
        let rootStarted = ProcessInfo.processInfo.systemUptime
        guard let walker = manager.enumerator(at: scope.url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in result.skipped += 1; return true }) else { result.skipped += 1; continue }
        for case let url as URL in walker {
            if examined >= itemLimit || ProcessInfo.processInfo.systemUptime - rootStarted > rootTimeLimit || ProcessInfo.processInfo.systemUptime - started > timeLimit { result.limited = true; break }
            examined += 1
            let relative = String(url.path.dropFirst(scope.url.path.count + 1)).lowercased()
            if runningIDs.contains(where: { relative.contains($0.lowercased()) }) {
                walker.skipDescendants()
                continue
            }
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if let file = eligible(url, runningIDs: runningIDs, now: now, scope: scope, includeRecent: includeRecent), seen.insert(file.id).inserted {
                candidates += 1
                result.candidateBytes += file.size
                topByCategory[scope.category, default: []].append(file)
                if topByCategory[scope.category, default: []].count > 200 {
                    topByCategory[scope.category] = Array(topByCategory[scope.category, default: []].sorted { $0.size > $1.size }.prefix(100))
                }
            }
        }
        }
        result.files = JunkCategory.allCases.flatMap { category in
            Array(topByCategory[category, default: []].sorted { $0.size > $1.size }.prefix(100))
        }
        result.files.sort { $0.size > $1.size }
        result.examined = examined
        result.candidateCount = candidates
        if candidates > result.files.count { result.limited = true }
        return result
    }
}

enum Page { case overview, apps, cache }

actor MetricsWorker {
    private let sampler = Sampler()
    func sample(includeApps: Bool) -> (Reading, [AppUsage]) { sampler.sample(includeApps: includeApps) }
}

enum SmartSelection {
    static let browserIDs: Set<String> = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium"]
    static func recommended(_ files: [CacheFile], runningIDs: [String]) -> [CacheFile] {
        files.filter { file in
            let isBrowserCache = file.scope.category == .cache && file.scope.owner.map { browserIDs.contains($0) } == true
            let name = file.url.lastPathComponent.lowercased()
            let isOldLog = file.scope.category == .logs && (["log", "crash", "ips"].contains(file.url.pathExtension.lowercased()) || name.hasSuffix(".log.gz") || (name.contains(".log.") && name.hasSuffix(".gz")))
            return (isBrowserCache || isOldLog) && CacheScanner.validForTrash(file, runningIDs: runningIDs)
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var reading = Reading()
    @Published var apps: [AppUsage] = []
    @Published var page = Page.overview { didSet { changed?() } }
    @Published var selectedApps = Set<String>()
    @Published var selectedFiles = Set<String>()
    @Published var cache = CacheScan()
    @Published var scanning = false
    @Published var cleaning = false
    @Published var selectingSmart = false
    @Published var scanned = false
    @Published var includeRecentCaches = false
    @Published var categoryFilter = "全部"
    @Published var expandedNodes = Set<String>()
    @Published var sortByCPU = false
    @Published var message: String?
    @Published var displayMode = UserDefaults.standard.string(forKey: "displayMode") ?? "compact" {
        didSet { UserDefaults.standard.set(displayMode, forKey: "displayMode"); changed?() }
    }
    var changed: (() -> Void)?
    var panelVisible = false
    private let worker = MetricsWorker()
    private var timer: DispatchSourceTimer?
    private var busy = false

    init(startMonitoring: Bool = true) {
        guard startMonitoring else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let includeApps = panelVisible
        Task(priority: .utility) { [weak self, worker] in
            let value = await worker.sample(includeApps: includeApps)
            guard let self = self else { return }
            self.reading = value.0
            self.apps = value.1
            self.selectedApps.formIntersection(Set(value.1.map(\.id)))
            self.busy = false
            self.changed?()
        }
    }

    var sortedApps: [AppUsage] {
        apps.sorted { sortByCPU ? $0.cpu > $1.cpu : $0.memory > $1.memory }
    }
    var selectedSize: UInt64 { cache.files.filter { selectedFiles.contains($0.id) }.reduce(0) { $0 + $1.size } }
    var visibleFiles: [CacheFile] { cache.files.filter { categoryFilter == "全部" || $0.scope.category.rawValue == categoryFilter } }
    var panelHeight: CGFloat { page == .cache ? max(536, min(648, (NSScreen.main?.visibleFrame.height ?? 800) - 40)) : 536 }
    func toggleSelection(_ files: [CacheFile]) {
        let ids = Set(files.filter(\.isSelectable).map(\.id))
        if ids.isSubset(of: selectedFiles) { selectedFiles.subtract(ids) } else { selectedFiles.formUnion(ids) }
    }
    func toggleExpansion(_ id: String) {
        if expandedNodes.contains(id) { expandedNodes.remove(id) } else { expandedNodes.insert(id) }
    }
    func smartSelect() {
        guard !scanning && !cleaning && !selectingSmart else { return }
        selectingSmart = true
        let files = cache.files
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        Task { [weak self] in
            let recommended = await Task.detached(priority: .utility) { SmartSelection.recommended(files, runningIDs: ids) }.value
            guard let self = self else { return }
            self.selectedFiles = Set(recommended.map(\.id))
            self.selectingSmart = false
            self.message = recommended.isEmpty ? "没有符合低风险规则的候选；打开的浏览器不会预选。" : "已预选 \(recommended.count) 个旧日志或浏览器缓存，请检查后清理。不能保证零影响。"
        }
    }

    func quitSelectedApps() {
        let selected = apps.filter { selectedApps.contains($0.id) && applicationForQuit($0) != nil }
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "退出 \(selected.count) 个应用？"
        alert.informativeText = selected.map(\.name).joined(separator: "、") + "\n\n应用会正常退出；如有未保存内容，请在应用的提示中保存。"
        alert.addButton(withTitle: "退出所选应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var failed = 0
        for usage in selected {
            guard let app = applicationForQuit(usage) else { failed += 1; continue }
            if !app.terminate() { failed += 1 }
        }
        selectedApps.removeAll()
        message = failed == 0 ? "已请求正常退出；内存和 CPU 数据会随后更新。" : "有 \(failed) 个应用无法退出，请在该应用中手动关闭。"
        refresh()
    }

    func scanCaches() {
        guard !scanning && !cleaning else { return }
        scanning = true; scanned = true; message = nil; selectedFiles.removeAll()
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let recent = includeRecentCaches
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { CacheScanner.scan(runningIDs: ids, includeRecent: recent) }.value
            guard let self = self else { return }
            self.cache = result; self.scanning = false
            self.expandedNodes = Set(JunkCategory.allCases.map { "category:" + $0.rawValue })
        }
    }

    func trashSelectedFiles() {
        guard !cleaning else { return }
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let files = cache.files.filter { selectedFiles.contains($0.id) && CacheScanner.validForTrash($0, runningIDs: ids) }
        guard !files.isEmpty else { message = "所选文件已发生变化或正在使用，请重新扫描。"; return }
        let alert = NSAlert()
        alert.messageText = "将 \(files.count) 个所选文件移到废纸篓？"
        alert.informativeText = "合计 \(sizeText(files.reduce(0) { $0 + $1.size }))。大文件、安装包和残留配置需确认用途；移除失效启动项会改变登录启动设置。\n\n可从废纸篓放回；清倒废纸篓后才真正释放磁盘空间。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let currentIDs = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let currentFiles = files.filter { CacheScanner.validForTrash($0, runningIDs: currentIDs) }
        guard !currentFiles.isEmpty else { message = "确认期间文件发生变化或应用已启动，请重新扫描。"; return }
        cleaning = true
        NSWorkspace.shared.recycle(currentFiles.map(\.url)) { mapping, error in
            DispatchQueue.main.async {
                let moved = Set(mapping.keys.map(\.path))
                self.cache.files.removeAll { moved.contains($0.id) }
                self.selectedFiles.subtract(moved)
                self.cleaning = false
                self.message = error.map { "部分文件未能移动：\($0.localizedDescription)" } ?? "已将 \(moved.count) 个文件移到废纸篓，可放回。"
            }
        }
    }
}

@MainActor struct MetricCard: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) { Image(systemName: symbol).foregroundStyle(color); Text(title).foregroundStyle(.secondary) }.font(.system(size: 12, weight: .medium))
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.13))
                    Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }.frame(height: 4)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor struct ActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

@MainActor struct SelectionBox: View {
    @ObservedObject var model: MonitorModel
    let files: [CacheFile]
    var body: some View {
        let selectable = files.filter(\.isSelectable)
        let count = selectable.filter { model.selectedFiles.contains($0.id) }.count
        let all = count == selectable.count && !selectable.isEmpty
        let partial = count > 0 && !all
        Button { model.toggleSelection(files) } label: {
            Image(systemName: all ? "checkmark.square.fill" : partial ? "minus.square.fill" : "square")
                .font(.system(size: 14)).foregroundStyle(all || partial ? Color.orange : Color.secondary.opacity(0.5))
                .frame(width: 20, height: 22)
        }.buttonStyle(.plain).disabled(selectable.isEmpty || model.scanning || model.cleaning || model.selectingSmart)
            .accessibilityLabel(all ? "取消全选 \(selectable.count) 个文件" : "选择全部 \(selectable.count) 个文件")
            .accessibilityValue(partial ? "部分已选（\(count)/\(selectable.count)）" : all ? "已全选" : selectable.isEmpty ? "仅查看" : "未选中")
    }
}

@MainActor struct FileRow: View {
    @ObservedObject var model: MonitorModel
    let file: CacheFile
    var body: some View {
        HStack(spacing: 6) {
            SelectionBox(model: model, files: [file])
            Button { model.toggleSelection([file]) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Text(file.relativePath).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!file.isSelectable || model.scanning || model.cleaning || model.selectingSmart).help(file.url.path)
            Text(sizeText(file.size)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("在 Finder 中查看")
        }.padding(.vertical, 5).padding(.horizontal, 4)
            .background(model.selectedFiles.contains(file.id) ? Color.orange.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor struct FileBranch<Content: View>: View {
    @ObservedObject var model: MonitorModel
    let key: String
    let title: String
    let files: [CacheFile]
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                SelectionBox(model: model, files: files)
                Button { model.toggleExpansion(key) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.expandedNodes.contains(key) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 3)
                        Text("\(files.count) · \(sizeText(files.reduce(0) { $0 + $1.size }))").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(title)
            }.padding(.vertical, 4)
            if model.expandedNodes.contains(key) { LazyVStack(alignment: .leading, spacing: 2) { content() }.padding(.leading, 16) }
        }
    }
}

@MainActor struct FileTree: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(JunkCategory.allCases, id: \.rawValue) { category in
                let files = model.visibleFiles.filter { $0.scope.category == category }
                if !files.isEmpty {
                    FileBranch(model: model, key: "category:" + category.rawValue, title: category.rawValue, files: files) {
                        ForEach(fileGroups(files)) { group in
                            FileBranch(model: model, key: group.id, title: group.title, files: group.files) {
                                ForEach(group.files) { file in FileRow(model: model, file: file) }
                            }
                        }
                    }
                }
            }
        }
    }
}

@MainActor struct PanelView: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.page != .overview {
                    Button { model.page = .overview; model.message = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).padding(.trailing, 5).help("返回概览")
                }
                Image(systemName: "waveform.path").foregroundStyle(.teal)
                Text(model.page == .overview ? appName : model.page == .apps ? "释放资源" : "清理冗余").font(.system(size: 15, weight: .semibold))
                Spacer()
                Circle().fill(model.reading.ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(model.reading.ready ? "实时" : "采样中").font(.system(size: 10)).foregroundStyle(.secondary)
                Menu {
                    Picker("菜单栏显示", selection: $model.displayMode) {
                        Text("文字与数字").tag("labeled")
                        Text("紧凑四项 · C=CPU，M=内存").tag("compact")
                        Text("仅小图标 · 点击看详情").tag("icon")
                    }
                    Button("打开活动监视器") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                    Divider()
                    Button("退出极简状态") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary) }.menuStyle(.borderlessButton).fixedSize().frame(width: 24)
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
            Divider().opacity(0.5)
            Group {
                switch model.page {
                case .overview: overview
                case .apps: appsPage
                case .cache: cachePage
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider().opacity(0.5)
            HStack {
                Text("每 2 秒更新 · 数据仅在本机处理").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 390, height: model.panelHeight).background(Color(nsColor: .windowBackgroundColor))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                MetricCard(title: "CPU · 处理器", symbol: "cpu", value: model.reading.cpuOK ? String(format: "%.0f%%", model.reading.cpu) : "—", detail: "当前使用的计算能力", fraction: model.reading.cpu / 100, color: .teal)
                MetricCard(title: "已用运行内存", symbol: "memorychip", value: model.reading.memoryOK ? String(format: "%.1f GB", Double(model.reading.usedMemory) / gib) : "—", detail: String(format: "已用 %.0f%% / 总共 %.0f GB", model.reading.memoryPercent, Double(model.reading.totalMemory) / gib), fraction: model.reading.memoryPercent / 100, color: .indigo)
            }
            HStack {
                networkMetric("上传", symbol: "arrow.up", speed: model.reading.upload, color: .orange)
                Divider().frame(height: 38).padding(.horizontal, 10)
                networkMetric("下载", symbol: "arrow.down", speed: model.reading.download, color: .blue)
            }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            VStack(spacing: 0) {
                ActionRow(symbol: "bolt", title: "释放内存 · 减轻 CPU", detail: "选择占用较高的应用并正常退出", color: .teal) { model.page = .apps; model.message = nil; model.refresh() }
                Divider().padding(.leading, 60).opacity(0.5)
                ActionRow(symbol: "trash", title: "清理冗余文件", detail: "缓存、日志、安装包与下载大文件", color: .orange) { model.page = .cache; model.message = nil }
            }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        }.padding(20)
    }

    private func networkMetric(_ title: String, symbol: String, speed: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(model.reading.ready ? speedText(speed) : "—").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("退出暂时不用的应用，释放它占用的资源。").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("排序", selection: $model.sortByCPU) { Text("内存占用").tag(false); Text("CPU 占用").tag(true) }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.sortedApps) { usage in
                        Button {
                            if model.selectedApps.contains(usage.id) { model.selectedApps.remove(usage.id) } else { model.selectedApps.insert(usage.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedApps.contains(usage.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selectedApps.contains(usage.id) ? Color.teal : Color.secondary.opacity(0.4))
                                if let icon = usage.icon { Image(nsImage: icon).resizable().frame(width: 25, height: 25) }
                                Text(usage.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(sizeText(usage.memory)).font(.system(size: 12, weight: .medium))
                                    Text(String(format: "CPU %.1f%%", usage.cpu)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.monospacedDigit()
                            }.padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).background(model.selectedApps.contains(usage.id) ? Color.teal.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("应用统计含可归属的子进程；内存为驻留量，可能含共享页。CPU 占全部核心。").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Button("退出所选应用\(model.selectedApps.isEmpty ? "" : "（\(model.selectedApps.count)）")") { model.quitSelectedApps() }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.large).frame(maxWidth: .infinity).disabled(model.selectedApps.isEmpty)
        }.padding(20)
    }

    private var cachePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("大文件、配置残留和启动项需检查用途。安装记录仅查看；智能选择只预选低风险项目，不能保证零影响。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("包含近期缓存（会跳过能识别的运行应用）", isOn: $model.includeRecentCaches).font(.system(size: 10)).toggleStyle(.checkbox).disabled(model.scanning || model.cleaning)
            HStack {
                Button(model.scanned ? "重新扫描" : "开始扫描") { model.scanCaches() }.buttonStyle(.bordered).disabled(model.scanning || model.cleaning)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small); Text("扫描中…").font(.system(size: 11)).foregroundStyle(.secondary) }
                else if model.scanned { Text("\(model.cache.candidateCount) 个结果 · \(sizeText(model.cache.candidateBytes))").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Picker("类别", selection: $model.categoryFilter) {
                Text("全部类别").tag("全部")
                ForEach(JunkCategory.allCases, id: \.rawValue) { category in Text(category.rawValue).tag(category.rawValue) }
            }.font(.system(size: 11))
            HStack(spacing: 4) {
                SelectionBox(model: model, files: model.visibleFiles)
                Text("全选（\(model.visibleFiles.filter(\.isSelectable).count)）").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(model.selectingSmart ? "选择中…" : "智能选择") { model.smartSelect() }.buttonStyle(.bordered).tint(.orange).controlSize(.small).disabled(model.cache.files.isEmpty || model.scanning || model.cleaning || model.selectingSmart).help("低风险预选，需自行检查；不能保证零影响")
                Button("展开全部") {
                    for category in JunkCategory.allCases {
                        let files = model.visibleFiles.filter { $0.scope.category == category }
                        model.expandedNodes.insert("category:" + category.rawValue)
                        model.expandedNodes.formUnion(fileGroups(files).map(\.id))
                    }
                }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                Button("收起") { model.expandedNodes.removeAll() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.visibleFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.scanned ? "checkmark.circle" : "sparkles").font(.system(size: 28)).foregroundStyle(.teal.opacity(0.7))
                    Text(model.scanning ? "正在查找候选文件" : model.scanned ? "该类别未找到候选文件" : "扫描后选择你想清理的文件").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { FileTree(model: model) }
            }
            if model.scanned { Text("已检查 \(model.cache.examined) 项 · 每类展示最大的 100 个候选\(model.cache.limited ? " · 部分结果受扫描限制" : "")\(model.cache.skipped > 0 ? " · 无权限目录已跳过" : "")").font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            if let message = model.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Button(model.cleaning ? "正在移到废纸篓…" : "移到废纸篓 · \(sizeText(model.selectedSize))") { model.trashSelectedFiles() }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).frame(maxWidth: .infinity).disabled(model.selectedFiles.isEmpty || model.scanning || model.cleaning || model.selectingSmart)
        }.padding(20)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: MonitorModel!
    private let statusSymbol = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "极简状态")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.ministatus.app").filter({ $0.processIdentifier != getpid() }).count > 0 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        model = MonitorModel()
        statusItem = NSStatusBar.system.statusItem(withLength: 164)
        statusItem.autosaveName = "MiniStatus"
        if let button = statusItem.button {
            button.title = "C— M— ↑— ↓—"
            button.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
            button.setAccessibilityLabel("极简状态：CPU、内存与网速。点击查看详情与清理。")
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 390, height: 536)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
        popover.delegate = self
        model.changed = { [weak self] in self?.updateStatus() }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 && self?.popover.isShown == true { self?.popover.performClose(nil); return nil }
            return event
        }
        if CommandLine.arguments.contains("--show-panel") || UserDefaults.standard.string(forKey: "lastVersion") != "1.3" {
            UserDefaults.standard.set("1.3", forKey: "lastVersion")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.togglePanel() }
        }
    }

    private func updateStatus() {
        if popover != nil {
            let size = NSSize(width: 390, height: model.panelHeight)
            if popover.contentSize != size { popover.contentSize = size }
        }
        let r = model.reading
        let cpu = r.cpuOK ? String(format: "%.0f%%", r.cpu) : "—"
        if model.displayMode == "icon" {
            if statusItem.length != 26 { statusItem.length = 26 }
            statusSymbol?.isTemplate = true
            if statusItem.button?.image == nil { statusItem.button?.image = statusSymbol }
            if statusItem.button?.title != "" { statusItem.button?.title = "" }
        } else {
            let width: CGFloat = model.displayMode == "compact" ? 164 : 256
            if statusItem.length != width { statusItem.length = width }
            statusItem.button?.image = nil
            let title = menuTitle(r, compact: model.displayMode == "compact")
            if statusItem.button?.title != title { statusItem.button?.title = title }
        }
        let description = "C = CPU（处理器）：当前用了 \(cpu) 的计算能力\nM = 运行内存：已用 \(sizeText(r.usedMemory)) / 总共 \(sizeText(r.totalMemory))（已用 \(Int(r.memoryPercent))%）\n上传 \(speedText(r.upload)) · 下载 \(speedText(r.download))\nK = KB/s，M = MB/s，G = GB/s；Wi-Fi 与有线网卡合计"
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel("极简状态。" + description)
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        model.panelVisible = true
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }
    func popoverDidClose(_ notification: Notification) { model.panelVisible = false }
}

#if TESTING
@MainActor final class RecycleResult {
    var finished = false
    var mapping: [URL: URL] = [:]
    var error: Error?
}

func extensionFeatureTests() -> [(String, Bool)] {
    let manager = FileManager.default
    let directory = CacheScanner.root.appendingPathComponent("local.ministatus.extension-fixture-" + UUID().uuidString)
    do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        func write(_ name: String, data: Data = Data(repeating: 1, count: 256)) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            let old = Int(Date().timeIntervalSince1970 - 40 * 86400)
            var times = [timeval(tv_sec: old, tv_usec: 0), timeval(tv_sec: old, tv_usec: 0)]
            guard url.path.withCString({ utimes($0, &times) }) == 0 else { throw NSError(domain: "fixture", code: 1) }
            return url
        }
        let browser = try write("browser.cache")
        let log = try write("archived.log")
        let gz = try write("unknown.gz")
        let browserScope = ScanRoot(url: directory, name: "浏览器缓存", category: .cache, owner: "com.google.Chrome")
        let unknownScope = ScanRoot(url: directory, name: "未知缓存", category: .cache)
        let logsScope = ScanRoot(url: directory, name: "日志", category: .logs)
        guard let browserFile = CacheScanner.eligible(browser, runningIDs: [], now: Date(), scope: browserScope),
              let unknownFile = CacheScanner.eligible(browser, runningIDs: [], now: Date(), scope: unknownScope),
              let logFile = CacheScanner.eligible(log, runningIDs: [], now: Date(), scope: logsScope),
              let gzFile = CacheScanner.eligible(gz, runningIDs: [], now: Date(), scope: logsScope) else { return [("扩展功能测试数据可生成", false)] }
        var results: [(String, Bool)] = []
        results.append(("智能选择预选已退出浏览器的缓存", SmartSelection.recommended([browserFile], runningIDs: []).count == 1))
        results.append(("智能选择排除运行中的浏览器及其辅助进程", SmartSelection.recommended([browserFile], runningIDs: ["com.google.Chrome.helper"]).isEmpty))
        results.append(("智能选择排除未知缓存和非日志压缩文件", SmartSelection.recommended([unknownFile, gzFile], runningIDs: []).isEmpty))
        results.append(("智能选择可以选择明确的旧日志", SmartSelection.recommended([logFile], runningIDs: []).count == 1))
        let target = directory.appendingPathComponent("missing-executable")
        func plist(_ name: String, command: String) throws -> URL {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "local.ministatus.fixture", "ProgramArguments": [command]], format: .xml, options: 0)
            return try write(name, data: data)
        }
        let dead = try plist("dead.plist", command: target.path)
        let live = try plist("live.plist", command: "/usr/bin/true")
        let relative = try plist("relative.plist", command: "python3")
        let bad = try write("malformed.plist")
        let startupScope = ScanRoot(url: directory, name: "启动项", category: .startup)
        let deadFile = CacheScanner.eligible(dead, runningIDs: [], now: Date(), scope: startupScope)
        results.append(("启动项只识别绝对路径且目标确实不存在的条目", deadFile != nil && CacheScanner.eligible(live, runningIDs: [], now: Date(), scope: startupScope) == nil && CacheScanner.eligible(relative, runningIDs: [], now: Date(), scope: startupScope) == nil && CacheScanner.eligible(bad, runningIDs: [], now: Date(), scope: startupScope) == nil))
        if let file = deadFile {
            try Data("restored executable".utf8).write(to: target)
            results.append(("目标程序重新出现后禁止移除该启动项", !CacheScanner.validForTrash(file, runningIDs: [])))
            results.append(("智能选择不选择启动项", SmartSelection.recommended([file], runningIDs: []).isEmpty))
        }
        let receiptScope = ScanRoot(url: directory, name: "安装记录", category: .receipt)
        if let receipt = CacheScanner.eligible(live, runningIDs: [], now: Date(), scope: receiptScope) {
            results.append(("安装记录只可查看，不可进入清理或智能选择", !receipt.isSelectable && !CacheScanner.validForTrash(receipt, runningIDs: []) && SmartSelection.recommended([receipt], runningIDs: []).isEmpty))
        } else { results.append(("安装记录可识别", false)) }
        let preferenceScope = ScanRoot(url: directory, name: "残留", category: .orphan, allowedNames: ["dead.plist"])
        let allowed = CacheScanner.eligible(dead, runningIDs: [], now: Date(), scope: preferenceScope)
        let forbidden = CacheScanner.eligible(live, runningIDs: [], now: Date(), scope: preferenceScope)
        results.append(("残留扫描只接受已识别的条目，不扩展到其他配置", allowed != nil && forbidden == nil))
        if let file = allowed { results.append(("智能选择不选择应用残留配置", SmartSelection.recommended([file], runningIDs: []).isEmpty)) }
        let many = directory.appendingPathComponent("many")
        try manager.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 1...255 {
            let url = many.appendingPathComponent("file-\(i).cache")
            try Data(repeating: 1, count: i).write(to: url)
            let old = Int(Date().timeIntervalSince1970 - 40 * 86400)
            var times = [timeval(tv_sec: old, tv_usec: 0), timeval(tv_sec: old, tv_usec: 0)]
            _ = url.path.withCString { utimes($0, &times) }
        }
        let scope = ScanRoot(url: many, name: "多文件", category: .cache)
        let scan = CacheScanner.scan(runningIDs: [], testRoots: [scope, scope])
        results.append(("重复根目录不会重复计数，且每类保留最大的100个", scan.candidateCount == 255 && scan.files.count == 100 && scan.files.first?.size == 255 && scan.files.last?.size == 156))
        let bounded = CacheScanner.scan(runningIDs: [], testRoots: [scope], itemLimit: 5)
        results.append(("扫描数量上限会停止并报告部分结果", bounded.limited && bounded.candidateCount <= 5 && bounded.examined <= 5))
        let timed = CacheScanner.scan(runningIDs: [], testRoots: [scope], timeLimit: 0)
        results.append(("扫描时间上限会停止并报告部分结果", timed.limited && timed.examined == 0))
        return results
    } catch { print("Extended fixture error: \(error)"); return [("扩展功能测试", false)] }
}

@MainActor func recycleRoundTripTest() -> Bool {
    let manager = FileManager.default
    let directory = CacheScanner.root.appendingPathComponent("local.ministatus.recycle-fixture-" + UUID().uuidString)
    do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let source = directory.appendingPathComponent("disposable-fixture.cache")
        let original = Data("MiniStatus disposable recovery test".utf8)
        try original.write(to: source)
        let result = RecycleResult()
        NSWorkspace.shared.recycle([source]) { mapping, error in
            DispatchQueue.main.async { result.mapping = mapping; result.error = error; result.finished = true }
        }
        let deadline = Date().addingTimeInterval(20)
        while !result.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard result.finished, result.error == nil, let trashed = result.mapping[source], !manager.fileExists(atPath: source.path) else {
            print("Recycle error: \(String(describing: result.error))"); return false
        }
        try manager.moveItem(at: trashed, to: source)
        return try Data(contentsOf: source) == original
    } catch { print("Recovery error: \(error)"); return false }
}

func ownResources() -> proc_taskinfo {
    var info = proc_taskinfo()
    _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
    return info
}

@MainActor func auditTests() {
    var failures = 0
    func check(_ name: String, _ condition: Bool) { print("\(condition ? "PASS" : "FAIL"): \(name)"); if !condition { failures += 1 } }
    let speeds: [Double] = [0, 1, 1023, 1024, 999.4 * 1024, 999.6 * 1024, 10 * 1_048_576, 999.6 * 1_048_576, 10 * gib, 1000 * gib, .infinity, .nan]
    check("网速边界与异常值的短格式不超过四个字符", speeds.allSatisfy { speedText($0, compact: true).count <= 4 })
    let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    var maxWidth = 0.0
    var noGap = true
    for percentage in stride(from: 0.0, through: 100.0, by: 10) {
        for speed in speeds {
            var reading = Reading()
            reading.cpu = percentage; reading.usedMemory = UInt64(percentage * 10); reading.totalMemory = 1000
            reading.upload = speed; reading.download = speed; reading.ready = true; reading.cpuOK = true; reading.memoryOK = true
            let title = menuTitle(reading, compact: true)
            maxWidth = max(maxWidth, (title as NSString).size(withAttributes: [.font: font]).width)
            noGap = noGap && title.range(of: "^C[0-9]+% M[0-9]+% ", options: .regularExpression) != nil
        }
    }
    check("紧凑菜单在 0–100% 和网速边界下适配 164pt", maxWidth + 12 <= 164)
    check("C/M 与百分比紧贴，没有内部补位空格", noGap)
    print(String(format: "菜单最大文字宽度 %.2fpt，固定外框 164pt", maxWidth))
    let baseline = ["en0": NetworkCount(sent: 100, received: 200)]
    let rate = networkRate(current: ["en0": NetworkCount(sent: 1124, received: 2248)], previous: baseline, elapsed: 2)
    check("网络差值按真实时间折算", rate.0 == 512 && rate.1 == 1024)
    let reset = networkRate(current: ["en0": NetworkCount(sent: 1, received: 1)], previous: baseline, elapsed: 2)
    check("接口计数重置不产生虚假高速", reset.0 == 0 && reset.1 == 0)
    let fresh = networkRate(current: ["en1": NetworkCount(sent: 500000, received: 500000)], previous: baseline, elapsed: 2)
    check("新接口首个差值不计入网速", fresh.0 == 0 && fresh.1 == 0)
    let zeroTime = networkRate(current: baseline, previous: baseline, elapsed: 0)
    check("零时间差不除零", zeroTime.0 == 0 && zeroTime.1 == 0)

    let scope = ScanRoot(url: CacheScanner.root, name: "用户缓存", category: .cache)
    let installerScope = ScanRoot(url: CacheScanner.root, name: "安装包", category: .installers)
    let files = [CacheFile(url: scope.url.appendingPathComponent("test-folder/a.cache"), relativePath: "a", size: 100, modified: Date(), scope: scope, includeRecent: false),
                 CacheFile(url: scope.url.appendingPathComponent("test-folder/b.cache"), relativePath: "b", size: 200, modified: Date(), scope: scope, includeRecent: false),
                 CacheFile(url: scope.url.appendingPathComponent("test-installer.dmg"), relativePath: "c", size: 300, modified: Date(), scope: installerScope, includeRecent: false)]
    let model = MonitorModel(startMonitoring: false)
    model.cache.files = files
    model.toggleSelection(files)
    check("全选覆盖全部已展示叶子且统计大小正确", model.selectedFiles.count == 3 && model.selectedSize == 600)
    model.toggleSelection([files[0]])
    check("取消子节点后父节点进入部分选择", model.selectedFiles.count == 2 && model.selectedSize == 500)
    model.categoryFilter = JunkCategory.installers.rawValue
    model.toggleSelection(model.visibleFiles)
    check("类别筛选后的取消全选不改变其他类别", model.selectedFiles == Set([files[1].id]))
    model.toggleSelection(model.visibleFiles)
    check("类别筛选后的全选只添加该类别", model.selectedFiles == Set([files[1].id, files[2].id]))
    model.categoryFilter = "全部"
    let groups = fileGroups(files.filter { $0.scope.category == .cache })
    check("类别内的文件按应用或文件夹归属分支", groups.count == 1 && groups[0].files.count == 2)
    model.toggleSelection(groups[0].files)
    check("半选分支点击后全选该分支", model.selectedFiles.count == 3)
    model.toggleSelection(groups[0].files)
    check("分支取消全选保留其他分支", model.selectedFiles == Set([files[2].id]))
    model.toggleExpansion("test"); model.toggleExpansion("test")
    check("树节点展开和收起可逆", !model.expandedNodes.contains("test"))
    check("缓存范围、年龄、符号链接、安装包和大文件边界", cacheScopeTest())
    let readOnly = CacheFile(url: scope.url.appendingPathComponent("readonly.plist"), relativePath: "readonly", size: 100, modified: Date(), scope: ScanRoot(url: scope.url, name: "安装记录", category: .receipt), includeRecent: false)
    model.cache.files = files + [readOnly]; model.selectedFiles.removeAll(); model.toggleSelection(model.cache.files)
    check("全选跳过只读安装记录", model.selectedFiles.count == 3 && !model.selectedFiles.contains(readOnly.id))
    for (name, result) in extensionFeatureTests() { check(name, result) }

    let sampler = Sampler()
    for _ in 0..<20 { _ = autoreleasepool { sampler.sample(includeApps: true) } }
    if let application = sampler.sample(includeApps: true).1.first {
        let changed = AppUsage(id: application.id, pid: application.pid, started: application.started + 1, name: application.name, cpu: 0, memory: 0)
        check("进程标识相同但启动时间变化时不会误退出新进程", applicationForQuit(changed) == nil)
    }
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var beforeRefs: mach_port_urefs_t = 0, afterRefs: mach_port_urefs_t = 0
    _ = mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &beforeRefs)
    let before = ownResources()
    var usageBefore = rusage()
    _ = getrusage(RUSAGE_SELF, &usageBefore)
    var timings: [Double] = []
    let loops = 3000
    for _ in 0..<loops {
        let start = ProcessInfo.processInfo.systemUptime
        _ = autoreleasepool { sampler.sample() }
        timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    let after = ownResources()
    var usageAfter = rusage()
    _ = getrusage(RUSAGE_SELF, &usageAfter)
    _ = mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &afterRefs)
    timings.sort()
    let memoryDelta = Int64(after.pti_resident_size) - Int64(before.pti_resident_size)
    check("3000 次采样后 host 端口引用没有增长", beforeRefs == afterRefs)
    check("3000 次采样后驻留内存增长小于 16MB", memoryDelta < 16 * 1024 * 1024)
    let cpuMS = Double((after.pti_total_user + after.pti_total_system) - (before.pti_total_user + before.pti_total_system)) * machTickToNanoseconds / 1_000_000
    func usageMS(_ usage: rusage) -> Double { Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000 }
    let usageDelta = usageMS(usageAfter) - usageMS(usageBefore)
    print(String(format: "CPU 独立校验：getrusage %.2fms，proc_taskinfo 转换后 %.2fms，Mach timebase %.5f", usageDelta, cpuMS, machTickToNanoseconds))
    check("进程 CPU 时间单位经转换后与 getrusage 一致", abs(usageDelta - cpuMS) < max(3, usageDelta * 0.05))
    print(String(format: "采样性能：P50 %.3fms / P95 %.3fms；RSS Δ %.2fMB；平均 CPU 时间 %.3fms/次；线程 %u→%u；host refs %u→%u", timings[loops/2], timings[Int(Double(loops) * 0.95)], Double(memoryDelta) / 1_048_576, cpuMS / Double(loops), before.pti_threadnum, after.pti_threadnum, beforeRefs, afterRefs))
    var appTimes: [Double] = []
    for _ in 0..<100 {
        let start = ProcessInfo.processInfo.systemUptime
        _ = autoreleasepool { sampler.sample(includeApps: true) }
        appTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    appTimes.sort()
    print(String(format: "应用列表采样：P50 %.3fms / P95 %.3fms", appTimes[50], appTimes[95]))
    check("应用列表采样 P95 小于 100ms", appTimes[95] < 100)
    check("独立临时文件移到废纸篓后可恢复且内容不变", recycleRoundTripTest())
    print("AUDIT \(failures == 0 ? "PASS" : "FAIL") — \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

func cacheScopeTest() -> Bool {
    let manager = FileManager.default
    let directory = CacheScanner.root.appendingPathComponent("local.ministatus.fixture-" + UUID().uuidString)
    do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.cache")
        let recent = directory.appendingPathComponent("recent.cache")
        let link = directory.appendingPathComponent("linked.cache")
        let installer = directory.appendingPathComponent("installer.dmg")
        let archive = directory.appendingPathComponent("personal.zip")
        let large = directory.appendingPathComponent("large.data")
        try Data(repeating: 42, count: 1024).write(to: old)
        try Data(repeating: 42, count: 128).write(to: recent)
        try Data(repeating: 42, count: 1024).write(to: installer)
        try Data(repeating: 42, count: 128).write(to: archive)
        manager.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 101 * 1024 * 1024)
        try handle.close()
        let past = Date().timeIntervalSince1970 - 40 * 86400
        for url in [old, installer, archive, large] {
            var times = [timeval(tv_sec: Int(past), tv_usec: 0), timeval(tv_sec: Int(past), tv_usec: 0)]
            guard url.path.withCString({ utimes($0, &times) }) == 0 else { return false }
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: old)
        let outside = manager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/example.txt")
        let installerScope = ScanRoot(url: directory, name: "fixture", category: .installers)
        let largeScope = ScanRoot(url: directory, name: "fixture", category: .large)
        let ownerScope = ScanRoot(url: directory, name: "fixture", category: .logs, owner: "local.ministatus.fixture")
        let checks = CacheScanner.eligible(old, runningIDs: [], now: Date())?.size == 1024
            && CacheScanner.eligible(recent, runningIDs: [], now: Date()) == nil
            && CacheScanner.eligible(recent, runningIDs: [], now: Date(), includeRecent: true) != nil
            && CacheScanner.eligible(link, runningIDs: [], now: Date()) == nil
            && CacheScanner.eligible(outside, runningIDs: [], now: Date()) == nil
            && CacheScanner.eligible(old, runningIDs: [directory.lastPathComponent], now: Date()) == nil
            && CacheScanner.eligible(old, runningIDs: ["local.ministatus.fixture"], now: Date(), scope: ownerScope) == nil
            && CacheScanner.eligible(installer, runningIDs: [], now: Date(), scope: installerScope) != nil
            && CacheScanner.eligible(archive, runningIDs: [], now: Date(), scope: installerScope) == nil
            && CacheScanner.eligible(large, runningIDs: [], now: Date(), scope: largeScope) != nil
            && CacheScanner.eligible(old, runningIDs: [], now: Date(), scope: largeScope) == nil
        guard let candidate = CacheScanner.eligible(old, runningIDs: [], now: Date()) else { return false }
        let validBefore = CacheScanner.validForTrash(candidate, runningIDs: [])
        try Data(repeating: 42, count: 2048).write(to: old)
        let validAfter = CacheScanner.validForTrash(candidate, runningIDs: [])
        if !checks || !validBefore || validAfter { print("Boundary checks=\(checks), validBefore=\(validBefore), validAfter=\(validAfter)") }
        return checks && validBefore && !validAfter
    } catch {
        print("Cache fixture error: \(error.localizedDescription)")
        return false
    }
}

func selfTest() {
    let sampler = Sampler()
    _ = sampler.sample(includeApps: true)
    Thread.sleep(forTimeInterval: 1)
    let (reading, apps) = sampler.sample(includeApps: true)
    let valid = reading.ready && reading.cpuOK && reading.memoryOK && reading.cpu >= 0 && reading.cpu <= 100 && reading.usedMemory > 0 && reading.usedMemory <= reading.totalMemory && reading.upload >= 0 && reading.download >= 0 && !apps.isEmpty
    print(String(format: "CPU %.1f%% | 内存 %.2f / %.0f GB (%.1f%%) | ↑ %@ ↓ %@ | 应用 %d", reading.cpu, Double(reading.usedMemory) / gib, Double(reading.totalMemory) / gib, reading.memoryPercent, speedText(reading.upload), speedText(reading.download), apps.count))
    for app in apps.sorted(by: { $0.memory > $1.memory }).prefix(4) { print("\(app.name): \(sizeText(app.memory)), CPU \(String(format: "%.1f", app.cpu))%") }
    guard cacheScopeTest() else { print("FAIL: 清理范围、新文件、符号链接或运行应用排除检查"); exit(1) }
    print(valid ? "PASS: 实时采样与清理范围检查" : "FAIL: 采样结果异常")
    exit(valid ? 0 : 1)
}

@MainActor func renderPreview(path: String, page: Page) {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let model = MonitorModel(startMonitoring: false)
    model.page = page
    let sampler = Sampler()
    _ = sampler.sample(includeApps: true)
    Thread.sleep(forTimeInterval: 0.3)
    let value = sampler.sample(includeApps: true)
    model.reading = value.0; model.apps = value.1
    if page == .cache {
        model.scanned = true
        let scope = ScanRoot(url: CacheScanner.root, name: "浏览器缓存", category: .cache)
        model.cache.files = [CacheFile(url: CacheScanner.root.appendingPathComponent("example.cache"), relativePath: "Chrome/Default/Cache/example.cache", size: 31_000_000, modified: Date(), scope: scope, includeRecent: false)]
        model.cache.candidateCount = 1234; model.cache.candidateBytes = 5_300_000_000; model.cache.examined = 42000
        model.expandedNodes = Set(["category:" + JunkCategory.cache.rawValue] + fileGroups(model.cache.files).map(\.id))
    }
    let view = NSHostingView(rootView: PanelView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: model.panelHeight), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    view.frame = NSRect(x: 0, y: 0, width: 390, height: model.panelHeight)
    for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("FAIL: render bitmap"); exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("Rendered \(path)") } catch { print(error); exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if CommandLine.arguments.contains("--audit") {
    auditTests()
} else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), index + 1 < CommandLine.arguments.count {
    let page: Page = CommandLine.arguments.contains("--cache") ? .cache : CommandLine.arguments.contains("--apps") ? .apps : .overview
    renderPreview(path: CommandLine.arguments[index + 1], page: page)
} else if CommandLine.arguments.contains("--scan-report") {
    let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    let result = CacheScanner.scan(runningIDs: ids, includeRecent: CommandLine.arguments.contains("--recent"))
    print("检查 \(result.examined) 项，\(result.candidateCount) 个候选，\(sizeText(result.candidateBytes))，展示 \(result.files.count) 个，跳过 \(result.skipped) 项，限制 \(result.limited)")
    for category in JunkCategory.allCases {
        let files = result.files.filter { $0.scope.category == category }
        print("\(category.rawValue)：展示 \(files.count) 个 / \(sizeText(files.reduce(0) { $0 + $1.size }))")
    }
    exit(0)
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
#else
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
#endif
