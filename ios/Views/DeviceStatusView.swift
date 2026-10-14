//
//  DeviceStatusView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/4/26.
//

import SwiftUI

struct DeviceStatusView: View {
    @ObservedObject var bleViewModel: BLEViewModel
    var showLabelOnly: Bool = false // Let's us customize it for smaller screens!

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
            
            // Only show the battery if we are connected and have data
            if bleViewModel.bleState.isConnected {
                if let batteryLevel = bleViewModel.remoteBatteryLevel {
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Text("\(batteryLevel)%")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        Image(systemName: getBatteryIcon(for: batteryLevel))
                            .font(.system(size: 14))
                            .foregroundColor(getBatteryColor(for: batteryLevel))
                    }
                } else {
                    Spacer()
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
        level <= 20 ? .red : .green
    }

    private func getBatteryIcon(for level: Int) -> String {
        switch level {
        case ...10:   return "battery.0percent"
        case 11...35:  return "battery.25percent"
        case 36...65:  return "battery.50percent"
        case 66...85:  return "battery.75percent"
        default:       return "battery.100percent"
        }
    }
}
