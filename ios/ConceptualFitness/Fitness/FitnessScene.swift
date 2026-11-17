import SwiftUI

struct FitnessWeekDay: Identifiable, Equatable {
    let id: String
    let letter: String
    let number: String
    let load: Double
    let isToday: Bool
}

struct FitnessWeekWorkout: Equatable {
    let strain: Double?
    let distanceMeters: Double?
}

struct FitnessWeek: Equatable {
    let days: [FitnessWeekDay]
    let load: Double?
    let target: Double?
    let sessions: Int
    let workouts: [String: FitnessWeekWorkout]

    init(detail: StrainDetail? = nil, today: Date = Date()) {
        let calendar = ScoreDateFormatters.calendar
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? calendar.startOfDay(for: today)
        let loads = Dictionary(
            (detail?.chart.points ?? []).compactMap { point in point.date.map { ($0, point.loadPoints ?? 0) } },
            uniquingKeysWith: { first, _ in first }
        )
        days = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let id = ScoreDateFormatters.apiDate.string(from: date)
            return FitnessWeekDay(
                id: id,
                letter: String(ScoreDateFormatters.weekday.string(from: date).prefix(1)),
                number: ScoreDateFormatters.dayOfMonth.string(from: date),
                load: loads[id] ?? 0,
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
        load = detail?.summary.progressLoadPoints ?? detail?.summary.loadPoints
        target = detail?.summary.targetLoadPoints ?? detail?.chart.targetLoadPoints
        sessions = detail?.contributors.count ?? 0
        workouts = Dictionary(
            (detail?.contributors ?? []).map {
                ($0.id, FitnessWeekWorkout(strain: $0.strainLoadPoints, distanceMeters: $0.distanceMeters))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var peakHeights: [Double] {
        let tallest = max(days.map(\.load).max() ?? 0, 1)
        return days.map { $0.load / tallest }
    }
}

struct FitnessHero: View {
    let week: FitnessWeek

    static let chipSpacing: CGFloat = 4
    static let sideInset: CGFloat = 16
    private static let mountainZone: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This week")
                .font(.subheadline.weight(.semibold))
                .opacity(0.82)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(week.load.map { "\(Int($0.rounded()))" } ?? "--")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let target = week.target {
                    Text("of \(Int(target.rounded())) load")
                        .font(.body.weight(.semibold))
                        .opacity(0.82)
                }
            }
            Text(sessionsText)
                .font(.subheadline.weight(.medium))
                .opacity(0.9)
            chips
                .padding(.top, 12)
            Color.clear
                .frame(height: Self.mountainZone)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .background {
            GeometryReader { proxy in
                FitnessScene(heights: week.peakHeights)
                    .frame(height: proxy.size.height + FitnessScene.overscroll)
                    .offset(y: -FitnessScene.overscroll)
            }
            .padding(.horizontal, -Self.sideInset)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var sessionsText: String {
        switch week.sessions {
        case 0: "No sessions yet"
        case 1: "1 session so far"
        default: "\(week.sessions) sessions so far"
        }
    }

    private var accessibilitySummary: String {
        let load = week.load.map { "\(Int($0.rounded()))" } ?? "no"
        let target = week.target.map { " of \(Int($0.rounded()))" } ?? ""
        return "This week, \(load)\(target) load. \(sessionsText)."
    }

    private var chips: some View {
        HStack(spacing: Self.chipSpacing) {
            ForEach(week.days) { day in
                VStack(spacing: 2) {
                    Text(day.letter).font(.caption2.weight(.medium))
                    Text(day.number).font(.system(.subheadline, design: .rounded, weight: .bold))
                }
                .foregroundStyle(day.isToday ? Color(hex: 0x123B45) : .white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background {
                    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                    if day.isToday {
                        shape.fill(.white)
                    } else {
                        shape.fill(.white.opacity(0.2))
                    }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

struct FitnessScene: View {
    let heights: [Double]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    static let overscroll: CGFloat = 600
    private static let fade: CGFloat = 44
    private static let peakBase: CGFloat = 46
    private static let peakHalfWidth: CGFloat = 30
    private static let tallestPeak: CGFloat = 66
    private static let lowestPeak: CGFloat = 18
    private static let fillerHeights: [CGFloat] = [22, 30, 20, 34, 24, 32, 18, 26]
    private static let backPeaks: [(position: CGFloat, height: CGFloat, isSnowy: Bool)] = [
        (0.46, 62, false), (0.66, 82, true), (0.90, 56, false)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let palette = FitnessScenePalette(dark: colorScheme == .dark)
            ZStack(alignment: .bottomLeading) {
                sky(palette, size: size)
                if colorScheme == .dark { stars(size: size) }
                light(palette, size: size)
                FitnessRidge(profile: FitnessRidge.far)
                    .fill(palette.farRidge)
                    .frame(height: 130)
                Rectangle()
                    .fill(palette.peaks)
                    .frame(height: Self.peakBase)
                ForEach(Array(Self.backPeaks.enumerated()), id: \.offset) { index, backPeak in
                    FitnessBackPeak(isSnowy: backPeak.isSnowy, rock: palette.backPeaks, cap: palette.cap)
                        .frame(width: backPeak.height * 1.15, height: backPeak.height)
                        .scaleEffect(y: risen || reduceMotion ? 1 : 0.45, anchor: .bottom)
                        .opacity(risen ? 1 : 0)
                        .offset(x: size.width * backPeak.position - backPeak.height * 0.575, y: -Self.peakBase + 1)
                        .animation(riseAnimation(index: index + 2), value: risen)
                }
                ForEach(Array(Self.fillerHeights.enumerated()), id: \.offset) { index, height in
                    fillerPeak(index: index, height: height, palette: palette, width: size.width)
                }
                ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                    peak(index: index, height: height, palette: palette, width: size.width)
                }
                FitnessForeground()
                    .fill(palette.foreground)
                    .frame(height: 40)
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1 - Self.fade / max(size.height, 1)),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
        .onAppear { risen = true }
    }

    private func sky(_ palette: FitnessScenePalette, size: CGSize) -> some View {
        let scene = max(size.height - Self.overscroll, 1)
        let top = Self.overscroll / max(size.height, 1)
        let span = scene / max(size.height, 1)
        return LinearGradient(stops: [
            .init(color: palette.sky[0], location: 0),
            .init(color: palette.sky[0], location: top),
            .init(color: palette.sky[1], location: top + span * 0.5),
            .init(color: palette.sky[2], location: top + span * 0.8),
            .init(color: palette.sky[3], location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    private func stars(size: CGSize) -> some View {
        let scene = size.height - Self.overscroll
        let points: [(CGFloat, CGFloat, CGFloat)] = [
            (0.10, 0.14, 1.0), (0.85, 0.09, 1.2), (0.74, 0.25, 0.9), (0.31, 0.07, 0.9), (0.92, 0.39, 1.0), (0.51, 0.45, 0.8)
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(.white.opacity(0.65))
                    .frame(width: point.2 * 2, height: point.2 * 2)
                    .offset(x: size.width * point.0, y: Self.overscroll + scene * point.1)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func light(_ palette: FitnessScenePalette, size: CGSize) -> some View {
        let glow: CGFloat = 240
        return ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: palette.glow.opacity(palette.glowStrength), location: 0),
                        .init(color: palette.glow.opacity(palette.glowStrength * 0.5), location: 0.35),
                        .init(color: palette.glow.opacity(0), location: 1)
                    ],
                    center: .center, startRadius: 0, endRadius: glow / 2
                ))
                .frame(width: glow, height: glow)
            Circle()
                .fill(palette.disc)
                .frame(width: palette.discSize, height: palette.discSize)
        }
        .offset(x: size.width * 0.73 - glow / 2, y: -(84 - glow / 2))
    }

    private func peak(index: Int, height: Double, palette: FitnessScenePalette, width: CGFloat) -> some View {
        let count = CGFloat(max(heights.count, 1))
        let chip = (width - FitnessHero.sideInset * 2 - FitnessHero.chipSpacing * (count - 1)) / count
        let center = FitnessHero.sideInset + chip / 2 + CGFloat(index) * (chip + FitnessHero.chipSpacing)
        let full = Self.lowestPeak + (Self.tallestPeak - Self.lowestPeak) * min(max(height, 0), 1)
        let shown = risen ? full : (reduceMotion ? full : full * 0.45)
        let isTallest = height >= 1 && full > 50
        return ZStack(alignment: .bottom) {
            FitnessPeak(height: shown)
                .fill(palette.peaks)
            if isTallest {
                FitnessPeakCap(height: shown)
                    .fill(palette.cap)
            }
        }
        .frame(width: Self.peakHalfWidth * 2, height: Self.tallestPeak + 12, alignment: .bottom)
        .opacity(risen ? 1 : 0)
        .offset(x: center - Self.peakHalfWidth, y: -Self.peakBase + 1)
        .animation(riseAnimation(index: index), value: risen)
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: height)
    }

    private func fillerPeak(index: Int, height: CGFloat, palette: FitnessScenePalette, width: CGFloat) -> some View {
        let count = CGFloat(max(heights.count, 1))
        let chip = (width - FitnessHero.sideInset * 2 - FitnessHero.chipSpacing * (count - 1)) / count
        let center = FitnessHero.sideInset - FitnessHero.chipSpacing / 2 + CGFloat(index) * (chip + FitnessHero.chipSpacing)
        let shown = risen || reduceMotion ? height : height * 0.45
        return FitnessPeak(height: shown)
            .fill(palette.fillerPeaks)
            .frame(width: 52, height: Self.tallestPeak + 12, alignment: .bottom)
            .opacity(risen ? 1 : 0)
            .offset(x: center - 26, y: -Self.peakBase + 1)
            .animation(riseAnimation(index: index), value: risen)
    }

    private func riseAnimation(index: Int) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45).delay(Double(index) * 0.05)
    }
}

private struct FitnessScenePalette {
    let sky: [Color]
    let farRidge: Color
    let fillerPeaks: Color
    let backPeaks: Color
    let peaks: Color
    let cap: Color
    let foreground: Color
    let glow: Color
    let glowStrength: Double
    let disc: Color
    let discSize: CGFloat

    init(dark: Bool) {
        if dark {
            sky = [Color(hex: 0x04080E), Color(hex: 0x0B2530), Color(hex: 0x27404D), Color(hex: 0x4B4656)]
            farRidge = Color(hex: 0x2B4D57).opacity(0.6)
            fillerPeaks = Color(hex: 0x184550)
            backPeaks = Color(hex: 0x1C4A55)
            peaks = Color(hex: 0x12343D)
            cap = Color(hex: 0xC9DCE4).opacity(0.7)
            foreground = Color(hex: 0x0A2128)
            glow = Color(hex: 0xDCE9F2)
            glowStrength = 0.5
            disc = Color(hex: 0xE6EEF3)
            discSize = 30
        } else {
            sky = [Color(hex: 0x0E2C38), Color(hex: 0x2A6871), Color(hex: 0xE4A470), Color(hex: 0xF4D3A6)]
            farRidge = Color(hex: 0x6FA7A2).opacity(0.55)
            fillerPeaks = Color(hex: 0x2B6873)
            backPeaks = Color(hex: 0x347580)
            peaks = Color(hex: 0x1E5560)
            cap = Color(hex: 0xF7E3C4).opacity(0.85)
            foreground = Color(hex: 0x123B45)
            glow = Color(hex: 0xFFE9C2)
            glowStrength = 0.95
            disc = Color(hex: 0xFFF1D6)
            discSize = 36
        }
    }
}

private struct FitnessPeak: Shape {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - height))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FitnessPeakCap: Shape {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let apex = CGPoint(x: rect.midX, y: rect.maxY - height)
        let drop = height * 0.3
        let spread = rect.width / 2 * 0.3
        var path = Path()
        path.move(to: apex)
        path.addLine(to: CGPoint(x: apex.x + spread, y: apex.y + drop))
        path.addLine(to: CGPoint(x: apex.x + spread * 0.2, y: apex.y + drop * 0.78))
        path.addLine(to: CGPoint(x: apex.x - spread * 0.45, y: apex.y + drop * 1.1))
        path.addLine(to: CGPoint(x: apex.x - spread, y: apex.y + drop))
        path.closeSubpath()
        return path
    }
}

private struct FitnessBackPeak: View {
    let isSnowy: Bool
    let rock: Color
    let cap: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                FitnessPeak(height: proxy.size.height).fill(rock)
                if isSnowy {
                    FitnessPeakCap(height: proxy.size.height).fill(cap)
                }
            }
        }
    }
}

private struct FitnessRidge: Shape {
    let profile: [(CGFloat, CGFloat)]

    static let far: [(CGFloat, CGFloat)] = [
        (0, 80), (0.10, 104), (0.20, 90), (0.31, 118), (0.42, 94),
        (0.54, 122), (0.67, 96), (0.78, 114), (0.90, 94), (1, 108)
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for point in profile {
            path.addLine(to: CGPoint(x: rect.minX + rect.width * point.0, y: rect.maxY - point.1))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FitnessForeground: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        func point(_ x: CGFloat, _ up: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + width * x, y: rect.maxY - up)
        }
        var path = Path()
        path.move(to: point(0, 0))
        path.addLine(to: point(0, 30))
        path.addCurve(to: point(0.28, 38), control1: point(0.10, 42), control2: point(0.18, 33))
        path.addCurve(to: point(0.62, 35), control1: point(0.41, 45), control2: point(0.49, 30))
        path.addCurve(to: point(1, 40), control1: point(0.74, 42), control2: point(0.85, 32))
        path.addLine(to: point(1, 0))
        path.closeSubpath()
        return path
    }
}
