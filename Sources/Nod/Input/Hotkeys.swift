// OWNER: workstream C (app-ui).
import Carbon.HIToolbox
import Foundation

enum IslandHotkey: UInt32 {
    /// ⌥↵: the current request's default decision (allow for low/review, deny for high).
    case defaultAction = 1
    /// ⌥⌫: deny.
    case deny = 2
}

/// Registers and unregisters ⌥↵ / ⌥⌫ as global hotkeys.
protocol HotkeyRegistrar: AnyObject {
    var isRegistered: Bool { get }
    var onPress: ((IslandHotkey) -> Void)? { get set }
    func register()
    func unregister()
}

/// Holds the hotkeys ONLY while a request is pending (spec anti-goal: never steal ⌥↵ / ⌥⌫ otherwise).
@MainActor
final class HotkeyController {
    private let registrar: HotkeyRegistrar
    private let hasPending: @MainActor () -> Bool
    private var loop: ObservationLoop<Bool>?

    init(registrar: HotkeyRegistrar, hasPending: @escaping @MainActor () -> Bool) {
        self.registrar = registrar
        self.hasPending = hasPending
    }

    var isRegistered: Bool { registrar.isRegistered }

    func start() {
        loop?.cancel()
        let loop = ObservationLoop({ [hasPending] in hasPending() }) { [weak self] pending in
            self?.sync(pending: pending)
        }
        self.loop = loop
        loop.start()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if registrar.isRegistered {
            registrar.unregister()
            Log.debug("hotkeys: unregistered ⌥↵ ⌥⌫ (stopped)")
        }
    }

    private func sync(pending: Bool) {
        if pending, !registrar.isRegistered {
            registrar.register()
            Log.debug("hotkeys: registered ⌥↵ ⌥⌫ (request pending)")
        } else if !pending, registrar.isRegistered {
            registrar.unregister()
            Log.debug("hotkeys: unregistered ⌥↵ ⌥⌫ (no request pending)")
        }
    }
}

/// Carbon `RegisterEventHotKey`: works without Accessibility permission.
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private static let signature: OSType = 0x4E4F_4421 // 'NOD!'
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    var onPress: ((IslandHotkey) -> Void)?

    var isRegistered: Bool { !refs.isEmpty }

    init() {
        installHandler()
    }

    deinit {
        for ref in refs { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == CarbonHotkeyRegistrar.signature,
                  let key = IslandHotkey(rawValue: hk.id) else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { registrar.onPress?(key) }
            return noErr
        }, 1, &spec, me, &handlerRef)
        if status != noErr { Log.info("hotkeys: InstallEventHandler failed (\(status))") }
    }

    func register() {
        guard refs.isEmpty else { return }
        let keys: [(IslandHotkey, Int)] = [(.defaultAction, kVK_Return), (.deny, kVK_Delete)]
        for (key, code) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: key.rawValue)
            let status = RegisterEventHotKey(UInt32(code), UInt32(optionKey), id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                Log.info("hotkeys: RegisterEventHotKey failed for \(key) (\(status))")
            }
        }
    }

    func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}

/// One always-registered global hotkey (the composer's ⌃⌥P). It has its own Carbon signature, so the
/// request hotkeys' handler ignores it and it ignores theirs.
final class GlobalHotkey {
    /// ⌃⌥P opens the prompt composer.
    static let composeKeyCode = UInt32(kVK_ANSI_P)
    static let composeModifiers = UInt32(controlKey | optionKey)
    static let composeLabel = "⌃⌥P"

    private let signature: OSType
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    var isRegistered: Bool { ref != nil }

    init(keyCode: UInt32 = GlobalHotkey.composeKeyCode, modifiers: UInt32 = GlobalHotkey.composeModifiers,
         signature: OSType = 0x4E4F_4443 /* 'NODC' */) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.signature = signature
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns false when the system refuses the registration (for example another app owns the combination).
    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hk = EventHotKeyID()
                let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                guard err == noErr, hk.signature == hotkey.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { hotkey.onPress?() }
                return noErr
            }, 1, &spec, me, &handlerRef)
            if status != noErr {
                Log.info("hotkeys: InstallEventHandler failed for \(Self.composeLabel) (\(status))")
                return false
            }
        }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &newRef)
        guard status == noErr, let newRef else {
            Log.info("hotkeys: could not register \(Self.composeLabel) (\(status))")
            return false
        }
        ref = newRef
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
