import Foundation

/// A point expressed in the referenced structural node's local coordinate system.
public struct FlowAttachment: Codable, Sendable, Equatable {
  public var nodeId: String
  public var localPoint: Vec3

  public init(nodeId: String, localPoint: Vec3) {
    self.nodeId = nodeId
    self.localPoint = localPoint
  }
}

public enum FlowDirection: String, Codable, Sendable {
  case forward
  case reverse
}

/// An editable annotation whose endpoints follow ordinary scene nodes.
/// Route points and width are expressed in the annotation node's local coordinates.
public struct FlowRecipe: Codable, Sendable, Equatable {
  public var source: FlowAttachment
  public var target: FlowAttachment
  public var routePoints: [Vec3]
  public var direction: FlowDirection
  public var width: Double
  public var label: String
  public var animated: Bool

  public init(
    source: FlowAttachment,
    target: FlowAttachment,
    routePoints: [Vec3] = [],
    direction: FlowDirection = .forward,
    width: Double = 0.01,
    label: String = "",
    animated: Bool = true
  ) {
    self.source = source
    self.target = target
    self.routePoints = routePoints
    self.direction = direction
    self.width = width
    self.label = label
    self.animated = animated
  }
}

/// Host-measured structural bounds, expressed in the named node's local coordinates.
/// These describe a snapshot; they are not authored geometry or persistent scene state.
public struct NodeLocalBounds: Codable, Sendable, Equatable {
  public var nodeId: String
  public var minimum: Vec3
  public var maximum: Vec3

  public init(nodeId: String, minimum: Vec3, maximum: Vec3) {
    self.nodeId = nodeId
    self.minimum = minimum
    self.maximum = maximum
  }
}
