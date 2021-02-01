import UIKit
import MapboxMaps
import MapboxCoreMaps
import MapboxDirections
import MapboxCoreNavigation
import Turf

/**
 `NavigationMapView` is a subclass of `UIView`, which draws `MapView` on its surface and provides convenience functions for adding `Route` lines to a map.
 */
open class NavigationMapView: UIView {
    
    // MARK: Class constants
    
    struct FrameIntervalOptions {
        static let durationUntilNextManeuver: TimeInterval = 7
        static let durationSincePreviousManeuver: TimeInterval = 3
        static let defaultFramesPerSecond = PreferredFPS.maximum
        static let pluggedInFramesPerSecond = PreferredFPS.lowPower
    }
    
    /**
     The minimum preferred frames per second at which to render map animations.
     
     This property takes effect when the application has limited resources for animation, such as when the device is running on battery power. By default, this property is set to `PreferredFPS.normal`.
     */
    // TODO: Mapbox Maps should provide the ability to set custom `PreferredFPS` value.
    public var minimumFramesPerSecond = PreferredFPS.normal
    
    /**
     Returns the altitude that the map camera initally defaults to.
     */
    public var defaultAltitude: CLLocationDistance = 1000.0
    
    /**
     Returns the altitude the map conditionally zooms out to when user is on a motorway, and the maneuver length is sufficently long.
     */
    public var zoomedOutMotorwayAltitude: CLLocationDistance = 2000.0
    
    /**
     Returns the threshold for what the map considers a "long-enough" maneuver distance to trigger a zoom-out when the user enters a motorway.
     */
    public var longManeuverDistance: CLLocationDistance = 1000.0
    
    /**
     Maximum distance the user can tap for a selection to be valid when selecting an alternate route.
     */
    public var tapGestureDistanceThreshold: CGFloat = 50
    
    /**
     A collection of street road classes for which a congestion level substitution should occur.
     
     For any street road class included in the `roadClassesWithOverriddenCongestionLevels`, all route segments with an `CongestionLevel.unknown` traffic congestion level and a matching `MapboxDirections.MapboxStreetsRoadClass`
     will be replaced with the `CongestionLevel.low` congestion level.
     */
    // TODO: Implement the ability to override congestion levels.
    public var roadClassesWithOverriddenCongestionLevels: Set<MapboxStreetsRoadClass>? = nil
    
    enum IdentifierType: Int {
        case source
        
        case route
        
        case routeCasing
    }
    
    struct IdentifierString {
        static let identifier = Bundle.mapboxNavigation.bundleIdentifier ?? ""
        static let arrowImage = "triangle-tip-navigation"
        static let waypointCircle = "\(identifier)_waypointsCircle"
        static let arrowSource = "\(identifier)_arrowSource"
        static let arrow = "\(identifier)_arrow"
        static let arrowStrokeSource = "\(identifier)arrowStrokeSource"
        static let arrowStroke = "\(identifier)_arrowStroke"
        static let arrowSymbolSource = "\(identifier)_arrowSymbolSource"
        static let arrowSymbol = "\(identifier)_arrowSymbol"
        static let arrowCasingSymbol = "\(identifier)_arrowCasingSymbol"
        static let instructionSource = "\(identifier)_instructionSource"
        static let instructionLabel = "\(identifier)_instructionLabel"
        static let instructionCircle = "\(identifier)_instructionCircle"
    }
    
    @objc dynamic public var trafficUnknownColor: UIColor = .trafficUnknown
    @objc dynamic public var trafficLowColor: UIColor = .trafficLow
    @objc dynamic public var trafficModerateColor: UIColor = .trafficModerate
    @objc dynamic public var trafficHeavyColor: UIColor = .trafficHeavy
    @objc dynamic public var trafficSevereColor: UIColor = .trafficSevere
    @objc dynamic public var routeCasingColor: UIColor = .defaultRouteCasing
    @objc dynamic public var routeAlternateColor: UIColor = .defaultAlternateLine
    @objc dynamic public var routeAlternateCasingColor: UIColor = .defaultAlternateLineCasing
    @objc dynamic public var traversedRouteColor: UIColor = .defaultTraversedRouteColor
    @objc dynamic public var maneuverArrowColor: UIColor = .defaultManeuverArrow
    @objc dynamic public var maneuverArrowStrokeColor: UIColor = .defaultManeuverArrowStroke
    @objc dynamic public var buildingDefaultColor: UIColor = .defaultBuildingColor
    @objc dynamic public var buildingHighlightColor: UIColor = .defaultBuildingHighlightColor
    @objc dynamic public var reducedAccuracyActivatedMode: Bool = false {
        didSet {
            let frame = CGRect(origin: .zero, size: 75.0)
            userCourseView = reducedAccuracyActivatedMode
                ? UserHaloCourseView(frame: frame)
                : UserPuckCourseView(frame: frame)
        }
    }
    
    public private(set) var mapView: MapView!
    
    /**
     The object that acts as the navigation delegate of the map view.
     */
    // TODO: Consider renaming to `delegate`.
    public weak var navigationMapViewDelegate: NavigationMapViewDelegate?
    
    /**
     The object that acts as the course tracking delegate of the map view.
     */
    public weak var courseTrackingDelegate: NavigationMapViewCourseTrackingDelegate?
    
