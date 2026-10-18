import SwiftUI
import WheelieCore

/// Looping how-to animation: a file is dragged out of a Finder window, the
/// trigger key goes down, the wheel opens under the pointer, the file is
/// dropped on a petal and the converted copy appears next to the original.
/// Drawn entirely with SwiftUI shapes and SF Symbols.
struct WelcomeIllustration: View {
    let modifier: TriggerModifier
    let animated: Bool

    static let cycle: Double = 6.6
    /// The frame shown when Reduce Motion is on: wheel open, file over a petal.
    static let stillFrame: Double = 3.5

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let t = animated
                ? max(context.date.timeIntervalSince(startDate), 0).truncatingRemainder(dividingBy: Self.cycle)
                : Self.stillFrame
            VStack(spacing: 12) {
                WelcomeScene(t: t, modifier: modifier)
                    .frame(height: 210)
                WelcomeSteps(active: animated ? Self.step(at: t) : nil, modifier: modifier)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation: drag a file, tap \(modifier.name), and drop it on a petal of the wheel. The converted file appears next to the original.")
    }

    static func step(at t: Double) -> Int {
        switch t {
        case ..<1.5: return 0
        case ..<2.5: return 1
        case ..<4.3: return 2
        default: return 3
        }
    }
}

/// 0 before `a`, 1 after `b`, smooth in between.
private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    guard b > a else { return t >= b ? 1 : 0 }
    let x = min(max((t - a) / (b - a), 0), 1)
    return x * x * (3 - 2 * x)
}

private func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
}

private struct WelcomeScene: View {
    let t: Double
    let modifier: TriggerModifier

    static let targetPetal = 1
    static let formats = ["PNG", "JPG", "HEIC", "WEBP", "PDF", "TIFF"]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let finder = CGRect(x: 18, y: 16, width: w * 0.36, height: h - 64)
            let fileHome = CGPoint(x: finder.minX + finder.width * 0.32, y: finder.minY + finder.height * 0.55)
            let outputHome = CGPoint(x: finder.minX + finder.width * 0.72, y: fileHome.y)
            let center = CGPoint(x: w * 0.7, y: h / 2)
            let petal = WheelGeometry.offset(index: Self.targetPetal, count: Self.formats.count, radius: MiniWheel.innerRadius)
            let petalPoint = CGPoint(x: center.x + petal.width, y: center.y + petal.height)

            // Timeline.
            let appear = ramp(t, 0, 0.35)
            let drag = ramp(t, 0.5, 1.7)
            let keyDown = ramp(t, 1.45, 1.6) - ramp(t, 4.0, 4.15)
            let wheelOpen = ramp(t, 1.75, 2.2) * (1 - ramp(t, 5.0, 5.5))
            let toPetal = ramp(t, 2.55, 3.4)
            let dropped = ramp(t, 3.75, 4.0)
            let done = ramp(t, 4.0, 4.25) * (1 - ramp(t, 5.0, 5.4))
            let output = ramp(t, 4.35, 4.7) * (1 - ramp(t, 6.0, 6.4))
            let highlighted = toPetal > 0.6 && t < 5.0 ? Self.targetPetal : nil

            let dragPoint = mix(fileHome, center, drag)
            let arced = CGPoint(x: dragPoint.x, y: dragPoint.y + sin(drag * .pi) * -28)
            let filePoint = toPetal > 0 ? mix(center, petalPoint, toPetal) : arced
            let fileVisible = appear * (1 - dropped)
            let cursorVisible = ramp(t, 0.2, 0.45) * (1 - ramp(t, 4.2, 4.5))

            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [WheelView.accent.opacity(0.20), WheelView.accent.opacity(0.05)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))

                FinderWindowSketch()
                    .frame(width: finder.width, height: finder.height)
                    .position(x: finder.midX, y: finder.midY)

                // Original stays faintly in place while its drag image moves.
                FileCard(name: "photo.png", tint: .blue)
                    .opacity(drag > 0 ? 0.35 : appear)
                    .position(fileHome)

                FileCard(name: "photo.jpg", tint: .green, badge: true)
                    .scaleEffect(0.6 + 0.4 * output)
                    .opacity(output)
                    .position(outputHome)

                KeyCap(text: modifier.keyCap, pressed: keyDown)
                    .position(x: finder.midX, y: h - 22)

                MiniWheel(open: wheelOpen, highlighted: highlighted, done: done)
                    .position(center)

                FileCard(name: nil, tint: .blue)
                    .scaleEffect(1 - 0.5 * dropped)
                    .shadow(color: .black.opacity(0.25 * drag), radius: 6, y: 3)
                    .opacity(drag > 0 ? fileVisible * 0.92 : 0)
                    .position(filePoint)

                Image(systemName: "cursorarrow")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.black)
                    .shadow(color: .white, radius: 0.6)
                    .shadow(color: .white, radius: 0.6)
                    .opacity(cursorVisible)
                    .position(x: filePoint.x + 9, y: filePoint.y + 12)
            }
        }
    }
}

