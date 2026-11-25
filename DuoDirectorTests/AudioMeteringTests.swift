import AVFoundation
import Testing
@testable import DuoDirector

@Suite("Audio metering")
struct AudioMeteringTests {

    /// Builds a PCM CMSampleBuffer the way the capture pipeline delivers it.
    private func sampleBuffer(_ channels: [[Float]], format commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
                              interleaved: Bool = true) throws -> CMSampleBuffer {
        let frames = channels[0].count
        let format = try #require(AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000,
                                                channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (bufferIndex, audioBuffer) in list.enumerated() {
            let stride = interleaved ? channels.count : 1
            for frame in 0..<frames {
                for c in 0..<stride {
                    let channel = interleaved ? c : bufferIndex
                    let value = channels[channel][frame]
                    let index = frame * stride + c
                    switch commonFormat {
                    case .pcmFormatInt16:
                        audioBuffer.mData!.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32_767)
                    default:
                        audioBuffer.mData!.assumingMemoryBound(to: Float.self)[index] = value
                    }
                }
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
                             sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
        let sample = try #require(out)
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList)
        #expect(status == noErr)
        return sample
    }

    private func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.1) -> Bool { abs(a - b) < tolerance }

    @Test func float32StereoInterleaved() throws {
        let levels = try #require(AudioMetering.levels(from: sampleBuffer([
            [Float](repeating: 0.5, count: 480), [Float](repeating: 0.25, count: 480)])))
        #expect(close(levels.peakL, -6.02))
        #expect(close(levels.peakR, -12.04))
        #expect(close(levels.rmsL, -6.02))   // DC signal: RMS == peak
    }

    @Test func float32NonInterleaved() throws {
        let levels = try #require(AudioMetering.levels(from: sampleBuffer([
            [Float](repeating: 1.0, count: 256), [Float](repeating: 0.1, count: 256)], interleaved: false)))
        #expect(close(levels.peakL, 0))
        #expect(close(levels.peakR, -20))
    }

    @Test func int16MonoMirrorsToBothChannels() throws {
        let sine = (0..<480).map { Float(sin(Double($0) / 480 * 2 * .pi)) * 0.5 }
        let levels = try #require(AudioMetering.levels(from: sampleBuffer([sine], format: .pcmFormatInt16)))
        #expect(close(levels.peakL, -6.02, 0.2))
        #expect(levels.peakL == levels.peakR)
        #expect(close(levels.rmsL, -9.03, 0.3))   // sine RMS = peak − 3.01 dB
    }

    @Test func silenceIsFloored() throws {
        let levels = try #require(AudioMetering.levels(from: sampleBuffer([[Float](repeating: 0, count: 64),
                                                                           [Float](repeating: 0, count: 64)])))
        #expect(levels.peakL <= -119)
    }
}
