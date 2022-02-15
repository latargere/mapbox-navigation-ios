import UIKit
import MapboxMaps

extension UIColor {

    /**
     Returns `UIImage` representation of a `UIColor`.
     
     - parameter size: optional size of `UIImage`. If not provided empty image will be returned.
     */
    func image(_ size: CGSize = .zero) -> UIImage {
        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            self.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: size))
        }
    }
    
    /**
     Convenience initializer, which allows to convert `StyleColor` to `UIColor`. This initializer
     is primarily used while retrieving color information from `LineLayer`.
     */
    convenience init(_ styleColor: StyleColor) {
        self.init(red: CGFloat(styleColor.red / 255.0),
                  green: CGFloat(styleColor.green / 255.0),
                  blue: CGFloat(styleColor.blue / 255.0),
                  alpha: CGFloat(styleColor.alpha))
    }
}
