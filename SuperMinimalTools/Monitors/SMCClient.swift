//
//  SMCClient.swift
//  SuperMinimalTools
//

import Foundation
import IOKit

/// Minimal client for the AppleSMC user client, used to read temperature keys.
/// This is the same data source the Stats app uses for its CPU temperature,
/// so values match what users see in other monitoring tools.
nonisolated final class SMCClient {

    private static let kernelIndex: UInt32 = 2 // kSMCHandleYPCEvent

    private enum Command: UInt8 {
        case readKey = 5
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    // Layouts must match the kernel's SMCParamStruct (80 bytes) exactly.
    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private let connection: io_connect_t

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func fourCCString(_ value: UInt32) -> String {
        let characters = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                          UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: characters, encoding: .ascii) ?? ""
    }

    /// Total number of SMC keys on this machine.
    private var keyCount: Int {
        guard let value = readValue(key: "#KEY"), value.bytes.count >= 4 else { return 0 }
        let bytes = value.bytes
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    private func keyName(at index: Int) -> String? {
        var input = SMCParamStruct()
        input.data8 = Command.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        guard let output = call(&input) else { return nil }
        return Self.fourCCString(output.key)
    }

    private func readValue(key: String) -> (dataType: String, bytes: [UInt8])? {
        let keyCode = Self.fourCC(key)

        var infoInput = SMCParamStruct()
        infoInput.key = keyCode
        infoInput.data8 = Command.getKeyInfo.rawValue
        guard let info = call(&infoInput) else { return nil }

        var readInput = SMCParamStruct()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.data8 = Command.readKey.rawValue
        guard let output = call(&readInput) else { return nil }

        let size = min(Int(info.keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (Self.fourCCString(info.keyInfo.dataType), bytes)
    }

    /// Value of a key with SMC type "flt " (little-endian Float), e.g. temperatures.
    func floatValue(key: String) -> Double? {
        guard let value = readValue(key: key), value.dataType == "flt ", value.bytes.count >= 4 else { return nil }
        let bits = UInt32(value.bytes[0]) | UInt32(value.bytes[1]) << 8
            | UInt32(value.bytes[2]) << 16 | UInt32(value.bytes[3]) << 24
        return Double(Float(bitPattern: bits))
    }

    /// All key names starting with the given prefix (enumerated once; cache the result).
    func keys(withPrefix prefix: String) -> [String] {
        (0..<keyCount).compactMap { keyName(at: $0) }.filter { $0.hasPrefix(prefix) }
    }
}
