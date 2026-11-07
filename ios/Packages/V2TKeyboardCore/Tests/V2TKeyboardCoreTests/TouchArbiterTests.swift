import CoreGraphics
import Foundation
import Testing
@testable import V2TKeyboardCore

/// Fast two-thumb typing fed as touch timelines (#140): every tap must type its key, in the order the fingers
/// landed, while one-finger swipes, long presses and the space-bar trackpad still work.
struct TouchArbiterTests {
  let layout = KeyboardLayout(width: 402, language: .english)

  enum Step {
    /// A finger lands on the centre of a key (" " is space) at a time in milliseconds.
    case down(Int, String, Double)
    /// The finger slides by (dx, dy) key widths from where it is, sampled every 8 ms (120 Hz), ending then.
    case slide(Int, CGFloat, CGFloat, Double)
    case up(Int, Double)
    /// The view takes the finger over: alternatives open, or the space bar turns into a trackpad.
    case hold(Int)
  }

  func key(_ s: String) -> Key {
    layout.keys.first { s == " " ? $0.action == .space : $0.action == .character(s) }!
  }

  /// Runs a timeline and returns what was typed; a swipe shows as "~" (its letters were not typed).
  func run(_ steps: [Step]) -> String {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    var at: [Int: (CGPoint, Double)] = [:]
    var out = ""
    func apply(_ events: [TouchArbiter<Int>.Event]) {
      for e in events {
        switch e {
        case .tapped(let k, _, _): out += k.action == .space ? " " : (k.output(shift: .off) ?? "")
        case .swiped: out += "~"
        case .swipeStarted: break
        }
      }
    }
    for step in steps {
      switch step {
      case .down(let f, let s, let ms):
        let k = key(s)
        arbiter.began(f, key: k, at: k.center, time: ms / 1000, canSwipe: k.startsSwipe)
        at[f] = (k.center, ms)
      case .slide(let f, let dx, let dy, let ms):
        let (p0, t0) = at[f]!
        let n = max(1, Int(((ms - t0) / 8).rounded(.up)))
        let p1 = CGPoint(x: p0.x + dx * layout.unitWidth, y: p0.y + dy * layout.unitWidth)
        let samples = (1...n).map { i -> (CGPoint, TimeInterval) in
          let u = CGFloat(i) / CGFloat(n)
          return (CGPoint(x: p0.x + (p1.x - p0.x) * u, y: p0.y + (p1.y - p0.y) * u), (t0 + (ms - t0) * Double(u)) / 1000)
        }
        apply(arbiter.moved(f, samples))
        at[f] = (p1, ms)
      case .up(let f, let ms):
        apply(arbiter.ended(f, at: at[f]!.0, time: ms / 1000))
      case .hold(let f):
        arbiter.hold(f, types: true)
      }
    }
    return out
  }

  /// Two thumbs typing `text`: keys left of the middle go to the left thumb, the rest to the right. Each tap
  /// lands `gap` ms after the last, stays down `hold` ms, and the thumb rolls `roll` key widths in its last
  /// 24 ms as it lifts. The first tap does not roll: with no typing before it, a slide that long is a swipe.
  func thumbs(_ text: String, gap: Double, hold: Double, roll: CGFloat) -> [Step] {
    var downs: [(Int, Double, Step)] = []
    for (i, c) in text.enumerated() {
      let s = String(c), k = key(s)
      let thumb = s == " " ? (i % 2) : (k.center.x < layout.width / 2 ? 0 : 1)
      // each tap gets its own finger id, as each landing is a new UITouch
      let f = i, t = Double(i) * gap, roll = i == 0 ? 0 : roll
      downs.append((f, t, .down(f, s, t)))
      if roll > 0 { downs.append((f, t + hold - 24, .slide(f, 0, 0, t + hold - 24))) }
      downs.append((f, t + hold, roll > 0 ? .slide(f, thumb == 0 ? roll : -roll, -roll / 2, t + hold) : .slide(f, 0, 0, t + hold)))
      downs.append((f, t + hold + 0.01, .up(f, t + hold + 0.01)))
    }
    return downs.sorted { $0.1 < $1.1 }.map(\.2)
  }

