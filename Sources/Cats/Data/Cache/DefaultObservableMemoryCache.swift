//
//  DefaultObservableMemoryCache.swift
//  Cats
//
//  Created by Josh Gallant on 12/07/2025.
//

import Foundation
import Combine

/// An in-memory, thread-safe, generic cache with size limit (LRU eviction) and entry expiration (TTL expiry).
/// Supports per-key value observation using Combine publishers.
///
/// Features:
/// - Generic key-value storage.
/// - Optional maximum size (LRU eviction).
/// - Optional per-entry TTL (time-to-live).
/// - Thread safety with NSLock.
/// - Combine publisher for value changes per key.
/// - Manual cache and expiry management.
public final class DefaultObservableMemoryCache<Key: Hashable, Value>: ObservableMemoryCache, @unchecked Sendable {
    
    // MARK: - Private properties

    /// Maximum number of items to retain in the cache. When set, exceeding this limit triggers LRU eviction.
    private var maxSize: Int = 500
    /// Optional time-to-live (in seconds) for cache entries. If set, entries expire after this interval.
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
    public init(maxSize: Int? = nil, expiresAfter: TimeInterval? = nil) {
        if let size = maxSize, size > 0 {
            self.maxSize = size
        } else {
            if let _ = maxSize {
                print("Warning: maxSize must be positive, ignoring provided value and defaulting to 500.")
            }
            self.maxSize = 500
        }

        if let expiresAfter, expiresAfter > 0 {
            self.expiresAfter = expiresAfter
        } else {
            if let _ = expiresAfter {
                print("Warning: expiresAfter must be positive, ignoring provided value. Defaulting to no expiration.")
            }
            self.expiresAfter = nil
        }
    }

    /// Inserts or updates a value for the given key.
    ///
    /// - Parameters:
    ///   - key: The key to store.
    ///   - value: The value to store.
    ///
    /// If `ttl` is configured, entry expires after the TTL interval.
    /// If cache is full (`maxSize`), oldest entry will be evicted.
    /// Notifies publisher for this key.
    public func put(_ key: Key, value: Value) {
        let expiry = expiresAfter.map { Date().addingTimeInterval($0) }
        lock.lock()
        defer { lock.unlock() }
        storage[key] = (value, expiry)
        updateLRU_locked(for: key)
        subjects[key, default: .init(nil)].send(value)
        evictIfNeeded_locked()
    }

    /// Retrieves the value for the given key, if present and not expired.
    ///
    /// - Parameter key: The key to retrieve.
    /// - Returns: The value for the key, or `nil` if not present or expired.
    ///
    /// If expired, the entry is removed. Updates LRU order on successful get.
    /// Notifies publisher if expired.
    public func get(_ key: Key) -> Value? {
        var result: Value?
        modify(key) { slot in
            guard let entry = slot else { return }
            if let expiry = entry.expiry, expiry < Date() {
                slot = nil
                LRUKeys.removeAll { $0 == key }
                subjects[key]?.send(nil)
                subjects.removeValue(forKey: key)
            } else {
                updateLRU_locked(for: key)
                result = entry.value
            }
        }
        return result
    }

    /// Removes the value for the given key from the cache.
    ///
    /// - Parameter key: The key to remove.
    ///
    /// Notifies publisher for this key, if any, and removes publisher.
    public func remove(_ key: Key) {
        modify(key) { slot in
            slot = nil
            LRUKeys.removeAll { $0 == key }
            subjects[key]?.send(nil)
            subjects.removeValue(forKey: key)
        }
    }

    /// Returns a publisher that emits the current and future value changes for the specified key.
    ///
    /// - Parameter key: The key to observe.
    /// - Returns: An `AnyPublisher<Value?, Never>` that emits when the value changes, is set, or is removed.
    ///
    /// Publisher sends the current value (or `nil`) on subscription, then emits on every change, removal, or expiry.
    /// Publisher is retained while the key exists, and is removed on key removal or expiry.
    public func publisher(for key: Key) -> AnyPublisher<Value?, Never> {
        lock.lock()
        defer { lock.unlock() }
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
        return subject.eraseToAnyPublisher()
    }

    /// Clears all entries from the cache, including all keys and publishers.
    ///
    /// Notifies all publishers with `nil`.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        LRUKeys.removeAll()
        subjects.forEach { $0.value.send(nil) }
        subjects.removeAll()
    }

    /// Returns all valid, non-expired items currently in the cache.
    ///
    /// - Returns: A dictionary of all keys and their associated values.
    ///
    /// Expired items are removed during this call.
    public func allItems() -> [Key: Value] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Key: Value] = [:]
        let now = Date()
        for (key, entry) in storage {
            if let expiry = entry.expiry, expiry < now {
                storage[key] = nil
                LRUKeys.removeAll { $0 == key }
                subjects[key]?.send(nil)
                subjects.removeValue(forKey: key)
                continue
            }
            result[key] = entry.value
        }
        return result
    }

    // MARK: - Private helpers

    /// Helper for atomic, thread-safe mutation of a single entry.
    /// - Parameters:
    ///   - key: The key whose entry will be mutated.
    ///   - block: Closure that mutates the slot (value, expiry) for the key.
    private func modify(_ key: Key, _ block: (inout (value: Value, expiry: Date?)?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        block(&storage[key])
    }

    /// Updates LRU order for the given key. Must be called with lock held.
    private func updateLRU_locked(for key: Key) {
        LRUKeys.removeAll { $0 == key }
        LRUKeys.append(key)
    }

    /// Evicts oldest keys if cache exceeds max size. Must be called with lock held.
    private func evictIfNeeded_locked() {
        guard LRUKeys.count > maxSize else { return }
        while LRUKeys.count > maxSize {
            let oldest = LRUKeys.removeFirst()
            storage.removeValue(forKey: oldest)
            subjects[oldest]?.send(nil)
            subjects.removeValue(forKey: oldest)
        }
    }
}

