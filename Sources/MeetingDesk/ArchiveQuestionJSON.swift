import Foundation

/// Foundation's JSON parser silently keeps one value for a duplicate object key. Reject
/// that ambiguity before interpreting model evidence, including escaped duplicate keys.
enum ArchiveQuestionJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveQuestionFailure.invalidResponse
        }
        var scanner = Scanner(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.offset == scanner.bytes.count else { throw ArchiveQuestionFailure.invalidResponse }
        return value
    }

    private struct Scanner {
        let bytes: [UInt8]
        var offset = 0

        mutating func whitespace() {
            while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }

        mutating func value(depth: Int) throws {
            guard depth <= 12 else { throw ArchiveQuestionFailure.invalidResponse }
            whitespace()
            guard offset < bytes.count else { throw ArchiveQuestionFailure.invalidResponse }
            switch bytes[offset] {
            case 123: // object
                offset += 1; whitespace()
                var keys: Set<String> = []
                if consume(125) { return }
                while true {
                    whitespace()
                    let token = try string()
                    var wrapped = Data([91]); wrapped.append(contentsOf: token); wrapped.append(93)
                    guard let key = (try? JSONSerialization.jsonObject(with: wrapped) as? [String])?.first,
                          keys.insert(key).inserted else { throw ArchiveQuestionFailure.invalidResponse }
                    whitespace(); guard consume(58) else { throw ArchiveQuestionFailure.invalidResponse }
                    try value(depth: depth + 1); whitespace()
                    if consume(125) { return }
                    guard consume(44) else { throw ArchiveQuestionFailure.invalidResponse }
                }
            case 91: // array
                offset += 1; whitespace()
                if consume(93) { return }
                while true {
                    try value(depth: depth + 1); whitespace()
                    if consume(93) { return }
                    guard consume(44) else { throw ArchiveQuestionFailure.invalidResponse }
                }
            case 34: _ = try string()
            default:
                let start = offset
                while offset < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
                guard offset > start else { throw ArchiveQuestionFailure.invalidResponse }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1; return true
        }

        mutating func string() throws -> ArraySlice<UInt8> {
            let start = offset
            guard consume(34) else { throw ArchiveQuestionFailure.invalidResponse }
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if byte == 34 { return bytes[start..<offset] }
                if byte == 92 {
                    guard offset < bytes.count else { throw ArchiveQuestionFailure.invalidResponse }
                    offset += 1
                }
            }
            throw ArchiveQuestionFailure.invalidResponse
        }
    }
}
