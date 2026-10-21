import SceneKit
import UIKit

/// Local, procedural geometry: ownership traits never depend on downloaded artwork.
@MainActor enum ArtifactSceneFactory {
    static let collections = ["singularity", "sovereign", "prism", "orbit", "nova"]
    static let models = ["original", "pearl", "aurora", "gold", "crimson", "monochrome"]
    private static let posters: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 36; cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let environment: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 256))
        return renderer.image { context in
            UIColor(white: 0.12, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
            let colors = [UIColor(white: 0.15, alpha: 1).cgColor, UIColor.white.cgColor,
                          UIColor(red: 0.58, green: 0.68, blue: 0.9, alpha: 1).cgColor,
                          UIColor(white: 0.08, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.3, 0.55, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
            }
            UIColor(white: 1, alpha: 0.8).setFill()
            context.fill(CGRect(x: 42, y: 10, width: 26, height: 150)); context.fill(CGRect(x: 360, y: 38, width: 65, height: 100))
        }
    }()

    static func scene(collection: String, model: String?) -> SCNScene {
        let scene = SCNScene(); scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = environment; scene.lightingEnvironment.intensity = 1.1
        let camera = SCNNode(); camera.name = "camera"; camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 37; camera.camera?.zNear = 0.1; camera.camera?.zFar = 40
        camera.camera?.wantsHDR = true; camera.camera?.bloomIntensity = 0.25; camera.camera?.bloomThreshold = 1
        camera.position = SCNVector3(0, 0, 7.4); scene.rootNode.addChildNode(camera)
        let orbit = SCNNode(); orbit.name = "orbit"; scene.rootNode.addChildNode(orbit)
        let float = SCNNode(); float.name = "float"; orbit.addChildNode(float)
        let object = object(collection: collection, model: model ?? "original")
        object.name = "artifact"; object.eulerAngles = SCNVector3(0.16, -0.28, -0.08); float.addChildNode(object)
        light(scene, name: "key", position: SCNVector3(-3, 5, 5), intensity: 1100, color: .white)
        light(scene, name: "rim", position: SCNVector3(4, 1, -3), intensity: 1500, color: UIColor(red: 0.65, green: 0.75, blue: 1, alpha: 1))
        light(scene, name: "fill", position: SCNVector3(-3, -2, 3), intensity: 420, color: UIColor(red: 1, green: 0.78, blue: 0.65, alpha: 1))
        return scene
    }

    static func poster(collection: String, model: String?) -> UIImage {
        let key = "\(collection)-\(model ?? "original")" as NSString
        if let cached = posters.object(forKey: key) { return cached }
        let image: UIImage = autoreleasepool {
            let scene = scene(collection: collection, model: model)
            let renderer = SCNRenderer(device: nil, options: nil); renderer.scene = scene
            renderer.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
            return renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
        }
        posters.setObject(image, forKey: key, cost: 512 * 512 * 4); return image
    }

    private static func light(_ scene: SCNScene, name: String, position: SCNVector3, intensity: CGFloat, color: UIColor) {
        let node = SCNNode(); node.name = name; node.position = position; node.light = SCNLight()
        node.light?.type = .omni; node.light?.intensity = intensity; node.light?.color = color
        node.light?.attenuationStartDistance = 8; node.light?.attenuationEndDistance = 20
        scene.rootNode.addChildNode(node)
    }

    static func object(collection: String, model: String) -> SCNNode {
        let palette: [UInt32]
        switch model {
        case "pearl": palette = [0xF1F3FF, 0xBACEDD, 0x8498B4]
        case "aurora": palette = [0x7CE9CE, 0xA292F4, 0xECACDA]
        case "gold": palette = [0xEBC57C, 0xF8E5AC, 0xAD7135]
        case "crimson": palette = [0xC52D54, 0xF57B85, 0x421D36]
        case "monochrome": palette = [0x454752, 0xCDD1DF, 0x15151E]
        default:
            switch collection {
            case "singularity": palette = [0xDD8D72, 0xF9CD9D, 0x774B61]
            case "sovereign": palette = [0xD7AF64, 0xF6DE9A, 0x946B39]
            case "prism": palette = [0x9686E1, 0xD6D7FF, 0x6259B8]
            case "orbit": palette = [0x71BFAE, 0xC5F5DC, 0x38767C]
            default: palette = [0xECA47F, 0xFFE0B1, 0xB66B9A]
            }
        }
        let metal = palette.map { material($0, metal: model == "pearl" ? 0.15 : 0.82, roughness: model == "pearl" ? 0.2 : 0.28) }
        let glow = material(model == "monochrome" ? 0xED5666 : palette[1], metal: 0.35, roughness: 0.23, glow: true)
        let dark = material(0x080910, metal: 0.7, roughness: 0.22)
        let root = SCNNode()
        switch collection {
        case "singularity":
            add(SCNSphere(radius: 0.72), to: root, materials: [dark])
            let disk = SCNNode(); disk.eulerAngles = SCNVector3(0.32, 0, 0.19); root.addChildNode(disk)
            ring(1.22, pipe: model == "gold" ? 0.11 : 0.07, to: disk, material: metal[0])
            ring(1.46, pipe: 0.018, to: disk, material: glow)
            ring(0.83, pipe: 0.035, to: disk, material: glow)
            let halo = SCNNode(); halo.eulerAngles.x = .pi / 2; root.addChildNode(halo)
            ring(0.76, pipe: 0.024, to: halo, material: metal[1])
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                let bead = add(SCNSphere(radius: i.isMultiple(of: 3) ? 0.065 : 0.03), to: disk, materials: [glow])
                bead.position = SCNVector3(1.22 * cos(a), 0, 1.22 * sin(a))
            }
        case "sovereign":
            let peaks = model == "aurora" ? 8 : 6
            add(crown(peaks: peaks, tall: model == "crimson"), to: root, materials: metal)
            let base = SCNNode(); base.position.y = -0.59; root.addChildNode(base)
            ring(0.98, pipe: 0.075, to: base, material: metal[1])
            let lower = SCNNode(); lower.position.y = -0.44; root.addChildNode(lower)
            ring(1.01, pipe: 0.027, to: lower, material: glow)
            for i in 0..<peaks {
                let a = Double(i) * 2 * .pi / Double(peaks)
                let stone = add(SCNSphere(radius: model == "pearl" ? 0.11 : 0.085), to: root, materials: [glow])
                stone.position = SCNVector3(1.01 * cos(a), 0.92, 1.01 * sin(a))
                let jewel = add(SCNPyramid(width: 0.22, height: 0.24, length: 0.16), to: root, materials: [metal[2]])
                jewel.position = SCNVector3(1.04 * cos(a), -0.22, 1.04 * sin(a)); jewel.eulerAngles.y = Float(-a)
            }
        case "prism":
            add(crystal(facets: model == "aurora" ? 12 : (model == "crimson" ? 6 : 8), radius: model == "pearl" ? 0.85 : 0.98), to: root, materials: metal)
            let collar = SCNNode(); collar.position.y = 0.3; root.addChildNode(collar)
            ring(1.015, pipe: 0.018, to: collar, material: glow)
            let spark = add(SCNSphere(radius: 0.09), to: root, materials: [glow]); spark.position = SCNVector3(0, 1.35, 0)
        case "orbit":
            let globe = SCNSphere(radius: 0.77); globe.segmentCount = 64
            add(globe, to: root, materials: [metal[0]])
            for i in -2...2 {
                let band = SCNNode(); band.position.y = Float(i) * 0.22; root.addChildNode(band)
                ring(CGFloat(sqrt(0.77 * 0.77 - Double(i * i) * 0.22 * 0.22)), pipe: 0.018, to: band, material: metal[1])
            }
            let rings = SCNNode(); rings.eulerAngles = SCNVector3(0.25, 0, -0.45); root.addChildNode(rings)
            ring(1.19, pipe: model == "gold" ? 0.1 : 0.065, to: rings, material: metal[1])
            ring(1.4, pipe: 0.024, to: rings, material: glow)
            let moon = add(SCNSphere(radius: 0.14), to: rings, materials: [metal[2]]); moon.position = SCNVector3(1.29, 0.1, -0.6)
        default:
            add(star(points: model == "aurora" ? 6 : (model == "crimson" ? 5 : 4), inner: model == "crimson" ? 0.29 : 0.43), to: root, materials: metal)
            let heart = add(crystal(facets: 6, radius: 0.22), to: root, materials: [glow, metal[1], glow])
            heart.scale = SCNVector3(1, 0.3, 1); heart.eulerAngles.x = .pi / 2; heart.position.z = 0.42
            let halo = SCNNode(); halo.eulerAngles.x = .pi / 2; root.addChildNode(halo)
            ring(1.29, pipe: 0.013, to: halo, material: metal[1])
        }
        return root
    }

    private static func material(_ hex: UInt32, metal: CGFloat, roughness: CGFloat, glow: Bool = false) -> SCNMaterial {
        let m = SCNMaterial(); m.lightingModel = .physicallyBased; m.isDoubleSided = true
        let color = UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        m.diffuse.contents = color; m.metalness.contents = metal; m.roughness.contents = roughness
        if glow { m.emission.contents = color; m.emission.intensity = 0.55 }
        return m
    }
    @discardableResult private static func add(_ geometry: SCNGeometry, to parent: SCNNode, materials: [SCNMaterial]) -> SCNNode {
        geometry.materials = materials; let n = SCNNode(geometry: geometry); parent.addChildNode(n); return n
    }
    private static func ring(_ radius: CGFloat, pipe: CGFloat, to parent: SCNNode, material: SCNMaterial) {
        let torus = SCNTorus(ringRadius: radius, pipeRadius: pipe); torus.ringSegmentCount = 96; torus.pipeSegmentCount = 12
        add(torus, to: parent, materials: [material])
    }
    private static func crystal(facets: Int, radius: Double) -> SCNGeometry {
        var faces = [(SCNVector3, SCNVector3, SCNVector3)]()
        for i in 0..<facets {
            let a = Double(i) * 2 * .pi / Double(facets), b = Double(i + 1) * 2 * .pi / Double(facets)
            let p = SCNVector3(radius * cos(a), 0.3, radius * sin(a)), q = SCNVector3(radius * cos(b), 0.3, radius * sin(b))
            faces += [(SCNVector3(0, 1.22, 0), p, q), (p, SCNVector3(0, -1.25, 0), q)]
        }
        return mesh(faces)
    }
    private static func star(points: Int, inner: Double) -> SCNGeometry {
        var faces = [(SCNVector3, SCNVector3, SCNVector3)]()
        for i in 0..<(points * 2) {
            func vertex(_ j: Int) -> SCNVector3 {
                let a = Double(j) * .pi / Double(points) + .pi / 2, r = j.isMultiple(of: 2) ? 1.18 : 1.18 * inner
                return SCNVector3(cos(a) * r, sin(a) * r, 0)
            }
            let p = vertex(i), q = vertex(i + 1)
            faces += [(SCNVector3(0, 0, 0.4), p, q), (SCNVector3(0, 0, -0.3), q, p)]
        }
        return mesh(faces)
    }
    private static func crown(peaks: Int, tall: Bool) -> SCNGeometry {
        var faces = [(SCNVector3, SCNVector3, SCNVector3)]()
        let count = peaks * 2
        for i in 0..<count {
            func vertex(_ j: Int, radius: Double, top: Bool) -> SCNVector3 {
                let a = Double(j) * 2 * .pi / Double(count)
                return SCNVector3(radius * cos(a), top ? (j.isMultiple(of: 2) ? (tall ? 1.12 : 0.92) : 0.1) : -0.58, radius * sin(a))
            }
            let a = vertex(i, radius: 1, top: false), b = vertex(i + 1, radius: 1, top: false)
            let c = vertex(i, radius: 1.04, top: true), d = vertex(i + 1, radius: 1.04, top: true)
            let e = vertex(i, radius: 0.88, top: false), f = vertex(i + 1, radius: 0.88, top: false)
            let g = vertex(i, radius: 0.92, top: true), h = vertex(i + 1, radius: 0.92, top: true)
            faces += [(a,b,c), (b,d,c), (e,g,f), (f,g,h), (c,d,g), (d,h,g), (a,e,b), (b,e,f)]
        }
        return mesh(faces)
    }
    /// Explicit face normals keep the crystal cuts crisp in every renderer.
    private static func mesh(_ faces: [(SCNVector3, SCNVector3, SCNVector3)]) -> SCNGeometry {
        var vertices = [SCNVector3](), normals = [SCNVector3](), groups = [[UInt32]](repeating: [], count: 3)
        for (index, face) in faces.enumerated() {
            let (a,b,c) = face, u = SCNVector3(b.x-a.x,b.y-a.y,b.z-a.z), v = SCNVector3(c.x-a.x,c.y-a.y,c.z-a.z)
            let n = SCNVector3(u.y*v.z-u.z*v.y, u.z*v.x-u.x*v.z, u.x*v.y-u.y*v.x)
            let length = max(0.00001, sqrt(n.x*n.x+n.y*n.y+n.z*n.z))
            let normal = SCNVector3(n.x/length, n.y/length, n.z/length)
            let start = UInt32(vertices.count); vertices += [a,b,c]; normals += [normal,normal,normal]
            groups[index % 3] += [start,start+1,start+2]
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)], elements: groups.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) })
    }
}
