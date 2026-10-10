import Accelerate
import AVFoundation
import Foundation

/// Key and tempo worked out on this Mac from the song's 30-second preview in
/// Apple's or Deezer's catalogue — no analysis service has to be up.
///
/// Used only where ReccoBeats and GetSongBPM have nothing. A preview is
/// usually the chorus, which carries the key well, but thirty seconds is less
/// than those services hear; the log says how sure each key was.
enum PreviewAnalysis {

    static func analysis(for track: PlayerTrack) async -> TrackAnalysis? {
        guard let preview = await previewURL(for: track), let file = await download(preview) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let samples = decode(file), !Task.isCancelled else { return nil }
        let result = KeyTempoEstimator.estimate(samples, sampleRate: KeyTempoEstimator.sampleRate)
        Diagnostics.log("  preview: key \(result.key ?? "unclear") (\(result.agreement) of 4 agree), tempo \(result.tempo.map { String(format: "%.1f", $0) } ?? "unclear")")
        let analysis = TrackAnalysis(key: result.key, tempo: result.tempo)
        return analysis.isEmpty ? nil : analysis
    }

    // MARK: - Finding it

    /// Apple's catalogue first, then Deezer's, which has much that Apple's
    /// search index leaves out.
    private static func previewURL(for track: PlayerTrack) async -> URL? {
        if let url = await applePreview(for: track) { return url }
        return await deezerPreview(for: track)
    }

