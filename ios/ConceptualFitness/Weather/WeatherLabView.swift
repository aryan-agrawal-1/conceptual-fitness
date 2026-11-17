import SwiftUI

enum WeatherLabScene: String, CaseIterable, Identifiable {
    case clear
    case mostlySunny
    case partlyCloudy
    case cloudy
    case rain
    case heavyRain
    case snow
    case fog
    case storm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .mostlySunny: "Mostly sunny"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .snow: "Snow"
        case .fog: "Fog"
        case .storm: "Storm"
        }
    }

    var symbol: String {
        switch self {
        case .clear: "sun.max.fill"
        case .mostlySunny: "sun.min.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow: "cloud.snow.fill"
        case .fog: "cloud.fog.fill"
        case .storm: "cloud.bolt.rain.fill"
        }
    }

    var weatherCode: String {
        switch self {
        case .clear: "clear"
        case .mostlySunny: "mostlyClear"
        case .partlyCloudy: "partlyCloudy"
        case .cloudy: "cloudy"
        case .rain: "rain"
        case .heavyRain: "heavyRain"
        case .snow: "snow"
        case .fog: "foggy"
        case .storm: "thunderstorms"
        }
    }

    var cloudCover: Double {
        switch self {
        case .clear: 0.02
        case .mostlySunny: 0.22
        case .partlyCloudy: 0.45
        case .cloudy: 0.92
        case .rain: 0.85
        case .heavyRain: 0.95
        case .snow: 0.8
        case .fog: 0.7
        case .storm: 0.95
        }
    }

    var precipitation: Double {
        switch self {
        case .rain: 1.2
        case .heavyRain: 4.2
        case .snow: 2.2
        case .storm: 3.4
        default: 0
        }
    }

    var wind: Double {
        switch self {
        case .heavyRain, .storm: 9
        case .rain, .cloudy: 5
        case .fog: 2
        default: 3.5
        }
    }
}

enum WeatherLabTime: String, CaseIterable, Identifiable {
    case sunrise
    case morning
    case midday
    case sunset
    case night

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var hour: Double {
        switch self {
        case .sunrise: 6.2
        case .morning: 9.5
        case .midday: 13
        case .sunset: 19.75
        case .night: 23.5
        }
    }
}

struct WeatherBackgroundDebugControlsView: View {
    @State private var scene: WeatherLabScene
    @State private var time: WeatherLabTime
    @State private var heroCrop: Bool
    @State private var showsTuning = false
    @State private var cloudCover: Double
    @State private var precipitation: Double
    @State private var wind: Double
    @State private var speed = 1.8

    init() {
        let defaults = UserDefaults.standard
        let scene = defaults.string(forKey: "WeatherLabScene").flatMap(WeatherLabScene.init) ?? .partlyCloudy
        _scene = State(initialValue: scene)
        _time = State(initialValue: defaults.string(forKey: "WeatherLabTime").flatMap(WeatherLabTime.init) ?? .midday)
        _heroCrop = State(initialValue: defaults.string(forKey: "WeatherLabCrop") != "full")
        _cloudCover = State(initialValue: scene.cloudCover)
        _precipitation = State(initialValue: scene.precipitation)
        _wind = State(initialValue: scene.wind)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            preview
                .gesture(swipe)

            controls
        }
        .background(HealthTheme.page)
        .ignoresSafeArea(edges: .top)
    }

    private var preview: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                WeatherBackgroundView(weather: weather, debugOptions: WeatherDebugOptions(animationSpeedMultiplier: speed, useWeatherDateForTime: true))
                    .frame(height: heroCrop ? 360 : proxy.size.height)
                    .clipped()
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let all = WeatherLabScene.allCases
                let index = all.firstIndex(of: scene) ?? 0
                let next = value.translation.width < 0 ? index + 1 : index - 1
                select(all[(next + all.count) % all.count])
            }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WeatherLabScene.allCases) { item in
                            Button {
                                select(item)
                            } label: {
                                Label(item.title, systemImage: item.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(item == scene ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .id(item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: scene) { _, value in
                    withAnimation(.snappy) { reader.scrollTo(value, anchor: .center) }
                }
            }

            Picker("Time", selection: $time) {
                ForEach(WeatherLabTime.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            HStack {
                Picker("Crop", selection: $heroCrop) {
                    Text("Hero").tag(true)
                    Text("Full").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Spacer()
                Button(showsTuning ? "Hide tuning" : "Tune") {
                    withAnimation(.snappy) { showsTuning.toggle() }
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)

            if showsTuning {
                VStack(spacing: 10) {
                    slider("Cloud cover", value: $cloudCover, range: 0...1)
                    slider("Precipitation", value: $precipitation, range: 0...5)
                    slider("Wind", value: $wind, range: 0...18)
                    slider("Speed", value: $speed, range: 0...6)
                    Button("Reset to scene defaults") { select(scene) }
                        .font(.subheadline)
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
    }

    private func select(_ item: WeatherLabScene) {
        scene = item
        cloudCover = item.cloudCover
        precipitation = item.precipitation
        wind = item.wind
        speed = 1.8
    }

    private var weather: WeatherData {
        scene.weather(at: time, cloudCover: cloudCover, precipitation: precipitation, wind: wind)
    }
}

extension WeatherLabScene {
    func weather(at time: WeatherLabTime, cloudCover: Double? = nil, precipitation: Double? = nil, wind: Double? = nil) -> WeatherData {
        let today = Calendar.current.startOfDay(for: Date())
        let sunrise = today.addingTimeInterval(6 * 3600)
        let sunset = today.addingTimeInterval(20 * 3600)
        let date = today.addingTimeInterval(time.hour * 3600)
        return WeatherData(
            weatherCode: weatherCode,
            cloudCover: cloudCover ?? self.cloudCover,
            precipitationIntensity: precipitation ?? self.precipitation,
            isDay: date >= sunrise && date <= sunset,
            sunrise: sunrise,
            sunset: sunset,
            date: date,
            locationName: "Weather Lab",
            windSpeed: wind ?? self.wind
        )
    }
}

extension WeatherData {
    static var labOverride: WeatherData? {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let scene = defaults.string(forKey: "WeatherLabScene").flatMap(WeatherLabScene.init) else { return nil }
        let time = defaults.string(forKey: "WeatherLabTime").flatMap(WeatherLabTime.init) ?? .midday
        return scene.weather(at: time)
        #else
        return nil
        #endif
    }
}

#Preview("Weather Lab") {
    WeatherBackgroundDebugControlsView()
}
