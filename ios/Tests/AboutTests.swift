import Foundation
import Testing
@testable import V2T

struct AboutTests {
  let defaults = UserDefaults(suiteName: "v2t-about-\(UUID().uuidString)")!

  @Test func notShownAfterInstall() {
    let settings = Settings(defaults: defaults)

    #expect(settings.aboutShown == false)
  }

  @Test func shownIsKeptAcrossARelaunch() {
    Settings(defaults: defaults).aboutShown = true

    #expect(Settings(defaults: defaults).aboutShown == true)
  }
}
