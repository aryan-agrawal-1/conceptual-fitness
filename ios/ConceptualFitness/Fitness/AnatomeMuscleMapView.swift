import SwiftUI
import WebKit

struct AnatomeMuscleMapView: UIViewRepresentable {
    let primary: [String]
    let secondary: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let signature = primary.joined(separator: ",") + "|" + secondary.joined(separator: ",")
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature
        guard let dataURL = Bundle.main.url(forResource: "bodyPaths", withExtension: "json"),
              let bodyPaths = try? String(contentsOf: dataURL, encoding: .utf8),
              let primaryJSON = Self.json(primary.map(Self.normalizedMuscle)),
              let secondaryJSON = Self.json(secondary.map(Self.normalizedMuscle))
        else { return }
        view.loadHTMLString(
            Self.html(bodyPaths: bodyPaths, primary: primaryJSON, secondary: secondaryJSON),
            baseURL: nil
        )
    }

    final class Coordinator {
        var signature = ""
    }

    private static func html(bodyPaths: String, primary: String, secondary: String) -> String {
        """
        <!doctype html>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
          * { box-sizing: border-box; }
          html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
          .map { display: flex; align-items: center; justify-content: center; gap: 2px; width: 100%; height: 100%; }
          svg { width: 49%; height: 100%; overflow: visible; }
          path { stroke: rgba(90,100,115,.28); stroke-width: 1.2; vector-effect: non-scaling-stroke; }
        </style>
        <div class="map" id="map"></div>
        <script>
          const bodyPaths = \(bodyPaths);
          const primary = new Set(\(primary));
          const secondary = new Set(\(secondary));
          const ns = 'http://www.w3.org/2000/svg';
          for (const side of ['front', 'back']) {
            const svg = document.createElementNS(ns, 'svg');
            svg.setAttribute('viewBox', side === 'front' ? '0 0 724 1024' : '724 0 724 1024');
            svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
            for (const region of bodyPaths.male[side]) {
              const values = Object.values(region.path || {}).flat();
              const fill = primary.has(region.slug) ? '#DB6D37' : secondary.has(region.slug) ? '#4D8DC7' : '#DFE3E8';
              for (const d of values) {
                const path = document.createElementNS(ns, 'path');
                path.setAttribute('d', d);
                path.setAttribute('fill', fill);
                svg.appendChild(path);
              }
            }
            document.getElementById('map').appendChild(svg);
          }
        </script>
        """
    }

    private static func json(_ value: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedMuscle(_ value: String) -> String {
        let normalized = value.lowercased().replacingOccurrences(of: "_", with: " ")
        return [
            "abdominals": "abs",
            "shoulders": "deltoids",
            "glutes": "gluteal",
            "hamstrings": "hamstring",
            "lats": "upper-back",
            "middle back": "upper-back",
            "lower back": "lower-back",
            "traps": "trapezius",
            "quads": "quadriceps",
        ][normalized] ?? normalized.replacingOccurrences(of: " ", with: "-")
    }
}
