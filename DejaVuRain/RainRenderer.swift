import AppKit
import CoreText
import MetalKit

/// Layout must match `U` in the shader (32 bytes).
private struct RainUniforms {
    var viewport: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var atlasTile: SIMD2<Float>
    var atlasCols: Float
    var scanPeriod: Float
}

/// Draws a RainEngine into an MTKView. Shader is compiled at runtime,
/// so the project does not need Xcode's separate Metal toolchain.
@MainActor
final class RainRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: 3)

    /// Exactly 8 entries, as the shader expects.
    private let palette: [SIMD4<Float>] = {
        var p = Settings.colors.map { SIMD4<Float>($0.rgb, 1) }
        while p.count < 8 { p.append(p[0]) }
        return Array(p.prefix(8))
    }()

    private var engine: RainEngine?
    private var atlas: MTLTexture?
    private var atlasScale: CGFloat = 0
    private var tile = SIMD2<Int>(1, 1)
    private let atlasCols = 16
    private var buffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var lastTime: CFTimeInterval = 0

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: RainRenderer.shaderSource, options: nil)
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vmain")
        desc.fragmentFunction = library.makeFunction(name: "fmain")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true            // additive: the head blur glows over its neighbours
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .one
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 30        // heads move cell by cell; 30 fps is smooth and cheap
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuild(size: size, scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    private func rebuild(size: CGSize, scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        if scale != atlasScale { buildAtlas(scale: scale) }
        let cols = Int((size.width / CGFloat(tile.x)).rounded(.up))
        let rows = Int((size.height / CGFloat(tile.y)).rounded(.up))
        let settings = Settings.shared
        let engine = RainEngine(cols: cols, rows: rows, speedScale: settings.speedFactor, density: settings.density,
                                colorIndex: settings.engineColor, level: settings.brightness,
                                mixedPalette: Settings.mixedColors)
        self.engine = engine
        let length = engine.maxInstances * MemoryLayout<RainInstance>.stride
        buffers = (0..<3).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
    }

    func draw(in view: MTKView) {
        if engine == nil { rebuild(size: view.drawableSize, scale: view.window?.backingScaleFactor ?? 2) }
        guard let engine, let atlas, buffers.count == 3,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? 0 : min(now - lastTime, 0.1)
        lastTime = now

        // Settings changes reach only the drops born from now on; drops already falling keep theirs.
        let settings = Settings.shared
        engine.speedScale = settings.speedFactor
        engine.density = settings.density
        engine.colorIndex = settings.engineColor
        engine.level = settings.brightness
        engine.step(dt)

        inFlight.wait()
        bufferIndex = (bufferIndex + 1) % 3
        let buffer = buffers[bufferIndex]
        let count = engine.fillInstances(
            buffer.contents().bindMemory(to: RainInstance.self, capacity: engine.maxInstances),
            capacity: engine.maxInstances)

        let size = view.drawableSize
        var u = RainUniforms(
            viewport: SIMD2(Float(size.width), Float(size.height)),
            cellSize: SIMD2(Float(tile.x), Float(tile.y)),
            atlasTile: SIMD2(1 / Float(atlasCols), Float(tile.y) / Float(atlas.height)),
            atlasCols: Float(atlasCols),
            scanPeriod: Float(max(2, (1.5 * atlasScale).rounded())))

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<RainUniforms>.stride, index: 1)
        enc.setVertexBytes(palette, length: palette.count * MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<RainUniforms>.stride, index: 1)
        enc.setFragmentTexture(atlas, index: 0)
        if count > 0 {
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        enc.endEncoding()

        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Renders every glyph once, mirrored, into a grayscale texture.
    private func buildAtlas(scale: CGFloat) {
        atlasScale = scale
        let tw = Int((RainStyle.cellWidth * scale).rounded(.up))
        let th = Int((RainStyle.cellHeight * scale).rounded(.up))
        tile = SIMD2(tw, th)
        let glyphs = RainStyle.glyphs
        let atlasRows = (glyphs.count + atlasCols - 1) / atlasCols
        let w = tw * atlasCols, h = th * atlasRows

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)

        let font = CTFontCreateWithName(RainStyle.fontName as CFString, RainStyle.fontSize * scale, nil)
        let white = CGColor(gray: 1, alpha: 1)
        for (i, ch) in glyphs.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(ch), attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

            let x0 = CGFloat((i % atlasCols) * tw)
            let y0 = CGFloat(h - (i / atlasCols + 1) * th)   // CG origin is bottom-left; texture row 0 is the top
            ctx.saveGState()
            ctx.translateBy(x: x0 + CGFloat(tw), y: y0)      // mirror horizontally inside the tile
            ctx.scaleBy(x: -1, y: 1)
            ctx.textPosition = CGPoint(x: (CGFloat(tw) - width) / 2,
                                       y: (CGFloat(th) - ascent - descent) / 2 + descent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td), let data = ctx.data else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        atlas = tex
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Inst { float2 cell; float glyph; float bright; float white; float stretch; float color; };
    struct U { float2 viewport; float2 cellSize; float2 atlasTile; float atlasCols; float scanPeriod; };
    struct VOut { float4 pos [[position]]; float2 uv; float bright; float white; float3 tint; };

    vertex VOut vmain(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Inst* inst [[buffer(0)]], constant U& u [[buffer(1)]],
                      constant float4* palette [[buffer(2)]]) {
        Inst i = inst[iid];
        float2 corner = float2(vid & 1, vid >> 1);
        float2 size = u.cellSize * float2(1.0, i.stretch);
        float2 p = (i.cell + 0.5) * u.cellSize + (corner - 0.5) * size;
        float gc = fmod(i.glyph, u.atlasCols);
        float gr = floor(i.glyph / u.atlasCols);
        VOut o;
        o.pos = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
        o.uv = (float2(gc, gr) + corner) * u.atlasTile;
        o.bright = i.bright;
        o.white = i.white;
        o.tint = palette[min(uint(i.color), 7u)].rgb;
        return o;
    }

    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]], constant U& u [[buffer(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float a = atlas.sample(s, in.uv).r;
        float scan = fmod(floor(in.pos.y), u.scanPeriod) < 1.0 ? 0.55 : 1.0;   // thin horizontal scanlines
        float3 col = mix(in.tint, float3(1.0), in.white);
        float k = a * in.bright * mix(scan, 1.0, in.white);
        return float4(col * k, k);
    }
    """
}