    var userLocationForCourseTracking: CLLocation?
    var altitude: CLLocationDistance
    var routes: [Route]?
    var isAnimatingToOverheadMode = false
    var routePoints: RoutePoints?
    var routeLineGranularDistances: RouteLineGranularDistances?
    var routeRemainingDistancesIndex: Int?
    var routeLineTracksTraversal: Bool = false
    var fractionTraveled: Double = 0.0
    var preFractionTraveled: Double = 0.0
    var vanishingRouteLineUpdateTimer: Timer? = nil
    
    var shouldPositionCourseViewFrameByFrame = false {
        didSet {
            if shouldPositionCourseViewFrameByFrame {
                mapView.preferredFPS = .maximum
            }
        }
    }
    
    var showsRoute: Bool {
        get {
            guard let mainRouteLayerIdentifier = identifier(routes?.first, identifierType: .route),
                  let mainRouteCasingLayerIdentifier = identifier(routes?.first, identifierType: .routeCasing) else { return false }
            
            guard let _ = try? mapView.style.getLayer(with: mainRouteLayerIdentifier, type: LineLayer.self).get(),
                  let _ = try? mapView.style.getLayer(with: mainRouteCasingLayerIdentifier, type: LineLayer.self).get() else { return false }

            return true
        }
    }
    
    // TODO: When using previous version of Maps SDK `showsUserLocation` was overridden property of `MGLMapView`. Clarify whether it needs to be exposed.
    open var showsUserLocation: Bool {
        get {
            if tracksUserCourse || userLocationForCourseTracking != nil {
                return !userCourseView.isHidden
            }
            
            return mapView.locationManager.showUserLocation
        }
        set {
            if tracksUserCourse || userLocationForCourseTracking != nil {
                mapView.update {
                    $0.location.showUserLocation = false
                }
                
                userCourseView.isHidden = !newValue
            } else {
                userCourseView.isHidden = true

                mapView.update {
                    $0.location.showUserLocation = newValue
                }
            }
        }
    }
    
    /**
     The minimum default insets from the content frame to the edges of the user course view.
     */
    static let courseViewMinimumInsets = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
    
    /**
     Center point of the user course view in screen coordinates relative to the map view.
     - seealso: NavigationMapViewDelegate.navigationMapViewUserAnchorPoint(_:)
     */
    var userAnchorPoint: CGPoint {
        if let anchorPoint = navigationMapViewDelegate?.navigationMapViewUserAnchorPoint(self), anchorPoint != .zero {
            return anchorPoint
        }
        // TODO: Verify whether content insets verification is required.
        let contentFrame = bounds
        return CGPoint(x: contentFrame.midX, y: contentFrame.midY)
    }
    
    /**
     Determines whether the map should follow the user location and rotate when the course changes.
     - seealso: NavigationMapViewCourseTrackingDelegate
     */
    open var tracksUserCourse: Bool = false {
        didSet {
            if tracksUserCourse {
                enableFrameByFrameCourseViewTracking(for: 3)
                altitude = defaultAltitude
                showsUserLocation = true
                courseTrackingDelegate?.navigationMapViewDidStartTrackingCourse(self)
            } else {
                courseTrackingDelegate?.navigationMapViewDidStopTrackingCourse(self)
            }
            if let location = userLocationForCourseTracking {
                updateCourseTracking(location: location, animated: true)
            }
        }
    }

    /**
     A type that represents a `UIView` that is `CourseUpdatable`.
     */
    public typealias UserCourseView = UIView & CourseUpdatable
    
    /**
     A `UserCourseView` used to indicate the user’s location and course on the map.
     
     The `UserCourseView`'s `UserCourseView.update(location:pitch:direction:animated:)` method is frequently called to ensure that its visual appearance matches the map’s camera.
     */
    public var userCourseView: UserCourseView = UserPuckCourseView(frame: CGRect(origin: .zero, size: 75.0)) {
        didSet {
            oldValue.removeFromSuperview()
            installUserCourseView()
        }
    }
    
    public override init(frame: CGRect) {
        altitude = defaultAltitude
        super.init(frame: frame)
        
        setupMapView(frame)
        commonInit()
    }
    
    public required init?(coder: NSCoder) {
        altitude = defaultAltitude
        super.init(coder: coder)
        
        mapView = MapView(coder: coder)
        addSubview(mapView)
        
        commonInit()
    }
    
    fileprivate func commonInit() {
        makeGestureRecognizersRespectCourseTracking()
        makeGestureRecognizersUpdateCourseView()
        setupGestureRecognizers()
        installUserCourseView()
        showsUserLocation = false
    }
    
    func setupMapView(_ frame: CGRect) {
        guard let accessToken = AccountManager.shared.accessToken else {
            fatalError("Access token was not set.")
        }
        
        mapView = MapView(with: frame, resourceOptions: ResourceOptions(accessToken: accessToken))
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.update {
            $0.ornaments.showsScale = false
        }
        
        mapView.on(.renderFrameFinished) { [weak self] _ in
            guard let self = self,
                  self.shouldPositionCourseViewFrameByFrame,
                  let location = self.userLocationForCourseTracking else { return }
            
            self.userCourseView.center = self.mapView.screenCoordinate(for: location.coordinate).point
        }
        
        addSubview(mapView)
        
        mapView.pinTo(parentView: self)
    }
    
