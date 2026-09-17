//
//  CPUTemperatureReader.swift
//  SuperMinimalTools
//

import Foundation

/// Reads the CPU die temperature on Apple Silicon.
///
/// Primary source: the SMC "Tp…" float keys — the per-cluster CPU die
/// temperatures. Their average is what the Stats app shows by default, so our
/// value matches other monitoring tools. Fallback: IOHID thermal sensors
/// (cooler "PMU tdie" values, better than nothing). If neither source is
/// available (sandboxed build, future OS change), `read()` returns nil and
/// the UI shows "--".
nonisolated final class CPUTemperatureReader {

    private let smc: SMCClient?
    private let cpuDieKeys: [String]
    private let hidSensors: HIDThermalSensors?

    init?() {
        let smc = SMCClient()
        let cpuDieKeys = smc?.keys(withPrefix: "Tp") ?? []
        let hidSensors = HIDThermalSensors()
        guard (smc != nil && !cpuDieKeys.isEmpty) || hidSensors != nil else { return nil }
        self.smc = smc
        self.cpuDieKeys = cpuDieKeys
        self.hidSensors = hidSensors
    }

    /// Average CPU die temperature in °C, or nil if unavailable.
    func read() -> Double? {
        if let smc, !cpuDieKeys.isEmpty {
            let values = cpuDieKeys.compactMap { smc.floatValue(key: $0) }.filter { $0 > 10 && $0 < 130 }
            if !values.isEmpty {
                return values.reduce(0, +) / Double(values.count)
            }
        }
        return hidSensors?.hottestCPUTemperature()
    }
}

/// Fallback source: IOHIDEventSystemClient thermal sensors, resolved at
/// runtime via dlsym so nothing private is linked directly.
nonisolated final class HIDThermalSensors {

    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef?) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef?, Int32) -> Double

    // IOHIDEventTypes.h: kIOHIDEventTypeTemperature = 15; the value field is (type << 16).
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let client: CFTypeRef
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloatValue: GetFloatValue

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }

        guard let createClient = symbol("IOHIDEventSystemClientCreate", as: CreateClient.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloatValue = symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self),
              let client = createClient(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        // Thermal sensor services advertise Apple vendor usage page 0xff00, usage 5.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(client, matching)

        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloatValue = getFloatValue
    }

    /// Hottest CPU sensor in °C, or nil if unavailable.
    func hottestCPUTemperature() -> Double? {
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        var cpuReadings: [Double] = []
        var allReadings: [Double] = []
        for service in services {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let celsius = getFloatValue(event, Self.temperatureField)
            guard celsius > 0, celsius < 130 else { continue }
            allReadings.append(celsius)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            if Self.isCPUSensor(name) {
                cpuReadings.append(celsius)
            }
        }
        // Prefer CPU-specific sensors; fall back to all thermal sensors so we
        // still show something useful on chips with unexpected sensor names.
        let readings = cpuReadings.isEmpty ? allReadings : cpuReadings
        return readings.max()
    }

    /// Sensor names differ per chip generation (M1: "PMU tdie…", M2+: "pACC/eACC
    /// MTR Temp Sensor…"), so match generically instead of hardcoding names.
    static func isCPUSensor(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.contains("tdie")
            || lowercased.contains("cpu")
            || (lowercased.contains("acc") && lowercased.contains("mtr"))
    }
}
