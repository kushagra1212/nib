import Darwin
import Foundation

/// How much memory nib is actually using, including what it spawned.
///
/// nib's own resident size is about 100MB and says nothing useful: the engines
/// are separate processes, and the rewrite model alone is 2.7GB. Someone
/// watching Activity Monitor sees "nib" at 100MB and "llama-server" at 2.7GB
/// with no visible connection between them.
///
/// So the menu reports the total, and offers to release it. Reading it rather
/// than estimating it: a number nib invents about itself would be the first
/// thing to drift.
enum Footprint {
    struct Reading {
        /// nib itself.
        let app: Int64
        /// Everything nib started: llama-server, harper-ls.
        let helpers: Int64

        var total: Int64 { app + helpers }

        var summary: String {
            helpers > 0
                ? "\(Footprint.short(total)) (\(Footprint.short(helpers)) in engines)"
                : Footprint.short(total)
        }
    }

    /// Resident bytes for this process, from the kernel.
    static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO),
                          $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    /// The engines, by name, summed from `ps`.
    ///
    /// `ps` rather than walking the process table: the helpers are ordinary
    /// child processes and this is a menu label, not a hot path. Counted by
    /// name so a llama-server left behind by a crashed nib is still reported --
    /// it is still using the memory.
    static func helperBytes(names: [String] = ["llama-server", "harper-ls"]) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        guard (try? task.run()) != nil,
              let data = try? pipe.fileHandleForReading.readToEnd() else { return 0 }
        task.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .reduce(into: Int64(0)) { total, line in
                let parts = line.split(separator: " ", maxSplits: 1,
                                       omittingEmptySubsequences: true)
                guard parts.count == 2,
                      let kilobytes = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
                      names.contains(where: { parts[1].hasSuffix($0) })
                else { return }
                total += kilobytes * 1024
            }
    }

    static func read() -> Reading {
        Reading(app: residentBytes(), helpers: helperBytes())
    }

    /// Rounded the way a person reads it, not the way a disk is sold.
    static func short(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }
}
