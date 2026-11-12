import SwiftUI

/// The dictionary screen's "Sync with iCloud" switch, with one line on what syncs and how it went.
struct ICloudSyncRow: View {
  @EnvironmentObject var iCloud: ICloudSync

  var body: some View {
    Toggle(isOn: Binding(get: { iCloud.enabled }, set: { iCloud.enabled = $0 })) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Sync with iCloud")
        Text(Self.subtitle(iCloud.status, device: UIDevice.current.model)).font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("v2t.dict.iCloudStatus")
      }
    }
    .accessibilityIdentifier("v2t.dict.iCloud")
  }

  static func subtitle(_ status: ICloudSync.Status, device: String) -> String {
    switch status {
    case .off: "Off: your dictionary and the words you keep on the keyboard stay on this \(device)."
    case .synced: "Your dictionary and the words you keep on the keyboard, on your iPhones and iPads, through your own iCloud account. Audio never leaves this \(device)."
    case .waitingForICloud: "Waiting for iCloud: sign in to iCloud in Settings and your dictionary and kept words sync then."
    case .tooLarge(let bytes): "Not synced: your dictionary and kept words take \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), over the 1 MB iCloud keeps for an app. Remove some entries to sync again."
    case .failed(let reason): "Not synced: \(reason)"
    }
  }
}
