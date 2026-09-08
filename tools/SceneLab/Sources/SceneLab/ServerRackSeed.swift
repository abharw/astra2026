import SpatialCore

/// Reproducible authored starting content. This is a semantic teaching model, not a scan,
/// CAD model, or claim about a particular installed system.
func makeDetailedServerRack() throws -> SceneDocument {
    let recipes: [(String, GeometryRecipe)] = [
        ("post", .box(size: Vec3(0.022, 0.60, 0.022))),
        ("beam-x", .box(size: Vec3(0.48, 0.018, 0.024))),
        ("beam-z", .box(size: Vec3(0.022, 0.018, 0.856))),
        ("u-marker", .box(size: Vec3(0.009, 0.009, 0.003))),
        ("server-floor", .box(size: Vec3(0.40, 0.008, 0.646))),
        ("server-side", .box(size: Vec3(0.012, 0.080, 0.646))),
        ("server-rear", .box(size: Vec3(0.40, 0.080, 0.010))),
        ("server-cover", .box(size: Vec3(0.40, 0.008, 0.636))),
        ("rack-ear", .box(size: Vec3(0.026, 0.080, 0.012))),
        ("drive", .box(size: Vec3(0.040, 0.050, 0.032))),
        ("drive-handle", .box(size: Vec3(0.034, 0.006, 0.006))),
        ("light", .sphere(radius: 0.004, segments: 8)),
        ("control", .box(size: Vec3(0.025, 0.050, 0.014))),
        ("motherboard", .box(size: Vec3(0.31, 0.008, 0.21))),
        ("cpu", .box(size: Vec3(0.050, 0.010, 0.055))),
        ("heatsink-base", .box(size: Vec3(0.066, 0.010, 0.073))),
        ("heatsink-fin", .box(size: Vec3(0.005, 0.035, 0.068))),
        ("dimm", .box(size: Vec3(0.007, 0.040, 0.058))),
        ("dimm-bank", .box(size: Vec3(0.055, 0.004, 0.070))),
        ("fan", .cylinder(radius: 0.027, height: 0.030, radialSegments: 12)),
        ("fan-hub", .cylinder(radius: 0.009, height: 0.034, radialSegments: 12)),
        ("fan-cage", .box(size: Vec3(0.055, 0.060, 0.038))),
        ("backplane", .box(size: Vec3(0.32, 0.050, 0.010))),
        ("psu", .box(size: Vec3(0.085, 0.050, 0.14))),
        ("handle", .box(size: Vec3(0.055, 0.008, 0.012))),
        ("riser", .box(size: Vec3(0.060, 0.045, 0.090))),
        ("switch", .box(size: Vec3(0.40, 0.034, 0.30))),
        ("port", .box(size: Vec3(0.011, 0.010, 0.006))),
        ("vent", .box(size: Vec3(0.007, 0.026, 0.004))),
        ("pdu", .box(size: Vec3(0.032, 0.43, 0.038))),
        ("outlet", .box(size: Vec3(0.019, 0.026, 0.004))),
        ("cable", .tube(
            points: [Vec3(0, 0, 0), Vec3(0, 0, 0.10), Vec3(0.04, 0, 0.16)],
            radius: 0.004,
            radialSegments: 8
        ))
    ]
    let definitions = try recipes.map { id, recipe in
        GeometryDefinition(
            geometryId: id,
            contentHash: try canonicalContentHash(for: recipe),
            recipe: recipe
        )
    }
    let materials = [
        Material(materialId: "rack-black", baseColorLinear: [0.035, 0.045, 0.055, 1], metallic: 0.72, roughness: 0.34),
        Material(materialId: "chassis", baseColorLinear: [0.17, 0.19, 0.21, 1], metallic: 0.72, roughness: 0.38),
        Material(materialId: "cover", baseColorLinear: [0.25, 0.28, 0.30, 1], metallic: 0.78, roughness: 0.33),
        Material(materialId: "dark-plastic", baseColorLinear: [0.025, 0.030, 0.035, 1], metallic: 0.08, roughness: 0.62),
        Material(materialId: "pcb", baseColorLinear: [0.035, 0.19, 0.12, 1], metallic: 0.12, roughness: 0.62),
        Material(materialId: "aluminum", baseColorLinear: [0.48, 0.52, 0.55, 1], metallic: 0.85, roughness: 0.28),
        Material(materialId: "memory", baseColorLinear: [0.04, 0.27, 0.15, 1], metallic: 0.14, roughness: 0.58),
        Material(materialId: "service-blue", baseColorLinear: [0.03, 0.34, 0.78, 1], metallic: 0.12, roughness: 0.32),
        Material(materialId: "network", baseColorLinear: [0.04, 0.19, 0.26, 1], metallic: 0.35, roughness: 0.48),
        Material(materialId: "power", baseColorLinear: [0.31, 0.32, 0.34, 1], metallic: 0.52, roughness: 0.45),
        Material(materialId: "led-green", baseColorLinear: [0.05, 0.92, 0.30, 1], metallic: 0.05, roughness: 0.18),
        Material(materialId: "cable-blue", baseColorLinear: [0.02, 0.25, 0.74, 1], metallic: 0.05, roughness: 0.50),
        Material(materialId: "cable-orange", baseColorLinear: [0.92, 0.20, 0.03, 1], metallic: 0.05, roughness: 0.50)
    ]

    let illustrative = Provenance(origin: .authored, factualSupport: .illustrative)
    let rackSource = Provenance(origin: .authored, factualSupport: .referenceBased, sourceRefs: [
        "https://www.se.com/us/en/product/AR3100/apc-netshelter-sx-server-rack-enclosure-42u-black-1991h-x-600w-x-1070d-mm-taa/"
    ])
    let r760Source = Provenance(origin: .authored, factualSupport: .referenceBased, sourceRefs: [
        "https://www.dell.com/support/manuals/en-us/oth-r760/per760_ism_pub/chassis-dimensions?guid=guid-04578793-7445-43f5-acc4-a0b11f85eb5f&lang=en-us",
        "https://www.dell.com/support/manuals/en-us/poweredge-r760/per760_ism_pub/inside-the-system?guid=guid-043d9f52-a16e-4494-a65a-128c47fd4ea4&lang=en-us",
        "https://www.dell.com/support/manuals/en-us/poweredge-r760/per760_ism_pub/system-overview?guid=guid-76d1f6a6-2a97-4b55-bef5-9db0afcce302&lang=en-us"
    ])
    var nodes = [SceneNode(
        nodeId: "rack",
        semantic: NodeSemantic(
            name: "Open-frame tabletop server rack",
            role: "assembly",
            description: "A 12U teaching cutaway derived from 19-inch rack and APC 42U proportions. Compressed to a 0.60 m tabletop height; rail holes and small dimensions are schematic."
        ),
        provenance: rackSource
    )]

    func assembly(
        _ id: String, parent: String, at position: Vec3, name: String,
        role: String, description: String, provenance: Provenance = illustrative
    ) {
        nodes.append(SceneNode(
            nodeId: id,
            parentId: parent,
            transform: Transform3D(translation: position),
            semantic: NodeSemantic(name: name, role: role, description: description),
            provenance: provenance
        ))
    }
    func part(
        _ id: String, parent: String, geometry: String, material: String, at position: Vec3,
        name: String, role: String, description: String = "Schematic authored geometry.",
        rotation: Quaternion = .identity
    ) {
        nodes.append(SceneNode(
            nodeId: id,
            parentId: parent,
            geometryId: geometry,
            materialId: material,
            transform: Transform3D(translation: position, rotation: rotation),
            semantic: NodeSemantic(name: name, role: role, description: description),
            provenance: illustrative
        ))
    }

    let posts = [
        Vec3(-0.23, 0.30, -0.417), Vec3(0.23, 0.30, -0.417),
        Vec3(-0.23, 0.30, 0.417), Vec3(0.23, 0.30, 0.417)
    ]
    for (index, position) in posts.enumerated() {
        let postID = "rack-post-\(index + 1)"
        part(postID, parent: "rack", geometry: "post", material: "rack-black", at: position, name: "Rack post \(index + 1)", role: "mounting-rail")
        if index >= 2 {
            for marker in 0..<6 {
                part(
                    "\(postID)-u-marker-\(marker + 1)",
                    parent: postID,
                    geometry: "u-marker",
                    material: "aluminum",
                    at: Vec3(index == 2 ? 0.0115 : -0.0115, -0.250 + Double(marker) * 0.100, 0.012),
                    name: "Paired U position marker \(marker + 1)",
                    role: "mounting-hole",
                    description: "One marker per displayed rack unit; the three-hole EIA pattern is simplified."
                )
            }
        }
    }
    for (level, y) in [("bottom", 0.010), ("top", 0.590)] {
        part("rack-\(level)-front", parent: "rack", geometry: "beam-x", material: "rack-black", at: Vec3(0, y, 0.417), name: "\(level.capitalized) front beam", role: "structure")
        part("rack-\(level)-rear", parent: "rack", geometry: "beam-x", material: "rack-black", at: Vec3(0, y, -0.417), name: "\(level.capitalized) rear beam", role: "structure")
        part("rack-\(level)-left", parent: "rack", geometry: "beam-z", material: "rack-black", at: Vec3(-0.23, y, 0), name: "\(level.capitalized) left beam", role: "structure")
        part("rack-\(level)-right", parent: "rack", geometry: "beam-z", material: "rack-black", at: Vec3(0.23, y, 0), name: "\(level.capitalized) right beam", role: "structure")
    }

    assembly(
        "server-1", parent: "rack", at: Vec3(0, 0.36, 0.075),
        name: "Server 1 — PowerEdge R760 teaching cutaway",
        role: "compute-server",
        description: "Reference-based 2U envelope and component topology. Pulled forward with cover lifted; internal sizes and installed DIMM choice are illustrative.",
        provenance: r760Source
    )
    part("server-1-floor", parent: "server-1", geometry: "server-floor", material: "chassis", at: Vec3(0, 0, 0), name: "Chassis floor", role: "chassis")
    part("server-1-left-wall", parent: "server-1", geometry: "server-side", material: "chassis", at: Vec3(-0.194, 0.040, 0), name: "Left chassis wall", role: "chassis")
    part("server-1-right-wall", parent: "server-1", geometry: "server-side", material: "chassis", at: Vec3(0.194, 0.040, 0), name: "Right chassis wall", role: "chassis")
    part("server-1-rear-wall", parent: "server-1", geometry: "server-rear", material: "chassis", at: Vec3(0, 0.040, -0.318), name: "Rear I/O wall", role: "rear-io")
    part("server-1-cover", parent: "server-1", geometry: "server-cover", material: "cover", at: Vec3(0, 0.105, -0.025), name: "Lifted server cover", role: "removable-cover", description: "Parked above the chassis for the teaching view; normally closes the enclosure.")
    for side in [-1.0, 1.0] {
        let label = side < 0 ? "left" : "right"
        part("server-1-\(label)-ear", parent: "server-1", geometry: "rack-ear", material: "chassis", at: Vec3(side * 0.213, 0.040, 0.321), name: "\(label.capitalized) rack ear", role: "rack-handle")
    }

    assembly(
        "server-1-front-storage", parent: "server-1", at: Vec3(0, 0.031, 0.316),
        name: "Eight-bay front storage group", role: "front-drive-bays",
        description: "This teaching model selects the documented 8 x 2.5-inch front option."
    )
    for index in 0..<8 {
        let driveID = "server-1-drive-\(index + 1)"
        part(driveID, parent: "server-1-front-storage", geometry: "drive", material: "dark-plastic", at: Vec3(-0.143 + Double(index) * 0.041, 0, 0), name: "Front drive carrier \(index + 1)", role: "hot-swap-drive")
        part("\(driveID)-handle", parent: driveID, geometry: "drive-handle", material: "service-blue", at: Vec3(0, -0.017, 0.019), name: "Drive \(index + 1) release handle", role: "service-latch")
    }
    part("server-1-left-control", parent: "server-1", geometry: "control", material: "dark-plastic", at: Vec3(-0.181, 0.034, 0.326), name: "Left control panel", role: "front-control")
    part("server-1-power-light", parent: "server-1-left-control", geometry: "light", material: "led-green", at: Vec3(0, 0.012, 0.010), name: "Power status light", role: "status-indicator")
    part("server-1-right-control", parent: "server-1", geometry: "control", material: "dark-plastic", at: Vec3(0.181, 0.034, 0.326), name: "Right control panel and service tag", role: "front-control")
    part("server-1-backplane", parent: "server-1", geometry: "backplane", material: "pcb", at: Vec3(0, 0.031, 0.270), name: "Front drive backplane", role: "storage-backplane")
    part("server-1-motherboard", parent: "server-1", geometry: "motherboard", material: "pcb", at: Vec3(0, 0.010, -0.040), name: "System motherboard", role: "system-board")

    let faceForward = Quaternion(0.7071067811865475, 0, 0, 0.7071067811865476)
    assembly(
        "server-1-fan-wall", parent: "server-1", at: Vec3(0, 0.037, 0.190),
        name: "Six-fan hot-swap cooling wall", role: "cooling-assembly",
        description: "Dell documents up to six hot-plug cooling fans."
    )
    for index in 0..<6 {
        let x = -0.145 + Double(index) * 0.058
        let fanID = "server-1-fan-\(index + 1)"
        part("\(fanID)-cage", parent: "server-1-fan-wall", geometry: "fan-cage", material: "dark-plastic", at: Vec3(x, 0, 0), name: "Fan \(index + 1) cage", role: "fan-carrier")
        part(fanID, parent: "server-1-fan-wall", geometry: "fan", material: "aluminum", at: Vec3(x, 0, 0.021), name: "Cooling fan \(index + 1)", role: "cooling-fan", rotation: faceForward)
        part("\(fanID)-hub", parent: fanID, geometry: "fan-hub", material: "service-blue", at: Vec3(0, 0, 0), name: "Fan \(index + 1) service hub", role: "service-point")
    }

    for cpuIndex in 0..<2 {
        let cpuID = "server-1-cpu-\(cpuIndex + 1)"
        assembly(cpuID, parent: "server-1-motherboard", at: Vec3(cpuIndex == 0 ? -0.075 : 0.075, 0.012, 0), name: "CPU socket \(cpuIndex + 1)", role: "processor-assembly", description: "One of the R760's two documented processor positions.")
        part("\(cpuID)-package", parent: cpuID, geometry: "cpu", material: "dark-plastic", at: Vec3(0, 0, 0), name: "CPU \(cpuIndex + 1) package", role: "processor")
        part("\(cpuID)-heatsink-base", parent: cpuID, geometry: "heatsink-base", material: "aluminum", at: Vec3(0, 0.012, 0), name: "CPU \(cpuIndex + 1) heat sink base", role: "heat-sink")
        for fin in 0..<5 {
            part("\(cpuID)-fin-\(fin + 1)", parent: cpuID, geometry: "heatsink-fin", material: "aluminum", at: Vec3(-0.024 + Double(fin) * 0.012, 0.034, 0), name: "CPU \(cpuIndex + 1) heat sink fin \(fin + 1)", role: "heat-sink-fin")
        }
    }
    let bankPositions = [-0.142, -0.112, 0.112, 0.142]
    for bank in 0..<4 {
        let bankID = "server-1-dimm-bank-\(bank + 1)"
        part(bankID, parent: "server-1-motherboard", geometry: "dimm-bank", material: "dark-plastic", at: Vec3(bankPositions[bank], 0.009, 0), name: "DIMM socket bank \(bank + 1)", role: "memory-sockets", description: "Represents eight of the documented 32 DDR5 sockets.")
        for module in 0..<4 {
            part("\(bankID)-module-\(module + 1)", parent: bankID, geometry: "dimm", material: "memory", at: Vec3(-0.018 + Double(module) * 0.012, 0.022, 0), name: "DIMM module \(bank * 4 + module + 1)", role: "memory-module", description: "Illustrative half-populated memory configuration.")
        }
    }

    assembly("server-1-rear-risers", parent: "server-1", at: Vec3(0, 0.035, -0.225), name: "Rear expansion area", role: "pcie-expansion", description: "Four schematic cages correspond to the documented rear riser groups.")
    for index in 0..<4 {
        part("server-1-riser-\(index + 1)", parent: "server-1-rear-risers", geometry: "riser", material: "dark-plastic", at: Vec3(-0.105 + Double(index) * 0.070, 0, 0), name: "PCIe riser cage \(index + 1)", role: "expansion-riser")
    }
    for index in 0..<2 {
        let psuID = "server-1-psu-\(index + 1)"
        part(psuID, parent: "server-1", geometry: "psu", material: "power", at: Vec3(index == 0 ? -0.145 : 0.145, 0.035, -0.240), name: "Redundant power supply \(index + 1)", role: "power-supply")
        part("\(psuID)-handle", parent: psuID, geometry: "handle", material: "service-blue", at: Vec3(0, 0, -0.076), name: "PSU \(index + 1) release handle", role: "service-latch")
    }

    assembly("server-2", parent: "rack", at: Vec3(0, 0.205, 0), name: "Server 2 — closed 2U compute node", role: "compute-server", description: "Schematic closed server; detailed internals are represented by Server 1.")
    part("server-2-chassis", parent: "server-2", geometry: "server-floor", material: "chassis", at: Vec3(0, 0, 0), name: "Server 2 chassis", role: "chassis")
    part("server-2-left-wall", parent: "server-2", geometry: "server-side", material: "chassis", at: Vec3(-0.194, 0.040, 0), name: "Server 2 left wall", role: "chassis")
    part("server-2-right-wall", parent: "server-2", geometry: "server-side", material: "chassis", at: Vec3(0.194, 0.040, 0), name: "Server 2 right wall", role: "chassis")
    part("server-2-rear-wall", parent: "server-2", geometry: "server-rear", material: "chassis", at: Vec3(0, 0.040, -0.318), name: "Server 2 rear wall", role: "rear-io")
    part("server-2-cover", parent: "server-2", geometry: "server-cover", material: "cover", at: Vec3(0, 0.080, 0), name: "Server 2 cover", role: "cover")
    for index in 0..<8 {
        part("server-2-drive-\(index + 1)", parent: "server-2", geometry: "drive", material: "dark-plastic", at: Vec3(-0.143 + Double(index) * 0.041, 0.031, 0.323), name: "Server 2 drive bay \(index + 1)", role: "hot-swap-drive")
    }
    for index in 0..<5 {
        part("server-2-vent-\(index + 1)", parent: "server-2", geometry: "vent", material: "aluminum", at: Vec3(-0.016 + Double(index) * 0.008, 0.031, 0.341), name: "Server 2 front vent \(index + 1)", role: "air-intake")
    }

    assembly("switch", parent: "rack", at: Vec3(0, 0.535, 0.055), name: "24-port top-of-rack network switch", role: "network-switch", description: "Illustrative switch with individually addressable front ports.")
    part("switch-chassis", parent: "switch", geometry: "switch", material: "network", at: Vec3(0, 0, 0), name: "Switch chassis", role: "chassis")
    for index in 0..<24 {
        let row = index / 12
        let column = index % 12
        part("switch-port-\(index + 1)", parent: "switch", geometry: "port", material: "dark-plastic", at: Vec3(-0.132 + Double(column) * 0.024, -0.006 + Double(row) * 0.013, 0.128), name: "Network port \(index + 1)", role: "ethernet-port")
    }
    part("switch-status", parent: "switch", geometry: "light", material: "led-green", at: Vec3(0.180, 0.006, 0.130), name: "Switch status light", role: "status-indicator")

    assembly("rear-pdu", parent: "rack", at: Vec3(0.205, 0.29, -0.390), name: "Vertical rack power distribution unit", role: "power-distribution", description: "Illustrative PDU mounted at the rear side of the frame.")
    part("rear-pdu-body", parent: "rear-pdu", geometry: "pdu", material: "power", at: Vec3(0, 0, 0), name: "PDU body", role: "power-distribution")
    for index in 0..<8 {
        part("rear-pdu-outlet-\(index + 1)", parent: "rear-pdu", geometry: "outlet", material: "dark-plastic", at: Vec3(0, -0.175 + Double(index) * 0.050, 0.021), name: "PDU outlet \(index + 1)", role: "power-outlet")
    }
    for index in 0..<4 {
        part("network-cable-\(index + 1)", parent: "rack", geometry: "cable", material: index.isMultiple(of: 2) ? "cable-blue" : "cable-orange", at: Vec3(-0.13 + Double(index) * 0.045, 0.515, 0.13), name: "Patch cable \(index + 1)", role: "network-cable", description: "Illustrative patch route; it does not assert a configured topology.")
    }

    let relationships = [
        Relationship(relationshipId: "server-1-network-uplink", kind: "illustrative-network-link", sourceNodeId: "server-1", targetNodeId: "switch", description: "Teaching relationship; cable routing and live configuration are not verified."),
        Relationship(relationshipId: "server-1-power-feed", kind: "illustrative-power-feed", sourceNodeId: "rear-pdu", targetNodeId: "server-1", description: "Teaching relationship; electrical configuration is not verified."),
        Relationship(relationshipId: "server-2-network-uplink", kind: "illustrative-network-link", sourceNodeId: "server-2", targetNodeId: "switch", description: "Teaching relationship; cable routing and live configuration are not verified.")
    ]
    return SceneDocument(
        documentId: "authored-server-rack-v2",
        geometryDefinitions: definitions,
        materials: materials,
        nodes: nodes,
        relationships: relationships
    )
}
