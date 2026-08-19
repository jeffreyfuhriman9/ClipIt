//
//  KeepScreenAwakeModifier.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 7/30/26.
//

import SwiftUI

/// View modifier that disables system auto-lock while the view is present or while a condition is met.
struct KeepScreenAwakeModifier: ViewModifier {
    let keepAwake: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                if keepAwake {
                    setIdleTimerDisabled(true)
                }
            }
            .onDisappear {
                // Always restore standard auto-lock when leaving the view
                setIdleTimerDisabled(false)
            }
            .onChange(of: keepAwake) { oldValue, newValue in
                UIApplication.shared.isIdleTimerDisabled = newValue
            }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        // Must be executed on the main thread
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = disabled
            print("📱 System idle timer disabled (screen forced awake): \(disabled)")
        }
    }
}

extension View {
    /// Forces the iPhone screen to stay awake and override auto-lock/dimming.
    /// - Parameter keepAwake: Pass `true` or a recording state boolean (defaults to `true`).
    func keepScreenAwake(_ keepAwake: Bool = true) -> some View {
        self.modifier(KeepScreenAwakeModifier(keepAwake: keepAwake))
    }
}
