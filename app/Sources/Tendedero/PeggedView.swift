import SwiftUI

/// One photo with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false
    @State private var lifted = false
    @State private var cornerPressed: GrabView.CornerAction?
    @State private var returnToken: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }
    private enum Phase: Equatable { case resting, dragging, settling }
    private var phase: Phase { dragging ? .dragging : (line.settlingID == item.id ? .settling : .resting) }
    private var holding: Bool { phase != .resting }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin(isOpen: dragging || line.settlingID == item.id)
                .zIndex(1)
            card
        }
        .offset(y: arrived ? 0 : -46)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: phase, initial: true) { _, value in transition(to: value) }
        .onDisappear {
            if line.hoveredID == item.id { line.hoveredID = nil }
            if let returnToken { line.completeSettling(item.id, token: returnToken) }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                withTransaction(Transaction(animation: nil)) { swing = 0; arrived = true; lifted = false }
                line.completeSettling(item.id, token: line.settlingToken)
            }
        }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        CardGeometry.photo(size, maxWidth: Layout.cardWidth - 14, maxHeight: Layout.photoMaxHeight)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CardGeometry.shell(photo: p)
    }

    /// Distance from the top of the hanging view (the clip) to the card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var card: some View {
        LineCardFace(item: item)
            // Concentric corners: the photo's radius is the frame's minus the
            // inset, the way macOS rounds nested shapes.
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .cardControl()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius)
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // Holding presses the photo in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(reduceMotion ? 1 : (holding ? 1 : (pressed ? 0.975 : (hovering ? 1.02 : 1))), anchor: .top)
            .animation(reduceMotion ? nil : (pressed ? .easeInOut(duration: 0.45) : AppMotion.control), value: pressed)
            // The open clip stays on the rope as a landing place. The card
            // steps away from its jaws while the system drag follows the hand.
            .offset(y: lifted && !reduceMotion ? 8 : 0)
            .opacity(dragging ? 0.22 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // cross sends a file in Tendedero's folder to the Trash; for a
                // file anywhere else it only hides it from the line.
                Image(systemName: line.isInInbox(item.id) ? "xmark" : "eye.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .cardControl()
                    .padding(3)
                    .opacity(hovering && !holding ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (cornerPressed == .discard ? 0.9 : 1))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(GrabArea(item: item, line: line, discardVisible: hovering && !holding, onCornerPress: { cornerPressed = $0 }))
            .overlay(alignment: .bottomLeading) {
                if item.isLibraryItem {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 16, height: 16)
                        .cardControl(active: true)
                        .padding(3)
                        .allowsHitTesting(false)
                        .accessibilityLabel("固定素材")
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: line.previewedID == item.id ? "eye.fill" : "eye")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(line.previewedID == item.id ? AppTheme.accent : Color.primary)
                    .frame(width: 20, height: 20)
                    .cardControl(active: line.previewedID == item.id)
                    .padding(3)
                    .opacity(dragging ? 0 : 1)
                    .scaleEffect(reduceMotion || cornerPressed != .preview ? 1 : 0.9)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                if copied {
                    Label { Text(L("Copied")) } icon: { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                        .offset(y: 16)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(reduceMotion ? nil : AppMotion.control, value: hovering)
            .animation(reduceMotion ? nil : AppMotion.control, value: cornerPressed)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { inside in
                hovering = inside
                if inside { line.hoveredID = item.id }
                else if line.hoveredID == item.id { line.hoveredID = nil }
                line.noteInteraction()
            }
            .rotationEffect(.degrees(holding ? 0 : swing + item.tilt), anchor: .top)
            .animation(reduceMotion ? nil : AppMotion.control, value: holding)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    private func transition(to phase: Phase) {
        switch phase {
        case .dragging:
            returnToken = nil
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { lifted = true }
        case .settling:
            let token = line.settlingToken
            returnToken = token
            withAnimation(reduceMotion ? nil : AppMotion.panel, completionCriteria: .removed) {
                lifted = false
            } completion: {
                line.completeSettling(item.id, token: token)
            }
        case .resting:
            withTransaction(Transaction(animation: nil)) { lifted = false }
        }
    }

    private func arrive() {
        if reduceMotion { arrived = true; swing = 0; return }
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        guard !reduceMotion else { return }
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { swing = 0; return }
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    func cardControl(active: Bool = false) -> some View {
        background(active ? AppTheme.selected : .clear, in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }

    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// A minimal aluminium clip: a brushed metal pill with a slot where it
/// grips the line, and a soft shadow so it reads on any background.
struct Clothespin: View {
    var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack {
            // Both jaws meet in the original silhouette when closed. The
            // hinge is at the rope slot, rather than at the end of the clip.
            jaw
                .brightness(-0.12)
                .rotationEffect(.degrees(isOpen ? 19 : 0), anchor: UnitPoint(x: 0.5, y: 0.35))
                .opacity(isOpen ? 1 : 0)
            jaw
                .rotationEffect(.degrees(isOpen ? -19 : 0), anchor: UnitPoint(x: 0.5, y: 0.35))
        }
        .frame(width: 9, height: 26)
        .animation(reduceMotion ? nil : .spring(response: isOpen ? 0.18 : 0.24, dampingFraction: 0.82), value: isOpen)
        .allowsHitTesting(false)
    }

    private var jaw: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
    }
}
