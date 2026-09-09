import Darwin
import Foundation
import IOKit

struct NetworkReading {
    let download: Double
    let upload: Double
    let availability: ReadingAvailability
}

final class NetworkCollector {
    private var previousReceived: UInt64?
    private var previousSent: UInt64?
    private var previousTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func read() -> NetworkReading {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let firstAddress = addressPointer else {
            // A failed interface enumeration must not touch the baseline, so
            // recovery computes the rate across the whole failed gap.
            return NetworkReading(download: 0, upload: 0, availability: .unavailable)
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

        let hadBaseline = previousReceived != nil && previousSent != nil && previousTime != nil
        let now = clock.now
        defer {
            previousReceived = received
            previousSent = sent
            previousTime = now
        }
        guard hadBaseline else {
            return NetworkReading(download: 0, upload: 0, availability: .warmingUp)
        }
        guard let previousReceived, let previousSent, let previousTime else {
            return NetworkReading(download: 0, upload: 0, availability: .unavailable)
        }
        let duration = Double(previousTime.duration(to: now).components.seconds)
            + Double(previousTime.duration(to: now).components.attoseconds) / 1e18
        guard duration > 0 else {
            return NetworkReading(download: 0, upload: 0, availability: .unavailable)
        }
        return NetworkReading(
            download: Double(received >= previousReceived ? received - previousReceived : 0) / duration,
            upload: Double(sent >= previousSent ? sent - previousSent : 0) / duration,
            availability: .available
        )
    }
}

struct DiskReading {
    let read: Double
    let write: Double
    let availability: ReadingAvailability
}

final class DiskCollector {
    private var previousRead: UInt64?
    private var previousWritten: UInt64?
    private var previousTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    func read() -> DiskReading {
        let totals = totalsFromRegistry()
        guard let totals else {
            // Preserve the last successful baseline: installing a zero baseline
            // here would fabricate a false spike from the full counter sum once
            // the registry read recovers.
            return DiskReading(read: 0, write: 0, availability: .unavailable)
        }
        let hadBaseline = previousRead != nil && previousWritten != nil && previousTime != nil
        let now = clock.now
        defer {
            previousRead = totals.read
            previousWritten = totals.write
            previousTime = now
        }
        guard hadBaseline else { return DiskReading(read: 0, write: 0, availability: .warmingUp) }
        guard let previousRead, let previousWritten, let previousTime else {
            return DiskReading(read: 0, write: 0, availability: .unavailable)
        }
        let elapsed = previousTime.duration(to: now)
        let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard duration > 0 else { return DiskReading(read: 0, write: 0, availability: .unavailable) }
        return DiskReading(
            read: Double(totals.read >= previousRead ? totals.read - previousRead : 0) / duration,
            write: Double(totals.write >= previousWritten ? totals.write - previousWritten : 0) / duration,
            availability: .available
        )
    }

    private func totalsFromRegistry() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
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

struct DiskCapacityReading {
    let capacityBytes: UInt64?
    let availableBytes: UInt64?
    let availability: ReadingAvailability
}

final class DiskCapacityCollector {
    private var cached: (capacityBytes: UInt64?, availableBytes: UInt64?) = (nil, nil)
    private var cachedAvailability: ReadingAvailability = .unavailable
    private let clock = ContinuousClock()
    private var nextRead: ContinuousClock.Instant?

    func read() -> DiskCapacityReading {
        let now = clock.now
        guard nextRead.map({ now >= $0 }) ?? true else {
            return DiskCapacityReading(
                capacityBytes: cached.capacityBytes,
                availableBytes: cached.availableBytes,
                availability: cachedAvailability
            )
        }
        nextRead = now.advanced(by: .seconds(30))

        // The root volume shares its APFS container with the Data volume, so a
        // single root read describes the capacity users see in Finder. Available
        // space excludes purgeable files, matching the volume's raw free space.
        var stats = statfs()
        guard let path = ("/" as NSString).utf8String,
              statfs(path, &stats) == 0,
              stats.f_bsize > 0
        else {
            cached = (nil, nil)
            cachedAvailability = .unavailable
            return DiskCapacityReading(capacityBytes: nil, availableBytes: nil, availability: .unavailable)
        }
        let blockSize = UInt64(stats.f_bsize)
        let capacity = UInt64(stats.f_blocks) * blockSize
        let available = UInt64(stats.f_bavail) * blockSize
        guard capacity > 0, available <= capacity else {
            cached = (nil, nil)
            cachedAvailability = .unavailable
            return DiskCapacityReading(capacityBytes: nil, availableBytes: nil, availability: .unavailable)
        }
        cached = (capacity, available)
        cachedAvailability = .available
        return DiskCapacityReading(capacityBytes: capacity, availableBytes: available, availability: .available)
    }
}
