//
//  EventLocationProvider.swift
//  Social
//
//  Ubicación mínima para Modo Evento: solo publica la posición actual para
//  comprobar si cae dentro del radio de un evento activo (EventModeViewModel).
//  Responsabilidad separada de HeadingProvider (que solo da rumbo de brújula)
//  aunque ambas envuelvan CLLocationManager — cada una publica una única cosa.
//

import Foundation
import CoreLocation
import Combine

final class EventLocationProvider: NSObject, ObservableObject {

    @Published private(set) var location: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters // suficiente para un radio de evento
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension EventLocationProvider: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }
}
