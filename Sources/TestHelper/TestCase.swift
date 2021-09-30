import Foundation
import XCTest
@testable import MapboxDirections
@testable import MapboxCoreNavigation
#if canImport(MapboxMaps)
import MapboxMaps
#endif

/// Base Mapbox XCTestCase class with common setup logic
open class TestCase: XCTestCase {
    public var billingServiceMock: BillingServiceMock!

    /// Inidicates whether one time initialization completed in ``initializeIfNeeded`` method.
    private static var isInitializationCompleted: Bool = false

    open override class func setUp() {
        super.setUp()
        initializeIfNeeded()
    }

    open override func setUp() {
        super.setUp()
        NavigationSettings.shared.initialize(directions: .mocked, tileStoreConfiguration: .default)
        billingServiceMock = .init()
        BillingHandler.__replaceSharedInstance(with: BillingHandler.__createMockedHandler(with: billingServiceMock))
        Navigator.shared.navigator.resetRideSession()
        Navigator._recreateNavigator()
    }

    /// Prepares tests for execution. Should be called once before any test runs.
    private static func initializeIfNeeded() {
        guard !isInitializationCompleted else { return }
        isInitializationCompleted = true

        DirectionsCredentials.injectSharedToken(.mockedAccessToken)
        #if canImport(MapboxMaps)
        ResourceOptionsManager.default.resourceOptions.accessToken = .mockedAccessToken
        #endif
        UserDefaults.standard.set("Location Usage Description", forKey: "NSLocationWhenInUseUsageDescription")
        UserDefaults.standard.set("Location Usage Description", forKey: "NSLocationAlwaysAndWhenInUseUsageDescription")
    }
}
