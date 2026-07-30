//
//  AuthGateView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 7/28/26.
//

import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject var supabaseService: SupabaseService
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var bleVM: BLEViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager

    var body: some View {
        Group {
            if supabaseService.isSignedIn {
                ContentView()
            } else {
                LoginView()
            }
        }
    }
}
