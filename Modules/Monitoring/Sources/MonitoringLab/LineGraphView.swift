import AppKit

// 弹窗内的历史曲线:下方半透明填充 + 上方实线,支持动态或固定上限。
final class LineGraphView: NSView {
    var lineColor: NSColor = AppTheme.accent {
        didSet { needsDisplay = true }
    }

    var values: [Double] = [] {
        didSet { needsDisplay = true }
    }

    var secondaryValues: [Double] = [] {
        didSet { needsDisplay = true }
    }

    var fixedMaxValue: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSeries(values, alpha: 1)
        if !secondaryValues.isEmpty {
            drawSeries(secondaryValues, alpha: 0.55)
        }
    }

    private func drawSeries(_ series: [Double], alpha: CGFloat) {
        let capacity = 120
        let values = series.suffix(capacity)
        guard values.count > 1 else { return }
        let maxValue = max(fixedMaxValue ?? (values.max() ?? 1), 0.0001) * 1.15

        // 采样点不足容量时铺满全宽,避免刚打开弹窗时曲线挤在右侧
        let count = values.count
        let stepX = bounds.width / CGFloat(max(count - 1, 1))
        let startIndex = 0

        func point(at index: Int, value: Double) -> NSPoint {
            let x = bounds.minX + stepX * CGFloat(startIndex + index)
            let fraction = CGFloat(min(max(value / maxValue, 0), 1))
            let y = bounds.minY + 2 + (bounds.height - 4) * fraction
            return NSPoint(x: x, y: y)
        }

        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: point(at: startIndex, value: values.first!).x, y: bounds.minY))
        for (index, value) in values.enumerated() {
            fillPath.line(to: point(at: startIndex + index, value: value))
        }
        fillPath.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        fillPath.close()
        lineColor.withAlphaComponent(0.28 * alpha).setFill()
        fillPath.fill()

        let linePath = NSBezierPath()
        for (index, value) in values.enumerated() {
            let p = point(at: startIndex + index, value: value)
            if index == 0 {
                linePath.move(to: p)
            } else {
                linePath.line(to: p)
            }
        }
        linePath.lineWidth = 1.5
        linePath.lineCapStyle = .round
        lineColor.withAlphaComponent(alpha).setStroke()
        linePath.stroke()
    }
}

// 水平用量条:圆角轨道 + 填充,支持多段(分类条形)。
final class BarMeterView: NSView {
    struct Segment {
        var fraction: Double
        var color: NSColor
    }

    var segments: [Segment] = [] {
        didSet { needsDisplay = true }
    }

    var barHeight: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(
            roundedRect: bounds,
            xRadius: barHeight / 2,
            yRadius: barHeight / 2
        )
        NSColor.white.withAlphaComponent(0.12).setFill()
        track.fill()

        var consumed: CGFloat = 0
        let total = bounds.width - barHeight
        for segment in segments {
            let width = total * CGFloat(min(max(segment.fraction, 0), 1))
            guard width > 0.5 else { continue }
            let rect = NSRect(x: bounds.minX + consumed, y: bounds.minY, width: width + barHeight, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            path.append(
                NSBezierPath(rect: NSRect(
                    x: bounds.minX + consumed + width,
                    y: bounds.minY,
                    width: barHeight,
                    height: bounds.height
                ))
            )
            segment.color.setFill()
            path.fill()
            consumed += width
        }
    }
}

// 图例行:色点 + 名称 + 右对齐数值。
final class LegendRowView: NSView {
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    var value: String = "" {
        didSet { valueLabel.stringValue = value }
    }

    init(name: String, color: NSColor?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (color ?? NSColor.clear).cgColor

        nameLabel.font = AppTheme.font(ofSize: 12)
        nameLabel.textColor = AppTheme.secondaryText
        nameLabel.stringValue = name
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = AppTheme.primaryText
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
