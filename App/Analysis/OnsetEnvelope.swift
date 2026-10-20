import Accelerate
import Foundation

/// A real-input FFT of one fixed size: the magnitudes of its first half.
final class RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var real: [Float]
    private var imaginary: [Float]

    init?(size: Int) {
        self.size = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        guard size > 1, size & (size - 1) == 0, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// |DFT| of the `size` samples in `frame` for bins 0..<size/2. The Nyquist bin is left out.
    func magnitudes(of frame: [Float], into out: inout [Float]) {
        let half = size / 2
        frame.withUnsafeBufferPointer { samples in
            samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
        }
        // vDSP's real transform is twice the DFT, and packs the Nyquist bin into the imaginary part of bin 0.
        out[0] = abs(real[0]) / 2
        for k in 1..<half { out[k] = (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot() / 2 }
    }

    /// Vectorized equivalent for long recordings; leave the drum detector on its original arithmetic path.
    func fastMagnitudes(of frame: [Float], into out: inout [Float]) {
        let half = size / 2
        frame.withUnsafeBufferPointer { samples in
            samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        out.withUnsafeMutableBufferPointer { output in
                            vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }
        var halfScale: Float = 0.5
        vDSP_vsmul(out, 1, &halfScale, &out, 1, vDSP_Length(half))
        out[0] = abs(real[0]) / 2
    }
}

enum OnsetEnvelope {
    /// Positive change of the log spectrum, using centred frames and zero padding at the ends.
    static func flux(_ samples: [Float], sampleRate: Double, frameSize: Int, hop: Int, optimized: Bool = false, progress: (Double) -> Void = { _ in }) throws -> [Float] {
        let n = frameSize
        let half = n / 2
        guard sampleRate > 0, hop > 0, let fft = RealFFT(size: n) else { throw HandPercussionError.fftUnavailable }
        let frames = samples.count / hop + 1
        let padded = [Float](repeating: 0, count: half) + samples + [Float](repeating: 0, count: n)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        let scale = 1 / Float(half)
        var frame = [Float](repeating: 0, count: n)
        var magnitude = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half)
        var current = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frames)
        var scaled: Float = 100 * scale
        var floor: Float = 0
        var bins = Int32(half)
        for t in 0..<frames {
            if t % 512 == 0 {
                try Task.checkCancellation()
                progress(Double(t) / Double(frames))
            }
            vDSP.multiply(padded[(t * hop)..<(t * hop + n)], window, result: &frame)
            if optimized {
                fft.fastMagnitudes(of: frame, into: &magnitude)
                vDSP_vsmul(magnitude, 1, &scaled, &current, 1, vDSP_Length(half))
                vvlog1pf(&current, current, &bins)
                if t > 0 {
                    vDSP_vsub(previous, 1, current, 1, &magnitude, 1, vDSP_Length(half))
                    vDSP_vthr(magnitude, 1, &floor, &magnitude, 1, vDSP_Length(half))
                    vDSP_sve(magnitude, 1, &flux[t], vDSP_Length(half))
                }
            } else {
                fft.magnitudes(of: frame, into: &magnitude)
                for k in 0..<half { current[k] = log1pf(100 * magnitude[k] * scale) }
                if t > 0 {
                    var rise: Float = 0
                    for k in 0..<half { rise += max(0, current[k] - previous[k]) }
                    flux[t] = rise
                }
            }
            swap(&previous, &current)
        }
        return flux
    }

    /// Remove the local mean (about 2.5 seconds) without keeping a spectrogram in memory.
    static func highPassed(_ flux: [Float], sampleRate: Double, hop: Int) -> [Float] {
        guard !flux.isEmpty, sampleRate > 0, hop > 0 else { return flux }
        let halfWindow = max(1, Int(2.5 * sampleRate / Double(hop)) / 2)
        var sum = 0.0
        var left = 0, right = 0
        var result = [Float](repeating: 0, count: flux.count)
        for i in flux.indices {
            let end = min(flux.count, i + halfWindow + 1)
            while right < end { sum += Double(flux[right]); right += 1 }
            let start = max(0, i - halfWindow)
            while left < start { sum -= Double(flux[left]); left += 1 }
            result[i] = flux[i] - Float(sum / Double(right - left))
        }
        return result
    }
}
