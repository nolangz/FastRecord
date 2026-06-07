import Foundation
import AVFoundation
import CoreAudio
import ScreenCaptureKit

// MARK: - 音频设备模型
struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID?
    
    static let defaultDevice = AudioDevice(
        id: "default", 
        name: "默认设备", 
        deviceID: nil
    )
}

// MARK: - 音频管理器
@MainActor
class AudioManager: ObservableObject {
    @Published var availableMicrophones: [AudioDevice] = []
    @Published var selectedMicrophone: AudioDevice = AudioDevice.defaultDevice
    @Published var isLoading = false
    
    // macOS版本检查
    private var supportsSCKMicrophone: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }
    
    init() {
        print("🎤 初始化音频管理器...")
        Task {
            await refreshMicrophoneDevices()
        }
    }
    
    // MARK: - 设备枚举
    func refreshMicrophoneDevices() async {
        print("🎤 刷新麦克风设备列表...")
        isLoading = true
        
        do {
            let devices = try await enumerateAudioInputDevices()
            await MainActor.run {
                self.availableMicrophones = [AudioDevice.defaultDevice] + devices
                // 如果当前选择的设备不在列表中，重置为默认
                if !self.availableMicrophones.contains(where: { $0.id == selectedMicrophone.id }) {
                    self.selectedMicrophone = AudioDevice.defaultDevice
                }
                self.isLoading = false
                print("✅ 找到 \(devices.count) 个麦克风设备")
            }
        } catch {
            await MainActor.run {
                print("❌ 枚举音频设备失败: \(error.localizedDescription)")
                self.availableMicrophones = [AudioDevice.defaultDevice]
                self.selectedMicrophone = AudioDevice.defaultDevice
                self.isLoading = false
            }
        }
    }
    
    private func enumerateAudioInputDevices() async throws -> [AudioDevice] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let devices = try self.getAudioInputDevices()
                    continuation.resume(returning: devices)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    nonisolated private func getAudioInputDevices() throws -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        // 获取所有音频设备数量
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法获取音频设备列表大小"
            ])
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        
        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法获取音频设备列表"
            ])
        }
        
        // 筛选输入设备
        for deviceID in deviceIDs {
            if let device = try? createAudioDevice(from: deviceID), isInputDevice(deviceID) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    nonisolated private func createAudioDevice(from deviceID: AudioDeviceID) throws -> AudioDevice {
        // 获取设备名称
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法获取设备名称大小"
            ])
        }
        
        var deviceName: Unmanaged<CFString>?
        status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceName
        )
        
        guard status == noErr, let deviceNameRef = deviceName?.takeRetainedValue(),
              let name = deviceNameRef as String? else {
            throw NSError(domain: "AudioError", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法获取设备名称"
            ])
        }
        
        return AudioDevice(
            id: String(deviceID),
            name: name,
            deviceID: deviceID
        )
    }
    
    nonisolated private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        return status == noErr && dataSize > 0
    }
    
    // MARK: - 设备选择
    func selectMicrophone(_ device: AudioDevice) {
        print("🎤 选择麦克风设备: \(device.name)")
        selectedMicrophone = device
    }
    
    // MARK: - SCK集成支持
    func getMicrophoneDeviceIDForSCK() -> String? {
        guard selectedMicrophone.id != AudioDevice.defaultDevice.id,
              let deviceID = selectedMicrophone.deviceID else {
            return nil  // 使用默认设备
        }
        return String(deviceID)
    }
    
    // MARK: - macOS版本适配
    func getRecommendedAudioConfiguration() -> AudioConfiguration {
        if supportsSCKMicrophone {
            return AudioConfiguration(
                method: .screenCaptureKit,
                description: "使用 ScreenCaptureKit 原生麦克风支持 (macOS 15+)"
            )
        } else {
            return AudioConfiguration(
                method: .avAudioEngine,
                description: "使用 AVAudioEngine 兼容方案 (macOS 13-14)"
            )
        }
    }
}

// MARK: - 音频配置模型
struct AudioConfiguration {
    enum Method {
        case screenCaptureKit  // macOS 15+
        case avAudioEngine     // macOS 13-14 兼容
    }
    
    let method: Method
    let description: String
}