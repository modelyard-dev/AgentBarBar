import XCTest
@testable import AgentBarBarCore

final class AppearanceTests: XCTestCase {
    func testExistingSettingsKeepDefaultAppearance() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"language\":\"en\"}".utf8))
        XCTAssertEqual(settings.dashboardTheme, "forest")
        XCTAssertEqual(settings.dashboardAppearance, "system")
        XCTAssertNoThrow(try settings.validated())
    }

    func testAppearanceRoundTripDoesNotChangeCollectionConfiguration() throws {
        let original = AppSettings()
        for theme in ["forest", "paper", "ocean", "mono"] {
            for appearance in ["system", "light", "dark"] {
                var settings = original
                settings.dashboardTheme = theme; settings.dashboardAppearance = appearance
                let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
                XCTAssertEqual(decoded.dashboardTheme, theme)
                XCTAssertEqual(decoded.dashboardAppearance, appearance)
                XCTAssertEqual(decoded.collectorConfiguration, original.collectorConfiguration)
                XCTAssertNoThrow(try decoded.validated())
            }
        }
        var invalid = original; invalid.dashboardTheme = "unknown"
        XCTAssertThrowsError(try invalid.validated())
        invalid = original; invalid.dashboardAppearance = "unknown"
        XCTAssertThrowsError(try invalid.validated())
    }
}
