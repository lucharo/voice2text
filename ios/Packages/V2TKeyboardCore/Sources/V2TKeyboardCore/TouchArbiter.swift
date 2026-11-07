import CoreGraphics
import Foundation

/// Decides, for every finger on the keys, whether it is a tap or a swipe, and keeps fast two-thumb typing in
/// order (#140). It holds no timers and draws nothing: `KeyboardView` feeds it touches and acts on what it
/// returns, and the tests feed it whole timelines.
///
/// Three rules keep a fast tap from being read as a swipe, all from Android's open-source keyboard (AOSP
/// LatinIME, the code Gboard grew from):
/// - **Rollover.** When a finger lifts, every older finger still down on a letter or space types first, in
///   the order they landed (LatinIME `PointerTracker.onUpEvent`, `PointerTrackerQueue.releaseAllPointersOlderThan`).
/// - **One finger swipes.** A finger slides into a swipe only while it is the only one on the keys; with
///   another finger down it stays a tap (LatinIME "detected sliding finger while multi touching").
/// - **No swipe straight after typing.** A finger that lands within 350 ms of the last tap (or while another
///   finger types) needs to travel
///   6 key widths, falling to the usual 0.7 over 450 ms, and to stay down at least 300 ms falling to 20 ms,
///   before it becomes a swipe (LatinIME `GestureStrokeRecognitionParams`: 350 ms, 6.0 → 0.35 key widths,
///   300 → 20 ms, 450 ms decay). A thumb that rolls as it lifts no longer turns its letter into a swipe.
///
/// And one for touch screens that merge two quick taps into one finger that jumps: a tap whose position
/// moves a key width or more between two samples types its first key and starts again on the second
/// (LatinIME `processPhantomSuddenMoveHack`).
public struct TouchArbiter<ID: Hashable> {
  /// What a finger's progress means for the keyboard.
  public enum Event: Equatable {
    /// A tap released: a character key types, other keys act (delete has already acted on touch-down).
    case tapped(Key, at: CGPoint, touch: ID)
    /// A finger crossed the threshold: stop its long-press timer, hide its balloon, draw a trail.
    case swipeStarted(touch: ID)
    /// A swipe ended; decode this trace.
    case swiped([CGPoint], touch: ID)
    /// A jump started a new tap on this key for the same finger (show its balloon).
    case pressed(Key, touch: ID)
  }

  public enum Mode: Equatable {
    /// A character or space key, released early by a newer finger lifting.
    case tap
    /// Any other key: acts only when its own finger lifts, and never swipes.
    case press
    case swiping
    /// The view owns it: long-press alternatives or the space-bar trackpad.
    case held
    /// Already typed by rollover; the finger is still down but means nothing more.
    case spent
  }

  private struct Track {
    let id: ID
    let key: Key
    let start: CGPoint
    let began: TimeInterval
    var points: [CGPoint]
    var mode: Mode
    let canSwipe: Bool
  }

  /// One key's width, the unit of every distance.
  public var unitWidth: CGFloat
  /// Distance a finger travels before it becomes a swipe, in key widths.
  public static var swipeDistance: CGFloat { 0.7 }
  static var fastTypingWindow: TimeInterval { 0.35 }
  static var fastTypingDecay: TimeInterval { 0.45 }
  static var fastTypingDistance: CGFloat { 6 }
  static var fastTypingTime: (from: TimeInterval, to: TimeInterval) { (0.30, 0.02) }
  /// A jump this far between two samples of one tap is two fingers, in key widths.
  static var jumpDistance: CGFloat { 1 }

  private var tracks: [Track] = []
  private var lastTap: TimeInterval?

  public init(unitWidth: CGFloat) { self.unitWidth = unitWidth }

  public func mode(of id: ID) -> Mode? { tracks.first { $0.id == id }?.mode }
  public func points(of id: ID) -> [CGPoint] { tracks.first { $0.id == id }?.points ?? [] }
  public var isEmpty: Bool { tracks.isEmpty }

