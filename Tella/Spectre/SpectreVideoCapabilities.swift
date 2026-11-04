//
//  SPECTRE Capture — runtime detection of video capabilities (Phase 3).
//  Nothing is promised by default: options are offered only if the device
//  reports them. Applying them is OFF by default (Tella's `.high` preset is
//  kept) until the transfer chain has been validated on real devices.
//

import AVFoundation

struct SpectreVideoMode: Hashable, Codable {
    var width: Int32
    var height: Int32
    var fps: Double
    var label: String { "\(height >= 2160 ? "4K" : "\(height)p") \(Int(fps)) i/s" }
}

struct SpectreVideoCapabilities {
    var modes: [SpectreVideoMode]
    var hasUltraWide: Bool
    var stabilizationModes: [AVCaptureVideoStabilizationMode]

    static func detect(position: AVCaptureDevice.Position = .back) -> SpectreVideoCapabilities {
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: position)
        var modes = Set<SpectreVideoMode>()
        var stab = Set<Int>()
        for f in wide?.formats ?? [] {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard [(1920, 1080), (3840, 2160)].contains(where: { $0.0 == d.width && $0.1 == d.height }) else { continue }
            for r in f.videoSupportedFrameRateRanges {
                for fps in [30.0, 60.0] where r.minFrameRate <= fps && fps <= r.maxFrameRate {
                    modes.insert(SpectreVideoMode(width: d.width, height: d.height, fps: fps))
                }
            }
            for m in [AVCaptureVideoStabilizationMode.standard, .cinematic, .cinematicExtended] where f.isVideoStabilizationModeSupported(m) {
                stab.insert(m.rawValue)
            }
        }
        return SpectreVideoCapabilities(
            modes: modes.sorted { ($0.height, $0.fps) < ($1.height, $1.fps) },
            hasUltraWide: ultra != nil,
            stabilizationModes: stab.sorted().compactMap(AVCaptureVideoStabilizationMode.init(rawValue:)))
    }
}

enum SpectreVideoSettings {
    private static let key = "spectre.video.mode"
    /// nil = keep Tella's default (.high preset). Stored in UserDefaults (not sensitive).
    static var selectedMode: SpectreVideoMode? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(SpectreVideoMode.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key) }
    }

    /// Applies the selected mode to the active device, if supported. Returns false otherwise
    /// (the camera keeps working with Tella's default configuration).
    @discardableResult
    static func applyIfSelected(to device: AVCaptureDevice, connection: AVCaptureConnection?) -> Bool {
        guard let mode = selectedMode else { return false }
        let match = device.formats.first { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == mode.width && d.height == mode.height &&
                f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= mode.fps && mode.fps <= $0.maxFrameRate }
        }
        guard let format = match, (try? device.lockForConfiguration()) != nil else { return false }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        if let c = connection, c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
        return true
    }
}
