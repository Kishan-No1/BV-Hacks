// OWNER: workstream C (app-ui).
import Foundation
import Observation

/// Re-runs `read` whenever an observed property it touched changes and calls `onChange` with the new value
/// (and once at start). Built on `withObservationTracking`; changes are delivered on the main actor.
@MainActor
final class ObservationLoop<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var last: Value?
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
    }

    func start() { track() }

    func cancel() { cancelled = true }

    private func track() {
        guard !cancelled else { return }
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Fires in willSet; re-read on the next main-actor turn, after the mutation landed.
            Task { @MainActor [weak self] in self?.track() }
        }
        if last != value {
            last = value
            onChange(value)
        }
    }
}
