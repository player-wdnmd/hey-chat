//
//  Item.swift
//  ChatMac
//
//  Created by T L on 2026/7/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
