import Foundation
import Testing
import UIKit
@testable import V2T

/// The private iCloud database shared by every device in a test, counting the sync's calls to it.
@MainActor final class FakeCloud: DictionaryCloud {
  var contents = CloudContents()
  var available = true
  var calls = 0

  func accountAvailable() async -> Bool { calls += 1; return available }
  func fetch() async throws -> CloudContents { calls += 1; return contents }
  func save(entries: DictionaryMerge.Records, learned: Set<String>?) async throws {
    calls += 1
    contents.entries.merge(entries) { $1 }
    if let learned { contents.learned = learned }
  }

  var records: DictionaryMerge.Records { contents.entries }
  var learned: [String] { contents.learned.sorted() }
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

  init(_ text: String, learned: [String] = [], model: String = "iPhone17,1", cloud: FakeCloud, clock: Clock) throws {
    self.clock = clock
    dictionary = PersonalDictionary(file: dir.appending(path: "dictionary.txt"), now: { clock.now })
    try dictionary.save(text)
    for w in learned { settings.learn(w) }
    sync = ICloudSync(dictionary: dictionary, settings: settings, cloud: cloud, device: model)
  }

  let clock: Clock
  /// A copy of this device's dictionary as the keyboard extension holds it.
  var keyboard: PersonalDictionary { PersonalDictionary(file: dictionary.file, writer: "keyboard", now: { [clock] in clock.now }) }
  var lines: [String] { dictionary.items.map(\.line) }
}

/// Serialized: a foreground notification reaches every started sync, so two tests must never overlap.
@MainActor @Suite(.serialized) struct ICloudSyncTests {
  let cloud = FakeCloud()
  let clock = Clock()

  func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
  func by(_ device: String, _ app: String = "app") -> DictionaryMerge.Source { .init(device: device, app: app) }

  @Test func twoDevicesWithDifferentEntriesConvergeToTheUnion() async throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    let pad = try Device("Fluide\nai => AI\n", cloud: cloud, clock: clock)

    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value
    clock.at(3); await phone.sync.sync().value

