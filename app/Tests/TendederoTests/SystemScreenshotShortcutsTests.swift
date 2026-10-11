import XCTest
@testable import Tendedero

final class SystemScreenshotShortcutsTests: XCTestCase {
    func testCategoryMatchIsExactAndCannotSelectModifierOrScreenshotActions() {
        XCTAssertTrue(ScreenshotCategorySelection.matches("Screenshots shortcuts"))
        XCTAssertTrue(ScreenshotCategorySelection.matches("截屏快捷键"))
        XCTAssertFalse(ScreenshotCategorySelection.matches("修饰键"))
        XCTAssertFalse(ScreenshotCategorySelection.matches("截屏"))
        XCTAssertFalse(ScreenshotCategorySelection.matches("Save picture of screen as a file"))
        XCTAssertFalse(ScreenshotCategorySelection.matches("Screenshots shortcuts help"))
        XCTAssertFalse(ScreenshotCategorySelection.matches(nil))
    }
}
