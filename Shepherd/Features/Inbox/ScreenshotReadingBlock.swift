import ShepherdCore
import SwiftUI

/// The screenshot reading under the inbox's summary card (ADR 0038 item 4).
///
/// A button, a spinner, the model's sentences under a tag saying where they were read, or one
/// line saying why not. The tag is the privacy statement and the scope statement at once: the
/// images were read on this Mac, and the sentences say what the images show — never whether the
/// pull request is right.
struct ScreenshotReadingBlock: View {
    let state: ScreenshotReadingState
    let onRead: () -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .offered(let count):
            Button(action: onRead) {
                Label(ScreenshotReadingBlock.buttonTitle(count: count), systemImage: "photo.on.rectangle")
            }
            .buttonStyle(SecondaryButtonStyle(height: 24))
            .help(String(
                localized: "Downloads up to two of the description's screenshots from GitHub and reads them with the model on this Mac. They are sent nowhere else."
            ))
        case .reading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Reading the screenshots on this Mac…"))
            }
            .font(Theme.type(.caption))
            .foregroundStyle(Theme.textMuted)
        case .read(let reading):
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                    Text(ScreenshotReadingBlock.caption(for: reading))
                }
                .font(Theme.type(.caption, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .help(String(
                    localized: "What the on-device model sees in the screenshots. It was not shown the description, and it does not judge the change."
                ))
                ForEach(reading.observations, id: \.self) { observation in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Theme.textMuted)
                        Text(observation)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
        case .failed(let reason):
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.circle")
                Text(reason)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.type(.caption))
            .foregroundStyle(Theme.textMuted)
        }
    }

    /// The button's title: how many will be read, and of how many when there are more.
    static func buttonTitle(count: Int) -> String {
        if count == 1 { return String(localized: "Read the screenshot") }
        let readable = min(count, DescriptionImages.maximumImages)
        if readable == count { return String(localized: "Read the \(count) screenshots") }
        return String(localized: "Read \(readable) of \(count) screenshots")
    }

    /// The tag over the sentences: what was read, and where.
    static func caption(for reading: ScreenshotReading) -> String {
        if reading.isPartial {
            return String(localized: "\(reading.readCount) of \(reading.totalCount) screenshots, read on this Mac")
        }
        if reading.readCount == 1 {
            return String(localized: "Screenshot read on this Mac")
        }
        return String(localized: "\(reading.readCount) screenshots, read on this Mac")
    }
}
