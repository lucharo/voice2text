import SwiftUI
import UIKit

/// Past dictations, newest first, one card each; swipe to delete. The toolbar exports them and holds the timings
/// tools.
struct HistoryView: View {
  @EnvironmentObject var history: History
  var body: some View {
    List {
      ForEach(history.items) { d in
        HistoryCard(item: d)
          .swipeActions { Button("Delete", role: .destructive) { try? history.delete(d.id) } }
      }
    }
    .overlay { if history.items.isEmpty { Text("No dictations yet").foregroundStyle(.secondary) } }
    .navigationTitle("History")
    .toolbar { TimingsToolbar() }
  }
}

/// One dictation: the cleaned text in a fixed number of lines until tapped, a bar, its figures, then the date, the
/// words as heard behind their own button, and Copy. Collapsed, every card is the same height whatever its length.
struct HistoryCard: View {
  let item: Dictation
  static let collapsedLines = 3
  @State private var expanded = false
  @State private var heardShown = false
  @State private var copies = 0
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      text
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Shows the first \(Self.collapsedLines) lines" : "Shows all of it")
        .accessibilityIdentifier("v2t.history.text")
      Divider()
      HistoryStatsRow(stats: item.stats)
      // the date, then Heard and Copy at the end of the line; at large text sizes, the buttons below the date
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { date; Spacer(minLength: 0); buttons }
        VStack(alignment: .leading, spacing: 6) { date; buttons }
      }
      if heardShown, let heard = item.heard {
        Text(heard).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Heard: \(heard)")
          .accessibilityIdentifier("v2t.history.heardText")
      }
    }
    .padding(.vertical, 6)
    // the bar between cards spans the card, not from the last text in it (Copy)
    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
  }

  private var date: some View {
    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
  }

  private var buttons: some View {
    HStack(spacing: 16) {
      if item.heard != nil { heardButton }
      copyButton
    }
  }

  /// The same lines reserved when collapsed, so a one-line dictation is as tall as a long one.
  @ViewBuilder private var text: some View {
    if expanded {
      Text(item.text)
    } else {
      Text(item.text).lineLimit(Self.collapsedLines, reservesSpace: true)
    }
  }

  private var heardButton: some View {
    Button { withAnimation(.snappy) { heardShown.toggle() } } label: {
      HStack(spacing: 4) {
        Text("Heard")
        Image(systemName: heardShown ? "chevron.down" : "chevron.right").imageScale(.small)
      }
      .padding(.vertical, 4).contentShape(Rectangle())
    }
    .font(.footnote)
    .buttonStyle(.borderless)  // in a list row, only this button takes the tap
    .accessibilityLabel("Heard")
    .accessibilityValue(heardShown ? "Shown" : "Hidden")
    .accessibilityHint("The words before cleanup and the dictionary changed them")
    .accessibilityIdentifier("v2t.history.heard")
  }

  private var copyButton: some View {
    Button {
      UIPasteboard.general.string = item.text
      copies += 1
      copied = true
      AccessibilityNotification.Announcement("Copied").post()
      let n = copies
      Task { try? await Task.sleep(for: .seconds(1.5)); if copies == n { copied = false } }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").imageScale(.small)
          .contentTransition(.symbolEffect(.replace))
        Text(copied ? "Copied" : "Copy")
      }
      .padding(.vertical, 4).contentShape(Rectangle())
    }
    .font(.footnote)
    .buttonStyle(.borderless)
    .accessibilityLabel(copied ? "Copied" : "Copy")
    .sensoryFeedback(.success, trigger: copies)  // the system's own confirmation: a haptic
    .accessibilityIdentifier("v2t.history.copy")
  }
}

/// The card's figures, each an SF Symbol and a number, on one line; at large text sizes they wrap to two lines,
/// then to one each, rather than truncate. VoiceOver reads each as a phrase ("speech 0.1 seconds").
struct HistoryStatsRow: View {
  let stats: [DictationStat]
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { items(stats) }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 16) { items(Array(stats.prefix(2))) }
        HStack(spacing: 16) { items(Array(stats.dropFirst(2))) }
      }
      VStack(alignment: .leading, spacing: 6) { items(stats) }
    }
    .font(.subheadline.weight(.medium))
    .monospacedDigit()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("v2t.history.stats")
  }

  private func items(_ s: [DictationStat]) -> some View {
    ForEach(s, id: \.symbol) { stat in
      HStack(spacing: 5) {
        Image(systemName: stat.symbol).foregroundStyle(.secondary)
        Text(stat.text)
      }
      .fixedSize()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(stat.spoken)
    }
  }
}
