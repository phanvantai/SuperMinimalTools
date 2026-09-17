//
//  ByteFormatting.swift
//  SuperMinimalTools
//

import Foundation

nonisolated enum ByteFormatting {

    /// Compact rate for the status bar: "0K", "873K", "1.4M", "2.1G".
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let kilobytes = max(0, bytesPerSecond) / 1024
        if kilobytes < 999.5 {
            return "\(Int(kilobytes.rounded()))K"
        }
        let megabytes = kilobytes / 1024
        if megabytes < 99.95 {
            return String(format: "%.1fM", megabytes)
        }
        if megabytes < 999.5 {
            return "\(Int(megabytes.rounded()))M"
        }
        return String(format: "%.1fG", megabytes / 1024)
    }

    /// Human-readable size, e.g. "18.2 GB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Full rate with unit, e.g. "1.4 MB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        size(Int64(max(0, bytesPerSecond))) + "/s"
    }
}
