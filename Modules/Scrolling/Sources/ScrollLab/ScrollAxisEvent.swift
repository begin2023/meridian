import CoreGraphics

/// 单个滚动轴（Y = Axis1，X = Axis2）的三层 delta 数据。
/// 取值优先级：像素点距 > 定点行距 > 整数行距。
struct ScrollAxis {
    let integerDelta: Int64
    let pointDelta: Double
    let fixedPtDelta: Double
    /// 数据载体是否为行距类（整数/定点），像素类设备（高分辨率滚轮）为 false。
    let fixed: Bool
    let valid: Bool

    /// 参与计算的可用数值。
    var usableValue: Double {
        if pointDelta != 0 { return pointDelta }
        if fixedPtDelta != 0 { return fixedPtDelta }
        return Double(integerDelta)
    }

    static let empty = ScrollAxis(
        integerDelta: 0,
        pointDelta: 0,
        fixedPtDelta: 0,
        fixed: false,
        valid: false
    )

    static func read(_ event: CGEvent, axis1: Bool) -> ScrollAxis {
        let integerField: CGEventField = axis1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
        let pointField: CGEventField = axis1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
        let fixedField: CGEventField = axis1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2

        let integer = event.getIntegerValueField(integerField)
        let point = event.getDoubleValueField(pointField)
        let fixedPt = event.getDoubleValueField(fixedField)

        if point != 0 {
            return ScrollAxis(integerDelta: integer, pointDelta: point, fixedPtDelta: fixedPt, fixed: false, valid: true)
        }
        if fixedPt != 0 {
            return ScrollAxis(integerDelta: integer, pointDelta: point, fixedPtDelta: fixedPt, fixed: true, valid: true)
        }
        if integer != 0 {
            return ScrollAxis(integerDelta: integer, pointDelta: point, fixedPtDelta: fixedPt, fixed: true, valid: true)
        }
        return ScrollAxis(integerDelta: integer, pointDelta: point, fixedPtDelta: fixedPt, fixed: false, valid: false)
    }
}

/// 一次滚动事件中两个轴的快照，附带全部改写操作。
struct ScrollWheelSnapshot {
    let event: CGEvent
    var y: ScrollAxis
    var x: ScrollAxis

    init(event: CGEvent) {
        self.event = event
        y = ScrollAxis.read(event, axis1: true)
        x = ScrollAxis.read(event, axis1: false)
    }

    var hasVerticalDelta: Bool { y.valid && y.usableValue != 0 }
    var hasHorizontalDelta: Bool { x.valid && x.usableValue != 0 }

    /// 反向滚轮：把该轴的三个 delta 字段全部取负。
    mutating func reverseVertical() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -y.integerDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -y.pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -y.fixedPtDelta)
        y = ScrollAxis(
            integerDelta: -y.integerDelta,
            pointDelta: -y.pointDelta,
            fixedPtDelta: -y.fixedPtDelta,
            fixed: y.fixed,
            valid: y.valid
        )
    }

    mutating func reverseHorizontal() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -x.integerDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -x.pointDelta)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -x.fixedPtDelta)
        x = ScrollAxis(
            integerDelta: -x.integerDelta,
            pointDelta: -x.pointDelta,
            fixedPtDelta: -x.fixedPtDelta,
            fixed: x.fixed,
            valid: x.valid
        )
    }

    /// 把某轴幅值放大到 threshold（保留符号），用于把小步距抬到 step 基线。
    static func normalized(_ value: Double, threshold: Double) -> Double {
        let magnitude = max(abs(value), threshold)
        return value > 0 ? magnitude : -magnitude
    }

    /// 清零某轴的全部字段（用于"该轴已被平滑管线接管，放行原事件时禁用此轴"）。
    mutating func clearVertical() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
    }

    mutating func clearHorizontal() {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
    }
}
