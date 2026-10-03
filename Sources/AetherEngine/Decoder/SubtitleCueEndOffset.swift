enum SubtitleCueEndOffset {
    static func resolve(decodedMilliseconds: UInt32, packetDuration: Int64?, timeBaseSeconds: Double,
                        isASS: Bool, fallback: Double) -> Double? {
        if decodedMilliseconds > 0 {
            return Double(decodedMilliseconds) / 1_000
        }
        if let packetDuration, packetDuration > 0 {
            return Double(packetDuration) * timeBaseSeconds
        }
        // ASS/SSA zero-length events are authored as instant states. A synthetic
        // five-second duration turns their final animation fragment into a ghost.
        return isASS ? nil : fallback
    }
}
