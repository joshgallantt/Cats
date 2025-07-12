//
//  DefaultObservableMemoryCacheTests.swift
//  Cats
//
//  Created by Josh Gallant on 12/07/2025.
//


import XCTest
import Combine

@testable import Cats

final class DefaultObservableMemoryCacheTests: XCTestCase {
    typealias Cache = DefaultObservableMemoryCache<String, Int>
    var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Initialization and Defaults

    func test_whenCacheIsCreated_thenItIsEmpty() {
        let cache = Cache()
        XCTAssertTrue(cache.allItems().isEmpty, "A newly created cache should be empty.")
    }

    func test_givenDefaultCache_whenPut_thenItemCanBeRetrieved() {
        let cache = Cache()
        cache.put("a", value: 1)
        XCTAssertEqual(cache.get("a"), 1, "Should retrieve the value just inserted.")
        XCTAssertGreaterThanOrEqual(cache.allItems().count, 1, "allItems should contain at least the inserted item.")
    }

    func test_givenMaxSizeAndTTL_whenPut_thenItemIsStored() {
        let cache = Cache(maxSize: 2, expiresAfter: 10)
        cache.put("a", value: 1)
        XCTAssertEqual(cache.get("a"), 1, "Item should be retrievable within size/TTL constraints.")
        XCTAssertEqual(cache.allItems(), ["a": 1], "allItems should match inserted content exactly.")
    }

    func test_givenInvalidInitParams_whenPut_thenCacheStoresItem() {
        let cache = Cache(maxSize: 0, expiresAfter: -2)
        cache.put("a", value: 1)
        XCTAssertEqual(cache.get("a"), 1, "Should store and retrieve value even with invalid params.")
        XCTAssertEqual(cache.allItems(), ["a": 1], "allItems should show the item inserted even for invalid params.")
    }

    // MARK: - Edge Parameter Cases

    func test_givenZeroMaxSize_whenPut_thenCacheUsesDefault() {
        let cache = Cache(maxSize: 0)
        cache.put("a", value: 1)
        XCTAssertEqual(cache.get("a"), 1, "Cache with maxSize 0 should fallback to default (500) and store values.")
    }

    func test_givenNegativeMaxSize_whenPut_thenCacheUsesDefault() {
        let cache = Cache(maxSize: -1)
        cache.put("a", value: 1)
        XCTAssertEqual(cache.get("a"), 1, "Cache with negative maxSize should fallback to default (500) and store values.")
    }

    // MARK: - Put, Overwrite, Remove

    func test_givenKeyExists_whenPutWithSameKey_thenValueIsOverwritten() {
        let cache = Cache()
        cache.put("a", value: 1)
        cache.put("a", value: 2)
        XCTAssertEqual(cache.get("a"), 2, "Value for a key should be overwritten on repeated put.")
    }

    func test_givenKeyExists_whenRemoveIsCalled_thenKeyIsNoLongerPresent() {
        let cache = Cache()
        cache.put("a", value: 1)
        cache.remove("a")
        XCTAssertNil(cache.get("a"), "Removed key should return nil.")
    }

    func test_givenKeyDoesNotExist_whenRemove_thenNoCrashAndNil() {
        let cache = Cache()
        XCTAssertNoThrow(cache.remove("ghost"), "Removing non-existing key should not crash.")
        XCTAssertNil(cache.get("ghost"), "Getting non-existing key should always return nil.")
    }

    // MARK: - Clear

    func test_givenCacheHasItems_whenClear_thenAllItemsAreRemoved() {
        let cache = Cache()
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.clear()
        XCTAssertTrue(cache.allItems().isEmpty, "Cache should be empty after clear.")
        XCTAssertNil(cache.get("a"), "Cleared key should return nil.")
        XCTAssertNil(cache.get("b"), "Cleared key should return nil.")
    }

    // MARK: - TTL Expiry

