//
//  CartoonAvatarView.swift
//  Social
//
//  Avatar ilustrado tipo "busto de dibujo animado" -- misma geometría
//  EXACTA (mismos comandos de path, mismo viewBox="8 2 104 104") que
//  `avatarSVG()` en SOCIAL_APP.html, el boceto que el usuario pidió seguir
//  "exactamente igual". Reimplementado nativo con SwiftUI `Canvas` (no un
//  WebView) para que encaje con el resto de la app.
//
//  Sustituye al círculo con degradado + icono de persona que dibujaba
//  antes PlaceholderAvatarProvider -- sigue sin ser un motor de avatares 3D
//  real (Avaturn/MetaPerson, ver AvatarProvider.swift), solo cambia el
//  ESTILO del marcador de posición para que coincida con el boceto.
//  Equivalente exacto de CartoonAvatar.kt (misma geometría normalizada).
//

import SwiftUI

struct CartoonAvatarView: View {
    let skin: Color
    let hair: Color
    let top: Color

    private let ox: CGFloat = 8
    private let oy: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let sx = size.width / 104
            let sy = size.height / 104
            func nx(_ v: CGFloat) -> CGFloat { (v - ox) * sx }
            func ny(_ v: CGFloat) -> CGFloat { (v - oy) * sy }

            // Cuerpo/hombros — M18 120 Q18 86 60 86 Q102 86 102 120 Z
            var body = Path()
            body.move(to: CGPoint(x: nx(18), y: ny(120)))
            body.addQuadCurve(to: CGPoint(x: nx(60), y: ny(86)), control: CGPoint(x: nx(18), y: ny(86)))
            body.addQuadCurve(to: CGPoint(x: nx(102), y: ny(120)), control: CGPoint(x: nx(102), y: ny(86)))
            body.closeSubpath()
            context.fill(body, with: .color(top))

            // Cuello — rect x=50 y=72 w=20 h=18 rx=6
            let neck = Path(roundedRect: CGRect(x: nx(50), y: ny(72), width: 20 * sx, height: 18 * sy), cornerRadius: 6 * sx)
            context.fill(neck, with: .color(skin))

            // Cara — ellipse cx=60 cy=52 rx=30 ry=33
            let face = Path(ellipseIn: CGRect(x: nx(60) - 30 * sx, y: ny(52) - 33 * sy, width: 60 * sx, height: 66 * sy))
            context.fill(face, with: .color(skin))

            // Orejas
            let earL = Path(ellipseIn: CGRect(x: nx(30) - 6 * sx, y: ny(54) - 6 * sx, width: 12 * sx, height: 12 * sx))
            let earR = Path(ellipseIn: CGRect(x: nx(90) - 6 * sx, y: ny(54) - 6 * sx, width: 12 * sx, height: 12 * sx))
            context.fill(earL, with: .color(skin))
            context.fill(earR, with: .color(skin))

            // Pelo — M28 46 Q28 14 60 14 Q92 14 92 46 Q88 30 60 30 Q32 30 28 46 Z
            var hairPath = Path()
            hairPath.move(to: CGPoint(x: nx(28), y: ny(46)))
            hairPath.addQuadCurve(to: CGPoint(x: nx(60), y: ny(14)), control: CGPoint(x: nx(28), y: ny(14)))
            hairPath.addQuadCurve(to: CGPoint(x: nx(92), y: ny(46)), control: CGPoint(x: nx(92), y: ny(14)))
            hairPath.addQuadCurve(to: CGPoint(x: nx(60), y: ny(30)), control: CGPoint(x: nx(88), y: ny(30)))
            hairPath.addQuadCurve(to: CGPoint(x: nx(28), y: ny(46)), control: CGPoint(x: nx(32), y: ny(30)))
            hairPath.closeSubpath()
            context.fill(hairPath, with: .color(hair))

            // Cejas — rect 12x3 rx=1.5 en (43,46) y (65,46)
            let browColor = Color(red: 0x4A / 255, green: 0x2E / 255, blue: 0x1A / 255)
            let browL = Path(roundedRect: CGRect(x: nx(43), y: ny(46), width: 12 * sx, height: 3 * sy), cornerRadius: 1.5 * sx)
            let browR = Path(roundedRect: CGRect(x: nx(65), y: ny(46), width: 12 * sx, height: 3 * sy), cornerRadius: 1.5 * sx)
            context.fill(browL, with: .color(browColor))
            context.fill(browR, with: .color(browColor))

            // Ojos — circle r=3.4 en (49,54) y (71,54)
            let eyeColor = Color(red: 0x33 / 255, green: 0x31 / 255, blue: 0x2F / 255)
            let eyeL = Path(ellipseIn: CGRect(x: nx(49) - 3.4 * sx, y: ny(54) - 3.4 * sx, width: 6.8 * sx, height: 6.8 * sx))
            let eyeR = Path(ellipseIn: CGRect(x: nx(71) - 3.4 * sx, y: ny(54) - 3.4 * sx, width: 6.8 * sx, height: 6.8 * sx))
            context.fill(eyeL, with: .color(eyeColor))
            context.fill(eyeR, with: .color(eyeColor))

            // Boca — M52 70 Q60 77 68 70, stroke #b5533f width 2.4
            var mouth = Path()
            mouth.move(to: CGPoint(x: nx(52), y: ny(70)))
            mouth.addQuadCurve(to: CGPoint(x: nx(68), y: ny(70)), control: CGPoint(x: nx(60), y: ny(77)))
            context.stroke(mouth, with: .color(Color(red: 0xB5 / 255, green: 0x53 / 255, blue: 0x3F / 255)), style: StrokeStyle(lineWidth: 2.4 * sx, lineCap: .round))
        }
    }
}

/// Paleta discreta de looks -- mismos valores hexadecimales exactos que
/// `LOOKS`/`me` en SOCIAL_APP.html, no colores inventados. `top` dobla
/// como "color de ropa"; usa el mismo conjunto de acentos de marca
/// (SocialColors) que el resto de la identidad visual de la app.
/// Equivalente exacto de AvatarLook (Kotlin).
enum AvatarLook {
    static let skinTones = ["#E0AC69", "#C68642", "#FFE0BD", "#8D5524", "#FCD7C2", "#F1C27D"]
    static let hairTones = ["#1A1A1A", "#111111", "#C9A227", "#B5B5B5", "#6B4226"]
    static let topColors = ["#4DABF7", "#20BF6B", "#A55EEA", "#F76707", "#495057", "#E64980"]

    static func random() -> (skin: String, hair: String, top: String) {
        (skinTones.randomElement()!, hairTones.randomElement()!, topColors.randomElement()!)
    }
}
