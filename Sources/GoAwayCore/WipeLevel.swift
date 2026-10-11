import Foundation

public enum WipePass: Equatable, Sendable {
    case constant(UInt8)
    case repeating([UInt8])
    case random
}

public enum WipeLevel: String, CaseIterable, Identifiable, Sendable {
    case simple
    case doe
    case dod
    case gutmann

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simple: return "Simple (1x)"
        case .doe: return "DoE (3x)"
        case .dod: return "DoD (7x)"
        case .gutmann: return "Gutmann (35x)"
        }
    }

    public var summary: String {
        switch self {
        case .simple: return "One pass of random data. Used automatically on SSDs."
        case .doe: return "Two random passes, then 0x00."
        case .dod: return "Seven U.S. DoD-style passes. Default on hard drives."
        case .gutmann: return "Thirty-five-pass Gutmann pattern. Slowest, for magnetic media."
        }
    }

    public var passCount: Int { passes.count }

    public var passes: [WipePass] {
        switch self {
        case .simple:
            return [.random]
        case .doe:
            return [.random, .random, .constant(0x00)]
        case .dod:
            return [
                .constant(0xF6),
                .constant(0x00),
                .constant(0xFF),
                .random,
                .constant(0x00),
                .constant(0xFF),
                .random
            ]
        case .gutmann:
            return Self.gutmannPasses
        }
    }

    /// Public 35-pass Gutmann sequence.
    public static let gutmannPasses: [WipePass] = {
        var passes: [WipePass] = [.random, .random, .random, .random]
        passes.append(.constant(0x55))
        passes.append(.constant(0xAA))
        passes.append(.repeating([0x92, 0x49, 0x24]))
        passes.append(.repeating([0x49, 0x24, 0x92]))
        passes.append(.repeating([0x24, 0x92, 0x49]))
        for value in stride(from: UInt8(0x00), through: 0xFF, by: 0x11) {
            passes.append(.constant(value))
        }
        passes.append(.repeating([0x92, 0x49, 0x24]))
        passes.append(.repeating([0x49, 0x24, 0x92]))
        passes.append(.repeating([0x24, 0x92, 0x49]))
        passes.append(.repeating([0x6D, 0xB6, 0xDB]))
        passes.append(.repeating([0xB6, 0xDB, 0x6D]))
        passes.append(.repeating([0xDB, 0x6D, 0xB6]))
        passes.append(contentsOf: [.random, .random, .random, .random])
        return passes
    }()

    public static func effectivePasses(level: WipeLevel, isSSD: Bool, respectSSD: Bool) -> [WipePass] {
        if isSSD && respectSSD {
            return WipeLevel.simple.passes
        }
        return level.passes
    }
}
