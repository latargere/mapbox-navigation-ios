import CoreLocation
import Foundation
import MapboxNavigationNative

extension FixLocation {
    convenience init(_ location: CLLocation) {
        var bearingAccuracy: NSNumber? = nil
        if #available(iOS 13.4, *) {
            bearingAccuracy = location.courseAccuracy >= 0 ? location.courseAccuracy as NSNumber : nil
        }
        
        // In practice, “submillisecond precision” is 10 nanosecond precision at best, but convert the timestamp to nanoseconds anyways.
        // Unlike on Android, we aren’t concerned about the timestamps’ monotonicity.
        let timestamp = location.timestamp.timeIntervalSince1970 * 1e6
        
        self.init(coordinate: location.coordinate,
                  monotonicTimestampNanoseconds: UInt64(timestamp),
                  time: location.timestamp,
                  speed: location.speed >= 0 ? location.speed as NSNumber : nil,
                  bearing: location.course >= 0 ? location.course as NSNumber : nil,
                  altitude: location.altitude as NSNumber,
                  accuracyHorizontal: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy as NSNumber : nil,
                  provider: nil,
                  bearingAccuracy: bearingAccuracy,
                  speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy as NSNumber : nil,
                  verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy as NSNumber : nil)
    }
}