    func test_givenShortTTL_whenTTLExpires_thenEntryIsRemoved() {
        let cache = Cache(expiresAfter: 0.01)
        cache.put("temp", value: 123)
        let exp = expectation(description: "wait for TTL expiry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            XCTAssertNil(cache.get("temp"), "Entry should be nil after TTL expires.")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    @MainActor
    func test_putExistingKey_resetsTTL() {
        let cache = Cache(expiresAfter: 0.05)
        cache.put("a", value: 1)
        let mid = expectation(description: "Second put (refresh TTL)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            cache.put("a", value: 2)
            mid.fulfill()
        }
        wait(for: [mid], timeout: 0.1)
        let exp = expectation(description: "Key should exist after TTL refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            XCTAssertEqual(cache.get("a"), 2, "TTL should reset on put for existing key.")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 0.2)
    }

    func test_getExpiredEntry_removesEntry() {
        let cache = Cache(expiresAfter: 0.001)
        cache.put("a", value: 1)
        let exp = expectation(description: "expire and get")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            XCTAssertNil(cache.get("a"), "Expired entry should return nil and be removed from cache.")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func test_allItems_removesExpiredEntries() {
        let cache = Cache(expiresAfter: 0.001)
        cache.put("a", value: 1)
        let exp = expectation(description: "expired entries are cleaned from allItems")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            XCTAssertTrue(cache.allItems().isEmpty, "Expired entries should not appear in allItems.")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - LRU Eviction

    func test_whenCacheIsFull_thenEvictsLeastRecentlyUsed() {
        let cache = Cache(maxSize: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        cache.put("c", value: 3) // Should evict "a"
        XCTAssertNil(cache.get("a"), "Cache should evict LRU ('a') after overflow.")
        XCTAssertEqual(cache.get("b"), 2, "Cache should retain non-LRU entries after eviction.")
        XCTAssertEqual(cache.get("c"), 3, "Cache should store new value after eviction.")
    }

    func test_LRUOrderUpdatesOnGet() {
        let cache = Cache(maxSize: 2)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        _ = cache.get("a") // Now 'a' is most recent
        cache.put("c", value: 3) // Should evict 'b'
        XCTAssertEqual(cache.get("a"), 1, "Recently accessed item should not be evicted.")
        XCTAssertNil(cache.get("b"), "Least recently used should be evicted after put.")
        XCTAssertEqual(cache.get("c"), 3, "New item should be present after eviction.")
    }

    // MARK: - Publisher Contract

    func test_publisherForUnsetKey_emitsNilImmediately() {
        let cache = Cache()
        let exp = expectation(description: "Publisher emits nil for unset key")
        cache.publisher(for: "ghost")
            .sink { value in
                if value == nil { exp.fulfill() }
            }
            .store(in: &cancellables)
        wait(for: [exp], timeout: 1)
    }

    @MainActor
    func test_publisher_emitsOnPutAndRemove() {
        let cache = Cache()
        let expSet = expectation(description: "publisher emits on set")
        let expRemove = expectation(description: "publisher emits nil on remove")
        var events: [Int?] = []
        cache.publisher(for: "k")
            .sink { value in
                events.append(value)
                if value == 10 { expSet.fulfill() }
                if value == nil && events.contains(10) { expRemove.fulfill() }
            }
            .store(in: &cancellables)
        cache.put("k", value: 10)
        cache.remove("k")
        wait(for: [expSet, expRemove], timeout: 1)
        XCTAssertEqual(events, [nil, 10, nil], "Publisher should emit [nil, 10, nil] for unset, set, remove.")
    }

    @MainActor
    func test_publisher_emitsOnExpiry() {
        let cache = Cache(expiresAfter: 0.01)
        let expSet = expectation(description: "publisher emits on set")
        let expExpire = expectation(description: "publisher emits nil on expiry")
        var events: [Int?] = []
        cache.publisher(for: "k")
            .sink { value in
                events.append(value)
                if value == 99 { expSet.fulfill() }
                if value == nil && events.contains(99) { expExpire.fulfill() }
            }
            .store(in: &cancellables)
        cache.put("k", value: 99)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            _ = cache.get("k")
        }
        wait(for: [expSet, expExpire], timeout: 2)
        XCTAssertTrue(events.contains(99), "Publisher should emit value before expiry.")
        XCTAssertTrue(events.contains(nil), "Publisher should emit nil after expiry.")
    }

    @MainActor
    func test_clear_emitsNilForAllActivePublishers() {
        let cache = Cache()
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        let expA = expectation(description: "A publisher emits nil")
        let expB = expectation(description: "B publisher emits nil")
        cache.publisher(for: "a").sink { if $0 == nil { expA.fulfill() } }.store(in: &cancellables)
        cache.publisher(for: "b").sink { if $0 == nil { expB.fulfill() } }.store(in: &cancellables)
        cache.clear()
        wait(for: [expA, expB], timeout: 1)
    }

    @MainActor
    func test_removeExpiredKey_shouldNotCrashAndPublisherEmitsNil() {
        let cache = Cache(expiresAfter: 0.01)
        let exp = expectation(description: "Publisher emits nil for expired key removal")
        cache.put("a", value: 1)
        cache.publisher(for: "a")
            .sink { value in
                if value == nil { exp.fulfill() }
            }
            .store(in: &cancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            cache.remove("a")
        }
        wait(for: [exp], timeout: 1)
    }

    @MainActor
    func test_publisherInitialValueIsCurrent() {
        let cache = Cache()
        cache.put("b", value: 42)
        let exp = expectation(description: "Publisher emits current value immediately")
        cache.publisher(for: "b")
            .sink { value in
                if value == 42 { exp.fulfill() }
            }
            .store(in: &cancellables)
        wait(for: [exp], timeout: 1)
    }

    @MainActor
    func test_publisherHandlesMultipleKeysIndependently() {
        let cache = Cache()
        let expA = expectation(description: "A emits")
        let expB = expectation(description: "B emits")
        cache.publisher(for: "a")
            .sink { value in if value == 1 { expA.fulfill() } }
            .store(in: &cancellables)
        cache.publisher(for: "b")
            .sink { value in if value == 2 { expB.fulfill() } }
            .store(in: &cancellables)
        cache.put("a", value: 1)
        cache.put("b", value: 2)
        wait(for: [expA, expB], timeout: 1)
    }

    // MARK: - Concurrency

    func test_concurrentPuts_shouldNotCrashAndFinalValueIsDeterministic() {
        let cache = Cache()
        let group = DispatchGroup()
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async { [cache] in
                cache.put("a", value: i)
                group.leave()
            }
        }
        group.wait()
        let value = cache.get("a")
        XCTAssert((0..<100).contains(value ?? -1), "Final value after concurrent puts should be one of the values put.")
    }
}

