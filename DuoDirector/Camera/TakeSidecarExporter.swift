import Foundation

/// Phase 4: writes edit-ready sidecars next to each take's .mov files in Documents/Takes
/// (visible in the Files app, since Info.plist enables file sharing):
///
///  • `<take>.duodirector.json`: everything we know: session identifier, both file
///    names, sync offset, capture settings, rating, shot, and every TakeMarker
///    (timestamp, 1–5 stars, note). Easy to script against.
///  • `<take>.fcpxml`: FCPXML 1.11 that Final Cut Pro imports directly and DaVinci
///    Resolve imports via File › Import › Timeline. It builds a project whose layout
///    follows `DualExportStyle`:
///      separateSyncedTracks  → rear on the spine, inner on lane 1 (offset-synced), full frame
///      pictureInPicture      → inner on lane 1 scaled to 30% in the bottom-right corner
///      splitScreenComposite  → rear and inner each scaled to 50%, side by side
///    Markers carry the note; the stars go in the marker value so they're searchable in
///    both NLEs. The take rating becomes a keyword ("★★★★☆").
///
/// Composites are delivered as NLE timelines rather than rendered on device. Rendering
/// would mean an AVAssetWriter + AVVideoComposition pass, which is heavy on a warm phone
/// and is exactly what the thermal guard is trying to avoid.
enum TakeSidecarExporter {

    struct Sidecar: Codable {
        struct File: Codable { var role: String; var fileName: String; var startOffsetSeconds: Double }
        struct Marker: Codable { var timestampSeconds: Double; var rating: Int; var stars: String; var note: String }
        var app = "DuoDirector"
        var formatVersion = 1
        var sessionIdentifier: String
        var takeNumber: Int
        var startedAt: Date
        var durationSeconds: Double
        var rating: Int
        var captureMode: String
        var exportStyle: String
        var resolution: String
        var frameRate: Int
        var codec: String
        var dolbyVision: Bool
        var shotTitle: String?
        var files: [File]
        var markers: [Marker]
    }

    struct Settings {
        var resolution: ResolutionPreset
        var frameRate: Int
        var codec: VideoCodecPreset
        var dolbyVision: Bool
    }

    /// Writes both sidecars and returns their URLs.
    static func write(take: TakeRecord, markers: [TakeMarker], settings: Settings,
                      directory: URL = CaptureSessionController.takesDirectory) throws -> (json: URL, fcpxml: URL) {
        let base = take.rearFileURL?.deletingPathExtension().lastPathComponent
            ?? "DuoDirector-T\(take.takeNumber)-\(take.sessionIdentifier.prefix(8))"
        let jsonURL = directory.appending(path: "\(base).duodirector.json")
        let xmlURL = directory.appending(path: "\(base).fcpxml")

        var files: [Sidecar.File] = []
        if let rear = take.rearFileURL { files.append(.init(role: "rear-guest", fileName: rear.lastPathComponent, startOffsetSeconds: 0)) }
        if let inner = take.innerFileURL {
            files.append(.init(role: "inner-host", fileName: inner.lastPathComponent, startOffsetSeconds: take.innerStartOffset))
        }
        let sidecar = Sidecar(
            sessionIdentifier: take.sessionIdentifier, takeNumber: take.takeNumber, startedAt: take.startedAt,
            durationSeconds: take.duration, rating: take.rating, captureMode: take.captureMode.rawValue,
            exportStyle: take.exportStyle.rawValue, resolution: settings.resolution.label,
            frameRate: settings.frameRate, codec: settings.codec.label, dolbyVision: settings.dolbyVision,
            shotTitle: take.shotTitle, files: files,
            markers: markers.map { .init(timestampSeconds: $0.timestamp, rating: $0.rating, stars: $0.stars, note: $0.note) })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(sidecar).write(to: jsonURL, options: .atomic)
        try fcpxml(take: take, markers: markers, settings: settings).write(to: xmlURL, atomically: true, encoding: .utf8)
        return (jsonURL, xmlURL)
    }

    // MARK: FCPXML