    private static func applePreview(for track: PlayerTrack) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: searchTerm(for: track)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        let results = await json(components.url)?["results"] as? [[String: Any]] ?? []
        return closest(to: track, in: results.compactMap { hit in
            guard let name = hit["trackName"] as? String, let artist = hit["artistName"] as? String,
                  let millis = hit["trackTimeMillis"] as? Double,
                  let preview = (hit["previewUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Candidate(name: name, artist: artist, seconds: millis / 1000, preview: preview)
        })
    }

    private static func deezerPreview(for track: PlayerTrack) async -> URL? {
        var components = URLComponents(string: "https://api.deezer.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: searchTerm(for: track)),
            URLQueryItem(name: "limit", value: "15"),
        ]
        let results = await json(components.url)?["data"] as? [[String: Any]] ?? []
        return closest(to: track, in: results.compactMap { hit in
            guard let name = hit["title"] as? String,
                  let artist = (hit["artist"] as? [String: Any])?["name"] as? String,
                  let seconds = hit["duration"] as? Double,
                  let preview = (hit["preview"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Candidate(name: name, artist: artist, seconds: seconds, preview: preview)
        })
    }

    private static func searchTerm(for track: PlayerTrack) -> String {
        "\(LyricsProvider.normalizeTitle(track.name)) \(LyricsProvider.normalizeArtist(track.artist))"
    }

    private struct Candidate {
        let name: String
        let artist: String
        let seconds: Double
        let preview: URL
    }

    /// By the Spotify bridge's rules — artist whole-word, titles mostly — with
    /// more room on length, since an edit or remaster of the same song can
    /// run a few seconds either way; the nearest in length wins. A sped-up,
    /// slowed or other version the song isn't is never taken: its key and
    /// tempo are its own.
    private static func closest(to track: PlayerTrack, in candidates: [Candidate]) -> URL? {
        let playing = versionWords(in: track.name)
        return candidates
            .filter { candidate in
                AnalysisProvider.names(candidate.artist, match: track.artist)
                    && abs(candidate.seconds - track.duration) <= 8
                    && AnalysisProvider.titlesAgree(candidate.name, track.name)
                    && versionWords(in: candidate.name).isSubset(of: playing)
            }
            .min { abs($0.seconds - track.duration) < abs($1.seconds - track.duration) }?
            .preview
    }

    /// Versions that change the key or tempo. A radio edit or an extended
    /// mix doesn't, so those are fine.
    private static let versions = ["sped up", "speed up", "slowed", "nightcore", "reverb", "remix", "live",
                                   "acoustic", "instrumental", "karaoke", "acapella", "a cappella", "cover",
                                   "8d", "demo"]

    private static func versionWords(in title: String) -> Set<String> {
        let spaced = " " + title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") + " "
        return Set(versions.filter { spaced.contains(" \($0) ") })
    }

    private static func json(_ url: URL?) async -> [String: Any]? {
        guard let url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func download(_ url: URL) async -> URL? {
        guard let (file, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // The session deletes its file on return; keep it under a name
        // AVAudioFile can read the format from — AAC from Apple, MP3 from Deezer.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        return (try? FileManager.default.moveItem(at: file, to: kept)) == nil ? nil : kept
    }

    /// Mono, at the estimator's rate.
    static func decode(_ file: URL) -> [Float]? {
        guard let audio = try? AVAudioFile(forReading: file),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: KeyTempoEstimator.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: audio.processingFormat, to: target) else { return nil }

        var samples: [Float] = []
        let chunk: AVAudioFrameCount = 16_384
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: chunk),
                      (try? audio.read(into: input, frameCount: chunk)) != nil, input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let channel = output.floatChannelData?[0] {
                samples += UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
            }
            finished = status == .endOfStream || status == .error || output.frameLength == 0
        }
        return samples.count > Int(KeyTempoEstimator.sampleRate * 10) ? samples : nil
    }
}

/// Key by pitch-class profiles, tempo by onset autocorrelation. Pure, so it
/// can be tested on any audio.
enum KeyTempoEstimator {

    static let sampleRate = 22_050.0

    struct Estimate {
        var key: String?
        var tempo: Double?
        /// How many of the four key readings named the key's notes: four is
        /// near certain, two a best guess.
        var agreement: Int
    }

    static func estimate(_ samples: [Float], sampleRate: Double) -> Estimate {
        let (key, agreement) = key(of: samples, sampleRate: sampleRate)
        return Estimate(key: key, tempo: tempo(of: samples, sampleRate: sampleRate), agreement: agreement)
    }

    // MARK: - Key

    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    private struct Profile {
        let major: [Double]
        let minor: [Double]

        /// Albrecht and Shanahan, from a corpus of real pieces.
        static let corpus = Profile(
            major: [0.238, 0.006, 0.111, 0.006, 0.137, 0.094, 0.016, 0.214, 0.009, 0.080, 0.008, 0.081],
            minor: [0.220, 0.006, 0.104, 0.123, 0.019, 0.103, 0.012, 0.214, 0.062, 0.022, 0.061, 0.052])
        /// Temperley's, from the Kostka–Payne textbook corpus.
        static let textbook = Profile(
            major: [5, 2, 3.5, 2, 4.5, 4, 2, 4.5, 2, 3.5, 1.5, 4],
            minor: [5, 2, 3.5, 4.5, 2, 4, 2, 4.5, 3.5, 2, 1.5, 4])
        /// Krumhansl and Kessler's listening tests.
        static let listening = Profile(
            major: [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
            minor: [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
        /// Just the seven notes of the scale.
        static let scale = Profile(
            major: [1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1],
            minor: [1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0])
    }

    /// Four readings that go wrong in different ways — most often by naming
    /// the key a fifth away — and the seven notes most of them name. Tested
    /// on 37 previews against published keys: right for 26 of the 30 where
    /// three or four agreed, which the log shows.
    static func key(of samples: [Float], sampleRate: Double) -> (key: String?, agreement: Int) {
        let size = 16_384
        let spectra = spectrogram(samples, size: size, hop: 4_096)
        guard !spectra.isEmpty else { return (nil, 0) }
        let binHz = sampleRate / Double(size)
        let tuning = tuningOffset(spectra, binHz: binHz)
        func chroma(_ low: Double, _ high: Double, overtones: Int) -> [Double] {
            chromagram(spectra, binHz: binHz, tuning: tuning, from: low, to: high, overtones: overtones)
        }
        let plain = chroma(55, 2_000, overtones: 1)
        let folded = chroma(55, 2_000, overtones: 4)
        let bass = chroma(40, 160, overtones: 1)
        let withBass = zip(normalised(chroma(55, 2_000, overtones: 3)), normalised(bass)).map { $0 + 0.5 * $1 }

        // Most trusted first: the corpus reading is most often exactly right,
        // so it settles any tie.
        let labels = [best(plain, .corpus), best(folded, .textbook), best(withBass, .scale), best(folded, .listening)]
            .compactMap { $0 }
            .map { names[$0.root] + ($0.minor ? "m" : "") }

        // The seven notes most readings name; then, of those, major or its
        // relative minor, whichever more said.
        let scale = mostCommon(labels.map(notes(of:)))
        let agreeing = labels.filter { notes(of: $0) == scale }
        return (mostCommon(agreeing), agreeing.count)
    }

    /// The most frequent, and on a tie the earliest.
    private static func mostCommon<T: Hashable>(_ items: [T]) -> T? {
        let counts = Dictionary(items.map { ($0, 1) }, uniquingKeysWith: +)
        return items.max { counts[$0]! < counts[$1]! }
    }

    private static func notes(of label: String) -> Set<Int> {
        let minor = label.hasSuffix("m")
        return notes(root: names.firstIndex(of: minor ? String(label.dropLast()) : label)!, minor: minor)
    }

    private static func best(_ chroma: [Double], _ profile: Profile) -> (root: Int, minor: Bool)? {
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        var result: (root: Int, minor: Bool, r: Double)?
        for root in 0..<12 {
            for minor in [false, true] {
                let shape = minor ? profile.minor : profile.major
                let r = correlation(chroma, (0..<12).map { shape[($0 - root + 12) % 12] })
                if r > result?.r ?? -.infinity { result = (root, minor, r) }
            }
        }
        return result.map { ($0.root, $0.minor) }
    }

    private static func notes(root: Int, minor: Bool) -> Set<Int> {
        Set((minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { ($0 + root) % 12 })
    }

    private static func normalised(_ values: [Double]) -> [Double] {
        let sum = values.reduce(0, +)
        return sum > 0 ? values.map { $0 / sum } : values
    }

    /// Energy per pitch class from spectral peaks, each frame normalised so
    /// a loud passage doesn't outvote the rest. With `overtones` above one,
    /// each peak is also credited to the notes it would be the second, third
    /// and fourth harmonic of — the third harmonic otherwise lends every
    /// note's fifth weight it hasn't earned.
    private static func chromagram(_ spectra: [[Float]], binHz: Double, tuning: Double,
                                   from low: Double, to high: Double, overtones: Int) -> [Double] {
        let lowBin = max(1, Int(low / binHz)), highBin = min(spectra[0].count - 2, Int(high / binHz))
        var total = [Double](repeating: 0, count: 12)
        for spectrum in spectra {
            var frame = [Double](repeating: 0, count: 12)
            for bin in lowBin...highBin where spectrum[bin] > spectrum[bin - 1] && spectrum[bin] >= spectrum[bin + 1] {
                let semitones = 12 * log2(Double(bin) * binHz / 440) - tuning
                let nearest = semitones.rounded()
                guard abs(semitones - nearest) < 0.35 else { continue }
                let magnitude = Double(spectrum[bin]).squareRoot()
                for harmonic in 1...overtones {
                    let below = nearest - (12 * log2(Double(harmonic))).rounded()
                    frame[((Int(below) + 9) % 12 + 12) % 12] += magnitude * pow(0.6, Double(harmonic - 1))
                }
            }
            let peak = frame.max() ?? 0
            if peak > 0 { for i in 0..<12 { total[i] += frame[i] / peak } }
        }
        return total
    }

    /// The recording's offset from A = 440, in semitones (±0.5), from where
    /// its peaks sit between semitones.
    private static func tuningOffset(_ spectra: [[Float]], binHz: Double) -> Double {
        let lowBin = Int(55 / binHz), highBin = min(spectra[0].count - 2, Int(2_000 / binHz))
        var x = 0.0, y = 0.0
        for spectrum in spectra {
            for bin in lowBin...highBin where spectrum[bin] > spectrum[bin - 1] && spectrum[bin] >= spectrum[bin + 1] {
                // Parabolic peak position for sub-bin accuracy.
                let a = Double(spectrum[bin - 1]), b = Double(spectrum[bin]), c = Double(spectrum[bin + 1])
                let shift = (a - c) / (2 * (a - 2 * b + c))
                let semitones = 12 * log2((Double(bin) + (shift.isFinite ? shift : 0)) * binHz / 440)
                let angle = 2 * Double.pi * (semitones - semitones.rounded())
                x += b.squareRoot() * cos(angle)
                y += b.squareRoot() * sin(angle)
            }
        }
        return atan2(y, x) / (2 * .pi)
    }

    // MARK: - Tempo

    static func tempo(of samples: [Float], sampleRate: Double) -> Double? {
        let hop = 256
        let frameRate = sampleRate / Double(hop)
        let onsets = onsetStrength(samples, size: 1_024, hop: hop)
        guard onsets.count > Int(frameRate * 8) else { return nil }

        // Autocorrelation across 50–220 BPM.
        let shortest = Int(frameRate * 60 / 220), longest = Int(frameRate * 60 / 50) + 1
        var acf = [Double](repeating: 0, count: longest * 4 + 2)
        for lag in 0..<acf.count where lag < onsets.count {
            var sum = 0.0
            for i in 0..<(onsets.count - lag) { sum += onsets[i] * onsets[i + lag] }
            acf[lag] = sum / Double(onsets.count - lag)
        }
        func acfAt(_ lag: Double) -> Double {
            let i = Int(lag), f = lag - Double(i)
            guard i + 1 < acf.count else { return 0 }
            return acf[i] * (1 - f) + acf[i + 1] * f
        }
        // A beat that's right lines up at two, three and four beats too, which
        // sharpens the estimate well past one frame.
        func strength(_ bpm: Double) -> Double {
            let lag = frameRate * 60 / bpm
            return (1...4).reduce(0) { $0 + acfAt(lag * Double($1)) } / 4
        }
        // Listeners hear tempos near 120 most readily; a gentle preference
        // picks between a tempo and its half or double.
        func weighted(_ bpm: Double) -> Double {
            strength(bpm) * exp(-0.5 * pow(log2(bpm / 120), 2))
        }

        var best = 0.0, bestScore = -Double.infinity
        for lag in shortest...longest {
            let bpm = frameRate * 60 / Double(lag)
            let score = weighted(bpm)
            if score > bestScore { best = bpm; bestScore = score }
        }
        // Refine to a hundredth of a beat per minute.
        var fine = best, fineScore = strength(best)
        for step in stride(from: -3.0, through: 3.0, by: 0.01) {
            let score = strength(best + step)
            if score > fineScore { fine = best + step; fineScore = score }
        }
        guard fineScore > 0 else { return nil }
        // Most records are made at a whole tempo.
        let whole = fine.rounded()
        return abs(fine - whole) <= 0.25 ? whole : (fine * 100).rounded() / 100
    }

    /// How much new energy each frame brings, on a log scale, with the
    /// local average taken off so only attacks remain.
    static func onsetStrength(_ samples: [Float], size: Int, hop: Int) -> [Double] {
        let spectra = spectrogram(samples, size: size, hop: hop)
        guard spectra.count > 1 else { return [] }
        let logged = spectra.map { $0.map { log1p(1_000 * Double($0).squareRoot()) } }
        var flux = [Double](repeating: 0, count: logged.count)
        for t in 1..<logged.count {
            var sum = 0.0
            for bin in 1..<logged[t].count { sum += max(0, logged[t][bin] - logged[t - 1][bin]) }
            flux[t] = sum
        }
        let window = 16
        return flux.indices.map { t in
            let lo = max(0, t - window), hi = min(flux.count - 1, t + window)
            let mean = flux[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            return max(0, flux[t] - mean)
        }
    }

    // MARK: - Shared

    /// Power spectra of Hann-windowed frames.
    static func spectrogram(_ samples: [Float], size: Int, hop: Int) -> [[Float]] {
        guard samples.count >= size else { return [] }
        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var result: [[Float]] = []
        result.reserveCapacity((samples.count - size) / hop + 1)

        for start in stride(from: 0, through: samples.count - size, by: hop) {
            samples.withUnsafeBufferPointer { buffer in
                vDSP.multiply(UnsafeBufferPointer(rebasing: buffer[start..<start + size]), window, result: &frame)
            }
            var power = [Float](repeating: 0, count: size / 2)
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    split.imagp[0] = 0   // Packed Nyquist; not wanted.
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
                }
            }
            result.append(power)
        }
        return result
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n, meanB = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - meanA) * (b[i] - meanB)
            da += (a[i] - meanA) * (a[i] - meanA)
            db += (b[i] - meanB) * (b[i] - meanB)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }
}
