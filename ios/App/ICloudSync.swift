import Foundation
import UIKit

/// Where the sync keeps its two values: iCloud key-value storage in the app, an in-memory store in tests.
protocol KeyValueSync: AnyObject {
  func data(forKey key: String) -> Data?
  func set(_ data: Data?, forKey key: String)
  @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueSync {}

/// Syncs the dictionary's entries and the keyboard's learned words with the user's other iPhones and iPads,
/// through iCloud key-value storage in the user's own iCloud account. Only the app syncs: the keyboard keeps
/// reading and writing the App Group, and what it adds while the app is closed goes up at the next sync. Runs
/// at launch, on return to the foreground, when iCloud brings a change and after the app edits the dictionary;
/// nothing runs in the background.
@MainActor final class ICloudSync: ObservableObject {
  /// Apple's limits, from https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore (read
  /// 12 November 2026): "Your app can have no more than 1024 keys in the iCloud key-value store. The total
  /// amount of available storage space for all values is 1 megabyte. The maximum size for a single value is
  /// 1 megabyte." and "If you exceed any of the prescribed limits during a write operation, the operation fails
  /// and the system doesn't add the keys or values to the store." v2t uses two short keys, so only the 1 MB
  /// total can bind; counted as 1,000,000 bytes, the smaller reading of "1 megabyte".
  nonisolated static let limit = 1_000_000
  nonisolated static let dictionaryKey = "dictionary", learnedKey = "learnedWords"

  enum Status: Equatable {
    case off, synced
    /// No iCloud account on the device: changes wait in the store, which iCloud sends on once one signs in.
    case waitingForICloud
    /// Both values together would take this many bytes, over `limit`: nothing was written.
    case tooLarge(bytes: Int)
    case failed(String)
  }

  @Published private(set) var status: Status
  let dictionary: PersonalDictionary
  let settings: Settings
  private let store: KeyValueSync
  private let signedIn: () -> Bool
  private let now: () -> Date
  private var observers: [NSObjectProtocol] = []
  /// Nothing syncs before `start`, so a launch that skips it (UI tests) never touches iCloud.
  private var started = false

  init(dictionary: PersonalDictionary, settings: Settings = .shared, store: KeyValueSync = NSUbiquitousKeyValueStore.default,
       // FileManager's token is nil with no iCloud account (and, Apple's page says, when iCloud Drive is off)
       signedIn: @escaping () -> Bool = { FileManager.default.ubiquityIdentityToken != nil },
       now: @escaping () -> Date = Date.init) {
    self.dictionary = dictionary
    self.settings = settings
    self.store = store
    self.signedIn = signedIn
    self.now = now
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

  /// Syncs now, and again on each return to the foreground and each change iCloud brings.
  func start() {
    started = true
    if observers.isEmpty {
      let center = NotificationCenter.default
      observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sync() }
      })
      observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.sync(fetch: true) }
      })
    }
    sync(fetch: true)
  }

  /// Merges this device's dictionary and learned words with iCloud's, then writes whichever side changed. Off,
  /// it reads and writes nothing. `fetch` asks iCloud for newer values first, which Apple's page advises only at
  /// launch and on return to the foreground.
  func sync(fetch: Bool = false) {
    guard started else { return }
    guard settings.iCloudSyncEnabled else { status = .off; return }
    if fetch { store.synchronize() }
    do {
      status = try dictionary.transaction {
        let synced = decode(DictionaryMerge.Records.self, try? Data(contentsOf: stateFile)) ?? [:]
        let remote = decode(DictionaryMerge.Records.self, store.data(forKey: Self.dictionaryKey)) ?? [:]
        let merged = DictionaryMerge.run(text: dictionary.text, synced: synced, remote: remote, now: now())
        let learnedHere = settings.learnedWords
        let learnedThere = Set(decode([String].self, store.data(forKey: Self.learnedKey)) ?? [])
        // no way to remove a learned word exists, so the union is the whole merge
        let learned = learnedHere.union(learnedThere)
        let records = try encode(merged.records), words = try encode(learned.sorted())
        // a store write over the limit would fail, and a cut record would read as deletions elsewhere
        guard records.count + words.count <= Self.limit else { return .tooLarge(bytes: records.count + words.count) }
        if merged.text != dictionary.text { try dictionary.write(merged.text) }
        if merged.records != synced { try records.write(to: stateFile, options: .atomic) }
        if merged.records != remote { store.set(records, forKey: Self.dictionaryKey) }
        for w in learned.subtracting(learnedHere).sorted() { settings.learn(w) }
        if learned != learnedThere { store.set(words, forKey: Self.learnedKey) }
        return signedIn() ? .synced : .waitingForICloud
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
    data.flatMap { try? JSONDecoder().decode(type, from: $0) }
  }

  private func encode(_ value: some Encodable) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys  // the same records always give the same bytes
    return try e.encode(value)
  }
}
