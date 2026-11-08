import Foundation

/// Visual constants, as decided in especificacao-visual.md (Obsidian). Sizes are in points.
enum RainStyle {
    static let green = SIMD3<Float>(0x00, 0xFF, 0x41) / 255          // #00FF41
    static let fontName = "HiraginoSans-W4"
    static let fontSize: CGFloat = 17
    static let cellWidth: CGFloat = 16
    static let cellHeight: CGFloat = 20
    static let speedRange: ClosedRange<Float> = 0.20...0.35          // screen heights per second
    static let fadeRange: ClosedRange<Float> = 1.2...3.0             // seconds until a lit cell is black
    static let trailChangesPerSecond: Float = 2                      // per column
    static let respawnDelay: ClosedRange<Double> = 0.3...4.0         // seconds before a column rains again
    static let glyphs: [Character] = Array(
        "ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ" + "0123456789" + "*+=\":.-<>|_"
    )
}

/// One glyph to draw. Layout must match `Inst` in the Metal shader (24 bytes).
struct RainInstance {
    var cell: SIMD2<Float>   // column, row
    var glyph: Float         // index into RainStyle.glyphs
    var bright: Float        // 0...1
    var white: Float         // 0 = tint color, 1 = white
    var stretch: Float       // vertical scale (head blur)
    var color: Float         // palette index
}

/// The falling-code simulation. Knows nothing about windows or Metal,
/// so the same engine can drive the wallpaper app and a future .saver.
final class RainEngine {
    let cols: Int
    let rows: Int

    private struct Drop {
        var row: Float          // head position, in cells
        var lastRow: Int        // last cell the head lit
        var speed: Float        // cells per second
        var fade: Float         // trail fade time, seconds
        var color: Int          // palette index, fixed when the drop is born
        var level: Float        // brightness, fixed when the drop is born
    }

    private var glyph: [UInt16]
    private var litAt: [Double]
    private var fade: [Float]
    private var tint: [UInt8]
    private var levelAt: [Float]
    private var isHead: [Bool]
    private var heads: [Int] = []
    private var drops: [[Drop]]
    private var nextSpawn: [Double]
    private var time: Double = 0

    // Live settings. Changing them affects only drops born afterwards, so the change arrives as a new wave.
    var speedScale: Float
    var density: Float
    var colorIndex: Int            // palette index, or RainEngine.mixed for a random color per drop
    var level: Float
    var mixedPalette: [Int]
    static let mixed = -1

    var maxInstances: Int { cols * rows * 2 }

    init(cols: Int, rows: Int, speedScale: Float = 1, density: Float = 1, colorIndex: Int = 0, level: Float = 1,
         mixedPalette: [Int] = [0, 1, 2, 3, 4, 5, 6]) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.speedScale = speedScale
        self.density = density
        self.colorIndex = colorIndex
        self.mixedPalette = mixedPalette
        self.level = level
        let n = self.cols * self.rows
        glyph = (0..<n).map { _ in RainEngine.randomGlyph() }
        litAt = Array(repeating: -1e9, count: n)
        fade = Array(repeating: 1, count: n)
        tint = Array(repeating: 0, count: n)
        levelAt = Array(repeating: 1, count: n)
        isHead = Array(repeating: false, count: n)
        drops = Array(repeating: [], count: self.cols)
        nextSpawn = (0..<self.cols).map { _ in Double.random(in: 0...3) }

        // Start with about half the columns already mid-fall, so the screen is not empty at launch.
        for c in 0..<self.cols where Float.random(in: 0..<1) < min(0.5 * density, 0.95) {
            var d = newDrop()
            let head = Int.random(in: 0..<self.rows)
            for r in 0...head {
                light(col: c, row: r, at: -Double(Float(head - r) / d.speed), drop: d)
            }
            d.row = Float(head)
            d.lastRow = head
            drops[c].append(d)
        }
    }

    private static func randomGlyph() -> UInt16 {
        UInt16.random(in: 0..<UInt16(RainStyle.glyphs.count))
    }

    private func newDrop() -> Drop {
        Drop(row: 0, lastRow: -1,
             speed: Float.random(in: RainStyle.speedRange) * speedScale * Float(rows),
             fade: Float.random(in: RainStyle.fadeRange),
             color: colorIndex == RainEngine.mixed ? (mixedPalette.randomElement() ?? 0) : colorIndex,
             level: level)
    }

    private func light(col: Int, row: Int, at t: Double, drop d: Drop) {
        let k = row * cols + col
        glyph[k] = RainEngine.randomGlyph()   // the head changes glyph at every cell it enters
        litAt[k] = t
        fade[k] = d.fade
        tint[k] = UInt8(d.color)
        levelAt[k] = d.level
    }

    func step(_ dt: Double) {
        time += dt
        for c in 0..<cols {
            var i = 0
            while i < drops[c].count {
                drops[c][i].row += drops[c][i].speed * Float(dt)
                let target = Int(drops[c][i].row)
                while drops[c][i].lastRow < target {
                    drops[c][i].lastRow += 1
                    if drops[c][i].lastRow < rows {
                        light(col: c, row: drops[c][i].lastRow, at: time, drop: drops[c][i])
                    }
                }
                if drops[c][i].lastRow >= rows { drops[c].remove(at: i) } else { i += 1 }
            }

            // New drop only once the previous one is well down the column.
            let clearRow = Int(Float(rows) / (3 * density))
            if time >= nextSpawn[c], drops[c].allSatisfy({ $0.lastRow > clearRow }) {
                drops[c].append(newDrop())
                nextSpawn[c] = time + Double.random(in: RainStyle.respawnDelay) / Double(density)
            }

            // A few random glyph swaps along the visible trail.
            if Float.random(in: 0..<1) < RainStyle.trailChangesPerSecond * Float(dt) {
                for _ in 0..<4 {
                    let k = Int.random(in: 0..<rows) * cols + c
                    if time - litAt[k] < Double(fade[k]) {
                        glyph[k] = RainEngine.randomGlyph()
                        break
                    }
                }
            }
        }
    }

    /// Writes the glyphs to draw this frame and returns how many were written.
    func fillInstances(_ out: UnsafeMutablePointer<RainInstance>, capacity: Int) -> Int {
        for k in heads { isHead[k] = false }
        heads.removeAll(keepingCapacity: true)
        for c in 0..<cols {
            for d in drops[c] where d.lastRow >= 0 && d.lastRow < rows {
                let k = d.lastRow * cols + c
                isHead[k] = true
                heads.append(k)
            }
        }

        var n = 0
        func emit(_ i: RainInstance) {
            guard n < capacity else { return }
            out[n] = i
            n += 1
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let k = r * cols + c
                let age = Float(time - litAt[k])
                let f = fade[k]
                guard age < f else { continue }
                let cell = SIMD2<Float>(Float(c), Float(r))
                let g = Float(glyph[k])
                let color = Float(tint[k])
                let level = levelAt[k]
                if isHead[k] {
                    // White head plus a stretched, faint copy for the vertical blur.
                    emit(RainInstance(cell: cell, glyph: g, bright: level, white: 1, stretch: 1, color: color))
                    emit(RainInstance(cell: cell, glyph: g, bright: 0.35 * level, white: 1, stretch: 2.2, color: color))
                } else {
                    let x = 1 - age / f
                    let bright = x * x * level                           // fades to near black
                    let white = max(0, 1 - age / 0.25) * 0.45            // lighter tint right behind the head
                    emit(RainInstance(cell: cell, glyph: g, bright: bright, white: white, stretch: 1, color: color))
                }
            }
        }
        return n
    }
}
