// App 图标生成器
//
// 菜单栏图标由系统 SF Symbol 直接渲染（见 menubar/main.swift 的 setIcon），
// 本脚本用**同一个符号**生成 App 图标 .icns，保证两处视觉同源：
//   - 菜单栏：系统按菜单栏标准尺寸与深浅色外观绘制，清晰度最佳
//   - App 图标：深石板色圆角底 + 白色符号，在访达/启动台/⌘Tab 中易辨识
//
// 输出:
//   Resources/icon_1024.png   1024 原始图
//   Resources/AdbWifiBar.icns App 图标（由原始图多倍率缩放打包）
//
// 想换图标只需改下面的 SYMBOL 常量，然后重新编译。
//
// 用法: swift menubar/gen-icon.swift <输出目录>

import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
try? FileManager.default.createDirectory(atPath: outDir,
                                         withIntermediateDirectories: true)

/// 与 main.swift 中菜单栏首选符号保持一致
let SYMBOL = "iphone.radiowaves.left.and.right"

/// 用 SF Symbol 渲染 1024×1024 App 图标母版（深色圆角底 + 白色符号）
func renderAppIcon(symbol: String, side: Int, to path: String) {
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
        FileHandle.standardError.write("缺少 SF Symbol: \(symbol)\n".data(using: .utf8)!)
        exit(1)
    }

    let dim = CGFloat(side)
    let rect = NSRect(x: 0, y: 0, width: dim, height: dim)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSGraphicsContext.current?.imageInterpolation = .high

    // 深石板色圆角底：白色符号对比清晰，也贴近 macOS 深色图标风格
    let bg = rect.insetBy(dx: dim * 0.085, dy: dim * 0.085)
    let radius = bg.width * 0.2237   // 接近 macOS 原生 squircle 的圆角比例
    NSGradient(starting: NSColor(srgbRed: 0.365, green: 0.400, blue: 0.455, alpha: 1),
               ending: NSColor(srgbRed: 0.204, green: 0.231, blue: 0.278, alpha: 1))?
        .draw(in: NSBezierPath(roundedRect: bg, xRadius: radius, yRadius: radius),
              angle: -90)

    // palette 单色渲染，避免 hierarchical 的灰度层次
    let cfg = NSImage.SymbolConfiguration(pointSize: dim, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let img = base.withSymbolConfiguration(cfg) ?? base

    // SF Symbol 画布自带大量留白（宽高比约 1.48:1）。按比例取墨迹范围绘制，
    // 在圆角底内留 16% 边距，缩小到各倍率时仍清晰。
    let inkW = img.size.width * 0.8951
    let inkH = img.size.height * 0.8807
    let target = rect.insetBy(dx: dim * 0.16, dy: dim * 0.16)
    let scale = min(target.width / inkW, target.height / inkH)
    let drawW = inkW * scale, drawH = inkH * scale
    let srcW = img.size.width, srcH = img.size.height
    img.draw(in: NSRect(x: target.midX - drawW / 2, y: target.midY - drawH / 2,
                        width: drawW, height: drawH),
             from: NSRect(x: srcW * 0.0518, y: srcH * 0.0601,
                          width: srcW * 0.8951, height: srcH * 0.8807),
             operation: .sourceOver, fraction: 1.0,
             respectFlipped: false, hints: nil)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

renderAppIcon(symbol: SYMBOL, side: 1024, to: "\(outDir)/icon_1024.png")

// 由 1024 母版生成 .iconset，再打包为 .icns
let iconset = "\(outDir)/AdbWifiBar.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = ["-z", "\(px)", "\(px)", "\(outDir)/icon_1024.png", "--out", "\(iconset)/\(name)"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AdbWifiBar.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)

if iconutil.terminationStatus != 0 {
    FileHandle.standardError.write("iconutil 打包 .icns 失败\n".data(using: .utf8)!)
    exit(1)
}
print("✓ 图标已生成: \(outDir)/icon_1024.png, AdbWifiBar.icns")
