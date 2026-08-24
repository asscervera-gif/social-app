//
//  HeadingProvider.swift
//  Social
//
//  Envuelve CLLocationManager para publicar el rumbo de brújula del dispositivo.
//
//  Corrección de honestidad: este comentario afirmaba que se usaba para
//  estabilizar el marcador y dar la guía "gira a la izquierda/derecha", pero
//  `SocialCameraView.swift` nunca leía `heading`/`needsCalibration` — solo
//  instanciaba y arrancaba/paraba el provider sin consumir su valor. Ambas
//  cosas (marcador y guía de apuntado) ya funcionan solo con el ángulo UWB
//  device-relative (`horizontalAngle`/`azimuth`, igual que en Android), que
//  es lo geométricamente correcto para un overlay sobre la cámara (marco de
//  referencia del propio dispositivo, no rumbo verdadero). Se quitó la
//  instanciación inútil en `SocialCameraView.swift` (consumía permiso de
//  ubicación y batería sin aportar nada). Esta clase se deja intacta —
//  bien escrita y correcta — como utilidad reservada para cuando exista de
//  verdad el mapa "Find" (mencionado en `app_store_listing.md`), que sí
//  necesitaría rumbo verdadero para orientar posiciones en un mapa.
//

import Foundation
import CoreLocation
import Combine

final class HeadingProvider: NSObject, ObservableObject {

    /// Rumbo verdadero en grados (0-360). nil hasta la primera lectura válida.
    @Published private(set) var heading: Double?

    /// true si CoreLocation indica que la brújula necesita calibración.
    @Published private(set) var needsCalibration = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.headingFilter = 1 // grados; actualiza con cambios pequeños para suavidad
    }

    /// Pide permiso "cuando se usa la app" y arranca las actualizaciones de rumbo.
    func start() {
        manager.requestWhenInUseAuthorization()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingHeading()
    }
}

extension HeadingProvider: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        needsCalibration = newHeading.headingAccuracy < 0
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        return needsCalibration
    }
}
