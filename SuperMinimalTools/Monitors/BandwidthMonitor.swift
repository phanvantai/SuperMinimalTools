//
//  BandwidthMonitor.swift
//  SuperMinimalTools
//

import Foundation

/// A single bandwidth measurement, in bytes per second.
nonisolated struct BandwidthReading: Sendable {
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
}

/// Turns cumulative network-interface byte counters into per-second rates.
@MainActor
final class BandwidthMonitor {

    private var previousTotals: (received: UInt64, sent: UInt64)?
    private var previousSampleTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// Returns nil on the first call (no previous sample to diff against).
    func sample() -> BandwidthReading? {
        guard let totals = Self.interfaceByteTotals() else { return nil }
        let now = clock.now
        defer {
            previousTotals = totals
            previousSampleTime = now
        }
        guard let previous = previousTotals, let previousTime = previousSampleTime else { return nil }
        let elapsed = previousTime.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return Self.rate(previous: previous, current: totals, elapsedSeconds: seconds)
    }

    /// Pure delta math, separated out for testing.
    nonisolated static func rate(
        previous: (received: UInt64, sent: UInt64),
        current: (received: UInt64, sent: UInt64),
        elapsedSeconds: Double
    ) -> BandwidthReading? {
        guard elapsedSeconds > 0 else { return nil }
        // The kernel counters are 32-bit and can wrap or reset (interface
        // re-attach); treat a backwards jump as a zero-rate tick rather than
        // producing a huge bogus spike.
        let received = current.received >= previous.received ? current.received - previous.received : 0
        let sent = current.sent >= previous.sent ? current.sent - previous.sent : 0
        return BandwidthReading(
            downloadBytesPerSecond: Double(received) / elapsedSeconds,
            uploadBytesPerSecond: Double(sent) / elapsedSeconds
        )
    }

    /// Sums ifi_ibytes / ifi_obytes over the physical (en*) interfaces.
    nonisolated private static func interfaceByteTotals() -> (received: UInt64, sent: UInt64)? {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(addressList) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer?.pointee {
            defer { pointer = interface.ifa_next }
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let dataPointer = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received &+= UInt64(data.ifi_ibytes)
            sent &+= UInt64(data.ifi_obytes)
        }
        return (received, sent)
    }
}