    func setupGestureRecognizers() {
        let gestures = gestureRecognizers ?? []
        let mapTapGesture = UITapGestureRecognizer(target: self, action: #selector(didRecieveTap(sender:)))
        mapTapGesture.requireFailure(of: gestures)
        mapView.addGestureRecognizer(mapTapGesture)
    }
    
    // MARK: - Overridden methods
    
    open override func layoutMarginsDidChange() {
        super.layoutMarginsDidChange()
        enableFrameByFrameCourseViewTracking(for: 3)
    }
    
    open override func prepareForInterfaceBuilder() {
        super.prepareForInterfaceBuilder()
        
        let image = UIImage(named: "feedback-map-error", in: .mapboxNavigation, compatibleWith: nil)
        let imageView = UIImageView(image: image)
        imageView.contentMode = .center
        imageView.backgroundColor = .gray
        imageView.frame = bounds
        addSubview(imageView)
    }
    
    open override func layoutSubviews() {
        super.layoutSubviews()
        
        // If the map is in tracking mode, make sure we update the camera and anchor after the layout pass.
        if tracksUserCourse {
            updateCourseTracking(location: userLocationForCourseTracking, camera:mapView.cameraView.camera, animated: false)
            
            // TODO: Find appropriate place where anchor can be updated.
            mapView.cameraView.anchor = userAnchorPoint
        }
    }
    
    /**
     Updates the map view’s preferred frames per second to the appropriate value for the current route progress.
     
     This method accounts for the proximity to a maneuver and the current power source. It has no effect if `tracksUserCourse` is set to `true`.
     */
    open func updatePreferredFrameRate(for routeProgress: RouteProgress) {
        guard tracksUserCourse else { return }
        
        let stepProgress = routeProgress.currentLegProgress.currentStepProgress
        let expectedTravelTime = stepProgress.step.expectedTravelTime
        let durationUntilNextManeuver = stepProgress.durationRemaining
        let durationSincePreviousManeuver = expectedTravelTime - durationUntilNextManeuver
        let conservativeFramesPerSecond = UIDevice.current.isPluggedIn ? FrameIntervalOptions.pluggedInFramesPerSecond : minimumFramesPerSecond
        
        if let upcomingStep = routeProgress.currentLegProgress.upcomingStep,
           upcomingStep.maneuverDirection == .straightAhead || upcomingStep.maneuverDirection == .slightLeft || upcomingStep.maneuverDirection == .slightRight {
            mapView.preferredFPS = shouldPositionCourseViewFrameByFrame ? FrameIntervalOptions.defaultFramesPerSecond : conservativeFramesPerSecond
        } else if durationUntilNextManeuver > FrameIntervalOptions.durationUntilNextManeuver &&
                    durationSincePreviousManeuver > FrameIntervalOptions.durationSincePreviousManeuver {
            mapView.preferredFPS = shouldPositionCourseViewFrameByFrame ? FrameIntervalOptions.defaultFramesPerSecond : conservativeFramesPerSecond
        } else {
            mapView.preferredFPS = FrameIntervalOptions.pluggedInFramesPerSecond
        }
    }
    
    /**
     Track position on a frame by frame basis. Used for first location update and when resuming tracking mode
     */
    public func enableFrameByFrameCourseViewTracking(for duration: TimeInterval) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(disableFrameByFramePositioning), object: nil)
        perform(#selector(disableFrameByFramePositioning), with: nil, afterDelay: duration)
        shouldPositionCourseViewFrameByFrame = true
    }
    
    @objc fileprivate func disableFrameByFramePositioning() {
        shouldPositionCourseViewFrameByFrame = false
    }
    
    // MARK: - User tracking methods
    
    func installUserCourseView() {
        if let location = userLocationForCourseTracking {
            updateCourseTracking(location: location)
        }
        mapView.addSubview(userCourseView)
    }
    
    @objc private func disableUserCourseTracking() {
        guard tracksUserCourse else { return }
        tracksUserCourse = false
    }
    
