import Darwin
import Foundation
import IOKit

final class NetworkCollector {
    private var previousReceived: UInt64?
    private var previousSent: UInt64?
    private var previousTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func read() -> (download: Double, upload: Double) {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
            return (0, 0)
        }
        defer { freeifaddrs(addressPointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = pointer {
            let item = interface.pointee
            let flags = Int32(item.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp, !isLoopback,
               item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = item.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(data.ifi_ibytes)
                sent += UInt64(data.ifi_obytes)
            }
            pointer = item.ifa_next
        }

        let now = clock.now
        defer {
            previousReceived = received
            previousSent = sent
            previousTime = now
        }
        guard let previousReceived, let previousSent, let previousTime else { return (0, 0) }
        let duration = Double(previousTime.duration(to: now).components.seconds)
            + Double(previousTime.duration(to: now).components.attoseconds) / 1e18
        guard duration > 0 else { return (0, 0) }
        return (
            Double(received >= previousReceived ? received - previousReceived : 0) / duration,
            Double(sent >= previousSent ? sent - previousSent : 0) / duration
        )
    }
}

final class DiskCollector {
    private var previousRead: UInt64?
    private var previousWritten: UInt64?
    private var previousTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func read() -> (read: Double, write: Double) {
        let totals = totalsFromRegistry()
        let now = clock.now
        defer {
            previousRead = totals.read
            previousWritten = totals.write
            previousTime = now
        }
        guard let previousRead, let previousWritten, let previousTime else { return (0, 0) }
        let elapsed = previousTime.duration(to: now)
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard duration > 0 else { return (0, 0) }
        return (
            Double(totals.read >= previousRead ? totals.read - previousRead : 0) / duration,
            Double(totals.write >= previousWritten ? totals.write - previousWritten : 0) / duration
        )
    }

    private func totalsFromRegistry() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            totalRead += (property["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            totalWrite += (property["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (totalRead, totalWrite)
    }
}
