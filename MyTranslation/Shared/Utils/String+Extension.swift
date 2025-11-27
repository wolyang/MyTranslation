//
//  String+Extension.swift
//  MyTranslation
//
//  Created by sailor.m on 11/14/25.
//

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
