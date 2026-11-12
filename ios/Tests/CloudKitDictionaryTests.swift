import CloudKit
import Foundation
import Testing
@testable import V2T

/// How an entry and the learned words map onto CloudKit records. Builds and reads records in memory only, so no
/// iCloud account is needed; whether CloudKit then encrypts them on the way up is Apple's part, untested here.
struct CloudKitDictionaryTests {
  let time = Date(timeIntervalSince1970: 5)

  @Test func anEntryKeepsItsWordsInEncryptedFieldsOnly() {
    let entry = DictionaryMerge.Record(line: "ai => AI", time: time, source: .init(device: "iPhone17,1", app: "keyboard"))

    let r = CloudKitDictionary.record(key: "replace:ai", entry)

    #expect([r.recordType, r.recordID.zoneID.zoneName] == ["DictionaryEntry", "Dictionary"])
    #expect(r.encryptedValues["key"] as? String == "replace:ai")
    #expect(r.encryptedValues["line"] as? String == "ai => AI")
    #expect([r["key"], r["line"]].allSatisfy { $0 == nil })
    #expect(r["time"] as? Date == time)
    #expect([r["sourceDevice"] as? String, r["sourceApp"] as? String] == ["iPhone17,1", "keyboard"])
  }

  /// Record names are not encrypted, so they carry a hash of the key, never its words.
  @Test func anEntrysRecordIsNamedByAHashOfItsKey() {
    let r = CloudKitDictionary.record(key: "term:claude", .init(line: "Claude", time: time))

    #expect(r.recordID.recordName == "entry-c20ad8da570995715dbad3cc3e30951035bc5504a3bc04110b8c5a8735bf94fb")
  }

  @Test(arguments: [
    DictionaryMerge.Record(line: "Claude", time: Date(timeIntervalSince1970: 5), source: .init(device: "iPad16,3", app: "app")),
    DictionaryMerge.Record(line: nil, time: Date(timeIntervalSince1970: 5), source: .init(device: "iPhone17,1", app: "app")),
    DictionaryMerge.Record(line: "Claude", time: .distantPast, source: nil),
  ])
  func anEntryReadsBackAsItWasWritten(entry: DictionaryMerge.Record) throws {
    let r = CloudKitDictionary.record(key: "term:claude", entry)

    let back = try #require(CloudKitDictionary.entry(from: r))

    #expect(back.key == "term:claude")
    #expect(back.record == entry)
  }

  /// The account check answers within its deadline even when CloudKit does not (as in the Simulator with no account).
  @MainActor @Test func aCheckThatNeverAnswersGivesTheFallbackAtTheDeadline() async {
    let start = ContinuousClock.now

    let answer = await CloudKitDictionary.answer(within: .milliseconds(100), or: false) {
      try? await Task.sleep(for: .seconds(30))
      return true
    }

    #expect(answer == false)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @MainActor @Test func aCheckThatAnswersInTimeGivesItsAnswer() async {
    let answer = await CloudKitDictionary.answer(within: .seconds(30), or: false) { true }

    #expect(answer == true)
  }

  /// A conditional save that met a newer server record: the server's wins when it is later, and nothing is saved.
  @Test func aConflictWithALaterServerEntryKeepsTheServers() {
    let mine = CloudKitDictionary.record(key: "replace:ai", .init(line: "ai => A.I.", time: Date(timeIntervalSince1970: 10)))
    let server = CloudKitDictionary.record(key: "replace:ai", .init(line: "ai => Ai", time: Date(timeIntervalSince1970: 20)))

    #expect(CloudKitDictionary.resolve(mine, against: server) == nil)
  }

  /// Mine is later: its fields go onto the server's record (whose change tag the next save must carry).
  @Test func aConflictWithAnEarlierServerEntryPutsMineOnTheServersRecord() throws {
    let entry = DictionaryMerge.Record(line: nil, time: Date(timeIntervalSince1970: 30), source: .init(device: "iPhone17,1", app: "app"))
    let mine = CloudKitDictionary.record(key: "replace:ai", entry)
    let server = CloudKitDictionary.record(key: "replace:ai", .init(line: "ai => Ai", time: Date(timeIntervalSince1970: 20)))

    let resolved = try #require(CloudKitDictionary.resolve(mine, against: server))

    #expect(resolved === server)
    #expect(CloudKitDictionary.entry(from: resolved)?.record == entry)
  }

  @Test func aConflictOnLearnedWordsSavesTheirUnionOnTheServersRecord() throws {
    let server = CloudKitDictionary.record(learned: ["kian", "fluide"])

    let resolved = try #require(CloudKitDictionary.resolve(CloudKitDictionary.record(learned: ["marimo", "kian"]), against: server))

    #expect(resolved === server)
    #expect(CloudKitDictionary.learned(from: resolved) == ["fluide", "kian", "marimo"])
  }

  @Test func aConflictOnLearnedWordsTheServerAlreadyHasSavesNothing() {
    let server = CloudKitDictionary.record(learned: ["kian", "marimo"])

    #expect(CloudKitDictionary.resolve(CloudKitDictionary.record(learned: ["marimo"]), against: server) == nil)
  }

  @Test func learnedWordsAreOneEncryptedListThatReadsBack() {
    let r = CloudKitDictionary.record(learned: ["marimo", "kian"])

    #expect([r.recordType, r.recordID.recordName] == ["LearnedWords", "learnedWords"])
    #expect(r.encryptedValues["words"] as? [String] == ["kian", "marimo"])
    #expect(r["words"] == nil)
    #expect(CloudKitDictionary.learned(from: r) == ["kian", "marimo"])
  }
}
