import Foundation
import Testing
import UIKit

/// The emoji panel's font-swap budget (EmojiFont, compiled in from the keyboard): it must exceed what the grid
/// can show, or the redraw after a swap would set off the next swap, forever.
@MainActor struct EmojiPanelTests {
  struct Grid: Sendable {
    let viewport: CGSize, cell: CGSize, expected: Int
  }

  // the grid sizes EmojiPanel.sizeCells gives: iPhone (5 rows of 37 pt), 11-inch iPad portrait, 13-inch landscape
  nonisolated static let grids: [Grid] = [
    Grid(viewport: CGSize(width: 402, height: 188), cell: CGSize(width: 42, height: 37), expected: 124),
    Grid(viewport: CGSize(width: 834, height: 290), cell: CGSize(width: 58, height: 48), expected: 206),
    Grid(viewport: CGSize(width: 1376, height: 414), cell: CGSize(width: 79, height: 69), expected: 242),
  ]

  @Test(arguments: grids)
  func theSwapBudgetExceedsTwoScreensOfTheGrid(_ g: Grid) {
    let limit = EmojiFont.limit(viewport: g.viewport, cell: g.cell)
    #expect(limit == g.expected)
    let rows = Int(g.viewport.height / g.cell.height)
    let columns = Int((g.viewport.width / g.cell.width).rounded(.up)) + 1
    #expect(limit >= 2 * rows * columns + PairPicker.glyphs)  // and an open pair picker on top
  }
}
