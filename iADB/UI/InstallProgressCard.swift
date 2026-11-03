import SwiftUI

/// Banner that visualises one APK installation from upload to `pm install`.
///
/// The upload half is a determinate bar driven by SYNC chunk reports. The
/// device half has no measurable output, so it switches to an indeterminate
/// sweep instead of inventing a percentage.
struct InstallProgressCard: View {
    let progress: InstallProgress
    let onCancel: () -> Void

    var body: some View {
        LabCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                InstallProgressBar(phase: progress.phase, fraction: progress.fraction)
                footer
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.raised, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: progress.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(progress.phase.title.ui)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailingReadout
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingReadout: some View {
        if progress.phase == .installed {
            EmptyView()
        } else if progress.phase == .uploading, let percent = progress.percent {
            Text(verbatim: "\(percent)%")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerText
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            if progress.phase.isInFlight {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.cream)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.raised, in: Capsule())
                        // The badge stays compact while the tappable area
                        // reaches the comfortable 44pt minimum.
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 44)
    }

    private var footerText: Text {
        switch progress.phase {
        case .uploading:
            if let detail = progress.uploadDetail {
                return Text(verbatim: detail)
            }
            return Text("Preparing the upload")
        case .installing:
            return Text("The device is unpacking the package")
        case .installed:
            return Text("Refreshing the package list")
        }
    }

    private var symbol: String {
        switch progress.phase {
        case .uploading: "arrow.up"
        case .installing: "shippingbox"
        case .installed: "checkmark"
        }
    }
}

/// Track plus fill: full for a finished install, determinate while uploading,
/// sweeping while the device works on its own.
private struct InstallProgressBar: View {
    let phase: InstallPhase
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                switch phase {
                case .installed:
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: width)
                case .uploading:
                    if let fraction {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(width * CGFloat(fraction), fraction > 0 ? 5 : 0))
                            .animation(.easeOut(duration: 0.18), value: fraction)
                    } else {
                        SweepBar(width: width)
                    }
                case .installing:
                    SweepBar(width: width)
                }
            }
        }
        .frame(height: 6)
    }
}

/// Owns its own animation state so the sweep restarts whenever the bar
/// appears, including the upload-to-install hand-off. A `@State` living on the
/// card would already be `true` by then, and the bar would sit still.
private struct SweepBar: View {
    let width: CGFloat

    @State private var leading = false

    var body: some View {
        Capsule()
            .fill(Theme.accent.opacity(0.85))
            .frame(width: width * 0.32)
            .offset(x: leading ? width * 0.68 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    leading = true
                }
            }
    }
}
