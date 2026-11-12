import SwiftUI

extension Settings {
  /// Whether the About v2t page has been shown: it opens by itself on the first launch after install, then only from
  /// its row on the home screen. App-only, so it lives here rather than in Shared.
  var aboutShown: Bool {
    get { defaults.bool(forKey: "aboutShown") }
    set { defaults.set(newValue, forKey: "aboutShown") }
  }
}

/// What v2t is, in five short points. Opens over the home screen on the first launch (with Continue), and from the
/// About v2t row afterwards.
struct AboutView: View {
  @EnvironmentObject var dictation: DictationService
  /// The first-launch sheet's button; nil when the page was pushed from its row, which has Back instead.
  var onContinue: (() -> Void)?

  var body: some View {
    let device = dictation.recommendation.deviceName
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Great keyboard and transcription, no compromises.")
          .font(.largeTitle.bold())
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("v2t.about.headline")
        AboutPoint(symbol: "keyboard", title: "A keyboard as good as Apple's",
                   detail: "Swipe to type, autocorrect and suggestions, so you don't trade a good keyboard for transcription.")
        AboutPoint(symbol: "lock.shield", title: "Transcription stays offline",
                   detail: "It runs on this \(device) after a one-time download. Audio never leaves it.")
        AboutPoint(symbol: "bolt", title: "Text almost as soon as you stop",
                   detail: "v2t transcribes while you talk, so the wait barely changes whether you spoke for 10\u{00A0}seconds or 20\u{00A0}minutes.")
        AboutPoint(symbol: "book.closed", title: "One dictionary for typing and dictation",
                   detail: "A word you keep on the keyboard is added to it, and Apple Intelligence cleanup spells it that way.")
        AboutPoint(symbol: "cpu", title: "Local first, with the right model",
                   detail: "Small, fast speech models tailored to speaking to an agent, where a small slip matters less than speed.")
      }
      .padding(24)
      // a readable column on an iPad, as the home screen keeps its rows
      .frame(maxWidth: 560, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      if let onContinue {
        Button(action: onContinue) { Text("Continue").frame(maxWidth: 400) }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .padding(.horizontal, 24).padding(.vertical, 12)
          .frame(maxWidth: .infinity)
          .background(.bar)
          .accessibilityIdentifier("v2t.about.continue")
      }
    }
    .background(Color(.systemBackground))
    .navigationTitle("About v2t")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// One point on the About page: an SF Symbol in the accent colour, a line, and at most one sentence under it.
struct AboutPoint: View {
  let symbol: String, title: String, detail: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Image(systemName: symbol)
        .font(.title3).foregroundStyle(Color.accentColor)
        .frame(width: 30)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
