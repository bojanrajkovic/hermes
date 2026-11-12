import SwiftUI

/// Centralized layout metrics + type system (SWIFTUI-RULES §2.4, §5.1).
///
/// Two rules keep this honest:
/// - **Scale** comes from semantic SwiftUI text styles only (`.caption` →
///   `.body` → `.title2` → `.largeTitle`), never hardcoded point sizes, so
///   Dynamic Type and OS metric updates keep working.
/// - **Emphasis is weight; de-emphasis is color** (`.secondary` /
///   `.tertiary`), never a lighter font weight.
///
/// When you find yourself typing the same number a third time, it belongs
/// here as a named metric.
public enum Theme {
    // MARK: Window
    public static let windowMinWidth: CGFloat = 900
    public static let windowMinHeight: CGFloat = 520
    public static let windowDefaultWidth: CGFloat = 1360
    public static let windowDefaultHeight: CGFloat = 860
    /// The first-run setup sheet.
    public static let setupWidth: CGFloat = 520
    public static let setupHeight: CGFloat = 420

    // MARK: Sidebar
    public static let sidebarMinWidth: CGFloat = 200
    public static let sidebarIdealWidth: CGFloat = 240
    public static let sidebarMaxWidth: CGFloat = 320
    /// A sidebar that holds pull request and issue rows, not only names.

    // MARK: List column (the middle column of a three-column layout)
    /// Wide enough for the toolbar above the column to hold the list control, also when the sidebar
    /// is hidden and the window buttons and the sidebar button sit there too.
    public static let listColumnMinWidth: CGFloat = 400
    public static let listColumnIdealWidth: CGFloat = 420
    public static let listColumnMaxWidth: CGFloat = 560

    // MARK: Rows
    public static let avatarSize: CGFloat = 16
    /// Vertical padding inside a two-line pull request or issue row.
    public static let rowVerticalPadding: CGFloat = 3
    /// Gap between a row's leading glyph and its text.
    public static let rowGlyphSpacing: CGFloat = 8
    /// Gap between items on a row's metadata line.
    public static let rowMetaSpacing: CGFloat = 6

    // MARK: Detail panes
    public static let detailInset: CGFloat = 20
    public static let cardCornerRadius: CGFloat = 8
    public static let cardPadding: CGFloat = 12
    /// Width cap for a conversation: wider than prose, for code blocks and tables.
    public static let conversationMaxWidth: CGFloat = 860

    // MARK: Reading column
    /// Cap the measure so body lines stay near the 60–75 character ideal for
    /// comfortable reading regardless of window width.
    public static let readingMaxWidth: CGFloat = 660
    public static let readingHorizontalInset: CGFloat = 32
    public static let readingTopInset: CGFloat = 28
    public static let readingBottomInset: CGFloat = 40
    /// Gap between a section heading and the next.
    public static let readingSectionSpacing: CGFloat = 28
    /// Gap between a heading and its body.
    public static let readingHeadingSpacing: CGFloat = 8
    /// Extra leading added to body paragraphs for readability.
    public static let bodyLineSpacing: CGFloat = 6

    // MARK: Table
    public static let badgeCornerRadius: CGFloat = 4
    public static let badgePaddingHorizontal: CGFloat = 7
    public static let badgePaddingVertical: CGFloat = 2

    // MARK: Type scale
    //
    // The whole app's typography lives here so hierarchy stays consistent and
    // a future restyle lands in one place.
    public enum Fonts {
        /// The reading column's page title — the hero.
        public static let pageTitle = Font.largeTitle.weight(.bold)
        /// The standfirst/lead under the title — set in a quieter color, not
        /// a lighter weight.
        public static let pageLead = Font.title3
        /// A section heading within the reading column.
        public static let sectionHeading = Font.title2.weight(.semibold)
        /// Reading body copy.
        public static let body = Font.body
        /// Metadata: timestamps, counts, the footer line.
        public static let meta = Font.caption

        /// A table cell's primary text.
        public static let tableCell = Font.body
        /// Numeric table cells — tabular figures so columns align.
        public static let tableNumber = Font.body.monospacedDigit()
        /// The status badge label.
        public static let badge = Font.caption.weight(.medium)

        /// A pull request or issue title in a list row.
        public static let rowTitle = Font.body
        /// The second line of a list row: number, counts, age.
        public static let rowMeta = Font.caption
        /// The title in a detail pane's header.
        public static let detailTitle = Font.title2.weight(.semibold)
        /// A heading inside a detail pane, such as "Commits".
        public static let paneHeading = Font.headline
        /// Branch names and commit SHAs.
        public static let code = Font.callout.monospaced()
    }
}
