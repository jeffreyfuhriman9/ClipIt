//
//  AuthViewModel.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 7/28/26.
//

import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

    @Published var email = ""
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let supabase = SupabaseService.shared


    func signUp() async {
        isLoading = true
        errorMessage = nil

        do {
            try await supabase.signUp(
                email: email,
                password: password
            )

            errorMessage = "Account created! Check your email if confirmation is required."

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }


    func signIn() async {
        isLoading = true
        errorMessage = nil

        do {
            try await supabase.signIn(
                email: email,
                password: password
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
