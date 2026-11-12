import CloudKit
import Foundation
import UIKit

/// Syncs the dictionary's entries and the keyboard's learned words with the user's other iPhones and iPads,
/// through the user's private iCloud database, with the words in encrypted fields (`CloudKitDictionary`). Only
/// the app syncs: the keyboard keeps reading and writing the App Group, and what it adds while the app is closed
/// goes up at the next sync. Runs at launch, on return to the foreground, when the iCloud account changes and
/// after the app edits the dictionary. Changes made on another device arrive at the next of those: a push from a
/// CloudKit subscription would need the "Remote notifications" background mode
/// (https://developer.apple.com/documentation/cloudkit/ckdatabasesubscription), which the app does not have.
@MainActor final class ICloudSync: ObservableObject {
  enum Status: Equatable {
    case off, synced
    /// No iCloud account on the device: nothing is read or written until there is one.
    case waitingForICloud
    /// One record (an entry, or the learned words) would take this many bytes, over Apple's 1 MB per record:
    /// nothing was written.
    case tooLarge(bytes: Int)
    case failed(String)
  }

  @Published private(set) var status: Status
  let dictionary: PersonalDictionary
  let settings: Settings
  private let cloud: DictionaryCloud
  private let device: String
  private var observers: [NSObjectProtocol] = []
  /// Nothing syncs before `start`, so a launch that skips it (UI tests) never touches iCloud.
  private var started = false
  /// The latest sync; each one waits for the one before, so two never interleave.
  private var running: Task<Void, Never>?

  /// `device` is the hardware model ("iPhone17,1"), which needs no permission; the name the user gave the device
  /// needs an entitlement since iOS 16 (https://developer.apple.com/documentation/uikit/uidevice/name).
  init(dictionary: PersonalDictionary, settings: Settings = .shared, cloud: DictionaryCloud? = nil,
       device: String = Recommendation.Device.current.model) {
    self.dictionary = dictionary
    self.settings = settings
    self.cloud = cloud ?? CloudKitDictionary()
    self.device = device
    status = settings.iCloudSyncEnabled ? .synced : .off
  }

  /// The sync state kept next to the dictionary, in the App Group: each entry's last synced record, deletions
  /// included. Written only inside the dictionary's transaction, so it always matches the file.
  var stateFile: URL { dictionary.file.deletingPathExtension().appendingPathExtension("sync.json") }

  var enabled: Bool {
    get { settings.iCloudSyncEnabled }
    set {
      settings.iCloudSyncEnabled = newValue
      status = newValue ? .synced : .off  // redraws the switch; the sync below then says how it went
      sync()
    }
  }

  /// Syncs now, and again on each return to the foreground and each iCloud account change.
  @discardableResult func start() -> Task<Void, Never> {
    started = true
    if observers.isEmpty {
      let center = NotificationCenter.default
      for name in [UIApplication.willEnterForegroundNotification, .CKAccountChanged] {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { _ = self?.sync() }
        })
      }
    }
    return sync()
  }

  /// Fetches what iCloud holds, merges it with this device's dictionary and learned words, writes the local side
  /// and uploads the records that changed. Off, it reads and writes nothing.
  @discardableResult func sync() -> Task<Void, Never> {
    let previous = running
    let task = Task { await previous?.value; await run() }
    running = task
    return task
  }

  private func run() async {
    guard started else { return }
    guard settings.iCloudSyncEnabled else { status = .off; return }
    guard await cloud.accountAvailable() else { status = .waitingForICloud; return }
    do {
      // a save that met a newer server record brings one more fetch and merge, so the record that won there (and
      // the learned words merged there) apply here now rather than at the next sync
      for _ in 0..<2 {
        guard let conflicted = try await pass() else { return }
        status = .synced
        if !conflicted { return }
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  /// One fetch, merge and upload. Nil when it stopped (sync turned off, a record too large), else whether the
  /// upload met a newer server record.
  private func pass() async throws -> Bool? {
    let remote = try await cloud.fetch()
    guard settings.iCloudSyncEnabled else { status = .off; return nil }  // turned off while fetching
    let upload: (entries: DictionaryMerge.Records, learned: Set<String>?)? = try dictionary.transaction {
      // none on a first sync, which the merge treats apart; an unreadable one counts as none
      let synced = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(DictionaryMerge.Records.self, from: $0) }
      let merged = DictionaryMerge.run(text: dictionary.text, synced: synced, remote: remote.entries,
                                       changes: dictionary.changes, device: device)
      // a record over the limit would be refused, and leaving it out would read as a deletion elsewhere
      let largest = max(merged.records.map { CloudKitDictionary.size(key: $0.key, $0.value) }.max() ?? 0,
                        CloudKitDictionary.size(learned: settings.learnedWords.union(remote.learned)))
      guard largest <= CloudKitDictionary.recordLimit else { status = .tooLarge(bytes: largest); return nil }
      // in one coordinated update the keyboard cannot interleave with; it returns any word the keyboard kept meanwhile
      let learned = try settings.learn(remote.learned)
      // the download is not a change made here
      if merged.text != dictionary.text { try dictionary.write(merged.text, asChanges: false) }
      // written on a first sync even when empty, so the next sync is not a first one
      if merged.records != synced {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        try e.encode(merged.records).write(to: stateFile, options: .atomic)
      }
      // the records now carry them
      if FileManager.default.fileExists(atPath: dictionary.changesFile.path()) { try FileManager.default.removeItem(at: dictionary.changesFile) }
      // only what iCloud lacks; one that fails to upload differs again at the next sync and goes then
      return (merged.records.filter { remote.entries[$0.key] != $0.value }, learned == remote.learned ? nil : learned)
    }
    guard let upload else { return nil }
    guard !upload.entries.isEmpty || upload.learned != nil else { return false }
    return try await cloud.save(entries: upload.entries, learned: upload.learned)
  }
}
