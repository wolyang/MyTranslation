//
//  Array+Extension.swift
//  MyTranslation
//
//  Created by sailor.m on 11/10/25.
//

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
