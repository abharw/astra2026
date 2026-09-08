import ARKit
import simd
/// Frozen metric depth from the same AR frame as the selected camera image.
/// It establishes a surface pose, not semantic object identity or hidden geometry.
struct DepthSnapshot {
  let width:Int
  let height:Int
  let depths:[Float]
  let confidence:[UInt8]
  let intrinsics:simd_float3x3
  let resolution:CGSize
  let camera:simd_float4x4
  init?(frame:ARFrame) {
    guard let depth=frame.sceneDepth else{return nil}
    let map=depth.depthMap
    width=CVPixelBufferGetWidth(map);height=CVPixelBufferGetHeight(map)
    CVPixelBufferLockBaseAddress(map,.readOnly)
    defer{CVPixelBufferUnlockBaseAddress(map,.readOnly)}
    guard let address=CVPixelBufferGetBaseAddress(map) else{return nil}
    let stride=CVPixelBufferGetBytesPerRow(map)/MemoryLayout<Float>.stride
    let pointer=address.assumingMemoryBound(to:Float.self)
    var values=[Float]();values.reserveCapacity(width*height)
    for y in 0..<height{values.append(contentsOf:UnsafeBufferPointer(start:pointer+y*stride,count:width))}
    depths=values
    if let c=depth.confidenceMap {
      CVPixelBufferLockBaseAddress(c,.readOnly);defer{CVPixelBufferUnlockBaseAddress(c,.readOnly)}
      if let base=CVPixelBufferGetBaseAddress(c){let p=base.assumingMemoryBound(to:UInt8.self);let bytes=CVPixelBufferGetBytesPerRow(c);var v=[UInt8]();v.reserveCapacity(width*height);for y in 0..<height{v.append(contentsOf:UnsafeBufferPointer(start:p+y*bytes,count:width))};confidence=v}else{confidence=[]}
    }else{confidence=[]}
    intrinsics=frame.camera.intrinsics;resolution=frame.camera.imageResolution;camera=frame.camera.transform
  }
  func point(_ raw:CGPoint)->SIMD3<Float>? {
    guard raw.x>=0,raw.x<=1,raw.y>=0,raw.y<=1 else{return nil}
    let x=min(width-1,max(0,Int(raw.x*CGFloat(width)))),y=min(height-1,max(0,Int(raw.y*CGFloat(height))))
    var samples=[Float]()
    for yy in max(0,y-1)...min(height-1,y+1){for xx in max(0,x-1)...min(width-1,x+1){let i=yy*width+xx,d=depths[i];if d.isFinite,d>0.15,d<6,(confidence.isEmpty || confidence[i]>=1){samples.append(d)}}}
    guard samples.count>=3 else{return nil};samples.sort();let z=samples[samples.count/2]
    let pixel=SIMD2<Float>(Float(raw.x*resolution.width),Float(raw.y*resolution.height))
    let local=SIMD4<Float>((pixel.x-intrinsics.columns.2.x)*z/intrinsics.columns.0.x,-(pixel.y-intrinsics.columns.2.y)*z/intrinsics.columns.1.y,-z,1)
    let world=camera*local;return SIMD3(world.x,world.y,world.z)
  }
  func frontNormal(near raw:CGPoint)->SIMD3<Float>? {
    guard let center=point(raw) else{return nil}
    let towards=simd_normalize(camera.translation-center)
    var normals=[SIMD3<Float>]()
    let dx=CGFloat(3)/CGFloat(width),dy=CGFloat(3)/CGFloat(height)
    for j in -1...1{for i in -1...1{
      let p=CGPoint(x:raw.x+CGFloat(i)*dx,y:raw.y+CGFloat(j)*dy)
      guard let l=point(CGPoint(x:p.x-dx,y:p.y)),let r=point(CGPoint(x:p.x+dx,y:p.y)),let u=point(CGPoint(x:p.x,y:p.y-dy)),let d=point(CGPoint(x:p.x,y:p.y+dy)),simd_distance(l,center)<0.2,simd_distance(r,center)<0.2,simd_distance(u,center)<0.2,simd_distance(d,center)<0.2 else{continue}
      let cross=simd_cross(r-l,d-u);guard simd_length(cross)>0.000001 else{continue};var n=simd_normalize(cross);if simd_dot(n,towards)<0{n = -n};if simd_dot(n,towards)>0.35{normals.append(n)}
    }}
    guard normals.count>=4 else{return nil}
    let n=simd_normalize(normals.reduce(SIMD3<Float>.zero,+))
    guard normals.filter({simd_dot($0,n)>0.92}).count>=4 else{return nil}
    return n
  }
}
