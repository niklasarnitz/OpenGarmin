import SwiftUI
import GarminModels
import GarminSession

struct DeviceView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage("feature.weather") private var weatherOn = true
    @AppStorage("feature.calendar") private var calendarOn = true
    @AppStorage("feature.notifications") private var notificationsOn = true
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Group {
                if let watch = app.watch.pairedWatch {
                    content(watch)
                } else {
                    ContentUnavailableView("No watch paired", systemImage: "applewatch.slash",
                                           description: Text("Pair a Garmin watch to see its status and settings."))
                }
            }
            .navigationTitle("Device")
        }
    }

    private func content(_ watch: PairedWatch) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                faceCard(watch)
                connection(watch)
                profile
                features
                information(watch)
                Button("Forget watch", systemImage: "trash", role: .destructive) { confirmForget = true }
                    .buttonStyle(.glass)
                    .padding(.top, 8)
            }
            .padding()
        }
        .background(Color.canvas.ignoresSafeArea())
        .confirmationDialog("Forget \(Formatting.deviceName(watch.catalogID))?", isPresented: $confirmForget,
                            titleVisibility: .visible) {
            Button("Forget watch", role: .destructive) { Task { await app.watch.forget() } }
        } message: {
            Text("OpenGarmin stops syncing with this watch. You can pair it again later.")
        }
    }

    private func faceCard(_ watch: PairedWatch) -> some View {
        let percent = app.watch.battery?.percent ?? 0
        let charging = app.watch.battery?.isCharging == true
        return VStack(spacing: 18) {
            ZStack {
                RingGauge(progress: Double(percent) / 100, tint: percent > 20 ? Palette.lichen : Palette.ember, lineWidth: 18)
                VStack(spacing: 4) {
                    MetricFigure(value: "\(percent)", unit: "%", size: 58)
                    Label(charging ? "Charging" : "Battery", systemImage: charging ? "bolt.fill" : "battery.50percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)

            VStack(spacing: 6) {
                Text(Formatting.deviceName(watch.catalogID))
                    .font(.screenTitle)
                Text(watch.info?.deviceModel ?? watch.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                WatchStatusPill(state: app.watch.state, battery: nil)
                    .padding(.top, 6)
            }
        }
        .tile()
    }

    private func connection(_ watch: PairedWatch) -> some View {
        MetricTile("Connection", symbol: "antenna.radiowaves.left.and.right", tint: Palette.glacier) {
            LabeledContent("Last sync", value: Formatting.lastSeen(watch.lastSync))
            LabeledContent("State", value: app.watch.state.label)
            HStack(spacing: 10) {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await app.watch.syncNow() }
                }
                .buttonStyle(.glassProminent)
                .disabled(app.watch.state.isSyncing)
                Button("Find watch", systemImage: "location.magnifyingglass") {
                    Task { try? await app.watch.findMyWatch() }
                }
                .buttonStyle(.glass)
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await app.watch.reconnect() }
                }
                .buttonStyle(.glass)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }
    }

    private var profile: some View {
        MetricTile("Profile", symbol: "person.crop.circle.fill", tint: Palette.dusk) {
            NavigationLink {
                ProfileEditorView()
            } label: {
                Label("Edit profile and send to watch", systemImage: "pencil")
            }
        }
    }

    private var features: some View {
        MetricTile("Phone features", symbol: "square.stack.3d.up.fill", tint: Palette.lichen) {
            Toggle("Weather", systemImage: "cloud.sun.fill", isOn: $weatherOn)
            Toggle("Calendar", systemImage: "calendar", isOn: $calendarOn)
            Toggle("Notifications", systemImage: "bell.fill", isOn: $notificationsOn)
            Text("Notifications reach the watch through iOS. Turn on Share System Notifications for the watch in Settings, Bluetooth.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onChange(of: weatherOn) { _, on in
            if on { Task { try? await PhoneSync.pushWeather(to: app.watch) } }
        }
        .onChange(of: calendarOn) { _, on in
            if on { Task { try? await PhoneSync.pushCalendar(to: app.watch) } }
        }
    }

    private func information(_ watch: PairedWatch) -> some View {
        MetricTile("Watch", symbol: "info.circle.fill", tint: .secondary) {
            LabeledContent("Model", value: watch.info?.deviceModel ?? Formatting.deviceName(watch.catalogID))
            LabeledContent("Software", value: watch.info?.softwareVersionString ?? "–")
            LabeledContent("Protocol", value: watch.info.map { "\($0.protocolVersion)" } ?? "–")
            Text("Features")
                .font(.tileTitle)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(watch.capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { capability in
                    Text(Formatting.capability(capability))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.glacier.opacity(0.15), in: .capsule)
                }
            }
        }
    }
}
