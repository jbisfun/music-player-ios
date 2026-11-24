import AVFoundation

/// The Android Equalizer effect as an AVAudioUnitEQ: the 5 bands, ±15 dB range and the
/// presets of AOSP's bundled equalizer (EffectEqualizer.cpp), in millibels like upstream.
enum Equalizer {
    /// Center frequencies in Hz.
    static let bands: [Float] = [60, 230, 910, 3600, 14000]
    static let minLevel = -1500
    static let maxLevel = 1500
    static let custom = -1

    static let presets: [(name: String, levels: [Int])] = [
        ("Normal", [300, 0, 0, 0, 300]),
        ("Classical", [500, 300, -200, 400, 400]),
        ("Dance", [600, 0, 200, 400, 100]),
        ("Flat", [0, 0, 0, 0, 0]),
        ("Folk", [300, 0, 0, 200, -100]),
        ("Heavy Metal", [400, 100, 900, 300, 0]),
        ("Hip Hop", [500, 300, 0, 100, 300]),
        ("Jazz", [400, 200, -200, 200, 500]),
        ("Pop", [-100, 200, 500, 100, -200]),
        ("Rock", [500, 300, -100, 300, 500]),
    ]

    /// Band levels (millibels) for the configured preset or the custom bands.
    static func levels(_ config: Config) -> [Int] {
        if config.equalizerPreset != custom, presets.indices.contains(config.equalizerPreset) {
            return presets[config.equalizerPreset].levels
        }
        return bands.indices.map { i in
            // stored as progress from the lowest level; missing bands sit in the middle
            (config.equalizerBands[i] ?? (maxLevel - minLevel) / 2) + minLevel
        }
    }

    static func apply(to eq: AVAudioUnitEQ, config: Config) {
        let lv = levels(config)
        for (i, band) in eq.bands.enumerated() where i < bands.count {
            band.filterType = i == 0 ? .lowShelf : (i == bands.count - 1 ? .highShelf : .parametric)
            band.frequency = bands[i]
            band.bandwidth = 1.5
            band.gain = Float(lv[i]) / 100
            band.bypass = false
        }
        eq.bypass = false
    }

    /// formatFrequency(): "60 Hz", "3.6 kHz".
    static func label(_ hz: Float) -> String {
        hz >= 1000 ? String(format: "%g kHz", (Double(hz) / 1000 * 10).rounded() / 10) : String(format: "%g Hz", Double(hz))
    }
}
