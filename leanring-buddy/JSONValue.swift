//
//  JSONValue.swift
//  leanring-buddy
//
//  A JSON value read at a boundary and checked before the app trusts it. The voice command path, the Worker replies, and
//  every theme.json use it, and the Quick Look extension compiles this file too, since `ClickyTheme.parse` reads one.
//

import Foundation

/// A JSON value at the boundaries Clicky crosses: the page, the Worker, the debug MCP endpoint, and a theme.json.
nonisolated enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let boolValue): try container.encode(boolValue)
        case .number(let numberValue): try container.encode(numberValue)
        case .string(let stringValue): try container.encode(stringValue)
        case .array(let arrayValue): try container.encode(arrayValue)
        case .object(let objectValue): try container.encode(objectValue)
        }
    }

    /// WebKit and JSONSerialization hand back Foundation objects typed as Any. Nil for anything that is not JSON.
    init?(foundationValue: Any) {
        switch foundationValue {
        case is NSNull:
            self = .null
        case let numberValue as NSNumber:
            // A Foundation Bool is an NSNumber too, and only its type ID tells them apart.
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                self = .bool(numberValue.boolValue)
            } else {
                self = .number(numberValue.doubleValue)
            }
        case let stringValue as String:
            self = .string(stringValue)
        case let arrayValue as [Any]:
            var convertedValues: [JSONValue] = []
            for element in arrayValue {
                guard let convertedValue = JSONValue(foundationValue: element) else { return nil }
                convertedValues.append(convertedValue)
            }
            self = .array(convertedValues)
        case let dictionaryValue as [String: Any]:
            var convertedObject: [String: JSONValue] = [:]
            for (key, element) in dictionaryValue {
                guard let convertedValue = JSONValue(foundationValue: element) else { return nil }
                convertedObject[key] = convertedValue
            }
            self = .object(convertedObject)
        default:
            return nil
        }
    }

    /// The Foundation form WebKit's callAsyncJavaScript arguments take.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let boolValue): return boolValue
        case .number(let numberValue): return numberValue
        case .string(let stringValue): return stringValue
        case .array(let arrayValue): return arrayValue.map(\.foundationValue)
        case .object(let objectValue): return objectValue.mapValues(\.foundationValue)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let objectValue) = self { return objectValue[key] }
        return nil
    }

    var numberValue: Double? {
        if case .number(let numberValue) = self { return numberValue }
        return nil
    }

    var stringValue: String? {
        if case .string(let stringValue) = self { return stringValue }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let boolValue) = self { return boolValue }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let arrayValue) = self { return arrayValue }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let objectValue) = self { return objectValue }
        return nil
    }

    /// One line of JSON with sorted keys, for logs, tool results, and the model's recent actions.
    var compactJSONText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encodedData = try? encoder.encode(self) else { return "null" }
        return String(decoding: encodedData, as: UTF8.self)
    }
}
