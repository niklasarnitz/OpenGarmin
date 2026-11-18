import SwiftUI
import UniformTypeIdentifiers
import GarminFIT
import GarminSession

/// The apps the watch lists, with delete, and the two installs: a Connect IQ .prg and a GPX course.
struct InstallView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var pickingApp = false
    @State private var pickingCourse = false
    @State private var course: CourseDraft?
    @State private var progress: Double?
    @State private var failure: String?
    @State private var confirmDelete: InstalledApp?

    /// Connect IQ apps (Gadgetbridge's PRG files). Declared as an imported type in project.yml.
    static let prgType = UTType(importedAs: "com.garmin.connectiq.prg", conformingTo: .data)
    /// GPX tracks, which become courses on the watch.
    static let gpxType = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)

    var body: some View {
        List {
            Section("On the watch") {
                if app.watch.installedApps.isEmpty {
                    Text("No apps listed.").foregroundStyle(.secondary)
                }
                ForEach(app.watch.installedApps) { installed in
                    LabeledContent {
                        Text(installed.version.map { "v\($0)" } ?? "")
                            .foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installed.name)
                            Text(installed.isSystem ? "Built in · \(installed.kind.title)" : installed.kind.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !installed.isSystem {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = installed }
                        }
                    }
                }
            }

            Section {
                Button("Connect IQ app (.prg)", systemImage: "square.and.arrow.down") { pickingApp = true }
                Button("Course from GPX track", systemImage: "map") { pickingCourse = true }
            } header: {
                Text("Install")
            } footer: {
                Text("Apps and courses are sent to the watch over Bluetooth. Keep the watch near the phone until the upload finishes.")
            }

            if let progress {
                Section {
                    ProgressView(value: progress) { Text("Sending to the watch") }
                }
            }
        }
        .navigationTitle("Apps and courses")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
        }
        .task { try? await app.watch.refreshInstalledApps() }
        .fileImporter(isPresented: $pickingApp, allowedContentTypes: [Self.prgType]) { result in
            guard let url = fileURL(result) else { return }
            install(url)
        }
        .fileImporter(isPresented: $pickingCourse, allowedContentTypes: [Self.gpxType]) { result in
            guard let url = fileURL(result) else { return }
            openCourse(url)
        }
        .sheet(item: $course) { draft in
            CourseImportView(draft: draft)
        }
        .confirmationDialog("Delete this app?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { installed in
            Button("Delete \(installed.name)", role: .destructive) { delete(installed) }
        } message: { _ in
            Text("The app is removed from the watch.")
        }
        .alert("Could not finish", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func fileURL(_ result: Result<URL, Error>) -> URL? {
        do {
            return try result.get()
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    private func refresh() {
        Task {
            do { try await app.watch.refreshInstalledApps() } catch { failure = error.localizedDescription }
        }
    }

    private func install(_ url: URL) {
        Task {
            do {
                let data = try readFile(url)
                progress = 0
                try await app.watch.installApp(data) { progress = $0 }
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
    }

    private func openCourse(_ url: URL) {
        do {
            let gpx = try readFile(url)
            let points = try GPXTrack.points(in: gpx)
            course = CourseDraft(name: url.deletingPathExtension().lastPathComponent, gpx: gpx, points: points)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete(_ installed: InstalledApp) {
        Task {
            do { try await app.watch.deleteInstalledApp(installed) } catch { failure = error.localizedDescription }
        }
    }

    /// Reads a file the user picked, which lives outside the app's sandbox.
    private func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

/// A GPX track the user picked, read and parsed, waiting to be sent as a course.
struct CourseDraft: Identifiable {
    let id = UUID()
    let name: String
    let gpx: Data
    let points: [GPXTrackPoint]
}

extension InstalledApp.Kind {
    var title: String {
        switch self {
        case .watchApp: "Watch app"
        case .watchFace: "Watch face"
        case .dataField: "Data field"
        case .widget: "Widget"
        case .audioContentProvider: "Audio content provider"
        case .activity: "Activity app"
        case .other: "App"
        }
    }
}
