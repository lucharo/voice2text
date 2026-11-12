import Foundation
import Testing
@testable import V2T

/// iCloud key-value storage shared by every device in a test, counting what the sync reads and writes.
final class FakeCloud: KeyValueSync {
  var values: [String: Data] = [:]
  var reads = 0, writes = 0, fetches = 0

  func data(forKey key: String) -> Data? { reads += 1; return values[key] }
  func set(_ data: Data?, forKey key: String) { writes += 1; values[key] = data }
  func synchronize() -> Bool { fetches += 1; return true }

  var records: DictionaryMerge.Records {
    values[ICloudSync.dictionaryKey].flatMap { try? JSONDecoder().decode(DictionaryMerge.Records.self, from: $0) } ?? [:]
  }
  var learned: [String] {
    values[ICloudSync.learnedKey].flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
  }
}

final class Clock {
  var now = Date(timeIntervalSince1970: 0)
  func at(_ seconds: TimeInterval) { now = Date(timeIntervalSince1970: seconds) }
}

/// One iPhone or iPad: its own App Group (dictionary file, sync state, settings), the shared cloud and clock.
@MainActor final class Device {
  let dir = FileManager.default.temporaryDirectory.appending(path: "v2t-sync-\(UUID().uuidString)")
  let settings = Settings(defaults: UserDefaults(suiteName: "v2t-sync-\(UUID().uuidString)")!)
  let dictionary: PersonalDictionary
  let sync: ICloudSync

  init(_ text: String, learned: [String] = [], cloud: FakeCloud, clock: Clock, signedIn: Bool = true) throws {
    dictionary = PersonalDictionary(file: dir.appending(path: "dictionary.txt"))
    try dictionary.save(text)
    for w in learned { settings.learn(w) }
    sync = ICloudSync(dictionary: dictionary, settings: settings, store: cloud, signedIn: { signedIn }, now: { clock.now })
  }

  var lines: [String] { dictionary.items.map(\.line) }
}

@MainActor struct ICloudSyncTests {
  let cloud = FakeCloud()
  let clock = Clock()

  func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

  @Test func twoDevicesWithDifferentEntriesConvergeToTheUnion() throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    let pad = try Device("Fluide\nai => AI\n", cloud: cloud, clock: clock)

    clock.at(1); phone.sync.start()
    clock.at(2); pad.sync.start()
    clock.at(3); phone.sync.sync()

