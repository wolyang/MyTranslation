//
//  RouterCancellationCenter.swift
//  MyTranslation
//
//  Created by sailor.m on 10/27/25.
//

import Foundation

final class RouterCancellationCenter {
    static let shared = RouterCancellationCenter()
    private let lock = NSLock()
    private var bags: [String: CancellationBag] = [:]

    func bag(for runID: String) -> CancellationBag {
        lock.lock(); defer { lock.unlock() }
        if let b = bags[runID] { return b }
        let b = CancellationBag()
        bags[runID] = b
        return b
    }

    func remove(runID: String) {
        lock.lock(); bags.removeValue(forKey: runID); lock.unlock()
    }

    func cancel(runID: String) {
        let bag = bag(for: runID)
        bag.cancelAll()
        remove(runID: runID)
    }
}

final class CancellationBag {
    private let lock = NSLock()
    private var cancels: [() -> Void] = []

    func insert(_ cancel: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(cancel)
    }

    func cancelAll() {
        lock.lock(); let toCall = cancels; cancels.removeAll(); lock.unlock()
        toCall.forEach { $0() }
    }
}
