//
//  DefaultObservableMemoryCache.swift
//  Cats
//
//  Created by Josh Gallant on 12/07/2025.
//

import Foundation
import Combine

/// An in-memory, thread-safe, generic cache with LRU eviction and optional global entry expiration.
/// Supports per-key value observation using Combine publishers.
///
/// Features:
/// - Generic key-value storage.
/// - Optional global TTL (time-to-live) for all entries.
/// - Maximum size limit with LRU (least-recently-used) eviction policy.
/// - Thread safety via `NSLock`. Safe for use from multiple threads.
/// - Per-key Combine publisher for observing value changes, removals, and expiry.
/// - Manual cache management (put, get, remove, clear).
/// - Easy extensibility: count, contains, future per-entry TTL, O(1) LRU.
///
public final class DefaultObservableMemoryCache<Key: Hashable, Value>: ObservableMemoryCache {

    // MARK: - Private properties

    /// Maximum number of items to retain in the cache. When set, exceeding this limit triggers LRU eviction.
    private var maxSize: Int = 500
    /// Optional global time-to-live (in seconds) for cache entries. If set, entries expire after this interval.
    private let expiresAfter: TimeInterval?
    /// Least-Recently-Used tracking. Most recently used key is at the end, and removed when maxSize is reached.
    private var LRUKeys: [Key] = []
    /// Backing storage for cache entries. Each entry tracks the value and its optional expiry date.
    private var storage: [Key: (value: Value, expiry: Date?)] = [:]
    /// Combine publishers for per-key value changes.
    private var subjects: [Key: CurrentValueSubject<Value?, Never>] = [:]
    /// Synchronizes access to all mutable state.
    private let lock = NSLock()

    // MARK: - Public API

    /// Initializes a new cache instance.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum cache size. When set, cache will not store more than `maxSize` items (LRU policy). Must be positive if provided.
    ///   - expiresAfter: Optional time-to-live (in seconds) for cache entries. When set, each entry expires after this interval. Must be positive if provided.
    public init(maxSize: Int? = 500, expiresAfter: TimeInterval? = nil) {
        if let size = maxSize, size > 0 {
            self.maxSize = size
        } else {
            self.maxSize = 500
        }
        if let expiresAfter, expiresAfter > 0 {
            self.expiresAfter = expiresAfter
        } else {
            self.expiresAfter = nil
        }
    }

    /// The current count of valid entries in the cache.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()

