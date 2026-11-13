import Testing
import Foundation
@testable import AppleSyncCore

@Suite("Step A Foundation Tests")
struct FoundationTests {
    @Test("EffectiveBundleID is deterministic and DNS-safe")
    func deterministicBundleID() {
        let a = EffectiveBundleID.make(teamID: "ABC123DEF4", originalBundleID: "com.friend.Cool App!")
        let b = EffectiveBundleID.make(teamID: "ABC123DEF4", originalBundleID: "com.friend.Cool App!")
        #expect(a == b)
        #expect(a.hasPrefix("com.applesync.abc123def4."))
        #expect(!a.contains(" "))
        #expect(!a.contains("!"))
    }

    @Test("DevicectlClient decodes v651.32 JSON schemas")
    func devicectlDecoding() async throws {
        let mock = MockCommandRunner { _, args, _, _, _ in
            if args.contains("list") {
                let json = """
                {
                  "result": {
                    "devices": [
                      {
                        "identifier": "CORE-123",
                        "properties": {
                          "hardware": {
                            "udid": "00000000-TEST-UDID",
                            "platform": "iOS",
                            "reality": "physical",
                            "marketingName": "iPhone Air"
                          },
                          "state": { "name": "My iPhone" },
                          "connection": {
                            "pairingState": "paired",
                            "transportType": "localNetwork",
                            "state": "disconnected"
                          }
                        }
                      }
                    ]
                  }
                }
                """
                return ProcessOutput(exitCode: 0, stdoutData: Data(json.utf8), stderrData: Data())
            } else if args.contains("lockState") {
                let json = """
                { "result": { "deviceIdentifier": "CORE-123", "passcodeRequired": false, "unlockedSinceBoot": true } }
                """
                return ProcessOutput(exitCode: 0, stdoutData: Data(json.utf8), stderrData: Data())
            }
            return ProcessOutput(exitCode: 0, stdoutData: Data("{\"result\":{}}".utf8), stderrData: Data())
        }
        let client = DevicectlClient(runner: mock)
        let devices = try await client.listDevices()
        #expect(devices.count == 1)
        #expect(devices[0].udid == "00000000-TEST-UDID")
        #expect(devices[0].isPhysicaliOSDevice)
        #expect(devices[0].isPaired)

        let lock = try await client.lockState(deviceIdentifier: "CORE-123")
        #expect(lock.passcodeRequired == false)
        #expect(lock.unlockedSinceBoot == true)
    }

    @Test("SystemProcessRunner executes command cleanly")
    func processRunnerWorks() async throws {
        let runner = SystemProcessRunner()
        let out = try await runner.run("/bin/echo", arguments: ["applesync-ok"])
        #expect(out.exitCode == 0)
        #expect(out.stdoutString == "applesync-ok")
    }
}

struct MockCommandRunner: CommandRunning {
    let handler: @Sendable (String, [String], URL?, [String: String]?, TimeInterval) async throws -> ProcessOutput

    func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        try await handler(executable, arguments, currentDirectory, environment, timeout)
    }
}
