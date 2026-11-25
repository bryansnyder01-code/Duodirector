import CoreGraphics
import SwiftUI
import Testing
@testable import DuoDirector

/// DuoRegions posture / insets / collisions and the Host PiP placement, using hand-made
/// region frames (Phase 5 made DuoRegions store frames so this is possible).
@MainActor
@Suite("Fold-aware layout")
struct LayoutTests {

    let inner = CGSize(width: 1000, height: 714)   // ~1.4:1 inner display, landscape

    @Test func flatWhenNoDivision() {
        #expect(DuoRegions(size: inner).posture == .flat)
        #expect(DuoRegions(size: inner).foldAxis == nil)
    }

    @Test func tallFoldIsBook() {
        let fold = CGRect(x: 480, y: 0, width: 40, height: 714)
        let regions = DuoRegions(divisionFrames: [fold], size: inner)
        #expect(regions.posture == .book(fold: fold))
        #expect(regions.foldAxis == .vertical)
    }

    @Test func wideFoldIsTabletop() {
        let fold = CGRect(x: 0, y: 337, width: 1000, height: 40)
        let regions = DuoRegions(divisionFrames: [fold], size: inner)
        #expect(regions.posture == .tabletop(fold: fold))
        #expect(regions.foldAxis == .horizontal)
    }

    @Test func simulatorOverrideFabricatesCentredCrease() {
        let regions = DuoRegions(size: inner)
        guard case .tabletop(let fold) = regions.posture(override: .tabletopLShape) else {
            Issue.record("expected tabletop"); return
        }
        #expect(fold.height == DuoRegions.simulatedCrease)
        #expect(abs(fold.midY - inner.height / 2) < 0.5)
        #expect(regions.posture(override: .closed) == .flat)
    }

    @Test func occlusionInsetsUseNearestEdge() {
        // Status area along the top, inner camera hugging the trailing edge.
        let status = CGRect(x: 0, y: 0, width: 1000, height: 30)
        let camera = CGRect(x: 950, y: 300, width: 50, height: 60)
        let insets = DuoRegions(occlusionFrames: [status, camera], size: inner).occlusionInsets
        #expect(insets.top == 30)
        #expect(insets.trailing == 50)
        #expect(insets.leading == 0)
        #expect(insets.bottom == 0)
    }

    @Test func verticalInsetsOnlyCountOverlappingRegions() {
        let column = CGRect(x: 800, y: 0, width: 200, height: 714)
        let top = CGRect(x: 850, y: 0, width: 100, height: 44)
        let elsewhere = CGRect(x: 0, y: 600, width: 100, height: 114)
        let result = DuoRegions(occlusionFrames: [top, elsewhere], size: inner).verticalInsets(forColumn: column)
        #expect(result.top == 44)
        #expect(result.bottom == 0)
    }

    @Test func collidesWithFoldAndOcclusions() {
        let regions = DuoRegions(divisionFrames: [CGRect(x: 0, y: 337, width: 1000, height: 40)],
                                 occlusionFrames: [CGRect(x: 0, y: 0, width: 60, height: 60)], size: inner)
        #expect(regions.collides(CGRect(x: 10, y: 10, width: 20, height: 20)))
        #expect(regions.collides(CGRect(x: 500, y: 350, width: 10, height: 10)))
        #expect(!regions.collides(CGRect(x: 500, y: 100, width: 10, height: 10)))
    }

    // MARK: PiP

    let tile = CGSize(width: 116, height: 154)

    @Test func pipCornersStayInsideTheContainer() {
        let regions = DuoRegions(size: inner)
        for corner in PiPCorner.allCases {
            let rect = MovableHostPiP.rect(for: corner, tile: tile, container: inner,
                                           insets: regions.occlusionInsets, margin: 12)
            #expect(CGRect(origin: .zero, size: inner).contains(rect), "\(corner)")
        }
    }

    @Test func pipMovesOffTheActiveInnerCamera() {
        // The inner camera's .occlusion sits in the bottom-trailing corner while recording.
        let camera = CGRect(x: 840, y: 480, width: 160, height: 234)
        let regions = DuoRegions(occlusionFrames: [camera], size: inner)
        let corner = MovableHostPiP.clearCorner(preferred: .bottomTrailing, tile: tile, container: inner,
                                                regions: regions, margin: 12)
        let rect = MovableHostPiP.rect(for: corner, tile: tile, container: inner,
                                       insets: regions.occlusionInsets, margin: 12)
        #expect(!regions.collides(rect))
    }

    @Test func dragSnapsToNearestClearCorner() {
        let regions = DuoRegions(size: inner)
        let corner = MovableHostPiP.nearestClearCorner(to: CGPoint(x: 50, y: 50), tile: tile,
                                                       container: inner, regions: regions, margin: 12)
        #expect(corner == .topLeading)
    }
}
