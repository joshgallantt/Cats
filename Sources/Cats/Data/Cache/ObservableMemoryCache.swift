//
//  ObservableMemoryCache.swift
//  Cats
//
//  Created by Josh Gallant on 12/07/2025.
//


import Foundation
import Combine

public protocol ObservableMemoryCache {
    associatedtype Key: Hashable
    associatedtype Value
    
    func put(_ key: Key, value: Value)
    
    func get(_ key: Key) -> Value?
    
    func remove(_ key: Key)
    
    func clear()
    
    func allItems() -> [Key: Value]
    
    func publisher(for key: Key) -> AnyPublisher<Value?, Never>
}

