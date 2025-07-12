# Cats

Clean Architecture Toolkit for Swift

---

Cats is a toolkit for building scalable, testable, and reactive apps in Swift using Clean Architecture principles. It provides:

- 📦 **Observable in-memory cache** (thread-safe, LRU + TTL expiry, Combine publishers)
- 🎯 **State-driven ViewModel protocol** for predictable UI state binding
- 🚦 **Event-driven ViewModel protocol** for one-off effects and UI events

## Features

- Generic, thread-safe, observable in-memory cache (`ObservableMemoryCache`, `DefaultObservableMemoryCache`)
- LRU (Least Recently Used) eviction and per-entry TTL (time-to-live) expiry
- Combine publisher support for cache value changes and view model communication
- Protocol-oriented design to promote testability and separation of concerns
- Full test suite for cache correctness and edge cases

---

## 🧩 Protocols

### StateViewModel

A protocol for view models that expose a single, immutable state struct, and a publisher for observing state changes. Useful for SwiftUI or UIKit data binding.

**How it works:**
- Define a State struct with all view model state.
- Expose the state via a Published property and a statePublisher.
- Mutate state via methods. Observers react to changes via the publisher.

**Example:**
```
final class CounterViewModel: StateViewModel {
    struct State { var count: Int = 0 }
    @Published private(set) var state = State()
    var statePublisher: Published<State>.Publisher { $state }
    func increment() { state.count += 1 }
}

struct CounterView: View {
    @StateObject var viewModel = CounterViewModel()
    @State private var count = 0

    var body: some View {
        VStack {
            Text("Count: \(count)")
            Button("Increment") {
                viewModel.increment()
            }
        }
        .onReceive(viewModel.statePublisher) { state in
            self.count = state.count
        }
    }
}
```
---

### EventViewModel

A protocol for view models that publish transient events (navigation, alerts, side effects) via a Combine publisher. Complements StateViewModel for one-off or ephemeral events.

**How it works:**
- Define a ViewEvent enum for all possible events.
- Expose an eventPublisher (AnyPublisher<ViewEvent, Never>).
- Send events using a PassthroughSubject from methods.

**Example:**
```
// Define event types as structs conforming to ViewEvent
struct LoginSucceeded: ViewEvent {}
struct LoginFailed: ViewEvent { let message: String }

// ViewModel implementation
final class LoginViewModel: EventViewModel, ObservableObject {
    private let eventSubject = PassthroughSubject<ViewEvent, Never>()
    var eventPublisher: AnyPublisher<ViewEvent, Never> { eventSubject.eraseToAnyPublisher() }

    func login(username: String, password: String) {
        if username == "cat", password == "meow" {
            eventSubject.send(LoginSucceeded())
        } else {
            eventSubject.send(LoginFailed(message: "Invalid credentials"))
        }
    }
}

struct LoginView: View {
    @StateObject var viewModel = LoginViewModel()
    @State private var message: String? = nil

    var body: some View {
        VStack {
            Button("Login") {
                viewModel.login(username: "cat", password: "meow")
            }
            if let message {
                Text(message)
            }
        }
        .onReceive(viewModel.eventPublisher) { event in
            switch event {
            case is LoginSucceeded:
                message = "Welcome!"
            case let failure as LoginFailed:
                message = "Login failed: \(failure.message)"
            default:
                break
            }
        }
    }
}
```

---

## 📦 Observable Memory Cache

Cats provides a generic, thread-safe, LRU + TTL in-memory cache with Combine publisher support. Conforms to ObservableMemoryCache protocol.

**Features:**
- Generic key-value storage
- LRU eviction when exceeding max size
- Optional TTL (per-entry expiry)
- Per-key Combine publisher for observation
- Manual remove and clear
- Thread-safety

**Examples:**

**1. Set Up Repository to Use Cache**
```
final class WishlistRepository {

    private let cache: ObservableMemoryCache<String, Bool>

    init(cache: ObservableMemoryCache<String, Bool>) {
        self.cache = cache
    }

    func observeIsWishlisted(productID: String) -> AnyPublisher<Bool?, Never> {
        cache.publisher(for: productID)
    }

    func setIsWishlisted(_ value: Bool, for productID: String) {
        cache.put(productID, value: value)
    }
}
```

**2. Set Up Use Case to Use Repository**
```
init(repository: WishlistRepository) {
    self.repository = repository
}

func execute(productID: String) -> AnyPublisher<Bool?, Never> {
    repository
        .observeIsWishlisted(productID: productID)
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
}
```

**3. Set Up ViewModel to Use UseCase**

```
final class ProductWishlistViewModel: StateViewModel {

    @Published private(set) var isWishlisted: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private let observeIsWishlisted: ObserveProductIsWishlistedStateUseCase

    init(observeIsWishlisted: ObserveProductIsWishlistedStateUseCase, productID: String) {
        self.observeIsWishlisted = observeIsWishlisted
        observeWishlistedState(productID: productID)
    }

    private func observeWishlistedState(productID: String) {
        observeIsWishlisted.execute(productID: productID)
            .sink { [weak self] isWishlisted in
                self?.isWishlisted = isWishlisted ?? false
            }
            .store(in: &cancellables)
    }
}
```