  /// A finger landed on `key`. `canSwipe`: a letter key on the letters page.
  public mutating func began(_ id: ID, key: Key, at p: CGPoint, time: TimeInterval, canSwipe: Bool) {
    tracks.removeAll { $0.id == id }
    tracks.append(track(id, key: key, at: p, time: time, canSwipe: canSwipe))
  }

  private func track(_ id: ID, key: Key, at p: CGPoint, time: TimeInterval, canSwipe: Bool) -> Track {
    let releasable = key.isCharacter || key.action == .space
    return Track(id: id, key: key, start: p, began: time, points: [p], mode: releasable ? .tap : .press,
                 canSwipe: canSwipe)
  }

  /// The finger moved through these samples, oldest first. `keyAt` finds the key under a point, for a jump.
  public mutating func moved(_ id: ID, _ samples: [(CGPoint, TimeInterval)], canSwipe: (Key) -> Bool,
                             keyAt: (CGPoint) -> Key?) -> [Event] {
    var events: [Event] = []
    for (p, t) in samples {
      guard let i = tracks.firstIndex(where: { $0.id == id }) else { break }
      let last = tracks[i].points.last ?? p
      if tracks[i].mode == .tap, hypot(p.x - last.x, p.y - last.y) >= Self.jumpDistance * unitWidth,
         let next = keyAt(p), next.id != tracks[i].key.id {
        events += release(i, at: last, time: t)
        if next.isCharacter || next.action == .space {
          tracks[i] = track(id, key: next, at: p, time: t, canSwipe: canSwipe(next))
          events.append(.pressed(next, touch: id))
        } else {
          tracks[i].mode = .spent
        }
        continue
      }
      tracks[i].points.append(p)
      if tracks[i].mode == .tap, tracks[i].canSwipe, startsSwipe(tracks[i], at: p, time: t) {
        tracks[i].mode = .swiping
        events.append(.swipeStarted(touch: id))
      }
    }
    return events
  }

  private func startsSwipe(_ track: Track, at p: CGPoint, time: TimeInterval) -> Bool {
    guard tracks.count == 1 else { return false }
    let travelled = hypot(p.x - track.start.x, p.y - track.start.y)
    let base = Self.swipeDistance * unitWidth
    // a tap typed shortly before this finger landed, or by another finger while it was down
    guard let lastTap, lastTap > track.began - Self.fastTypingWindow else { return travelled > base }
    let elapsed = time - track.began
    let decay = max(0, 1 - elapsed / Self.fastTypingDecay)
    let distance = base + (Self.fastTypingDistance * unitWidth - base) * decay
    let (from, to) = Self.fastTypingTime
    return travelled > distance && elapsed >= to + (from - to) * decay
  }

  /// The view took this finger over (alternatives showed, or the space bar became a trackpad). False when
  /// rollover has already typed it.
  @discardableResult public mutating func hold(_ id: ID) -> Bool {
    guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].mode == .tap || tracks[i].mode == .press
    else { return false }
    tracks[i].mode = .held
    return true
  }

  /// The finger lifted. Older fingers still on a letter or space type first.
  public mutating func ended(_ id: ID, at p: CGPoint, time: TimeInterval) -> [Event] {
    guard let i = tracks.firstIndex(where: { $0.id == id }) else { return [] }
    var events: [Event] = []
    let track = tracks[i]
    if track.mode != .spent {
      for j in 0..<i where tracks[j].mode == .tap {
        events += release(j, at: tracks[j].points.last ?? tracks[j].start, time: time)
      }
    }
    switch track.mode {
    case .tap, .press:
      events.append(.tapped(track.key, at: p, touch: id))
      if track.mode == .tap { lastTap = time }
    case .swiping: events.append(.swiped(track.points + [p], touch: id))
    case .held, .spent: break
    }
    tracks.removeAll { $0.id == id }
    return events
  }

  /// The system took the touch away: it means nothing.
  public mutating func cancelled(_ id: ID) {
    tracks.removeAll { $0.id == id }
  }

  private mutating func release(_ i: Int, at p: CGPoint, time: TimeInterval) -> [Event] {
    tracks[i].mode = .spent
    lastTap = time
    return [.tapped(tracks[i].key, at: p, touch: tracks[i].id)]
  }
}
