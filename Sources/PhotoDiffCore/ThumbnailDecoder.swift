import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a packed thumbnail record's BC7 blocks into an ordinary JPEG.
///
/// The decoding is done by the GPU, because BC7 is a hardware texture format with no
/// software decoder in the system frameworks.
///
/// One thing here is easy to get wrong and worth stating plainly: the compressed
/// texture must be **sampled in a shader**. A `MTLBlitCommandEncoder` copy from a
/// compressed texture to an RGBA one does not decode anything — it reinterprets the
/// bytes — and it fails quietly, producing an image that looks like a decoding bug
/// rather than a usage bug.
public final class ThumbnailDecoder: @unchecked Sendable {

    public enum Failure: Error, LocalizedError {
        case noGPU
        case unsupported
        case badRecord

        public var errorDescription: String? {
            switch self {
            case .noGPU: return "No Metal device, so packed thumbnails cannot be decoded"
            case .unsupported: return "This Mac cannot decode BC7 textures"
            case .badRecord: return "That thumbnail record could not be read"
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    /// Samples the compressed texture and writes straight pixels. Alpha is forced
    /// opaque: these are thumbnails of photographs, and a stray alpha channel would
    /// only make them look washed out.
    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void expand(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
            float4 c = src.sample(s, float2(gid) + 0.5);
            dst.write(float4(c.rgb, 1.0), gid);
        }
        """

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noGPU }
        guard device.supportsBCTextureCompression else { throw Failure.unsupported }
        guard let queue = device.makeCommandQueue() else { throw Failure.noGPU }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let fn = library.makeFunction(name: "expand") else { throw Failure.noGPU }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: fn)
    }

    /// Decodes one record to JPEG bytes, cropped back to the recorded size.
    public func jpeg(from record: PackedThumbnails.Record, quality: Double = 0.9) -> Data? {
        guard let image = decode(record) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    public func decode(_ record: PackedThumbnails.Record) -> CGImage? {
        let padW = record.paddedWidth, padH = record.paddedHeight
        guard record.pixelData.count >= record.blockBytes else { return nil }

        let td = MTLTextureDescriptor()
        td.pixelFormat = .bc7_rgbaUnorm
        td.width = padW
        td.height = padH
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let compressed = device.makeTexture(descriptor: td) else { return nil }

        let bytesPerRow = record.blocksWide * PackedThumbnails.bytesPerBlock
        record.pixelData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            compressed.replace(
                region: MTLRegionMake2D(0, 0, padW, padH),
                mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow
            )
        }

        let rd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: padW, height: padH, mipmapped: false)
        rd.usage = [.shaderWrite, .shaderRead]
        rd.storageMode = .shared
        guard let plain = device.makeTexture(descriptor: rd),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(compressed, index: 0)
        encoder.setTexture(plain, index: 1)
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (padW + 7) / 8, height: (padH + 7) / 8, depth: 1),
            threadsPerThreadgroup: group)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: padW * padH * 4)
        plain.getBytes(&pixels, bytesPerRow: padW * 4,
                       from: MTLRegionMake2D(0, 0, padW, padH), mipmapLevel: 0)

        guard let ctx = CGContext(
            data: &pixels, width: padW, height: padH, bitsPerComponent: 8,
            bytesPerRow: padW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let full = ctx.makeImage() else { return nil }

        // Crop the block padding back off.
        guard record.width != padW || record.height != padH else { return full }
        return full.cropping(to: CGRect(x: 0, y: 0,
                                        width: record.width, height: record.height))
    }
}
