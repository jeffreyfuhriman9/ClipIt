//
//  DeviceStatusView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/4/26.
//

import SwiftUI

struct DeviceStatusView: View {
    @ObservedObject var bleViewModel: BLEViewModel
    var showLabelOnly: Bool = false // Lets us customize it for smaller screens!

    var body: some View {
        HStack(spacing: 8) {
            // Connection Dot & Label
            HStack(spacing: 6) {
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundColor(bleViewModel.bleState.isConnected ? .green : .gray)
                
                Text(bleViewModel.bleState.isConnected ? "Clipit Button Connected" : bleViewModel.bleState.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            
            // Only show the battery if we are connected and showLabelOnly is false
            if bleViewModel.bleState.isConnected && !showLabelOnly {
                Spacer()
                
                if let batteryLevel = bleViewModel.remoteBatteryLevel {
                    HStack(spacing: 4) {
                        Text("\(batteryLevel)%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        // 🔋 Fixed System Icon Mapping Strings
                        Image(systemName: getBatteryIcon(for: batteryLevel))
                            .font(.system(size: 14))
                            .foregroundColor(getBatteryColor(for: batteryLevel))
                    }
                } else {
                    // Small loading wheel while waiting for the Arduino's first signal
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func getBatteryColor(for level: Int) -> Color {
        switch level {
        case ...20:   return .red     // Under 20% turns critical Red
        default:      return .primary   // White in Dark Mode, Black in Light
        }
    }

    private func getBatteryIcon(for level: Int) -> String {
        switch level {
        case ...10:   return "battery.0"
        case 11...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...85: return "battery.75"
        default:      return "battery.100"
        }
    }
}
