import SwiftUI
import MapKit
import GarminFIT

/// Shows a GPX track on a map and sends it to the watch as a course, with the name and turn prompts chosen here.
struct CourseImportView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draft: CourseDraft
    @State private var name: String
    @State private var includeTurns = true
    @State private var progress: Double?
    @State private var failure: String?

    init(draft: CourseDraft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(initialPosition: .region(region)) {
                        MapPolyline(coordinates: coordinates)
                            .stroke(Palette.blaze, lineWidth: 4)
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .listRowInsets(EdgeInsets())
                    LabeledContent("Points", value: "\(draft.points.count)")
                }

                Section {
                    TextField("Course name", text: $name)
                    Toggle("Turn prompts", isOn: $includeTurns)
                } footer: {
                    Text("Turn prompts add a course point at each turn in the track, as Gadgetbridge does.")
                }

                if let progress {
                    Section {
                        ProgressView(value: progress) { Text("Sending to the watch") }
                    }
                }
            }
            .navigationTitle("Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(progress != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Could not send the course", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private var coordinates: [CLLocationCoordinate2D] {
        draft.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The bounds of the track with a margin, so the whole route is in view.
    private var region: MKCoordinateRegion {
        let lats = draft.points.map(\.latitude)
        let lons = draft.points.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0, maxLon = lons.max() ?? 0
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.01),
                                   longitudeDelta: max((maxLon - minLon) * 1.3, 0.01))
        )
    }

    private func send() {
        progress = 0
        Task {
            do {
                try await app.watch.installCourse(gpx: draft.gpx, name: name.trimmingCharacters(in: .whitespaces),
                                                  includeTurns: includeTurns) { progress = $0 }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            progress = nil
        }
    }
}
