import SwiftUI

/// App shell. Recording and on-device transcription land once the first scope is agreed (#75).
@main struct V2TApp: App {
  @StateObject var history = History()

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        List {
          if history.items.isEmpty {
            Text("No dictations yet").foregroundStyle(.secondary)
          }
          ForEach(history.items) { d in
            Text(d.text).lineLimit(3)
          }
        }
        .navigationTitle("v2t")
      }
    }
  }
}
