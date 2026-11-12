import CloudKit
import CryptoKit
import Foundation

/// What iCloud holds for the dictionary: each entry's record by key, and the learned words.
struct CloudContents: Equatable, Sendable {
  var entries: DictionaryMerge.Records = [:]
  var learned: Set<String> = []
}

/// Where the sync reads and writes: the user's private CloudKit database in the app, an in-memory one in tests.
@MainActor protocol DictionaryCloud: AnyObject {
  /// Whether the device has an iCloud account the private database can be used with.
  func accountAvailable() async -> Bool
  func fetch() async throws -> CloudContents
  /// Saves these entry records (the ones that changed) and, when not nil, the learned words.
  func save(entries: DictionaryMerge.Records, learned: Set<String>?) async throws
}

/// The dictionary in the user's private CloudKit database, in the container iCloud.es.luischav.v2t. What Apple
/// documents, read 12 November 2026:
/// - https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase: "Only the user can
///   access their private database, by default." "Data in the private database isn't visible in the developer
///   portal." "Data in the private database counts toward the user's iCloud storage quota."
/// - https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues: "CloudKit encrypts the fields'
///   values on-device before saving them to iCloud, and decrypts the values only after fetching them from the
///   server. When you enable Advanced Data Protection, the encryption keys are available exclusively to the
///   record's owner". Record names and the fields outside `encryptedValues` are not encrypted, so a record's name
///   is a hash of its key and its words are only ever in encrypted fields.
/// - https://developer.apple.com/documentation/cloudkit/ckrecord: "the data that a record stores must not exceed
///   1 MB." (`recordLimit`)
/// - https://developer.apple.com/documentation/cloudkit/ckerror/code/limitexceeded: "400 items (records or
///   shares) per operation", "2 MB per request", and "If your app receives limitExceeded, it must split the
///   operation in half and try both requests again."
/// - https://developer.apple.com/documentation/cloudkit/ckrecordzone: records go in a custom zone, whose changes
///   can be fetched without a query index.
/// The record schema is written out in ios/README.md ("iCloud records").
final class CloudKitDictionary: DictionaryCloud {
  nonisolated static let containerID = "iCloud.es.luischav.v2t"
  nonisolated static let zoneID = CKRecordZone.ID(zoneName: "Dictionary")
  nonisolated static let entryType = "DictionaryEntry", learnedType = "LearnedWords"
  nonisolated static let learnedName = "learnedWords"
  nonisolated static let recordLimit = 1_000_000
  nonisolated static let operationLimit = 400

  private let container = CKContainer(identifier: CloudKitDictionary.containerID)
  private var database: CKDatabase { container.privateCloudDatabase }

  /// How long the account check may take before the sync counts the account as not there yet: CloudKit's request
  /// timeout is URLSession's `timeoutIntervalForRequest`
  /// (https://developer.apple.com/documentation/cloudkit/ckoperation/configuration-swift.class/timeoutintervalforrequest),
  /// whose "default value is `60`" (https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest).
  /// In the Simulator with no iCloud account, `accountStatus()` gave no answer for over nine minutes.
  nonisolated static let accountDeadline = Duration.seconds(60)

  func accountAvailable() async -> Bool {
    let container = container
    return await Self.answer(within: Self.accountDeadline, or: false) { (try? await container.accountStatus()) == .available }
  }

  /// `work`'s answer, or `fallback` once `deadline` passes first; a late answer is dropped, and the work, which
  /// CloudKit gives no way to cancel, finishes on its own.
  static func answer<T: Sendable>(within deadline: Duration, or fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
    await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
      var answered = false
      let reply = { (value: T) in
        guard !answered else { return }
        answered = true
        c.resume(returning: value)
      }
      Task { reply(await work()) }
      Task { try? await Task.sleep(for: deadline); reply(fallback) }
    }
  }

  /// Every record in the zone. No change token is kept: the dictionary is small, and the merge needs all of it.
  func fetch() async throws -> CloudContents {
    var contents = CloudContents()
    var token: CKServerChangeToken?
    var more = true
    while more {
      let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                    deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
      do {
        changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
      } catch let e as CKError where e.code == .zoneNotFound {
        return contents  // nothing saved yet: the first save creates the zone
      }
      for result in changes.modificationResultsByID.values {
        let record = try result.get().record
        if record.recordType == Self.learnedType {
          contents.learned = Self.learned(from: record)
        } else if let (key, entry) = Self.entry(from: record) {
          contents.entries[key] = entry
        }
      }
      token = changes.changeToken
      more = changes.moreComing
    }
    return contents
  }

  func save(entries: DictionaryMerge.Records, learned: Set<String>?) async throws {
    var records = entries.map { Self.record(key: $0.key, $0.value) }
    if let learned { records.append(Self.record(learned: learned)) }
    guard !records.isEmpty else { return }
    _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
    for start in stride(from: 0, to: records.count, by: Self.operationLimit) {
      try await save(Array(records[start..<min(start + Self.operationLimit, records.count)]))
    }
  }

  /// Saves over whatever the server holds: the merge already chose each record against a fresh fetch.
  private func save(_ records: [CKRecord]) async throws {
    do {
      let results = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
      for result in results.saveResults.values { _ = try result.get() }
    } catch let e as CKError where e.code == .limitExceeded && records.count > 1 {
      try await save(Array(records[..<(records.count / 2)]))
      try await save(Array(records[(records.count / 2)...]))
    }
  }

  // MARK: Records

  /// The record's name: a hash, since record names are not encrypted and a key holds the entry's words.
  nonisolated static func recordName(key: String) -> String {
    "entry-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  nonisolated static func record(key: String, _ entry: DictionaryMerge.Record) -> CKRecord {
    let r = CKRecord(recordType: entryType, recordID: CKRecord.ID(recordName: recordName(key: key), zoneID: zoneID))
    r.encryptedValues["key"] = key
    r.encryptedValues["line"] = entry.line
    r["time"] = entry.time
    r["sourceDevice"] = entry.source?.device
    r["sourceApp"] = entry.source?.app
    return r
  }

  nonisolated static func entry(from r: CKRecord) -> (key: String, record: DictionaryMerge.Record)? {
    guard r.recordType == entryType, let key = r.encryptedValues["key"] as? String, let time = r["time"] as? Date else { return nil }
    let source = (r["sourceDevice"] as? String).flatMap { device in
      (r["sourceApp"] as? String).map { DictionaryMerge.Source(device: device, app: $0) }
    }
    return (key, DictionaryMerge.Record(line: r.encryptedValues["line"] as? String, time: time, source: source))
  }

  nonisolated static func record(learned: Set<String>) -> CKRecord {
    let r = CKRecord(recordType: learnedType, recordID: CKRecord.ID(recordName: learnedName, zoneID: zoneID))
    r.encryptedValues["words"] = learned.sorted()
    return r
  }

  nonisolated static func learned(from r: CKRecord) -> Set<String> {
    Set(r.encryptedValues["words"] as? [String] ?? [])
  }

  /// The bytes of a record's own text, which is what counts against `recordLimit` here; Apple does not say how it
  /// counts encryption's overhead.
  nonisolated static func size(key: String, _ entry: DictionaryMerge.Record) -> Int {
    key.utf8.count + (entry.line?.utf8.count ?? 0) + (entry.source.map { $0.device.utf8.count + $0.app.utf8.count } ?? 0) + 8
  }

  nonisolated static func size(learned: Set<String>) -> Int { learned.reduce(0) { $0 + $1.utf8.count } }
}
