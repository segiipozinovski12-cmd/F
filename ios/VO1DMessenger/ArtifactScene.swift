import SceneKit
import UIKit

/// Local, supplied meshes: storefront posters and inspection share the same assets.
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
        do { return try ArtifactModelAssets.object(collection: collection, model: model) }
        catch {
            assertionFailure("Invalid bundled artifact asset: \(collection), \(error)")
            return SCNNode()
        }
    }
}
