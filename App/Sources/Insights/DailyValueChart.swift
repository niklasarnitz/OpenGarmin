import SwiftUI
import Charts
import GarminModels

/// One value per day over a date range: a bar a day up to two months, the 7-day mean as a line beyond that. Days of
/// the range without a value are greyed, as the other charts grey missing data.
struct DailyValueChart: View {
    let points: [PointSample]
    let interval: DateInterval
    let tint: Color
    var height: CGFloat = 140

    private var rangeDays: Int { Int((interval.duration / 86_400).rounded()) }

    var body: some View {
        let calendar = Calendar.current
        let measured = Set(points.map { calendar.startOfDay(for: $0.date) })
        let missing = rangeDays <= 62
            ? stride(from: 0, to: rangeDays, by: 1).compactMap { offset -> Date? in
                let day = calendar.date(byAdding: .day, value: offset, to: interval.start)!
                return day <= .now && !measured.contains(day) ? day : nil
            }
            : []
        Chart {
            ForEach(missing, id: \.self) { day in
                RectangleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Color.secondary.opacity(0.14))
            }
            if rangeDays <= 62 {
                ForEach(points, id: \.date) { point in
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("Value", point.value))
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(4)
                }
            } else {
                ForEach(ChartSmoothing.rollingMean(points, days: 7), id: \.date) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartXAxis {
            switch rangeDays {
            case ...8:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.caption2)
                }
            case ...62:
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2)
                }
            default:
                AxisMarks(values: .stride(by: .month, count: rangeDays > 200 ? 2 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.caption2)
                }
            }
        }
        .frame(height: height)
    }
}