private struct FinderWindowSketch: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 7)
                Circle().fill(Color.yellow.opacity(0.8)).frame(width: 7, height: 7)
                Circle().fill(Color.green.opacity(0.7)).frame(width: 7, height: 7)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06))
            Spacer()
        }
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

private struct FileCard: View {
    let name: String?
    let tint: Color
    var badge = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white)
                    .frame(width: 32, height: 40)
                    .overlay(
                        Image(systemName: "photo.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(tint.gradient)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.12)))
                if badge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .green)
                        .offset(x: 5, y: 4)
                }
            }
            if let name {
                Text(name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
        }
    }
}

private struct KeyCap: View {
    let text: String
    /// 0 = up, 1 = fully pressed.
    let pressed: Double

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed > 0.5 ? Color.white : Color.primary)
            .frame(width: 84, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(pressed > 0.5 ? AnyShapeStyle(WheelView.accent) : AnyShapeStyle(.background))
            )
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(WheelView.accent.opacity(0.3 + 0.7 * pressed), lineWidth: 1))
            .shadow(color: .black.opacity(0.18 * (1 - pressed)), radius: 0, x: 0, y: 2.5 * (1 - pressed))
            .offset(y: 2 * pressed)
            .scaleEffect(1 - 0.04 * pressed)
    }
}

private struct MiniWheel: View {
    let open: Double
    let highlighted: Int?
    let done: Double

    static let innerRadius: CGFloat = 52
    static let innerPetal: CGFloat = 32
    static let outerRadius: CGFloat = 84
    static let outerPetal: CGFloat = 22
    static let tools = ["scissors", "archivebox", "crop", "doc.on.doc", "terminal", "wand.and.stars", "speaker.wave.2", "rotate.right"]

    var body: some View {
        let extent = Self.outerRadius + Self.outerPetal / 2 + 6
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.05)],
                                     center: .center, startRadius: 20, endRadius: extent))
                .frame(width: extent * 2, height: extent * 2)

            ForEach(0..<Self.tools.count, id: \.self) { i in
                Circle()
                    .fill(.background.opacity(0.92))
                    .overlay(Circle().strokeBorder(WheelView.accent.opacity(0.35), lineWidth: 1))
                    .overlay(Image(systemName: Self.tools[i]).font(.system(size: 9, weight: .semibold)))
                    .frame(width: Self.outerPetal, height: Self.outerPetal)
                    .offset(WheelGeometry.offset(index: i, count: Self.tools.count, radius: Self.outerRadius))
            }

            Circle()
                .stroke(WheelView.accent.opacity(0.28), lineWidth: 1.5)
                .frame(width: Self.innerRadius * 2, height: Self.innerRadius * 2)

            ForEach(0..<WelcomeScene.formats.count, id: \.self) { i in
                let on = highlighted == i
                Circle()
                    .fill(on ? AnyShapeStyle(WheelView.accent) : AnyShapeStyle(.background))
                    .overlay(Circle().strokeBorder(WheelView.accent.opacity(on ? 1 : 0.45), lineWidth: 1.2))
                    .overlay(
                        Text(WelcomeScene.formats[i])
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    )
                    .frame(width: Self.innerPetal, height: Self.innerPetal)
                    .shadow(color: .black.opacity(on ? 0.25 : 0.12), radius: on ? 5 : 2, y: 1)
                    .scaleEffect(on ? 1.18 : 1)
                    .offset(WheelGeometry.offset(index: i, count: WelcomeScene.formats.count, radius: Self.innerRadius))
            }

            ZStack {
                Circle().fill(.thickMaterial)
                Circle().strokeBorder(WheelView.accent.opacity(0.5), lineWidth: 1.5)
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .opacity(1 - done)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .scaleEffect(0.5 + 0.5 * done)
                    .opacity(done)
            }
            .frame(width: 40, height: 40)
        }
        .scaleEffect(0.35 + 0.65 * open + 0.07 * sin(open * .pi))
        .opacity(open)
    }
}

/// "1 Drag a file · 2 Tap ⇧ Shift · 3 Drop on a petal", following the animation.
private struct WelcomeSteps: View {
    let active: Int?
    let modifier: TriggerModifier

    var body: some View {
        HStack(spacing: 8) {
            step(0, "Drag a file")
            chevron
            step(1, "Tap \(modifier.label)")
            chevron
            step(2, "Drop on a petal")
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
    }

    private func step(_ index: Int, _ text: String) -> some View {
        let isActive = active == index
        let isDone = (active ?? 0) > index
        return HStack(spacing: 5) {
            ZStack {
                Circle().fill(isActive ? AnyShapeStyle(WheelView.accent) : AnyShapeStyle(Color.primary.opacity(0.1)))
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.secondary)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isActive ? Color.white : Color.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(text)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isActive ? WheelView.accent.opacity(0.14) : Color.clear))
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}
