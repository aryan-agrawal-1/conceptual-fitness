import Foundation

struct EarthPoint {
    let latitude: Double
    let longitude: Double
}

enum EarthLand {
    static let columns = 120

    static let points: [EarthPoint] = {
        var points: [EarthPoint] = []
        for (row, bits) in grid.enumerated() {
            let latitude = (90 - (Double(row) + 0.5) * 180 / Double(grid.count)) * .pi / 180
            let stride = max(1, Int((1 / max(cos(latitude), 0.05)).rounded()))
            for column in Swift.stride(from: 0, to: columns, by: stride) where bits[column] {
                points.append(EarthPoint(latitude: latitude, longitude: ((Double(column) + 0.5) * 360 / Double(columns) - 180) * .pi / 180))
            }
        }
        return points
    }()

    static let home: EarthPoint = {
        let degrees = Double(TimeZone.current.secondsFromGMT()) / 240
        let column = min(columns - 1, max(0, Int((degrees + 180) / 360 * Double(columns))))
        let rows = grid.indices.sorted { abs($0 - 16) < abs($1 - 16) }
        let row = rows.first { grid[$0][column] } ?? 16
        return EarthPoint(
            latitude: (90 - (Double(row) + 0.5) * 180 / Double(grid.count)) * .pi / 180,
            longitude: ((Double(column) + 0.5) * 360 / Double(columns) - 180) * .pi / 180
        )
    }()

    private static let grid: [[Bool]] = rows.map { row in
        row.flatMap { digit -> [Bool] in
            let value = digit.hexDigitValue ?? 0
            return [value & 8 != 0, value & 4 != 0, value & 2 != 0, value & 1 != 0]
        }
    }

    private static let rows = [
        "000000000000000000000000000000",
        "000000000000000000000000000000",
        "00000001ff4ff80000000000000000",
        "0000000ffffffc00f0000018000000",
        "00000f3fc7fffc0000000007c00000",
        "00003ebbc07ff800000201fff61000",
        "03e03fdff83ff0001c003fffffff80",
        "c7ffffff9e3f80007fffffffffffff",
        "27ffffff3c3e0e01ffffffffffffff",
        "07fffff8381c0003dffffffffffffc",
        "0383fff83e000023cfffffffffe060",
        "0000ffff3f0000319fffffffffc0c0",
        "00007fffff800077fffffffffff080",
        "00003fffffc0001ffffffffffff000",
        "00001fffff00001fffffffffffc000",
        "00003ffff800007ffc77ffffff9000",
        "00003ffff00000707ff3fffffe0000",
        "00001fffe000007017fbfffff22000",
        "00000fffc000003f00fffffff2c000",
        "000007ff8000007ffbfffffff80000",
        "000003f0800000fffff7fffff80000",
        "000002f0000001fffffbfffff00000",
        "00000070400003ffff7f1fffe00000",
        "00000076380003fffffe0f9e800000",
        "0000001e000003ffffbc0e0f080000",
        "00000003000003fffff00607880000",
        "000000011f0001fffff80601040000",
        "000000003f8000fffff80204040000",
        "000000003fe00043fff0000e300000",
        "000000007fe00001ffe00006e00000",
        "000000007ff80001ffc00006e88000",
        "000000007fff0000ff800003087a00",
        "000000007fff0000ff800000c03800",
        "000000003fff0000ff800000000400",
        "000000003ffe0000ffc8000001d000",
        "000000001ffe0000ff98000007d800",
        "000000000ffe0000ff1000000ff800",
        "0000000007fc00007f3000003ffc00",
        "000000000ff000007e0000003ffe00",
        "000000000ff000007e0000003ffe00",
        "000000000fe000003c0000003ffe00",
        "000000000fc0000020000000107c00",
        "000000001f80000000000000001c02",
        "000000001e00000000000000000002",
        "000000001e0000000000000000000c",
        "000000001c00000000000000000008",
        "000000001c00000000000000000000",
        "000000001800000000000000000000",
        "000000000400000000000000000000",
        "000000000000000000000000000000",
        "000000000000000000000000000000",
        "000000000000000000000000000000",
        "0000000006000000001f41fffff800",
        "000000000e000007ffffeffffffff0",
        "0000103fff0001fffffffffffffff8",
        "001ffffff8003fffffffffffffffe0",
        "007fffffe018ffffffffffffffffc0",
        "007fffffffffffffffffffffffffe0",
        "ffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffff",
    ]
}
