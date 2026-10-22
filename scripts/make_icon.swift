// Kullanım: swift scripts/make_icon.swift <çıktı.png>
// Üst üste dizili üç "kitap" (arşiv) çizen 1024x1024 uygulama simgesi üretir.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS "squircle"e yakın yuvarlatılmış kare, kenarlarda boşluk bırakır
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
tilePath.fill()
ctx.restoreGState()

tilePath.addClip()
let bg = NSGradient(colors: [NSColor(red: 0.20, green: 0.17, blue: 0.45, alpha: 1),
                             NSColor(red: 0.10, green: 0.36, blue: 0.70, alpha: 1)])!
bg.draw(in: tile, angle: -60)

// Üst üste üç kitap
func book(y: CGFloat, color: NSColor, stripe: NSColor, inset: CGFloat) {
    let w = tile.width - 2 * 120 - inset * 2
    let h: CGFloat = 150
    let rect = CGRect(x: tile.midX - w / 2, y: y, width: w, height: h)
    let p = NSBezierPath(roundedRect: rect, xRadius: 34, yRadius: 34)
    let g = NSGradient(colors: [color.blended(withFraction: 0.25, of: .white)!, color])!
    g.draw(in: p, angle: -90)
    // sayfa kenarı
    let pages = CGRect(x: rect.maxX - 70, y: rect.minY + 22, width: 52, height: h - 44)
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: pages, xRadius: 12, yRadius: 12).fill()
    // sırt şeridi
    stripe.setFill()
    NSBezierPath(roundedRect: CGRect(x: rect.minX + 38, y: rect.minY + 22, width: 26, height: h - 44),
                 xRadius: 8, yRadius: 8).fill()
}
book(y: tile.minY + 150, color: NSColor(red: 0.62, green: 0.20, blue: 0.72, alpha: 1), stripe: NSColor.white.withAlphaComponent(0.55), inset: 0)
book(y: tile.minY + 318, color: NSColor(red: 0.12, green: 0.66, blue: 0.62, alpha: 1), stripe: NSColor.white.withAlphaComponent(0.55), inset: 30)
book(y: tile.minY + 486, color: NSColor(red: 0.96, green: 0.58, blue: 0.16, alpha: 1), stripe: NSColor.white.withAlphaComponent(0.6), inset: 10)

// Kitapları saran kayış
let strapX = tile.midX + 40
let strap = CGRect(x: strapX, y: tile.minY + 120, width: 64, height: 560)
NSColor(red: 0.85, green: 0.15, blue: 0.20, alpha: 1).setFill()
NSBezierPath(roundedRect: strap, xRadius: 14, yRadius: 14).fill()
NSColor.white.withAlphaComponent(0.25).setFill()
NSBezierPath(roundedRect: CGRect(x: strap.minX + 8, y: strap.minY + 8, width: 10, height: strap.height - 16), xRadius: 5, yRadius: 5).fill()

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: out))
