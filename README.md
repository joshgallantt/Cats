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
- Define an Event that conforms to ViewEvent protocol.
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
import Combine

final class WishlistRepository {
    private let cache: ObservableMemoryCache<String, Set<String>>
    private let service: WishlistService
    private let wishlistKey = "wishlist"

    init(cache: ObservableMemoryCache<String, Set<String>>, service: WishlistService) {
        self.cache = cache
        self.service = service
    }

    func observeIsWishlisted(productID: String) -> AnyPublisher<Bool, Never> {
        cache.publisher(for: wishlistKey)
            .map { ids in ids?.contains(productID) ?? false }
            .eraseToAnyPublisher()
    }

    func addToWishlist(productID: String) async throws {
        let updatedIDs = try await service.addProduct(productID: productID)
        cache.put(wishlistKey, value: Set(updatedIDs))
    }

    func removeFromWishlist(productID: String) async throws {
        let updatedIDs = try await service.removeProduct(productID: productID)
        cache.put(wishlistKey, value: Set(updatedIDs))
    }
}

```

**2. Set Up Use Cases to Use Repository**
```
struct ObserveProductInWishlistUseCase {
    private let repository: WishlistRepository
    init(repository: WishlistRepository) { self.repository = repository }

    func execute(productID: String) -> AnyPublisher<Bool, Never> {
        repository.observeIsWishlisted(productID: productID)
    }
}

struct AddProductToWishlistUseCase {
    private let repository: WishlistRepository
    init(repository: WishlistRepository) { self.repository = repository }

    func execute(productID: String) async throws {
        try await repository.addToWishlist(productID: productID)
    }
}

struct RemoveProductFromWishlistUseCase {
    private let repository: WishlistRepository
    init(repository: WishlistRepository) { self.repository = repository }

    func execute(productID: String) async throws {
        try await repository.removeFromWishlist(productID: productID)
    }
}

```

**3. Set Up ViewModel to Use UseCase**

```
import Combine

@MainActor
final class WishlistButtonViewModel: ObservableObject {
    @Published private(set) var isWishlisted: Bool = false

    private let productID: String
    private let observeProductInWishlist: ObserveProductInWishlistUseCase
    private let addProductToWishlist: AddProductToWishlistUseCase
    private let removeProductFromWishlist: RemoveProductFromWishlistUseCase

    private var cancellables = Set<AnyCancellable>()

    init(
        productID: String,
        observeProductInWishlist: ObserveProductInWishlistUseCase,
        addProductToWishlist: AddProductToWishlistUseCase,
        removeProductFromWishlist: RemoveProductFromWishlistUseCase
    ) {
        self.productID = productID
        self.observeProductInWishlist = observeProductInWishlist
        self.addProductToWishlist = addProductToWishlist
        self.removeProductFromWishlist = removeProductFromWishlist
        observeWishlistState()
    }

    private func observeWishlistState() {
        observeProductInWishlist.execute(productID: productID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isWishlisted in
                self?.isWishlisted = isWishlisted
            }
            .store(in: &cancellables)
    }

    func toggleWishlist() {
        let previousValue = isWishlisted
        isWishlisted.toggle()

        Task { @MainActor in
            do {
                if isWishlisted {
                    try await addProductToWishlist.execute(productID: productID)
                } else {
                    try await removeProductFromWishlist.execute(productID: productID)
                }
            } catch {
                isWishlisted = previousValue
            }
        }
    }
}

```
