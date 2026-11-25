import Observation
import PencilKit
import SwiftUI

// =====================================================================================
//  PencilKit integration (Phase 3)
//
//  • PKCanvasView is wrapped in a UIViewRepresentable. The drawing lives in SwiftUI state as
//    `Data` (`PKDrawing.dataRepresentation()`), so it can be stored on a ShotListItem
//    and shared by both screens.
//  • We do NOT show the floating system PKToolPicker by default. Its palette can drift
//    over the canvas, and on a 7.6" display that steals drawing room. Instead, tools are
//    docked in our trailing column (PencilShotListView) and pushed into `canvas.tool`.
//  • drawingPolicy: `.pencilOnly` on device, so a palm or finger scrolls/annotates
//    nothing by accident. The Simulator has no Pencil, so it's forced to `.anyInput`
//    there (mouse/trackpad drawing works). Creators can also opt in to finger drawing.
//  • Nano-texture inner display: the matte glass already adds paper-like friction, so
//    default widths are a touch thinner than PencilKit's and the canvas is a warm
//    off-black rather than pure black, which reads better under the diffusing coating.
// =====================================================================================

/// Lets SwiftUI buttons in the tool dock drive undo/redo/clear on the live canvas.
@Observable
@MainActor
final class PencilCanvasController {
    @ObservationIgnored fileprivate weak var canvas: PKCanvasView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() { canvas?.undoManager?.undo(); refresh() }
    func redo() { canvas?.undoManager?.redo(); refresh() }

    func clear() {
        guard let canvas else { return }
        canvas.drawing = PKDrawing()
        canvas.delegate?.canvasViewDrawingDidChange?(canvas)
        refresh()
    }

    fileprivate func refresh() {
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
    }
}

/// Docked drawing tools.
enum PencilDockTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser, lasso
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: "Pen"
        case .pencil: "Pencil"
        case .marker: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .pencil: "pencil"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    /// Builds the PencilKit tool for the dock selection.
    func pkTool(color: UIColor, width: CGFloat) -> PKTool {
        switch self {
        case .pen: return PKInkingTool(.pen, color: color, width: width)
        case .pencil: return PKInkingTool(.pencil, color: color, width: width * 1.6)
        // Highlighter: PencilKit's marker ink, translucent, wide.
        case .marker: return PKInkingTool(.marker, color: color.withAlphaComponent(0.45), width: width * 6)
        case .eraser: return PKEraserTool(.vector)
        case .lasso: return PKLassoTool()
        }
    }
}

struct PencilCanvasView: UIViewRepresentable {
    @Binding var drawingData: Data
    var tool: PKTool = PKInkingTool(.pen, color: .white, width: 2.5)
    var allowsFingerDrawing = false
    var controller: PencilCanvasController?
    /// Optional system tool picker (used by the small take-notes canvas in the editor).
    var showsSystemToolPicker = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = UIColor(red: 0.09, green: 0.085, blue: 0.08, alpha: 1)
        canvas.isOpaque = true
        canvas.delegate = context.coordinator
        canvas.drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        canvas.alwaysBounceVertical = false
        canvas.tool = tool
        applyPolicy(to: canvas)
        controller?.canvas = canvas

        if showsSystemToolPicker {
            let picker = PKToolPicker()
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            context.coordinator.toolPicker = picker
            DispatchQueue.main.async { canvas.becomeFirstResponder() }
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if !showsSystemToolPicker { canvas.tool = tool }
        applyPolicy(to: canvas)
        controller?.canvas = canvas
        // Replace the drawing only when it changed from outside (e.g. switching shots),
        // so we don't reset the undo stack on every stroke.
        // Empty `Data` means "no sketch" (that's what ShotListItem.sketchData == nil maps to).
        let isExternallyEmpty = drawingData.isEmpty && canvas.drawing.strokes.isEmpty
        if !isExternallyEmpty && canvas.drawing.dataRepresentation() != drawingData {
            canvas.drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        }
    }

    private func applyPolicy(to canvas: PKCanvasView) {
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput         // mouse / trackpad / finger in the Simulator
        #else
        canvas.drawingPolicy = allowsFingerDrawing ? .anyInput : .pencilOnly
        #endif
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvasView
        var toolPicker: PKToolPicker?

        init(_ parent: PencilCanvasView) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let data = canvasView.drawing.strokes.isEmpty ? Data() : canvasView.drawing.dataRepresentation()
            if data != parent.drawingData { parent.drawingData = data }
            MainActor.assumeIsolated { parent.controller?.refresh() }
        }
    }
}