  @Test func overlappingThumbsTypeEveryLetterInOrder() {
    let text = "the quick brown fox jumps over"
    var failures: [String] = []
    for gap in stride(from: 40.0, through: 120, by: 10) {
      for hold in [60.0, 90, 130, 180] {
        for roll: CGFloat in [0, 0.3, 0.8, 1.2] {
          let got = run(thumbs(text, gap: gap, hold: hold, roll: roll))
          if got != text { failures.append("gap \(Int(gap)) hold \(Int(hold)) roll \(roll): \(got)") }
        }
      }
    }
    #expect(failures.isEmpty, "\(failures.count) timelines dropped or reordered letters:\n\(failures.prefix(12).joined(separator: "\n"))")
  }

  @Test func aShortTapDuringALongHoldTypesAfterIt() {
    // left thumb holds "t" 150 ms; the right thumb taps "y" inside that hold and lifts first
    #expect(run([.down(0, "t", 0), .down(1, "y", 60), .up(1, 110), .up(0, 150)]) == "ty")
  }

  @Test func aSlowSingleFingerSwipeStillSwipes() {
    #expect(run([.down(0, "t", 0), .slide(0, -3, 1, 250), .slide(0, 4, 0, 500), .up(0, 510)]) == "~")
  }

  @Test func aSwipeAfterAPauseSwipesEvenOneKeyLong() {
    // "we": the finger slides one key; nothing typed for a second before
    #expect(run([.down(0, "a", 0), .up(0, 80), .down(1, "w", 1100), .slide(1, 1, 0, 1250), .up(1, 1260)]) == "a~")
  }

  @Test func aSwipeStraightAfterTypingStillSwipesOnceItTravels() {
    // a tap, then 200 ms later a swipe across the keyboard over half a second
    #expect(run([.down(0, "i", 0), .up(0, 80), .down(1, "l", 280), .slide(1, -4, 0, 480), .slide(1, 3, -1, 780), .up(1, 790)]) == "i~")
  }

  @Test func aSecondFingerDoesNotTurnAFirstFingersSlideIntoASwipe() {
    #expect(run([.down(0, "t", 0), .down(1, "o", 30), .slide(0, 1.5, 0, 90), .up(0, 100), .up(1, 140)]) == "to")
  }

  @Test func heldAlternativesTypeNothingHereButReleaseOlderTapsFirst() {
    // "e" opens its accents (the view types the accent); "t", still down from before, types first
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let t = key("t"), e = key("e")
    arbiter.began(0, key: t, at: t.center, time: 0, canSwipe: true)
    arbiter.began(1, key: e, at: e.center, time: 0.05, canSwipe: true)
    let held = arbiter.hold(1, types: true)
    #expect(held)
    #expect(arbiter.ended(1, at: e.center, time: 0.6) == [.tapped(t, at: t.center, touch: 0)])
    #expect(arbiter.ended(0, at: t.center, time: 0.7).isEmpty)  // already typed
    #expect(arbiter.isEmpty)
  }

