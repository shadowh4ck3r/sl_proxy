import Charts
import SwiftUI

/// Live download/upload speeds with a rolling one-minute chart.
struct TrafficCard: View {
    @ObservedObject var traffic: TrafficMonitor

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                stat("Download", traffic.downloadSpeedText, total: traffic.downloadTotalText, icon: "arrow.down.circle.fill")
                Divider().frame(height: 44)
                stat("Upload", traffic.uploadSpeedText, total: traffic.uploadTotalText, icon: "arrow.up.circle.fill")
            }
            chart
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var chart: some View {
        Chart {
            ForEach(traffic.history) { sample in
                AreaMark(
                    x: .value("Time", sample.id),
                    y: .value("Speed", sample.down),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(Brand.gold.opacity(0.22))
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", sample.id),
                    y: .value("Speed", sample.down),
                    series: .value("Direction", "Download")
                )
                .foregroundStyle(Brand.gold)
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", sample.id),
                    y: .value("Speed", sample.up),
                    series: .value("Direction", "Upload")
                )
                .foregroundStyle(Brand.orange)
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 90)
    }

    private func stat(_ title: String, _ value: String, total: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Brand.gradient)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(total)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