    public func updateCourseTracking(location: CLLocation?, camera: CameraOptions? = nil, animated: Bool = false) {
        // While animating to overhead mode, don't animate the puck.
        let duration: TimeInterval = animated && !isAnimatingToOverheadMode ? 1 : 0
        userLocationForCourseTracking = location
        guard let location = location, CLLocationCoordinate2DIsValid(location.coordinate) else {
            return
        }
        
        let centerUserCourseView = { [weak self] in
            guard let point = self?.mapView.screenCoordinate(for: location.coordinate).point else { return }
            
            self?.userCourseView.center = point
        }
        
        if tracksUserCourse {
            centerUserCourseView()
            
            let zoomLevel = CGFloat(ZoomLevelForAltitude(altitude,
                                                         self.mapView.pitch,
                                                         location.coordinate.latitude,
                                                         self.mapView.bounds.size))
            
            let camera = camera ?? CameraOptions(center: location.coordinate,
                                                 zoom: zoomLevel,
                                                 bearing: location.course,
                                                 pitch: 45)
            mapView.cameraManager.setCamera(to: camera, animated: animated, duration: duration, completion: nil)
        } else {
            // Animate course view updates in overview mode
            UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear], animations: centerUserCourseView)
        }
        
        userCourseView.update(location: location,
                              pitch: mapView.cameraView.pitch,
                              direction: location.course,
                              animated: animated,
                              tracksUserCourse: tracksUserCourse)
    }
    
    // MARK: Feature Addition/removal properties and methods
    
    /**
     Showcases route array. Adds routes and waypoints to map, and sets camera to point encompassing the route.
     */
    public static let defaultPadding: UIEdgeInsets = UIEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
    
    public func showcase(_ routes: [Route], animated: Bool = false) {
        guard let activeRoute = routes.first,
              let coordinates = activeRoute.shape?.coordinates,
              !coordinates.isEmpty else { return }
        
        removeArrow()
        removeRoutes()
        removeWaypoints()
        
        show(routes)
        showWaypoints(on: activeRoute)
        
        fit(to: activeRoute, facing: 0, animated: animated)
    }
    
    func fit(to route: Route, facing direction: CLLocationDirection = 0, animated: Bool = false) {
        guard let shape = route.shape, !shape.coordinates.isEmpty else { return }
        
        let newCamera = mapView.cameraManager.camera(fitting: .lineString(shape),
                                                     edgePadding: safeArea + NavigationMapView.defaultPadding,
                                                     bearing: CGFloat(direction),
                                                     pitch: 0)
        
        mapView.cameraManager.setCamera(to: newCamera, animated: animated, completion: nil)
    }
    
    public func show(_ routes: [Route], legIndex: Int = 0) {
        removeRoutes()
        
        self.routes = routes
        
        // TODO: Add ability to handle legIndex.
        var parentLayerIdentifier: String? = nil
        for (index, route) in routes.enumerated() {
            if index == 0 {
                parentLayerIdentifier = addMainRouteLayer(route)
                parentLayerIdentifier = addMainRouteCasingLayer(route, below: parentLayerIdentifier)
                
                if routeLineTracksTraversal {
                    initPrimaryRoutePoints(route: route)
                }
                
                continue
            }
            
            parentLayerIdentifier = addAlternativeRouteLayer(route,  below: parentLayerIdentifier)
            addAlternativeRouteCasingLayer(route, below: parentLayerIdentifier)
        }
    }
    
    @discardableResult func addMainRouteLayer(_ route: Route) -> String? {
        guard let shape = route.shape else { return nil }
        
        var geoJSONSource = GeoJSONSource()
        geoJSONSource.data = .geometry(.lineString(shape))
        geoJSONSource.lineMetrics = true
        
        guard let sourceIdentifier = identifier(route, identifierType: .source) else { return nil }
        mapView.style.addSource(source: geoJSONSource, identifier: sourceIdentifier)
        
        let fractionTraveledForStops = routeLineTracksTraversal ? fractionTraveled : 0.0
        guard let layerIdentifier = identifier(route, identifierType: .route) else { return nil }
        var lineLayer = LineLayer(id: layerIdentifier)
        lineLayer.source = sourceIdentifier
        // TODO: Implement ability to change `lineWidth` depending on zoom level.
        lineLayer.paint?.lineWidth = .constant(.init(8.0))
        lineLayer.layout?.lineJoin = .round
        lineLayer.layout?.lineCap = .round
        
        let gradientStops = routeLineGradient(route, fractionTraveled: fractionTraveledForStops)
        if let data = routeLineGradientExpression(gradientStops).data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: []) {
            let _ = try? mapView.__map.setStyleLayerPropertyForLayerId(layerIdentifier,
                                                                       property: "line-gradient",
                                                                       value: value)
        }
        
        var parentLayer: String? {
            var parentLayer: String? = nil
            let identifiers = [
                IdentifierString.arrow,
                IdentifierString.arrowSymbol,
                IdentifierString.arrowCasingSymbol,
                IdentifierString.arrowStroke,
                IdentifierString.waypointCircle
            ]
            
            guard let layers = try? mapView.__map.getStyleLayers().reversed() else { return nil }
            for layer in layers {
                if !(layer.type == "symbol") && !identifiers.contains(layer.id) {
                    let source = try? mapView.__map.getStyleLayerProperty(forLayerId: layer.id, property: "source").value as? String
                    let sourceLayer = try? mapView.__map.getStyleLayerProperty(forLayerId: layer.id, property: "source-layer").value as? String
                    
                    if let source = source,
                       source.isEmpty,
                       let sourceLayer = sourceLayer,
                       sourceLayer.isEmpty {
                        continue
                    }
                    
                    parentLayer = layer.id
                    break
                }
            }
            
            return parentLayer
        }
        
        mapView.style.addLayer(layer: lineLayer, layerPosition: LayerPosition(above: parentLayer))
        
        return layerIdentifier
    }
    
    @discardableResult func addMainRouteCasingLayer(_ route: Route, below parentLayerIndentifier: String? = nil) -> String? {
        guard let shape = route.shape else { return nil }
        
        var geoJSONSource = GeoJSONSource()
        geoJSONSource.data = .geometry(.lineString(shape))
        geoJSONSource.lineMetrics = true
        
        guard let sourceIdentifier = identifier(route, identifierType: .source, isMainRouteCasingSource: true) else { return nil }
        mapView.style.addSource(source: geoJSONSource, identifier: sourceIdentifier)
        
        let fractionTraveledForStops = routeLineTracksTraversal ? fractionTraveled : 0.0
        guard let layerIdentifier = identifier(route, identifierType: .routeCasing) else { return nil }
        var lineLayer = LineLayer(id: layerIdentifier)
        lineLayer.source = sourceIdentifier
        lineLayer.paint?.lineColor = .constant(.init(color: routeCasingColor))
        // TODO: Implement ability to change `lineWidth` depending on zoom level.
        lineLayer.paint?.lineWidth = .constant(.init(12.0))
        lineLayer.layout?.lineJoin = .round
        lineLayer.layout?.lineCap = .round
        
        mapView.style.addLayer(layer: lineLayer, layerPosition: LayerPosition(below: parentLayerIndentifier))
        
        let gradientStops = routeCasingGradient(fractionTraveledForStops)
        if let data = routeLineGradientExpression(gradientStops).data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: []) {
            let _ = try? mapView.__map.setStyleLayerPropertyForLayerId(layerIdentifier,
                                                                       property: "line-gradient",
                                                                       value: value)
        }

        return layerIdentifier
    }
    
    @discardableResult func addAlternativeRouteLayer(_ route: Route, below parentLayerIndentifier: String? = nil) -> String? {
        guard let shape = route.shape else { return nil }
        
        var geoJSONSource = GeoJSONSource()
        geoJSONSource.data = .geometry(.lineString(shape))
        geoJSONSource.lineMetrics = true
        
        guard let sourceIdentifier = identifier(route, identifierType: .source) else { return nil }
        mapView.style.addSource(source: geoJSONSource, identifier: sourceIdentifier)
        
        guard let layerIdentifier = identifier(route, identifierType: .route) else { return nil }
        var lineLayer = LineLayer(id: layerIdentifier)
        lineLayer.source = sourceIdentifier
        lineLayer.paint?.lineColor = .constant(.init(color: routeAlternateColor))
        // TODO: Implement ability to change `lineWidth` depending on zoom level.
        lineLayer.paint?.lineWidth = .constant(.init(8.0))
        lineLayer.layout?.lineJoin = .round
        lineLayer.layout?.lineCap = .round

        mapView.style.addLayer(layer: lineLayer, layerPosition: LayerPosition(below: parentLayerIndentifier))
        
        return layerIdentifier
    }
    
    @discardableResult func addAlternativeRouteCasingLayer(_ route: Route, below parentLayerIndentifier: String? = nil) -> String? {
        guard let shape = route.shape else { return nil }
        
        var geoJSONSource = GeoJSONSource()
        geoJSONSource.data = .geometry(.lineString(shape))
        geoJSONSource.lineMetrics = true
        
        guard let sourceIdentifier = identifier(route, identifierType: .source) else { return nil }
        mapView.style.addSource(source: geoJSONSource, identifier: sourceIdentifier)
        
        guard let layerIdentifier = identifier(route, identifierType: .routeCasing) else { return nil }
        var lineLayer = LineLayer(id: layerIdentifier)
        lineLayer.source = sourceIdentifier
        lineLayer.paint?.lineColor = .constant(.init(color: routeAlternateCasingColor))
        // TODO: Implement ability to change `lineWidth` depending on zoom level.
        lineLayer.paint?.lineWidth = .constant(.init(12.0))
        lineLayer.layout?.lineJoin = .round
        lineLayer.layout?.lineCap = .round
        
        mapView.style.addLayer(layer: lineLayer, layerPosition: LayerPosition(below: parentLayerIndentifier))
        
        return layerIdentifier
    }
    
    /**
     Adds the route waypoints to the map given the current leg index. Previous waypoints for completed legs will be omitted.
     */
    public func showWaypoints(on route: Route, legIndex: Int = 0) {
        // TODO: Implement ability to show waypoints.
        
        if let lastLeg = route.legs.last, let destinationCoordinate = lastLeg.destination?.coordinate {
            mapView.annotationManager.removeAnnotations(annotationsToRemove())
            
            var destinationAnnotation = PointAnnotation(coordinate: destinationCoordinate)
            destinationAnnotation.title = "navigation_annotation"
            mapView.annotationManager.addAnnotation(destinationAnnotation)
        }
    }
    
    public func removeRoutes() {
        var sourceIdentifiers = Set<String>()
        var layerIdentifiers = Set<String>()
        routes?.enumerated().forEach {
            if $0.offset == 0, let identifier = identifier($0.element, identifierType: .source, isMainRouteCasingSource: true) {
                sourceIdentifiers.insert(identifier)
            }
            
            if let identifier = identifier($0.element, identifierType: .source) {
                sourceIdentifiers.insert(identifier)
            }
            
            if let identifier = identifier($0.element, identifierType: .route) {
                layerIdentifiers.insert(identifier)
            }
            
            if let identifier = identifier($0.element, identifierType: .routeCasing) {
                layerIdentifiers.insert(identifier)
            }
        }
        
        mapView.style.removeLayers(layerIdentifiers)
        mapView.style.removeSources(sourceIdentifiers)
        
        routes = nil
        routePoints = nil
        routeLineGranularDistances = nil
    }
    
    func identifier(_ route: Route?, identifierType: IdentifierType, isMainRouteCasingSource: Bool = false) -> String? {
        guard let route = route else { return nil }
        let identifier = Unmanaged.passUnretained(route).toOpaque()
        
        switch identifierType {
        case .source:
            if isMainRouteCasingSource {
                return "\(identifier)_casing_source"
            }
            
            return "\(identifier)_source"
            
        case .route:
            return "\(identifier)_route"
            
        case .routeCasing:
            return "\(identifier)_casing"
        }
    }
    
    public func removeWaypoints() {
        mapView.annotationManager.removeAnnotations(annotationsToRemove())
    }
    
    func annotationsToRemove() -> [Annotation] {
        // TODO: Improve annotations filtering functionality.
        return mapView.annotationManager.annotations.values.filter({ $0.title == "navigation_annotation" })
    }
    
    /**
     Shows the step arrow given the current `RouteProgress`.
     */
    public func addArrow(route: Route, legIndex: Int, stepIndex: Int) {
        guard route.legs.indices.contains(legIndex),
              route.legs[legIndex].steps.indices.contains(stepIndex),
              let mainRouteLayerIdentifier = identifier(route, identifierType: .route),
              let triangleImage = Bundle.mapboxNavigation.image(named: "triangle")?.withRenderingMode(.alwaysTemplate) else { return }
        
        let _ = mapView.style.setStyleImage(image: triangleImage, with: IdentifierString.arrowImage, scale: 1.0)
        
        let minimumZoomLevel: Double = 8.0
        let step = route.legs[legIndex].steps[stepIndex]
        let maneuverCoordinate = step.maneuverLocation
        
        guard step.maneuverType != .arrive else { return }
        
        // TODO: Implement ability to change `shaftLength` depending on zoom level.
        let shaftLength = max(min(30 * mapView.metersPerPointAtLatitude(latitude: maneuverCoordinate.latitude), 30), 10)
        let shaftPolyline = route.polylineAroundManeuver(legIndex: legIndex, stepIndex: stepIndex, distance: shaftLength)
        
        if shaftPolyline.coordinates.count > 1 {
            let shaftStrokeCoordinates = shaftPolyline.coordinates
            let shaftDirection = shaftStrokeCoordinates[shaftStrokeCoordinates.count - 2].direction(to: shaftStrokeCoordinates.last!)
            
            var arrowSource = GeoJSONSource()
            arrowSource.data = .feature(Feature(shaftPolyline))
            var arrow = LineLayer(id: IdentifierString.arrow)
            if let _ = try? mapView.style.getSource(identifier: IdentifierString.arrowSource, type: GeoJSONSource.self).get() {
                let geoJSON = Feature.init(geometry: Geometry.lineString(shaftPolyline))
                let _ = mapView.style.updateGeoJSON(for: IdentifierString.arrowSource, with: geoJSON)
            } else {
                arrow.minZoom = Double(minimumZoomLevel)
                arrow.layout?.lineCap = .butt
                arrow.layout?.lineJoin = .round
                // TODO: Implement ability to change `lineWidth` depending on zoom level.
                arrow.paint?.lineWidth = .constant(.init(14.0))
                arrow.paint?.lineColor = .constant(.init(color: maneuverArrowColor))
                
                mapView.style.addSource(source: arrowSource, identifier: IdentifierString.arrowSource)
                arrow.source = IdentifierString.arrowSource
                if let _ = try? mapView.style.getLayer(with: IdentifierString.waypointCircle, type: LineLayer.self).get() {
                    mapView.style.addLayer(layer: arrow, layerPosition: LayerPosition(above: mainRouteLayerIdentifier, below: IdentifierString.waypointCircle))
                } else {
                    mapView.style.addLayer(layer: arrow, layerPosition: LayerPosition(above: mainRouteLayerIdentifier))
                }
            }
            
            var arrowStrokeSource = GeoJSONSource()
            arrowStrokeSource.data = .feature(Feature(shaftPolyline))
            var arrowStroke = LineLayer(id: IdentifierString.arrowStroke)
            if let _ = try? mapView.style.getSource(identifier: IdentifierString.arrowStrokeSource, type: GeoJSONSource.self).get() {
                let geoJSON = Feature.init(geometry: Geometry.lineString(shaftPolyline))
                let _ = mapView.style.updateGeoJSON(for: IdentifierString.arrowStrokeSource, with: geoJSON)
            } else {
                arrowStroke.minZoom = arrow.minZoom
                arrowStroke.layout?.lineCap = arrow.layout?.lineCap
                arrowStroke.layout?.lineJoin = arrow.layout?.lineJoin
                // TODO: Implement ability to change `lineWidth` depending on zoom level.
                arrowStroke.paint?.lineWidth = .constant(.init(16.0))
                arrowStroke.paint?.lineColor = .constant(.init(color: maneuverArrowStrokeColor))
                
                mapView.style.addSource(source: arrowStrokeSource, identifier: IdentifierString.arrowStrokeSource)
                arrowStroke.source = IdentifierString.arrowStrokeSource
                mapView.style.addLayer(layer: arrowStroke, layerPosition: LayerPosition(above: mainRouteLayerIdentifier))
            }
            
            let point = Point(shaftStrokeCoordinates.last!)
            var arrowSymbolSource = GeoJSONSource()
            arrowSymbolSource.data = .feature(Feature(point))
            if let _ = try? mapView.style.getSource(identifier: IdentifierString.arrowSymbolSource, type: GeoJSONSource.self).get() {
                let geoJSON = Feature.init(geometry: Geometry.point(point))
                let _ = mapView.style.updateGeoJSON(for: IdentifierString.arrowSymbolSource, with: geoJSON)
                let _ = try? mapView.__map.setStyleLayerPropertyForLayerId(IdentifierString.arrowSymbol, property: "icon-rotate", value: shaftDirection)
                let _ = try? mapView.__map.setStyleLayerPropertyForLayerId(IdentifierString.arrowCasingSymbol, property: "icon-rotate", value: shaftDirection)
            } else {
                var arrowSymbolLayer = SymbolLayer(id: IdentifierString.arrowSymbol)
                arrowSymbolLayer.minZoom = Double(minimumZoomLevel)
                arrowSymbolLayer.layout?.iconImage = .constant(.name(IdentifierString.arrowImage))
                arrowSymbolLayer.paint?.iconColor = .constant(.init(color: maneuverArrowColor))
                arrowSymbolLayer.layout?.iconRotationAlignment = .map
                arrowSymbolLayer.layout?.iconRotate = .constant(.init(shaftDirection))
                // TODO: Implement ability to change `iconSize` depending on zoom level.
                arrowSymbolLayer.layout?.iconSize = .constant(.init(2))
                arrowSymbolLayer.layout?.iconAllowOverlap = .constant(true)
                
                var arrowSymbolLayerCasing = SymbolLayer(id: IdentifierString.arrowCasingSymbol)
                arrowSymbolLayerCasing.minZoom = arrowSymbolLayer.minZoom
                arrowSymbolLayerCasing.layout?.iconImage = arrowSymbolLayer.layout?.iconImage
                arrowSymbolLayerCasing.paint?.iconColor = .constant(.init(color: maneuverArrowStrokeColor))
                arrowSymbolLayerCasing.layout?.iconRotationAlignment = arrowSymbolLayer.layout?.iconRotationAlignment
                arrowSymbolLayerCasing.layout?.iconRotate = arrowSymbolLayer.layout?.iconRotate
                // TODO: Implement ability to change `iconSize` depending on zoom level.
                arrowSymbolLayerCasing.layout?.iconSize = .constant(.init(2.5))
                arrowSymbolLayerCasing.layout?.iconAllowOverlap = arrowSymbolLayer.layout?.iconAllowOverlap
                
                mapView.style.addSource(source: arrowSymbolSource, identifier: IdentifierString.arrowSymbolSource)
                arrowSymbolLayer.source = IdentifierString.arrowSymbolSource
                arrowSymbolLayerCasing.source = IdentifierString.arrowSymbolSource
                mapView.style.addLayer(layer: arrowSymbolLayer)
                mapView.style.addLayer(layer: arrowSymbolLayerCasing, layerPosition: LayerPosition(below: IdentifierString.arrowSymbol))
            }
        }
    }
    
    /**
     Removes the step arrow from the map.
     */
    public func removeArrow() {
        let layerSet: Set = [
            IdentifierString.arrow,
            IdentifierString.arrowStroke,
            IdentifierString.arrowSymbol,
            IdentifierString.arrowCasingSymbol
        ]
        mapView.style.removeLayers(layerSet)
        
        let sourceSet: Set = [
            IdentifierString.arrowSource,
            IdentifierString.arrowStrokeSource,
            IdentifierString.arrowSymbolSource
        ]
        mapView.style.removeSources(sourceSet)
    }
    
    public func localizeLabels() {
        // TODO: Implement ability to localize road labels.
    }
    
    public func showVoiceInstructionsOnMap(route: Route) {
        var featureCollection = FeatureCollection(features: [])
        
        for (legIndex, leg) in route.legs.enumerated() {
            for (stepIndex, step) in leg.steps.enumerated() {
                for instruction in step.instructionsSpokenAlongStep! {
                    let coordinate = LineString(route.legs[legIndex].steps[stepIndex].shape!.coordinates.reversed()).coordinateFromStart(distance: instruction.distanceAlongStep)!
                    var feature = Feature(Point(coordinate))
                    feature.properties = [
                        "instruction": instruction.text
                    ]
                    featureCollection.features.append(feature)
                }
            }
        }

        if let _ = try? mapView.style.getSource(identifier: IdentifierString.instructionSource, type: GeoJSONSource.self).get() {
            _ = mapView.style.updateGeoJSON(for: IdentifierString.instructionSource, with: featureCollection)
        } else {
            var source = GeoJSONSource()
            source.data = .featureCollection(featureCollection)
            mapView.style.addSource(source: source, identifier: IdentifierString.instructionSource)
            
            var symbolLayer = SymbolLayer(id: IdentifierString.instructionLabel)
            symbolLayer.source = IdentifierString.instructionSource
            
            let instruction = Exp(.toString) {
                Exp(.get) {
                    "instruction"
                }
            }
            
            symbolLayer.layout?.textField = .expression(instruction)
            symbolLayer.layout?.textSize = .constant(14)
            symbolLayer.paint?.textHaloWidth = .constant(1)
            symbolLayer.paint?.textHaloColor = .constant(.init(color: .white))
            symbolLayer.paint?.textOpacity = .constant(0.75)
            symbolLayer.layout?.textAnchor = .bottom
            symbolLayer.layout?.textJustify = .left
            mapView.style.addLayer(layer: symbolLayer)
            
            var circleLayer = CircleLayer(id: IdentifierString.instructionCircle)
            circleLayer.source = IdentifierString.instructionSource
            circleLayer.paint?.circleRadius = .constant(5)
            circleLayer.paint?.circleOpacity = .constant(0.75)
            circleLayer.paint?.circleColor = .constant(.init(color: .white))
            mapView.style.addLayer(layer: circleLayer)
        }
    }
    
    /**
     Sets the camera directly over a series of coordinates.
     */
    public func setOverheadCameraView(from userLocation: CLLocation, along lineString: LineString, for padding: UIEdgeInsets) {
        isAnimatingToOverheadMode = true
        tracksUserCourse = false
    
        // TODO: Implement functionality which allows to change camera options based on traversed distance.
        
        let newCamera = mapView.cameraManager.camera(fitting: .lineString(lineString),
                                                     edgePadding: padding,
                                                     bearing: 0,
                                                     pitch: 0)
        
        mapView.cameraManager.setCamera(to: newCamera, animated: true, duration: 1) { [weak self] _ in
            self?.isAnimatingToOverheadMode = false
        }

        updateCourseView(to: userLocation, pitch: newCamera.pitch, direction: newCamera.bearing, animated: true)
    }
    
    /**
     Recenters the camera and begins tracking the user's location.
     */
    public func recenterMap() {
        tracksUserCourse = true
        enableFrameByFrameCourseViewTracking(for: 3)
    }
    
    // MARK: - Gesture recognizers methods
    
    /**
     Fired when NavigationMapView detects a tap not handled elsewhere by other gesture recognizers.
     */
    @objc func didRecieveTap(sender: UITapGestureRecognizer) {
        guard let routes = routes, let tapPoint = sender.point else { return }
        
        let waypointTest = waypoints(on: routes, closeTo: tapPoint)
        if let selected = waypointTest?.first {
            navigationMapViewDelegate?.navigationMapView(self, didSelect: selected)
            return
        } else if let routes = self.routes(closeTo: tapPoint) {
            guard let selectedRoute = routes.first else { return }
            navigationMapViewDelegate?.navigationMapView(self, didSelect: selectedRoute)
        }
    }
    
    private func waypoints(on routes: [Route], closeTo point: CGPoint) -> [Waypoint]? {
        let tapCoordinate = mapView.coordinate(for: point)
        let multipointRoutes = routes.filter { $0.legs.count > 1}
        guard multipointRoutes.count > 0 else { return nil }
        let waypoints = multipointRoutes.compactMap { route in
            route.legs.dropLast().compactMap { $0.destination }
        }.flatMap {$0}
        
        // Sort the array in order of closest to tap.
        let closest = waypoints.sorted { (left, right) -> Bool in
            let leftDistance = calculateDistance(coordinate1: left.coordinate, coordinate2: tapCoordinate)
            let rightDistance = calculateDistance(coordinate1: right.coordinate, coordinate2: tapCoordinate)
            return leftDistance < rightDistance
        }
        
        // Filter to see which ones are under threshold.
        let candidates = closest.filter({
            let coordinatePoint = mapView.point(for: $0.coordinate)
            
            return coordinatePoint.distance(to: point) < tapGestureDistanceThreshold
        })
        
        return candidates
    }
    
    private func routes(closeTo point: CGPoint) -> [Route]? {
        let tapCoordinate = mapView.coordinate(for: point)
        
        // Filter routes with at least 2 coordinates.
        guard let routes = routes?.filter({ $0.shape?.coordinates.count ?? 0 > 1 }) else { return nil }
        
        // Sort routes by closest distance to tap gesture.
        let closest = routes.sorted { (left, right) -> Bool in
            // Existence has been assured through use of filter.
            let leftLine = left.shape!
            let rightLine = right.shape!
            let leftDistance = leftLine.closestCoordinate(to: tapCoordinate)!.coordinate.distance(to: tapCoordinate)
            let rightDistance = rightLine.closestCoordinate(to: tapCoordinate)!.coordinate.distance(to: tapCoordinate)
            
            return leftDistance < rightDistance
        }
        
        // Filter closest coordinates by which ones are under threshold.
        let candidates = closest.filter {
            let closestCoordinate = $0.shape!.closestCoordinate(to: tapCoordinate)!.coordinate
            let closestPoint = mapView.point(for: closestCoordinate)
            
            return closestPoint.distance(to: point) < tapGestureDistanceThreshold
        }
        
        return candidates
    }
    
    @objc func updateCourseView(_ sender: UIGestureRecognizer) {
        if sender.state == .ended, let validAltitude = mapView.altitude {
            altitude = validAltitude
            enableFrameByFrameCourseViewTracking(for: 2)
        }
        
        // Capture altitude for double tap and two finger tap after animation finishes
        if sender is UITapGestureRecognizer, sender.state == .ended {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: {
                if let altitude = self.mapView.altitude {
                    self.altitude = altitude
                }
            })
        }
        
        if let panGesture = sender as? UIPanGestureRecognizer,
           sender.state == .ended || sender.state == .cancelled {
            let velocity = panGesture.velocity(in: self)
            let didFling = sqrt(velocity.x * velocity.x + velocity.y * velocity.y) > 100
            if didFling {
                enableFrameByFrameCourseViewTracking(for: 1)
            }
        }
        
        if sender.state == .changed {
            guard let location = userLocationForCourseTracking else { return }
            
            updateCourseView(to: location)
        }
    }
    
    // MARK: - Utility methods
    
    /**
     Modifies the gesture recognizers to also disable course tracking.
     */
    func makeGestureRecognizersRespectCourseTracking() {
        for gestureRecognizer in mapView.gestureRecognizers ?? []
        where gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UIRotationGestureRecognizer {
            gestureRecognizer.addTarget(self, action: #selector(disableUserCourseTracking))
        }
    }
    
    func makeGestureRecognizersUpdateCourseView() {
        for gestureRecognizer in mapView.gestureRecognizers ?? [] {
            gestureRecognizer.addTarget(self, action: #selector(updateCourseView(_:)))
        }
    }
    
    private func updateCourseView(to location: CLLocation, pitch: CGFloat? = nil, direction: CLLocationDirection? = nil, animated: Bool = false) {
        userCourseView.update(location: location,
                              pitch: pitch ?? mapView.cameraView.pitch,
                              direction: direction ?? location.course,
                              animated: animated,
                              tracksUserCourse: tracksUserCourse)
        
        userCourseView.center = mapView.screenCoordinate(for: location.coordinate).point
    }
}
