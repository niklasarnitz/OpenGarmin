import Foundation

// CONTRACT (owned by the integrator). FIT decoder agent implements `FitDecoder.decode`,
// extraction agent consumes these types. Do not change these signatures.

/// A decoded FIT value. Invalid (sentinel) values are already removed by the decoder (field omitted).
public enum FitValue: Sendable, Hashable {
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case bytes([UInt8])
    case array([FitValue])

    public var int: Int64? {
        switch self {
        case .int(let v): v
        case .uint(let v): Int64(exactly: v)
        case .double(let v): Int64(v)
        case .array(let a): a.first?.int
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let v): Double(v)
        case .uint(let v): Double(v)
        case .double(let v): v
        case .array(let a): a.first?.double
        default: nil
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

public struct FitMessage: Sendable, Hashable {
    /// FIT global message number (e.g. 20 = record, 18 = session, 55 = monitoring).
    public var globalNumber: UInt16
    /// Raw (unscaled) field values keyed by field definition number.
    public var fields: [UInt8: FitValue]
    /// Developer fields keyed by (developerDataIndex << 8 | fieldNumber).
    public var developerFields: [UInt16: FitValue]

    public init(globalNumber: UInt16, fields: [UInt8: FitValue], developerFields: [UInt16: FitValue] = [:]) {
        self.globalNumber = globalNumber
        self.fields = fields
        self.developerFields = developerFields
    }

    public subscript(field: UInt8) -> FitValue? { fields[field] }
}

public struct FitFile: Sendable, Hashable {
    public var protocolVersion: UInt8
    public var profileVersion: UInt16
    public var messages: [FitMessage]

    public init(protocolVersion: UInt8, profileVersion: UInt16, messages: [FitMessage]) {
        self.protocolVersion = protocolVersion
        self.profileVersion = profileVersion
        self.messages = messages
    }

    public func messages(_ globalNumber: UInt16) -> [FitMessage] { messages.filter { $0.globalNumber == globalNumber } }
}

public enum FitError: Error, Equatable {
    case invalidHeader
    case crcMismatch
    case truncated
    case missingDefinition(localType: UInt8)
}