    #expect(phone.lines == ["Claude", "ai => AI", "Fluide"])
    #expect(pad.lines == ["Fluide", "ai => AI", "Claude"])
  }

  @Test func aDeletionReachesOtherDevicesAndAnOlderSnapshotCannotBringItBack() throws {
    let phone = try Device("Claude\nFluide\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    let oldPad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()
    clock.at(2); pad.sync.start()
    clock.at(3); oldPad.sync.start()  // has Fluide, and then stays away while it is deleted

    try phone.dictionary.remove("Fluide")
    clock.at(4); phone.sync.sync()
    clock.at(5); pad.sync.sync()
    clock.at(6); oldPad.sync.sync()
    clock.at(7); phone.sync.sync()

    #expect(phone.lines == ["Claude"])
    #expect(pad.lines == ["Claude"])
    #expect(oldPad.lines == ["Claude"])
    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast), "term:fluide": .init(line: nil, time: at(4))])
  }

  @Test func theSameEntryEditedOnTwoDevicesKeepsTheLaterEdit() throws {
    let phone = try Device("ai => AI\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()
    clock.at(2); pad.sync.start()

    try phone.dictionary.save("ai => A.I.\n")
    try pad.dictionary.save("AI => Ai\n")
    clock.at(10); phone.sync.sync()
    clock.at(11); pad.sync.sync()
    clock.at(12); phone.sync.sync()

    #expect(phone.dictionary.text == "AI => Ai\n")
    #expect(pad.dictionary.text == "AI => Ai\n")
  }

  /// The keyboard writes the App Group while the app is closed; the app's next sync finds the word and sends it.
  @Test func aWordTheKeyboardAddedWhileTheAppWasClosedIsUploaded() throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()

    try PersonalDictionary(file: phone.dictionary.file).addTerm("marimo")
    clock.at(2); phone.sync.sync(fetch: true)

    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast), "term:marimo": .init(line: "marimo", time: at(2))])
  }

  @Test func aFirstSyncOnAnEmptyDeviceDownloadsEverything() throws {
    let phone = try Device("Claude\nai => AI\n", learned: ["marimo"], cloud: cloud, clock: clock)
    let pad = try Device(PersonalDictionary.header, cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()

    clock.at(2); pad.sync.start()

    #expect(pad.dictionary.text == PersonalDictionary.header + "ai => AI\nClaude\n")
    #expect(pad.settings.learnedWords == ["marimo"])
  }

  @Test func aFirstSyncWithAnEmptyCloudUploadsEverything() throws {
    let phone = try Device("Claude\nai => AI\n", learned: ["kian", "marimo"], cloud: cloud, clock: clock)

    clock.at(1); phone.sync.start()

    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast), "replace:ai": .init(line: "ai => AI", time: .distantPast)])
    #expect(cloud.learned == ["kian", "marimo"])
    #expect(phone.sync.status == .synced)
  }

  @Test func learnedWordsFromTwoDevicesBecomeTheirUnion() throws {
    let phone = try Device("", learned: ["marimo"], cloud: cloud, clock: clock)
    let pad = try Device("", learned: ["kian"], cloud: cloud, clock: clock)

    clock.at(1); phone.sync.start()
    clock.at(2); pad.sync.start()
    clock.at(3); phone.sync.sync()

    #expect(phone.settings.learnedWords == ["kian", "marimo"])
    #expect(pad.settings.learnedWords == ["kian", "marimo"])
    #expect(cloud.learned == ["kian", "marimo"])
  }

  /// Only entries sync: comments, blank lines and a replacement missing a side stay where they are, while an
  /// entry from iCloud is added and one deleted there goes.
  @Test func commentsAndHeaderLinesSurviveAMergeUntouched() throws {
    let pad = try Device("Fluide\nKian\n", cloud: cloud, clock: clock)
    clock.at(1); pad.sync.start()
    try pad.dictionary.save("Fluide\n")
    clock.at(5); pad.sync.sync()  // Kian deleted at 5
    let phone = try Device("# mine\nClaude\n\n# names\nKian\nbad =>\n", cloud: cloud, clock: clock)

    clock.at(6); phone.sync.start()  // a first sync: this device's Kian is older than the deletion

    #expect(phone.dictionary.text == "# mine\nClaude\n\n# names\nbad =>\nFluide\n")
  }

  /// A device's first sync, also one that had sync off until now, cannot tell its old entries from new ones: an
  /// entry deleted elsewhere goes, and one iCloud has never seen goes up.
  @Test func aFirstSyncHonoursADeletionMadeElsewhere() throws {
    let phone = try Device("Claude\nFluide\n", cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()
    try phone.dictionary.remove("Fluide")
    clock.at(2); phone.sync.sync()
    let pad = try Device("Fluide\nKian\n", cloud: cloud, clock: clock)

    clock.at(10); pad.sync.start()

    #expect(pad.lines == ["Kian", "Claude"])
    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast), "term:fluide": .init(line: nil, time: at(2)),
                              "term:kian": .init(line: "Kian", time: .distantPast)])
  }

  /// After its first sync, even an empty one, a device's new entry is a deliberate change and beats an older deletion.
  @Test func aWordAddedAfterTheFirstSyncBeatsAnEarlierDeletion() throws {
    let pad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); pad.sync.start()
    let phone = try Device("marimo\n", cloud: cloud, clock: clock)
    clock.at(2); phone.sync.start()
    try phone.dictionary.remove("marimo")
    clock.at(3); phone.sync.sync()

    try PersonalDictionary(file: pad.dictionary.file).addTerm("marimo")
    clock.at(4); pad.sync.sync(fetch: true)

    #expect(pad.lines == ["marimo"])
    #expect(cloud.records == ["term:marimo": .init(line: "marimo", time: at(4))])
  }

  /// The keyboard keeps words while the app applies a download, each reading and writing back the one array: no
  /// word from either side is lost.
  @Test func wordsTheKeyboardKeepsDuringADownloadAllStay() async {
    let suite = "v2t-learn-\(UUID().uuidString)"
    let kept = (0..<100).map { "kept\($0)" }, downloaded = Set((0..<100).map { "cloud\($0)" })

    await withTaskGroup(of: Void.self) { group in
      for w in kept { group.addTask { Settings(defaults: UserDefaults(suiteName: suite)!).learn(w) } }
      group.addTask { _ = try? Settings(defaults: UserDefaults(suiteName: suite)!).learn(downloaded) }
    }

    #expect(Settings(defaults: UserDefaults(suiteName: suite)!).learnedWords == Set(kept).union(downloaded))
  }

  @Test func switchedOffItReadsAndWritesNothing() throws {
    let pad = try Device("Fluide\n", learned: ["kian"], cloud: cloud, clock: clock)
    clock.at(1); pad.sync.start()
    let before = cloud.values, reads = cloud.reads, writes = cloud.writes, fetches = cloud.fetches
    let phone = try Device("Claude\n", learned: ["marimo"], cloud: cloud, clock: clock)
    phone.settings.iCloudSyncEnabled = false

    clock.at(2); phone.sync.start()
    phone.sync.sync(fetch: true)

    #expect(phone.dictionary.text == "Claude\n")
    #expect(phone.settings.learnedWords == ["marimo"])
    #expect(cloud.values == before)
    #expect([cloud.reads, cloud.writes, cloud.fetches] as [Int] == [reads, writes, fetches])
    #expect(!FileManager.default.fileExists(atPath: phone.sync.stateFile.path()))
    #expect(phone.sync.status == .off)
  }

  @Test func overTheSizeLimitItWritesNothingAndSaysWhy() throws {
    let huge = String(repeating: "a", count: ICloudSync.limit)
    let phone = try Device("Claude\n\(huge)\n", learned: ["marimo"], cloud: cloud, clock: clock)
    cloud.values[ICloudSync.learnedKey] = try JSONEncoder().encode(["kian"])
    let before = cloud.values

    clock.at(1); phone.sync.start()

    #expect(cloud.values == before)
    #expect(phone.dictionary.text == "Claude\n\(huge)\n")
    #expect(phone.settings.learnedWords == ["marimo"])
    #expect(!FileManager.default.fileExists(atPath: phone.sync.stateFile.path()))
    guard case .tooLarge(let bytes) = phone.sync.status else { Issue.record("status \(phone.sync.status)"); return }
    #expect(bytes > ICloudSync.limit)
    #expect(ICloudSyncRow.subtitle(phone.sync.status, device: "iPhone").hasSuffix(", over the 1 MB iCloud keeps for an app. Remove some entries to sync again."))
  }

  @Test func withNoICloudAccountItSaysItIsWaiting() throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock, signedIn: false)

    clock.at(1); phone.sync.start()

    #expect(phone.sync.status == .waitingForICloud)
    #expect(ICloudSyncRow.subtitle(phone.sync.status, device: "iPhone") == "Waiting for iCloud: sign in to iCloud in Settings and your dictionary and kept words sync then.")
  }

  @Test func aChangeFromICloudIsMergedWhenItArrives() throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); phone.sync.start()
    clock.at(2); pad.sync.start()
    try pad.dictionary.addTerm("Fluide")
    clock.at(3); pad.sync.sync()

    NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud)

    #expect(phone.lines == ["Claude", "Fluide"])
  }
}
