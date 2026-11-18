import SwiftUI
import WidgetKit

struct SyncLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(Palette.blaze)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Syncing \(context.attributes.watchName)")
                        .font(.headline)
                    Text(context.state.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: context.state.progress)
                        .tint(Palette.blaze)
                }
                Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.figure(26))
                    .monospacedDigit()
            }
            .padding()
            .activityBackgroundTint(Color.canvas)
            .activitySystemActionForegroundColor(Palette.blaze)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Palette.blaze)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView(value: context.state.progress)
                            .tint(Palette.blaze)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Palette.blaze)
            } compactTrailing: {
                Text(context.state.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Palette.blaze)
            }
        }
    }
}