    static func fcpxml(take: TakeRecord, markers: [TakeMarker], settings: Settings) -> String {
        let fps = max(1, settings.frameRate)
        func t(_ seconds: Double) -> String {
            // Frame-accurate rational time, as FCPXML expects ("1234/30s").
            let frames = Int((seconds * Double(fps)).rounded())
            return "\(frames)/\(fps)s"
        }
        let width = settings.resolution.width, height = settings.resolution.height
        let duration = t(max(take.duration, 1.0 / Double(fps)))
        let formatName = "FFVideoFormat\(settings.resolution == .uhd4K ? "3840x2160" : "1080")p\(fps)"
        let colorSpace = settings.dolbyVision ? "9-18-9 (Rec. 2020 HLG)" : "1-1-1 (Rec. 709)"
        let rearName = take.rearFileURL?.lastPathComponent ?? "rear.mov"
        let innerName = take.innerFileURL?.lastPathComponent

        // Frame is 100 units tall in FCPXML transform space; width = 100 × aspect.
        let halfWidth = 100.0 * Double(width) / Double(height) / 2
        var rearTransform = ""
        var innerTransform = ""
        switch take.exportStyle {
        case .separateSyncedTracks:
            break
        case .pictureInPicture:
            let scale = 0.3
            innerTransform = #"<adjust-transform position="\#(fmt(halfWidth - halfWidth * scale - 4)) \#(fmt(-(50 - 50 * scale - 4)))" scale="\#(scale) \#(scale)"/>"#
        case .splitScreenComposite:
            rearTransform = #"<adjust-transform position="\#(fmt(-halfWidth / 2)) 0" scale="0.5 0.5"/>"#
            innerTransform = #"<adjust-transform position="\#(fmt(halfWidth / 2)) 0" scale="0.5 0.5"/>"#
        }

        let markerXML = markers.map {
            #"            <marker start="\#(t($0.timestamp))" duration="1/\#(fps)s" value="\#(xml($0.stars + " " + $0.note))" note="\#(xml($0.note))"/>"#
        }.joined(separator: "\n")
        let keyword = take.rating > 0
            ? #"            <keyword start="0s" duration="\#(duration)" value="\#(String(repeating: "★", count: take.rating))\#(String(repeating: "☆", count: 5 - take.rating))"/>"#
            : ""

        var innerAsset = ""
        var innerClip = ""
        if let innerName {
            innerAsset = #"""
                <asset id="r3" name="Host (inner)" start="0s" duration="\#(duration)" hasVideo="1" hasAudio="1" format="r1" videoSources="1" audioSources="1">
                    <media-rep kind="original-media" src="./\#(xml(innerName))"/>
                </asset>
        """#
            innerClip = #"""
                    <asset-clip ref="r3" lane="1" offset="\#(t(take.innerStartOffset))" duration="\#(duration)" name="Host (inner)">
                        \#(innerTransform)
                    </asset-clip>
        """#
        }

        return #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <!-- Generated by DuoDirector. session=\#(take.sessionIdentifier) -->
        <fcpxml version="1.11">
            <resources>
                <format id="r1" name="\#(formatName)" frameDuration="1/\#(fps)s" width="\#(width)" height="\#(height)" colorSpace="\#(colorSpace)"/>
                <asset id="r2" name="Guest (rear)" start="0s" duration="\#(duration)" hasVideo="1" hasAudio="1" format="r1" videoSources="1" audioSources="1">
                    <media-rep kind="original-media" src="./\#(xml(rearName))"/>
                </asset>
        \#(innerAsset)
            </resources>
            <library>
                <event name="DuoDirector \#(take.startedAt.formatted(.iso8601.year().month().day()))">
                    <project name="Take \#(take.takeNumber)\#(take.shotTitle.map { " – " + xml($0) } ?? "")">
                        <sequence format="r1" duration="\#(duration)" tcStart="0s" tcFormat="NDF">
                            <spine>
                                <asset-clip ref="r2" offset="0s" duration="\#(duration)" name="Guest (rear)">
                                    \#(rearTransform)
        \#(markerXML)
        \#(keyword)
        \#(innerClip)
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """#
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func xml(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
