import SwiftUI

struct MainTabView: View {
    enum Destination: Hashable { case today, insights, activities, workouts, device }

    @State private var selection: Destination = .today

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.max.fill", value: Destination.today) {
                TodayView()
            }
            Tab("Insights", systemImage: "chart.xyaxis.line", value: Destination.insights) {
                InsightsView()
            }
            Tab("Activities", systemImage: "figure.run", value: Destination.activities) {
                ActivitiesView()
            }
            Tab("Workouts", systemImage: "list.bullet.clipboard", value: Destination.workouts) {
                WorkoutsView()
            }
            Tab("Device", systemImage: "applewatch", value: Destination.device) {
                DeviceView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
