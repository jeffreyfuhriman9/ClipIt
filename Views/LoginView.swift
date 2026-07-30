//
//  LoginView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 7/28/26.
//

import SwiftUI

struct LoginView: View {

    @StateObject private var viewModel = AuthViewModel()

    var body: some View {

        VStack(spacing: 20) {

            Text("Welcome to ClipIt")
                .font(.largeTitle)
                .bold()

            TextField("Email", text: $viewModel.email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)

            SecureField("Password", text: $viewModel.password)
                .textFieldStyle(.roundedBorder)


            Button("Create Account") {
                Task {
                    await viewModel.signUp()
                }
            }


            Button("Login") {
                Task {
                    await viewModel.signIn()
                }
            }


            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundColor(.red)
            }

        }
        .padding()
    }
}
