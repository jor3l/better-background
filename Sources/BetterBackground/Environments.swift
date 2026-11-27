import AppKit
import RealityKit

/// Builds the room around the person. Each environment is rebuilt from scratch when its
/// look changes, which is cheap for scenes this size.
@MainActor
enum EnvironmentBuilder {
    struct Built {
        let root: Entity
        /// Lit models that should receive the image-based light.
        let litModels: [Entity]
    }

    static func build(_ t: Tuning) -> Built {
        let root = Entity()
        root.name = "Environment"
        var lit: [Entity] = []

        func add(_ e: ModelEntity, lit isLit: Bool = true) {
            root.addChild(e)
            if isLit { lit.append(e) }
        }
        func box(_ w: Float, _ h: Float, _ d: Float, _ m: Material, at p: SIMD3<Float>, radius: Float = 0) -> ModelEntity {
            let e = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: radius), materials: [m])
            e.position = p
            return e
        }
        func glow(_ c: RGBColor) -> UnlitMaterial {
            UnlitMaterial(color: c.nsColor)
        }

        let wall = pbr(t.wallColor.nsColor, roughness: 0.9)
        let floor = pbr(t.floorColor.nsColor, roughness: t.environment == .studio ? 0.4 : 0.6)

        // Shell shared by every environment
        add(box(7, 0.02, 7, floor, at: [0, -0.01, -0.5]))
        add(box(7, 3.2, 0.05, wall, at: [0, 1.6, -2.2]))
        add(box(0.05, 3.2, 5, wall, at: [-3.0, 1.6, 0.3]))
        add(box(0.05, 3.2, 5, wall, at: [3.0, 1.6, 0.3]))

        switch t.environment {
        case .livingRoom:
            let window = ModelEntity(mesh: .generatePlane(width: 1.4, height: 1.0), materials: [glow(t.accentColor)])
            window.position = [-1.6, 1.7, -2.17]
            add(window, lit: false)
            if t.showProps {
                let wood = pbr(NSColor(srgbRed: 0.3, green: 0.2, blue: 0.14, alpha: 1), roughness: 0.5)
                add(box(1.4, 0.04, 0.3, wood, at: [1.3, 1.5, -2.02]))
                add(box(0.08, 0.28, 0.2, pbr(.systemRed, roughness: 0.7), at: [1.0, 1.66, -2.02]))
                add(box(0.07, 0.24, 0.2, pbr(.systemTeal, roughness: 0.7), at: [1.1, 1.64, -2.02]))
                let vase = ModelEntity(mesh: .generateCylinder(height: 0.3, radius: 0.07), materials: [pbr(.white, roughness: 0.2)])
                vase.position = [1.6, 1.67, -2.02]
                add(vase)
                let ball = ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [pbr(.systemOrange, roughness: 0.3, metallic: 0.8)])
                ball.position = [-0.9, 0.18, -1.2]
                add(ball)
                let plant = ModelEntity(mesh: .generateCylinder(height: 1.1, radius: 0.18), materials: [pbr(NSColor(srgbRed: 0.2, green: 0.45, blue: 0.25, alpha: 1), roughness: 0.8)])
                plant.position = [2.2, 0.55, -1.5]
                add(plant)
            }

        case .studio:
            // Seamless backdrop: a large curved-looking sweep made of a tilted panel
            let sweep = box(5, 0.02, 1.2, floor, at: [0, 0.35, -1.85])
            sweep.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
            add(sweep)
            // Light pool on the back wall
            let pool = ModelEntity(mesh: .generatePlane(width: 2.2, height: 1.4, cornerRadius: 0.7), materials: [glow(RGBColor(t.accentColor.r * 0.35, t.accentColor.g * 0.35, t.accentColor.b * 0.35))])
            pool.position = [0.4, 1.5, -2.17]
            add(pool, lit: false)
            if t.showProps {
                let stand = pbr(.darkGray, roughness: 0.3, metallic: 0.9)
                for x: Float in [-2.0, 2.0] {
                    let pole = ModelEntity(mesh: .generateCylinder(height: 2.0, radius: 0.02), materials: [stand])
                    pole.position = [x, 1.0, -1.0]
                    add(pole)
                    let head = box(0.35, 0.35, 0.2, stand, at: [x, 2.05, -1.0], radius: 0.03)
                    add(head)
                }
            }

        case .neon:
            let colors = [t.accentColor, t.rimColor]
            for (k, y) in [Float(0.9), 1.6, 2.3].enumerated() {
                let strip = box(5.5, 0.03, 0.02, glow(colors[k % 2]), at: [0, y, -2.16])
                add(strip, lit: false)
            }
            for x: Float in [-2.97, 2.97] {
                let strip = box(0.02, 2.6, 0.03, glow(colors[x < 0 ? 0 : 1]), at: [x, 1.4, -1.0])
                add(strip, lit: false)
            }
            if t.showProps {
                let sign = ModelEntity(mesh: .generatePlane(width: 0.9, height: 0.35, cornerRadius: 0.17), materials: [glow(t.accentColor)])
                sign.position = [1.3, 2.0, -2.15]
                add(sign, lit: false)
                let shelf = pbr(NSColor(srgbRed: 0.15, green: 0.15, blue: 0.18, alpha: 1), roughness: 0.3, metallic: 0.6)
                add(box(1.2, 0.04, 0.3, shelf, at: [-1.3, 1.3, -2.02]))
                for (i, c) in [NSColor.systemPurple, .systemPink, .systemBlue].enumerated() {
                    add(box(0.18, 0.18, 0.18, pbr(c, roughness: 0.2, metallic: 0.5), at: [-1.7 + Float(i) * 0.35, 1.41, -2.02]))
                }
            }

        case .office:
            for x: Float in [-1.8, 0, 1.8] {
                let window = ModelEntity(mesh: .generatePlane(width: 1.3, height: 1.6), materials: [glow(t.accentColor)])
                window.position = [x, 1.7, -2.17]
                add(window, lit: false)
            }
            if t.showProps {
                let shelf = pbr(.white, roughness: 0.4)
                add(box(0.4, 1.8, 0.35, shelf, at: [-2.6, 0.9, -1.5]))
                let plant = ModelEntity(mesh: .generateSphere(radius: 0.35), materials: [pbr(NSColor(srgbRed: 0.25, green: 0.5, blue: 0.25, alpha: 1), roughness: 0.8)])
                plant.position = [2.4, 0.9, -1.6]
                add(plant)
                add(box(0.35, 0.55, 0.35, pbr(.lightGray, roughness: 0.5), at: [2.4, 0.27, -1.6]))
            }
        }

        if t.showDesk {
            let deskColor: NSColor = t.environment == .office ? NSColor(srgbRed: 0.8, green: 0.7, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.22, green: 0.22, blue: 0.25, alpha: 1)
            add(box(2.0, 0.05, 0.7, pbr(deskColor, roughness: 0.35), at: [0, 0.74, 0.55], radius: 0.01))
        }

        return Built(root: root, litModels: lit)
    }

    static func pbr(_ color: NSColor, roughness: Float, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        return material
    }
}
