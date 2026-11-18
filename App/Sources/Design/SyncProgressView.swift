import SwiftUI
import GarminSession

/// Sync progress: which file of how many, the overall bar, and a bar for the file downloading now, so a slow
/// transfer visibly moves. Shows nothing while no sync runs.
struct SyncProgressView: View {
    let state: WatchConnectionState
    let file: FileTransferProgress?

    var body: some View {
        if case let .syncing(progress, detail) = state {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress) {
                    Text(detail)
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.opacity)
                }
                .tint(Palette.blaze)
                if let file {
                    fileBar(file)
                }
            }
            .animation(.smooth, value: file)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func fileBar(_ file: FileTransferProgress) -> some View {
        if let fraction = file.fraction {
            ProgressView(value: fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(Self.caption(file, fraction: fraction))
            }
            .tint(Palette.glacier)
        } else {
            // Size unknown: an indeterminate bar, with the received bytes counting up underneath.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: nil as Double?)
                    .progressViewStyle(.linear)
                    .tint(Palette.glacier)
                Text(Self.bytes(file.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private static func caption(_ file: FileTransferProgress, fraction: Double) -> String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        guard let total = file.totalBytes else { return percent }
        return "\(bytes(file.bytes)) of \(bytes(total)) · \(percent)"
    }

    private static func bytes(_ count: Int) -> String {
        Int64(count).formatted(.byteCount(style: .file))
    }
}

#Preview {
    VStack(spacing: 24) {
        SyncProgressView(state: .syncing(progress: 3.0 / 9, detail: "Downloading activity 3 of 9"),
                         file: FileTransferProgress(bytes: 48_200, totalBytes: 131_072))
        SyncProgressView(state: .syncing(progress: 3.0 / 9, detail: "Downloading activity 3 of 9"),
                         file: FileTransferProgress(bytes: 48_200, totalBytes: nil))
    }
    .padding()
}
