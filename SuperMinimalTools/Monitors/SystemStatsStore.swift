//
//  SystemStatsStore.swift
//  SuperMinimalTools
//

import Foundation
import Observation

/// Drives the status-bar readout: samples the monitors every 2 seconds and
/// persists the user's show/hide preferences.
@Observable
@MainActor
final class SystemStatsStore {

    private(set) var cpuTemperature: Double?
    private(set) var bandwidth: BandwidthReading?

    var showsCPUTemperature: Bool {
        didSet { UserDefaults.standard.set(showsCPUTemperature, forKey: Self.showsCPUTemperatureKey) }
    }
    var showsBandwidth: Bool {
        didSet { UserDefaults.standard.set(showsBandwidth, forKey: Self.showsBandwidthKey) }
    }

    private static let showsCPUTemperatureKey = "showsCPUTemperature"
    private static let showsBandwidthKey = "showsBandwidth"

    private let bandwidthMonitor = BandwidthMonitor()
    private let temperatureReader = CPUTemperatureReader()
    private var monitorTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        showsCPUTemperature = defaults.object(forKey: Self.showsCPUTemperatureKey) as? Bool ?? true
        showsBandwidth = defaults.object(forKey: Self.showsBandwidthKey) as? Bool ?? true
        start()
    }

    /// Compact text for the menu bar; empty when both metrics are hidden.
    var statusBarText: String {
        var parts: [String] = []
        if showsCPUTemperature {
            if let cpuTemperature {
                parts.append("\(Int(cpuTemperature.rounded()))°")
            } else {
                parts.append("--°")
            }
        }
        if showsBandwidth {
            let reading = bandwidth ?? BandwidthReading(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)
            parts.append("↓\(ByteFormatting.compactRate(reading.downloadBytesPerSecond)) ↑\(ByteFormatting.compactRate(reading.uploadBytesPerSecond))")
        }
        return parts.joined(separator: "  ")
    }

    private func start() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func tick() {
        if let reading = bandwidthMonitor.sample() {
            bandwidth = reading
        }
        cpuTemperature = temperatureReader?.read()
    }
}
