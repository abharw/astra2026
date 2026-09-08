import Foundation
import simd

/// A bounded, directed curve with arc lengths prepared once for mesh and marker use.
struct FlowPath: Equatable {
    let points: [SIMD3<Double>]
    let cumulativeLengths: [Double]

    var length: Double { cumulativeLengths.last ?? 0 }
    var isDegenerate: Bool { points.count < 2 }

    init(controlPoints: [SIMD3<Double>]) {
        // Accepted recipes have at most ten controls. Keep the sampler bounded
        // even when called directly, and reject coordinates RealityKit cannot use.
        guard (2...128).contains(controlPoints.count),
              controlPoints.allSatisfy(Self.isNativeFinite),
              let first = controlPoints.first, let last = controlPoints.last,
              Self.magnitude(last - first) > 1e-9 else {
            points = []
            cumulativeLengths = []
            return
        }

        var controls: [SIMD3<Double>] = []
        for point in controlPoints where controls.last != point {
            controls.append(point)
        }

        var samples: [SIMD3<Double>] = [first]
        if controls.count == 2 {
            samples.append(last)
        } else {
            let chords = zip(controls, controls.dropFirst()).map { $1 - $0 }
            let chordLengths = chords.map(Self.magnitude)
            var derivatives = [chords[0]]
            for index in 1..<(controls.count - 1) {
                let incoming = chords[index - 1] / chordLengths[index - 1]
                let outgoing = chords[index] / chordLengths[index]
                // Short adjacent spans constrain the tangent, preventing a long
                // span from producing a loop around a nearby route point. At a
                // reversal the derivative is zero, so no zero vector is normalized.
                derivatives.append(
                    (incoming + outgoing) * (min(chordLengths[index - 1], chordLengths[index]) / 2)
                )
            }
            derivatives.append(chords[chords.count - 1])

            // Equal subdivisions preserve reversal symmetry. Do not distribute
            // leftover samples from one end of the path.
            let subdivisions = 127 / (controls.count - 1)
            for segment in 0..<(controls.count - 1) {
                for step in 1...subdivisions {
                    let point: SIMD3<Double>
                    if step == subdivisions {
                        point = controls[segment + 1]
                    } else {
                        let t = Double(step) / Double(subdivisions)
                        let t2 = t * t
                        let t3 = t2 * t
                        point = controls[segment] * (2 * t3 - 3 * t2 + 1)
                            + derivatives[segment] * (t3 - 2 * t2 + t)
                            + controls[segment + 1] * (-2 * t3 + 3 * t2)
                            + derivatives[segment + 1] * (t3 - t2)
                    }
                    if samples.last != point { samples.append(point) }
                }
            }
        }

        guard samples.allSatisfy(Self.isNativeFinite) else {
            points = []
            cumulativeLengths = []
            return
        }
        var retained = [first]
        var lengths: [Double] = [0]
        for index in samples.indices.dropFirst() {
            let point = samples[index]
            var nextLength = lengths[lengths.count - 1] + Self.magnitude(point - retained[retained.count - 1])
            // A tiny span following a long one can be smaller than an arc
            // length's ULP. Drop only those unrepresentable samples, instead of
            // suppressing the entire curve. The semantic endpoint stays exact.
            if index == samples.count - 1 {
                while nextLength <= lengths[lengths.count - 1], retained.count > 1 {
                    retained.removeLast()
                    lengths.removeLast()
                    nextLength = lengths[lengths.count - 1] + Self.magnitude(point - retained[retained.count - 1])
                }
            }
            if nextLength > lengths[lengths.count - 1] {
                retained.append(point)
                lengths.append(nextLength)
            }
        }
        points = retained
        cumulativeLengths = lengths
    }

    /// Distance is clamped to the curve; an empty path has a stable inert sample.
    func sample(at distance: Double) -> (position: SIMD3<Float>, tangent: SIMD3<Float>) {
        guard !isDegenerate else { return (.zero, [0, 1, 0]) }
        let clamped = distance.isNaN ? 0 : min(max(distance, 0), length)
        var lower = 0
        var upper = points.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if cumulativeLengths[middle] <= clamped {
                lower = middle
            } else {
                upper = middle
            }
        }
        let delta = points[upper] - points[lower]
        let fraction = (clamped - cumulativeLengths[lower])
            / (cumulativeLengths[upper] - cumulativeLengths[lower])
        return (
            SIMD3<Float>(points[lower] + delta * fraction),
            SIMD3<Float>(delta / Self.magnitude(delta))
        )
    }

    private static func magnitude(_ vector: SIMD3<Double>) -> Double {
        let scale = simd_reduce_max(simd_abs(vector))
        return scale > 0 ? scale * simd_length(vector / scale) : 0
    }

    private static func isNativeFinite(_ point: SIMD3<Double>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
            && Float(point.x).isFinite && Float(point.y).isFinite && Float(point.z).isFinite
    }
}
