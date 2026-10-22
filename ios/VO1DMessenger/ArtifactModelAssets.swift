import CryptoKit
import SceneKit
import UIKit

/// Geometry and PBR textures are bundled locally. No remote model URLs are accepted.
@MainActor enum ArtifactModelAssets {
    struct Catalog: Decodable { let version: Int; let collections: [String: Asset] }
    struct Asset: Decodable { let title: String; let source: String; let meshes: [Mesh]; let materials: [Material] }
    struct Mesh: Decodable { let name: String; let file: String; let vertices: Int; let indices: Int; let material: Int; let sha256: String }
    struct Material: Decodable {
        let name: String; let color: [CGFloat]; let metalness: CGFloat; let roughness: CGFloat
        let diffuse: String?; let normal: String?; let metallic: String?; let rough: String?; let ao: String?; let emission: String?
    }
    enum AssetError: Error { case invalidCatalog, invalidMesh, missingTexture }
    static let directory = Bundle.main.resourceURL!.appendingPathComponent("ArtifactModels", isDirectory: true)
    static let catalog: Catalog? = {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.version == 1 else { return nil }
        return catalog
    }()
    // Only five source templates are retained. Instances share immutable geometry data and textures.
    private static var templates: [String: SCNNode] = [:]
    private static let tinted: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 72; cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()

    static func object(collection: String, model: String) throws -> SCNNode {
        let original: SCNNode
        if let cached = templates[collection] { original = cached }
        else {
            original = try load(collection: collection)
            templates[collection] = original
        }
        let node = original.clone()
        guard model != "original" else { return node }
        let color: UIColor
        switch model {
        case "pearl": color = UIColor(red: 0.86, green: 0.92, blue: 1, alpha: 1)
        case "aurora": color = UIColor(red: 0.42, green: 0.92, blue: 0.79, alpha: 1)
        case "gold": color = UIColor(red: 1, green: 0.73, blue: 0.28, alpha: 1)
        case "crimson": color = UIColor(red: 0.91, green: 0.17, blue: 0.3, alpha: 1)
        case "monochrome": color = UIColor(white: 0.28, alpha: 1)
        default: return node
        }
        node.enumerateChildNodes { child, _ in
            guard let source = child.geometry, let geometry = source.copy() as? SCNGeometry else { return }
            geometry.materials = source.materials.map { source in
                let material = source.copy() as! SCNMaterial
                if let image = source.diffuse.contents as? UIImage {
                    let key = "\(collection)/\(source.name ?? "")/\(model)" as NSString
                    if let cached = tinted.object(forKey: key) { material.diffuse.contents = cached }
                    else {
                        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                        let result = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
                            let rect = CGRect(origin: .zero, size: image.size)
                            image.draw(in: rect)
                            // Color preserves the original texture's shading, facial features and panel detail.
                            color.setFill(); context.fill(rect, blendMode: .color)
                            color.withAlphaComponent(model == "monochrome" ? 0.32 : 0.12).setFill()
                            context.fill(rect, blendMode: .multiply)
                        }
                        tinted.setObject(result, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
                        material.diffuse.contents = result
                    }
                } else { material.diffuse.contents = color }
                if model == "pearl" { material.metalness.contents = 0.25; material.roughness.contents = 0.28 }
                else if collection != "nova" { material.roughness.intensity = 0.85 }
                return material
            }
            child.geometry = geometry
        }
        return node
    }

    private static func file(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name.utf8.count < 100, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw AssetError.invalidCatalog }
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private static func load(collection: String) throws -> SCNNode {
        guard let asset = catalog?.collections[collection], !asset.meshes.isEmpty, asset.meshes.count <= 32,
              !asset.materials.isEmpty, asset.materials.count <= 32 else { throw AssetError.invalidCatalog }
        let folder = try file(collection, in: directory)
        let materials = try asset.materials.map { spec -> SCNMaterial in
            guard spec.color.count == 3 else { throw AssetError.invalidCatalog }
            let material = SCNMaterial(); material.name = spec.name; material.lightingModel = .physicallyBased
            material.isDoubleSided = true
            material.diffuse.contents = UIColor(red: spec.color[0], green: spec.color[1], blue: spec.color[2], alpha: 1)
            material.metalness.contents = spec.metalness; material.roughness.contents = spec.roughness
            for (name, property) in [(spec.diffuse, material.diffuse), (spec.normal, material.normal),
                                     (spec.metallic, material.metalness), (spec.rough, material.roughness),
                                     (spec.ao, material.ambientOcclusion), (spec.emission, material.emission)] {
                guard let name else { continue }
                guard let image = UIImage(contentsOfFile: try file(name, in: folder).path) else { throw AssetError.missingTexture }
                property.contents = image; property.wrapS = .repeat; property.wrapT = .repeat
                property.magnificationFilter = .linear; property.minificationFilter = .linear; property.mipFilter = .linear
            }
            material.emission.intensity = spec.emission == nil ? 0 : 0.22
            return material
        }
        let root = SCNNode(); root.userData = ["source": asset.source, "assetVersion": 1]
        for mesh in asset.meshes {
            guard (3...200_000).contains(mesh.vertices), (3...1_000_000).contains(mesh.indices), mesh.indices.isMultiple(of: 3),
                  materials.indices.contains(mesh.material) else { throw AssetError.invalidMesh }
            let data = try Data(contentsOf: file(mesh.file, in: folder), options: .mappedIfSafe)
            let vertexBytes = mesh.vertices * 32
            guard data.count == vertexBytes + mesh.indices * 4,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == mesh.sha256 else { throw AssetError.invalidMesh }
            let sources = [(SCNGeometrySource.Semantic.vertex, 0, 3), (.normal, 12, 3), (.texcoord, 24, 2)].map { semantic, offset, components in
                SCNGeometrySource(data: data, semantic: semantic, vectorCount: mesh.vertices, usesFloatComponents: true,
                                  componentsPerVector: components, bytesPerComponent: 4, dataOffset: offset, dataStride: 32)
            }
            let elements = SCNGeometryElement(data: data.subdata(in: vertexBytes..<data.count), primitiveType: .triangles,
                                              primitiveCount: mesh.indices / 3, bytesPerIndex: 4)
            let geometry = SCNGeometry(sources: sources, elements: [elements]); geometry.materials = [materials[mesh.material]]
            let child = SCNNode(geometry: geometry); child.name = mesh.name; root.addChildNode(child)
        }
        return root
    }
}

