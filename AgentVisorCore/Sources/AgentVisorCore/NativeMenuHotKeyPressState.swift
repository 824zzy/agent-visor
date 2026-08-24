public struct NativeMenuHotKeyPressState {
    private var pressedIDs = Set<UInt32>()

    public init() {}

    public mutating func shouldHandle(id: UInt32, isPressed: Bool) -> Bool {
        if !isPressed {
            pressedIDs.remove(id)
            return false
        }
        return pressedIDs.insert(id).inserted
    }
}
