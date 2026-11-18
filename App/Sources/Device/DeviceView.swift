import SwiftUI
import GarminModels
import GarminSession

struct DeviceView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL
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
                if watch.capabilities.contains(.realtimeSettings) || app.watch.alarmSlots > 0 {
                    watchSettings(watch)
                }
                installs
                safety
                connectImport
                features
                notifications(watch)
                satelliteData
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
            SyncProgressView(state: app.watch.state, file: app.watch.fileProgress)
            NavigationLink {
                LiveView()
            } label: {
                Label("Live readings", systemImage: "waveform.path.ecg")
            }
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

    /// The settings the watch defines (when it has realtime settings), and the alarms the phone sends (when it takes them).
    private func watchSettings(_ watch: PairedWatch) -> some View {
        MetricTile("Watch settings", symbol: "gearshape.fill", tint: Palette.dusk) {
            if watch.capabilities.contains(.realtimeSettings) {
                NavigationLink {
                    WatchSettingsView(screenID: WatchSettingsScreen.rootID, fallbackTitle: "Watch settings")
                } label: {
                    Label("Display, alerts and activity tracking", systemImage: "slider.horizontal.3")
                }
            }
            if app.watch.alarmSlots > 0 {
                NavigationLink {
                    WatchAlarmsView()
                } label: {
                    Label("Alarms", systemImage: "alarm.fill")
                }
            }
        }
    }

    /// Garmin Connect history: signs in to the account and imports the activities and daily data it holds.
    @ViewBuilder
    private var connectImport: some View {
        if let service = app.watch as? GarminWatchService {
            MetricTile("Garmin Connect", symbol: "icloud.and.arrow.down", tint: Palette.glacier) {
                NavigationLink {
                    ConnectImportView(watch: service)
                } label: {
                    Label("Import history from Garmin Connect", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private var installs: some View {
        MetricTile("Apps and courses", symbol: "square.and.arrow.down.fill", tint: Palette.amber) {
            NavigationLink {
                InstallView()
            } label: {
                Label("Install apps and courses", systemImage: "square.and.arrow.down")
            }
        }
    }

    private var safety: some View {
        MetricTile("Safety", symbol: "shield.lefthalf.filled", tint: Palette.ember) {
            NavigationLink {
                EmergencyContactsView()
            } label: {
                Label("Emergency contacts", systemImage: "person.2.fill")
            }
        }
    }

    private var features: some View {
        MetricTile("Phone features", symbol: "square.stack.3d.up.fill", tint: Palette.lichen) {
            Toggle("Weather", systemImage: "cloud.sun.fill", isOn: $weatherOn)
            Toggle("Calendar", systemImage: "calendar", isOn: $calendarOn)
            if calendarOn {
                NavigationLink { CalendarSettingsView() } label: {
                    Label("Calendars and days ahead", systemImage: "list.bullet.rectangle")
                }
            }
            Toggle("Notifications", systemImage: "bell.fill", isOn: $notificationsOn)
        }
        .onChange(of: weatherOn) { _, on in
            if on { Task { try? await PhoneSync.pushWeather(to: app.watch) } }
        }
        .onChange(of: calendarOn) { _, on in
            Task {
                if on { _ = await CalendarSync.requestAccess() }
                try? await CalendarSync.push(to: app.watch)
            }
        }
    }

    /// iPhone notifications reach the watch through iOS (ANCS), which needs the bonded link and the system setting below.
    private func notifications(_ watch: PairedWatch) -> some View {
        MetricTile("Notifications", symbol: "bell.badge.fill", tint: Palette.blaze) {
            LabeledContent("Bonded") {
                Text(Self.isLinked(app.watch.state) ? "Connected" : "Not confirmed")
            }
            Text("iOS does not tell apps whether the watch is bonded. OpenGarmin counts it as bonded while the watch is connected, because the connection asks iOS to pair.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("To show iPhone notifications on the watch, open Settings, Bluetooth, \(Formatting.deviceName(watch.catalogID)), and turn on Share System Notifications.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
                Button("Send test", systemImage: "paperplane.fill") {
                    Task {
                        try? await app.watch.sendNotification(PhoneNotification(
                            id: Int(Date.now.timeIntervalSince1970), appIdentifier: "OpenGarmin",
                            title: "OpenGarmin test", body: "Notifications from OpenGarmin reach your watch.",
                            date: .now, category: .other
                        ))
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!Self.isLinked(app.watch.state))
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }
    }

    private static func isLinked(_ state: WatchConnectionState) -> Bool {
        switch state {
        case .connected, .syncing: true
        default: false
        }
    }

    /// The AGPS files the watch takes from the phone: each one's source, status and last download, and a refresh.
    @ViewBuilder
    private var satelliteData: some View {
        if let service = app.watch as? GarminWatchService {
            MetricTile("GPS satellite data", symbol: "location.fill", tint: Palette.amber) {
                ForEach(service.agps.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(entry.type.title, value: Self.agpsStatusText(entry.status))
                        LabeledContent("Last update", value: Formatting.lastSeen(entry.updatedAt))
                        TextField("Source URL", text: Binding(
                            get: { entry.url?.absoluteString ?? "" },
                            set: { service.agps.setURL(URL(string: $0), for: entry.type) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await service.agps.refresh(force: true) }
                }
                .buttonStyle(.glass)
                .disabled(service.agps.isRefreshing)
            }
        }
    }

    private static func agpsStatusText(_ status: AGPSStatus) -> String {
        switch status {
        case .missing: String(localized: "Missing")
        case .current: String(localized: "Current")
        case .expired: String(localized: "Expired")
        case let .failed(message): message
        }
    }

    private func information(_ watch: PairedWatch) -> some View {
        MetricTile("Watch", symbol: "info.circle.fill", tint: .secondary) {
            LabeledContent("Model", value: watch.info?.deviceModel ?? Formatting.deviceName(watch.catalogID))
            LabeledContent("Software", value: watch.info?.softwareVersionString ?? "–")
            LabeledContent("Protocol", value: watch.info.map { "\($0.protocolVersion)" } ?? "–")
            // The capability list is long and rarely needed, so it starts collapsed.
            DisclosureGroup("Additional information") {
                Text("Features")
                    .font(.tileTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.top, 4)
        }
    }
}
