//
//  EventViewModel.swift
//  Cats
//
//  Created by Josh Gallant on 12/07/2025.
//

import Combine

/// A protocol for view models that publish events to be observed by external components, such as views or coordinators.
///
/// Use this protocol when you want your view model to communicate one-off actions or effects (navigation, alerts, etc)
/// to interested observers. It is complementary to `StateViewModel`, which manages continuous state.
///
/// Example usage:
/// ```swift
/// final class LoginViewModel: EventViewModel {
///     enum ViewEvent { case loginSucceeded, loginFailed(String) }
///     private let eventSubject = PassthroughSubject<ViewEvent, Never>()
///     var eventPublisher: AnyPublisher<ViewEvent, Never> { eventSubject.eraseToAnyPublisher() }
///
///     func login(username: String, password: String) {
///         // ... on success:
///         eventSubject.send(.loginSucceeded)
///         // ... on failure:
///         eventSubject.send(.loginFailed("Invalid password"))
///     }
/// }
/// ```
public protocol EventViewModel: AnyObject {
    /// The type describing all possible events this view model can emit.
    associatedtype ViewEvent
    
    /// A publisher that emits view events.
    var eventPublisher: AnyPublisher<ViewEvent, Never> { get }
}
