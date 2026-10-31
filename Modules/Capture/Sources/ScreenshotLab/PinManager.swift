import AppKit

final class PinManager {
    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onQuickSave: ((CGImage) -> Void)?
    var onOCR: ((CGImage, CGRect?) -> Void)?
    var onEdit: ((CGImage) -> Void)?

    private var pins: [PinWindowController] = []

    var count: Int { pins.count }

    @discardableResult
    func add(image: CGImage, anchor: CGRect? = nil) -> CGRect? {
        let controller = PinWindowController(image: image, anchor: anchor)
        controller.onCopy = onCopy
        controller.onSave = onSave
        controller.onQuickSave = onQuickSave
        controller.onOCR = onOCR
        controller.onEdit = onEdit
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            // closePin invokes both the window delegate and its explicit callback.
            if self.pins.contains(where: { $0 === controller }) {
                self.pins.removeAll { $0 === controller }
            }
        }
        pins.append(controller)
        controller.show()
        return controller.window?.frame
    }

    func showAll() {
        pins.forEach { $0.showAgain() }
    }

    func hideAll() {
        pins.forEach { $0.hide() }
    }

    func closeAll() {
        let currentPins = pins
        pins.removeAll()
        currentPins.forEach { $0.close() }
    }
}
