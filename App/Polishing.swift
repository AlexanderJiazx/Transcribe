//
//  Polishing.swift
//  AlexTranscribeApp
//
//  Created by Alexander Jia on 2026-06-06.
//

import Foundation
import Playgrounds
import FoundationModels

#Playground {
    if #available(macOS 26.0, *) {
        let instructions = """
        Rewrite the sentence, remove filler word only.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "")
        print(response.content)
    } else {
        
    }
}
