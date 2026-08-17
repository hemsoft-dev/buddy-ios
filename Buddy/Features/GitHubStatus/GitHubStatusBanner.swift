import SwiftUI

struct GitHubStatusBanner: View {
    let incident: GitHubStatusIncident
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Link(destination: incident.detailsURL) {
            HStack(spacing: BuddyTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)

                if reduceMotion || dynamicTypeSize.isAccessibilitySize {
                    Text(bannerText)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollingIncidentText(text: bannerText)
                }

                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BuddyTheme.Spacing.medium)
            .padding(.vertical, BuddyTheme.Spacing.small)
            .foregroundStyle(.white)
            .background(.red)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(incident.accessibilityDescription)
        .accessibilityHint("Opens this incident on GitHub Status")
    }

    private var bannerText: String {
        "\(incident.title) · \(incident.summary) · Updated \(incident.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ScrollingIncidentText: View {
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .subheadline) private var estimatedCharacterWidth: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let estimatedTextWidth = max(CGFloat(text.count) * estimatedCharacterWidth, proxy.size.width)
                let travel = proxy.size.width + estimatedTextWidth
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let progress = seconds.truncatingRemainder(dividingBy: 18) / 18
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: proxy.size.width - travel * progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipped()
        }
        .frame(height: lineHeight)
        .accessibilityHidden(true)
    }
}