  @Test func touchesHandedOverTogetherTypeInLandingOrder() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let t = key("t"), y = key("y")
    // UIKit's touch set has no order: "y" registered first though "t" landed first
    arbiter.began(1, key: y, at: y.center, time: 0.06, canSwipe: true)
    arbiter.began(0, key: t, at: t.center, time: 0, canSwipe: true)
    #expect(arbiter.ended(1, at: y.center, time: 0.1) == [.tapped(t, at: t.center, touch: 0), .tapped(y, at: y.center, touch: 1)])
  }

  @Test func aSlideWaitingOutTheDelayCannotOpenAlternatives() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let a = key("a"), e = key("e")
    arbiter.began(0, key: a, at: a.center, time: 0, canSwipe: true)
    _ = arbiter.ended(0, at: a.center, time: 0.08)
    arbiter.began(1, key: e, at: e.center, time: 0.2, canSwipe: true)
    // 0.82 key widths by the 0.42 s long-press timer: not yet a swipe after typing, but no long press either
    let p = CGPoint(x: e.center.x - 0.82 * layout.unitWidth, y: e.center.y)
    _ = arbiter.moved(1, [(p, 0.62)])
    let held = arbiter.hold(1, types: true)
    #expect(!held && arbiter.mode(of: 1) == .tap)
  }

  @Test func aSlideOutAndBackCannotOpenAlternativesEither() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let a = key("a"), e = key("e")
    arbiter.began(0, key: a, at: a.center, time: 0, canSwipe: true)
    _ = arbiter.ended(0, at: a.center, time: 0.08)
    arbiter.began(1, key: e, at: e.center, time: 0.2, canSwipe: true)
    _ = arbiter.moved(1, [(CGPoint(x: e.center.x - 1.2 * layout.unitWidth, y: e.center.y), 0.4), (e.center, 0.61)])
    let held = arbiter.hold(1, types: true)
    #expect(!held)
  }

  @Test func aTapRightAfterAnAccentStaysATap() {
    // "e" held for an accent, then a quick tap that rolls 0.8 key widths: still typing, so not a swipe
    #expect(run([.down(0, "e", 0), .hold(0), .up(0, 600), .down(1, "t", 700), .slide(1, 0.8, 0, 760), .up(1, 770)]) == "t")
  }

  @Test func aFingerDownWhenThePageChangesTapsRatherThanSwipes() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let t = key("t")
    arbiter.began(0, key: t, at: t.center, time: 0, canSwipe: true)
    arbiter.stopSwipes()  // 123 released under another finger
    let events = arbiter.moved(0, [(CGPoint(x: t.center.x + 3 * layout.unitWidth, y: t.center.y), 0.3)])
    #expect(events.isEmpty && arbiter.mode(of: 0) == .tap)
  }

  @Test func theSpaceBarTrackpadTypesNoSpace() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let space = key(" ")
    arbiter.began(0, key: space, at: space.center, time: 0, canSwipe: false)
    let held = arbiter.hold(0, types: false)
    #expect(held)
    _ = arbiter.moved(0, [(CGPoint(x: space.center.x + 5 * layout.unitWidth, y: space.center.y), 0.9)])
    #expect(arbiter.ended(0, at: space.center, time: 1.2).isEmpty)
  }

  @Test func aRolledOverTapCannotBeHeldAfterwards() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let t = key("t"), y = key("y")
    arbiter.began(0, key: t, at: t.center, time: 0, canSwipe: true)
    arbiter.began(1, key: y, at: y.center, time: 0.05, canSwipe: true)
    _ = arbiter.ended(1, at: y.center, time: 0.1)
    #expect(arbiter.mode(of: 0) == .spent)
    let held = arbiter.hold(0, types: true)
    #expect(!held)  // its long-press timer firing late opens nothing
  }

  @Test func otherKeysActOnlyOnTheirOwnLiftAndNeverRollOver() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let shift = layout.keys.first { $0.action == .shift }!, a = key("a")
    arbiter.began(0, key: shift, at: shift.center, time: 0, canSwipe: false)
    arbiter.began(1, key: a, at: a.center, time: 0.05, canSwipe: true)
    #expect(arbiter.ended(1, at: a.center, time: 0.1) == [.tapped(a, at: a.center, touch: 1)])
    #expect(arbiter.ended(0, at: shift.center, time: 0.2) == [.tapped(shift, at: shift.center, touch: 0)])
  }

  @Test func aCancelledTouchTypesNothing() {
    var arbiter = TouchArbiter<Int>(unitWidth: layout.unitWidth)
    let a = key("a")
    arbiter.began(0, key: a, at: a.center, time: 0, canSwipe: true)
    arbiter.cancelled(0)
    #expect(arbiter.ended(0, at: a.center, time: 0.1).isEmpty)
  }
}