        for (key, entry) in storage {
            if let expiry = entry.expiry, expiry < now {
                storage[key] = nil
                LRUKeys.removeAll { $0 == key }
                subjects.removeValue(forKey: key)
            }
        }
        return storage.count
    }

    /// Returns true if the cache contains a value for the given key (non-expired).
    ///
    /// - Parameter key: The key to check.
    /// - Returns: `true` if present and not expired, else `false`.
    public func contains(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let entry = storage[key] {
            if let expiry = entry.expiry, expiry < Date() {
                return false
            }
            return true
        }
        return false
    }

    /// Inserts or updates a value for the given key.
    ///
    /// If `ttl` is configured, entry expires after the TTL interval.
    /// If cache is full (`maxSize`), oldest entry will be evicted.
    /// Notifies publisher for this key.
    public func put(_ key: Key, value: Value) {
        let expiry = expiresAfter.map { Date().addingTimeInterval($0) }
        var subject: CurrentValueSubject<Value?, Never>?
        lock.lock()
        storage[key] = (value, expiry)
        updateLRU_locked(for: key)
        subject = subjects[key]
        if subject == nil {
            let newSubject = CurrentValueSubject<Value?, Never>(value)
            subjects[key] = newSubject
            subject = newSubject
        }
        lock.unlock()
        subject?.send(value)
        lock.lock()
        evictIfNeeded_locked()
        lock.unlock()
    }

    /// Retrieves the value for the given key, if present and not expired.
    ///
    /// If expired, the entry is removed. Updates LRU order on successful get.
    /// Notifies publisher if expired.
    public func get(_ key: Key) -> Value? {
        var result: Value?
        var expiredSubject: CurrentValueSubject<Value?, Never>?
        lock.lock()
        if let entry = storage[key] {
            if let expiry = entry.expiry, expiry < Date() {
                storage[key] = nil
                LRUKeys.removeAll { $0 == key }
                expiredSubject = subjects[key]
                subjects.removeValue(forKey: key)
            } else {
                updateLRU_locked(for: key)
                result = entry.value
            }
        }
        lock.unlock()
        expiredSubject?.send(nil)
        return result
    }

    /// Removes the value for the given key from the cache.
    ///
    /// Notifies publisher for this key, if any, and removes publisher.
    public func remove(_ key: Key) {
        var removedSubject: CurrentValueSubject<Value?, Never>?
        lock.lock()
        storage[key] = nil
        LRUKeys.removeAll { $0 == key }
        removedSubject = subjects[key]
        subjects.removeValue(forKey: key)
        lock.unlock()
        removedSubject?.send(nil)
    }

    /// Returns a publisher that emits the current and future value changes for the specified key.
    ///
    /// Publisher sends the current value (or `nil`) on subscription, then emits on every change, removal, or expiry.
    /// Publisher is retained while the key exists, and is removed on key removal or expiry.
    ///
    /// - Important: If the key expires or is removed, subscribers receive `.send(nil)`. If you want to observe new values after re-insertion, resubscribe.
    public func publisher(for key: Key) -> AnyPublisher<Value?, Never> {
        lock.lock()
        let subject: CurrentValueSubject<Value?, Never>
        if let existing = subjects[key] {
            subject = existing
        } else {
            let value: Value? = {
                if let entry = storage[key], entry.expiry == nil || entry.expiry! >= Date() {
                    return entry.value
                } else {
                    return nil
                }
            }()
            subject = .init(value)
            subjects[key] = subject
        }
        lock.unlock()
        return subject.eraseToAnyPublisher()
    }

    /// Clears all entries from the cache, including all keys and publishers.
    ///
    /// Notifies all publishers with `nil`.
    public func clear() {
        var removedSubjects: [CurrentValueSubject<Value?, Never>] = []
        lock.lock()
        storage.removeAll()
        LRUKeys.removeAll()
        removedSubjects = Array(subjects.values)
        subjects.removeAll()
        lock.unlock()
        removedSubjects.forEach { $0.send(nil) }
    }

    /// Returns all valid, non-expired items currently in the cache.
    ///
    /// Expired items are removed during this call.
    public func allItems() -> [Key: Value] {
        var result: [Key: Value] = [:]
        var expiredSubjects: [CurrentValueSubject<Value?, Never>] = []
        let now = Date()
        lock.lock()
        for (key, entry) in storage {
            if let expiry = entry.expiry, expiry < now {
                storage[key] = nil
                LRUKeys.removeAll { $0 == key }
                if let expiredSubject = subjects[key] {
                    expiredSubjects.append(expiredSubject)
                }
                subjects.removeValue(forKey: key)
            } else {
                result[key] = entry.value
            }
        }
        lock.unlock()
        expiredSubjects.forEach { $0.send(nil) }
        return result
    }

    // MARK: - Private helpers

    /// Updates LRU order for the given key. Must be called with lock held.
    private func updateLRU_locked(for key: Key) {
        LRUKeys.removeAll { $0 == key }
        LRUKeys.append(key)
    }

    /// Evicts oldest keys if cache exceeds max size. Must be called with lock held.
    /// Extension point: Add eviction callback here if needed.
    private func evictIfNeeded_locked() {
        while LRUKeys.count > maxSize {
            let oldest = LRUKeys.removeFirst()
            storage.removeValue(forKey: oldest)
            if subjects.removeValue(forKey: oldest) != nil {
                // If you want eviction callbacks, send them here.
                // subject.send(nil) is intentionally not called here (see put/clear).
            }
        }
    }
}
