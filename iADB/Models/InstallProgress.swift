import Foundation

/// Which half of an APK installation is running.
///
/// The upload half is measurable because ADB's SYNC service reports every
/// 64 KiB chunk. `pm install` only reports its final exit status, so the
/// device half is drawn as indeterminate work instead of a fake percentage.
enum InstallPhase: Equatable, Sendable {
    case uploading
    case installing
    case installed

    /// English source string, localized through `Localizable.strings`.
    var title: String {
        switch self {
        case .uploading: "Uploading"
        case .installing: "Installing on device"
        case .installed: "Installed"
        }
    }

    /// False once the package is on the device, which hides the cancel action.
    var isInFlight: Bool {
        self != .installed
    }
}

/// Everything the install banner needs to render one APK installation.
struct InstallProgress: Equatable, Sendable {
    let fileName: String
    var phase: InstallPhase
    var completedUnits: Int64
    var totalUnits: Int64?

    init(
        fileName: String,
        phase: InstallPhase = .uploading,
        completedUnits: Int64 = 0,
        totalUnits: Int64? = nil
    ) {
        self.fileName = fileName
        self.phase = phase
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
    }

    /// Upload completion clamped to `0...1`, or `nil` when the size is unknown.
    var fraction: Double? {
        guard let totalUnits, totalUnits > 0 else { return nil }
        return min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
    }

    /// Rounded percentage for the corner readout.
    var percent: Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    /// Byte counter for the upload phase, or `nil` while the device installs.
    ///
    /// The `sent / total` layout stays language neutral on purpose: only the
    /// numbers change, so the line needs no localization entry.
    var uploadDetail: String? {
        guard phase == .uploading else { return nil }
        let sent = Self.byteText(completedUnits)
        guard let totalUnits, totalUnits > 0 else { return sent }
        return "\(sent) / \(Self.byteText(totalUnits))"
    }

    /// Deterministic, locale-independent size text: `1.4 MB`, `812 KB`, `64 B`.
    static func byteText(_ units: Int64) -> String {
        let value = Double(max(units, 0))
        if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        }
        if value >= 1_024 {
            return String(format: "%.0f KB", value / 1_024)
        }
        return "\(Int(value)) B"
    }
}

/// Keeps SwiftUI updates bounded while a large APK streams to the device.
///
/// A 200 MB package produces thousands of 64 KiB callbacks. Forwarding every
/// one of them would rebuild the banner far more often than the screen can
/// show, so samples are only reported when the rounded percentage moves.
/// When the total size is unknown there is no percentage to compare, and the
/// throttle falls back to one update per mebibyte.
struct InstallProgressThrottle {
    private var lastPercent: Int?
    private var lastReportedUnits: Int64?

    mutating func shouldReport(_ progress: TransferProgress) -> Bool {
        if let percent = progress.percent {
            guard percent != lastPercent else { return false }
            lastPercent = percent
            lastReportedUnits = progress.completedUnits
            return true
        }
        // Without a size there is no percentage to compare, so fall back to
        // one sample per mebibyte of progress.
        if let lastReportedUnits,
           progress.completedUnits - lastReportedUnits < 1_048_576 {
            return false
        }
        lastReportedUnits = progress.completedUnits
        return true
    }
}

extension TransferProgress {
    /// Rounded completion, or `nil` when the caller never learned the size.
    var percent: Int? {
        guard let totalUnits, totalUnits > 0 else { return nil }
        let ratio = min(max(Double(completedUnits) / Double(totalUnits), 0), 1)
        return Int((ratio * 100).rounded())
    }
}
