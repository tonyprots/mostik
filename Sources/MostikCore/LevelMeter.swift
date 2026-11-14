import Foundation

/// Уровень микрофона для волны и иконки строки меню: высокие частоты от 150 Гц и шкала по своему
/// шумовому полу. Прежняя шкала −55…−5 dBFS по сырому RMS ставила тишину на 0,42 высоты: гул
/// 0–80 Гц (вентилятор, стол) на 10–14 dB сильнее речевой полосы, речь добавляла к нему 6–7 dB,
/// а верх шкалы не достигался никогда (замер 2026-10-21 на трёх диктовках Антона).
/// Фильтр — только для уровня, звук в распознавание идёт как был.
public struct LevelMeter: Sendable {
    /// Биквад RBJ, высокие частоты; два каскада — 4-й порядок.
    struct Biquad: Sendable {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(highPass cutoff: Double, sampleRate: Double, q: Double = 0.707) {
            let w0 = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w0) / (2 * q)
            let c = cos(w0)
            let a0 = 1 + alpha
            b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
            a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
        }

        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Минимальная ширина шкалы над полом, dB: тихий голос не раздувается до полной высоты.
    public static let minSpan: Float = 15
    /// Шум до пол + 3 dB — ноль.
    public static let gate: Float = 3

    private var stages: [Biquad]
    private(set) public var floor: Float?
    private(set) public var ceiling: Float = -60

    public init(sampleRate: Double, cutoff: Double = 150) {
        stages = [Biquad(highPass: cutoff, sampleRate: sampleRate), Biquad(highPass: cutoff, sampleRate: sampleRate)]
    }

    /// RMS после фильтра, dBFS.
    public mutating func filteredDB(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return -140 }
        var sum: Float = 0
        for i in 0..<count {
            // NaN или бесконечность от устройства — как тишина: иначе состояние фильтра отравлено навсегда.
            var s = samples[i].isFinite ? samples[i] : 0
            for k in stages.indices { s = stages[k].run(s) }
            sum += s * s
        }
        if !sum.isFinite {
            // Переполнение на конечных сэмплах: фильтр с нуля, буфер — тишина.
            for k in stages.indices { stages[k].x1 = 0; stages[k].x2 = 0; stages[k].y1 = 0; stages[k].y2 = 0 }
            return -140
        }
        let rms = (sum / Float(count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    /// Уровень 0…1 по шумовому полу: пол вниз за ~0,3 с, вверх +2 dB/с (речь его не тянет);
    /// потолок вверх сразу, вниз −3 dB/с, не ближе `minSpan` к полу.
    public mutating func level(db: Float, dt: Float) -> Float {
        // Нефинитный замер пол и потолок не трогает.
        guard db.isFinite, dt.isFinite else { return 0 }
        var f = floor ?? db
        if db < f { f += (db - f) * 0.15 } else { f = min(db, f + 2 * dt) }
        floor = f
        ceiling = max(db, ceiling - 3 * dt, f + Self.minSpan)
        let lo = f + Self.gate
        let t = max(0, min(1, (db - lo) / max(ceiling - lo, 1)))
        return Float(pow(Double(t), 0.7))
    }

    public mutating func level(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Float {
        level(db: filteredDB(samples, count: count), dt: Float(Double(count) / sampleRate))
    }
}