    #expect(phone.lines == ["Claude", "ai => AI", "Fluide"])
    #expect(pad.lines == ["Fluide", "ai => AI", "Claude"])
  }

  @Test func aDeletionReachesOtherDevicesAndAnOlderSnapshotCannotBringItBack() async throws {
    let phone = try Device("Claude\nFluide\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    let oldPad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value
    clock.at(3); await oldPad.sync.start().value  // has Fluide, and then stays away while it is deleted

    clock.at(4); try phone.dictionary.remove("Fluide")
    await phone.sync.sync().value
    clock.at(5); await pad.sync.sync().value
    clock.at(6); await oldPad.sync.sync().value
    clock.at(7); await phone.sync.sync().value

    #expect(phone.lines == ["Claude"])
    #expect(pad.lines == ["Claude"])
    #expect(oldPad.lines == ["Claude"])
    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast),
                              "term:fluide": .init(line: nil, time: at(4), source: by("iPhone17,1"))])
  }

  @Test func theSameEntryEditedOnTwoDevicesKeepsTheLaterEdit() async throws {
    let phone = try Device("ai => AI\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value

    clock.at(10); try phone.dictionary.save("ai => A.I.\n")
    clock.at(11); try pad.dictionary.save("AI => Ai\n")
    await phone.sync.sync().value
    await pad.sync.sync().value
    await phone.sync.sync().value

    #expect(phone.dictionary.text == "AI => Ai\n")
    #expect(pad.dictionary.text == "AI => Ai\n")
  }

  /// The keyboard writes the App Group while the app is closed; the app's next sync finds the word and sends it,
  /// saying the keyboard on this device added it.
  @Test func aWordTheKeyboardAddedWhileTheAppWasClosedIsUploaded() async throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value

    clock.at(2); try phone.keyboard.addTerm("marimo")
    await phone.sync.sync().value

    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast),
                              "term:marimo": .init(line: "marimo", time: at(2), source: by("iPhone17,1", "keyboard"))])
  }

  /// Each change records the device and whether the keyboard or the app made it; once synced, the keyboard's
  /// mark is spent, so a later edit in the app is the app's.
  @Test func eachChangeSaysWhichDeviceAndWhetherTheKeyboardOrTheAppMadeIt() async throws {
    let pad = try Device("", model: "iPad16,3", cloud: cloud, clock: clock)
    clock.at(1); await pad.sync.start().value
    clock.at(2); try pad.keyboard.addTerm("marimo")
    try pad.dictionary.addReplacement(heard: "ai", written: "AI")
    await pad.sync.sync().value

    clock.at(3); try pad.dictionary.save("Marimo\nai => AI\n")
    await pad.sync.sync().value

    #expect(cloud.records == ["term:marimo": .init(line: "Marimo", time: at(3), source: by("iPad16,3")),
                              "replace:ai": .init(line: "ai => AI", time: at(2), source: by("iPad16,3"))])
  }

  @Test func aFirstSyncOnAnEmptyDeviceDownloadsEverything() async throws {
    let phone = try Device("Claude\nai => AI\n", learned: ["marimo"], cloud: cloud, clock: clock)
    let pad = try Device(PersonalDictionary.header, cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value

    clock.at(2); await pad.sync.start().value

    #expect(pad.dictionary.text == PersonalDictionary.header + "ai => AI\nClaude\n")
    #expect(pad.settings.learnedWords == ["marimo"])
  }

  @Test func aFirstSyncWithAnEmptyCloudUploadsEverything() async throws {
    let phone = try Device("Claude\nai => AI\n", learned: ["kian", "marimo"], cloud: cloud, clock: clock)

    clock.at(1); await phone.sync.start().value

    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast), "replace:ai": .init(line: "ai => AI", time: .distantPast)])
    #expect(cloud.learned == ["kian", "marimo"])
    #expect(phone.sync.status == .synced)
  }

  @Test func learnedWordsFromTwoDevicesBecomeTheirUnion() async throws {
    let phone = try Device("", learned: ["marimo"], cloud: cloud, clock: clock)
    let pad = try Device("", learned: ["kian"], cloud: cloud, clock: clock)

    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value
    clock.at(3); await phone.sync.sync().value

    #expect(phone.settings.learnedWords == ["kian", "marimo"])
    #expect(pad.settings.learnedWords == ["kian", "marimo"])
    #expect(cloud.learned == ["kian", "marimo"])
  }

  /// Only entries sync: comments, blank lines and a replacement missing a side stay where they are, while an
  /// entry from iCloud is added and one deleted there goes.
  @Test func commentsAndHeaderLinesSurviveAMergeUntouched() async throws {
    let pad = try Device("Fluide\nKian\n", cloud: cloud, clock: clock)
    clock.at(1); await pad.sync.start().value
    clock.at(5); try pad.dictionary.save("Fluide\n")  // Kian deleted at 5
    await pad.sync.sync().value
    let phone = try Device("# mine\nClaude\n\n# names\nKian\nbad =>\n", cloud: cloud, clock: clock)

    clock.at(6); await phone.sync.start().value  // a first sync: this device's Kian is older than the deletion

    #expect(phone.dictionary.text == "# mine\nClaude\n\n# names\nbad =>\nFluide\n")
  }

  /// A device's first sync, also one that had sync off until now, cannot tell its old entries from new ones: an
  /// entry deleted elsewhere goes, and one iCloud has never seen goes up.
  @Test func aFirstSyncHonoursADeletionMadeElsewhere() async throws {
    let phone = try Device("Claude\nFluide\n", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); try phone.dictionary.remove("Fluide")
    await phone.sync.sync().value
    let pad = try Device("Fluide\nKian\n", cloud: cloud, clock: clock)

    clock.at(10); await pad.sync.start().value

    #expect(pad.lines == ["Kian", "Claude"])
    #expect(cloud.records == ["term:claude": .init(line: "Claude", time: .distantPast),
                              "term:fluide": .init(line: nil, time: at(2), source: by("iPhone17,1")),
                              "term:kian": .init(line: "Kian", time: .distantPast)])
  }

  /// After its first sync, even an empty one, a device's new entry is a deliberate change and beats an older deletion.
  @Test func aWordAddedAfterTheFirstSyncBeatsAnEarlierDeletion() async throws {
    let pad = try Device("", model: "iPad16,3", cloud: cloud, clock: clock)
    clock.at(1); await pad.sync.start().value
    let phone = try Device("marimo\n", cloud: cloud, clock: clock)
    clock.at(2); await phone.sync.start().value
    clock.at(3); try phone.dictionary.remove("marimo")
    await phone.sync.sync().value

    clock.at(4); try pad.keyboard.addTerm("marimo")
    await pad.sync.sync().value

    #expect(pad.lines == ["marimo"])
    #expect(cloud.records == ["term:marimo": .init(line: "marimo", time: at(4), source: by("iPad16,3", "keyboard"))])
  }

  /// Last writer wins by when an entry was changed, not when its device synced: an edit made offline at 10 loses
  /// to one made at 20 elsewhere, though it reaches iCloud later.
  @Test func anOfflineEditLosesToALaterEditSyncedFirst() async throws {
    let phone = try Device("ai => AI\n", cloud: cloud, clock: clock)
    let pad = try Device("", model: "iPad16,3", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value

    clock.at(10); try phone.dictionary.save("ai => A.I.\n")
    clock.at(20); try pad.dictionary.save("ai => Ai\n")
    await pad.sync.sync().value
    clock.at(30); await phone.sync.sync().value

    #expect(phone.dictionary.text == "ai => Ai\n")
    #expect(cloud.records == ["replace:ai": .init(line: "ai => Ai", time: at(20), source: by("iPad16,3"))])
  }

  /// The same for a deletion: one made offline at 10 loses to an edit made at 20 elsewhere.
  @Test func anOfflineDeletionLosesToALaterEditSyncedFirst() async throws {
    let phone = try Device("ai => AI\n", cloud: cloud, clock: clock)
    let pad = try Device("", model: "iPad16,3", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value

    clock.at(10); try phone.dictionary.remove("ai => AI")
    clock.at(20); try pad.dictionary.save("ai => Ai\n")
    await pad.sync.sync().value
    clock.at(30); await phone.sync.sync().value

    #expect(phone.dictionary.text == "ai => Ai\n")
    #expect(cloud.records == ["replace:ai": .init(line: "ai => Ai", time: at(20), source: by("iPad16,3"))])
  }

  /// A download whose sync state could not be written is still not a change made here: when the entry it
  /// deleted is added again elsewhere (by a device whose clock reads earlier), the re-addition wins.
  @Test func aDownloadWhoseSyncStateWasNotWrittenIsNotALocalChange() async throws {
    let phone = try Device("Fluide\n", cloud: cloud, clock: clock)
    let pad = try Device("", model: "iPad16,3", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value
    clock.at(10); try pad.dictionary.remove("Fluide")
    await pad.sync.sync().value
    let state = phone.sync.stateFile.path()
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: state)
    clock.at(20); await phone.sync.sync().value  // writes the deletion, then fails to write its sync state
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: state)
    guard case .failed = phone.sync.status else { Issue.record("the state write did not fail: \(phone.sync.status)"); return }

    clock.at(15); try pad.dictionary.addTerm("Fluide")
    await pad.sync.sync().value
    clock.at(30); await phone.sync.sync().value

    #expect(phone.lines == ["Fluide"])
    #expect(cloud.records == ["term:fluide": .init(line: "Fluide", time: at(15), source: by("iPad16,3"))])
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

  @Test func switchedOffItReadsAndWritesNothing() async throws {
    let pad = try Device("Fluide\n", learned: ["kian"], cloud: cloud, clock: clock)
    clock.at(1); await pad.sync.start().value
    let before = cloud.contents, calls = cloud.calls
    let phone = try Device("Claude\n", learned: ["marimo"], cloud: cloud, clock: clock)
    phone.settings.iCloudSyncEnabled = false

    clock.at(2); await phone.sync.start().value
    await phone.sync.sync().value

    #expect(phone.dictionary.text == "Claude\n")
    #expect(phone.settings.learnedWords == ["marimo"])
    #expect(cloud.contents == before)
    #expect(cloud.calls == calls)
    #expect(!FileManager.default.fileExists(atPath: phone.sync.stateFile.path()))
    #expect(phone.sync.status == .off)
  }

  @Test func overTheSizeLimitItWritesNothingAndSaysWhy() async throws {
    let huge = String(repeating: "a", count: CloudKitDictionary.recordLimit / 2)
    let phone = try Device("Claude\n\(huge)\n", learned: ["marimo"], cloud: cloud, clock: clock)
    cloud.contents.learned = ["kian"]
    let before = cloud.contents

    clock.at(1); await phone.sync.start().value

    #expect(cloud.contents == before)
    #expect(phone.dictionary.text == "Claude\n\(huge)\n")
    #expect(phone.settings.learnedWords == ["marimo"])
    #expect(!FileManager.default.fileExists(atPath: phone.sync.stateFile.path()))
    #expect(phone.sync.status == .tooLarge(bytes: CloudKitDictionary.recordLimit + "term:".count + 8))
    #expect(ICloudSyncRow.subtitle(phone.sync.status, device: "iPhone").hasSuffix(", over the 1 MB iCloud allows in one record. Shorten it to sync again."))
  }

  @Test func withNoICloudAccountItSaysItIsWaitingAndTouchesNothing() async throws {
    cloud.available = false
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)

    clock.at(1); await phone.sync.start().value

    #expect(phone.sync.status == .waitingForICloud)
    #expect(cloud.contents == CloudContents())
    #expect(!FileManager.default.fileExists(atPath: phone.sync.stateFile.path()))
    #expect(ICloudSyncRow.subtitle(phone.sync.status, device: "iPhone") == "Waiting for iCloud: sign in to iCloud in Settings and your dictionary and kept words sync then.")
  }

  /// No push arrives from iCloud: a change made on another device is fetched when the app comes back to the
  /// foreground.
  @Test func returningToTheForegroundFetchesChangesMadeElsewhere() async throws {
    let phone = try Device("Claude\n", cloud: cloud, clock: clock)
    let pad = try Device("", cloud: cloud, clock: clock)
    clock.at(1); await phone.sync.start().value
    clock.at(2); await pad.sync.start().value
    try pad.dictionary.addTerm("Fluide")
    clock.at(3); await pad.sync.sync().value

    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    for _ in 0..<200 where phone.lines.count < 2 { try await Task.sleep(for: .milliseconds(10)) }

    #expect(phone.lines == ["Claude", "Fluide"])
  }
}
