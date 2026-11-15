import Charts
import NXShellUI
import SwiftUI

/// The last session of a game: the frame rate over time, the stretches where the phone was hot shaded behind it, and the heat and
/// battery in a line. The numbers come from `SessionRecorder`; nothing here reads the phone.
struct SessionChart: View {
    @EnvironmentObject private var model: ShellHostModel
    let report: SessionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.text(.lastSession)).font(.system(size: 11)).foregroundStyle(ShellInk.secondary)
                Spacer()
                if let average = report.averageFPS {
                    Text("\(Int(average.rounded())) fps").font(.system(size: 11, weight: .medium)).foregroundStyle(ShellInk.secondary)
                }
            }
            Chart {
                ForEach(Array(report.buckets.enumerated()), id: \.offset) { _, bucket in
                    if bucket.thermal >= 2 {
                        RectangleMark(xStart: .value("from", Double(bucket.t - SessionReport.bucketSeconds) / 60), xEnd: .value("to", Double(bucket.t) / 60))
                            .foregroundStyle((bucket.thermal >= 3 ? ShellInk.bad : ShellInk.accent).opacity(0.18))
                    }
                    if let fps = bucket.fps {
                        LineMark(x: .value("minutes", Double(bucket.t) / 60), y: .value("fps", fps))
                            .foregroundStyle(ShellInk.accent).interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: 0...max(60, (report.buckets.compactMap(\.fps).max() ?? 60).rounded(.up)))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel().foregroundStyle(ShellInk.secondary) } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(ShellInk.line); AxisValueLabel().foregroundStyle(ShellInk.secondary) } }
            .frame(height: 110)
            HStack(spacing: 14) {
                Text("\(model.text(.sessionHeat)) · \(heat(report.worstThermal))")
                if let used = report.batteryUsed { Text("\(model.text(.sessionBattery)) · \(Int(used.rounded())) %") }
            }
            .font(.system(size: 11)).foregroundStyle(ShellInk.secondary)
        }
        .padding(14)
        .background(ShellInk.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ShellInk.line))
    }

    private func heat(_ level: Int) -> String {
        switch level {
        case 0: return model.text(.thermalNominal)
        case 1: return model.text(.thermalFair)
        case 2: return model.text(.thermalSerious)
        default: return model.text(.thermalCritical)
        }
    }
}
