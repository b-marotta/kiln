import Foundation
import CoreML

// Invoked by build.sh; ship portable compiled models, never the Python runtime.
let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: destination, withIntermediateDirectories: true)
// Remove assets left by builds that bundled the previous optional model.
for name in ["RealESRGAN_x2plus.mlmodelc", "RealESRGAN-LICENSE.txt"] {
    let obsolete = destination.appendingPathComponent(name)
    if fm.fileExists(atPath: obsolete.path) { try fm.removeItem(at: obsolete) }
}
for name in ["PiperSR_2x"] {
    let compiled = try MLModel.compileModel(at: source.appendingPathComponent(name + ".mlpackage"))
    let target = destination.appendingPathComponent(name + ".mlmodelc")
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.copyItem(at: compiled, to: target)
    try? fm.removeItem(at: compiled)
}
for name in ["PiperSR-LICENSE.txt", "NOTICE.txt"] {
    let target = destination.appendingPathComponent(name)
    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    try fm.copyItem(at: source.appendingPathComponent(name), to: target)
}
