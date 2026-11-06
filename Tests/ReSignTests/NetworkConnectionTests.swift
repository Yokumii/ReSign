import XCTest
@testable import ReSign

final class NetworkConnectionTests: XCTestCase {
    func testNumericAddressesAndClearingConfiguration() throws {
        XCTAssertNil(try DeviceService.validatedNetworkAddress("  \n"))
        XCTAssertEqual(try DeviceService.validatedNetworkAddress(" 10.29.31.172\n"), "10.29.31.172")
        XCTAssertEqual(try DeviceService.validatedNetworkAddress("192.168.1.20"), "192.168.1.20")
        XCTAssertEqual(try DeviceService.validatedNetworkAddress("fd12::1234"), "fd12::1234")
    }

    func testRejectsURLsHostnamesPortsAndNonUnicastAddresses() {
        for address in ["iphone.local", "https://10.29.31.172", "10.29.31.172:62078",
                        "10.29.31.172/16", "999.1.1.1", "0.0.0.0", "127.0.0.1",
                        "224.0.0.251", "255.255.255.255", "::", "::1", "ff02::fb",
                        "fe80::1234", "fe80::1234%en0", "::ffff:127.0.0.1"] {
            XCTAssertThrowsError(try DeviceService.validatedNetworkAddress(address), address)
        }
    }

    func testLegacyDeviceRecordDoesNotRequireAnAddress() throws {
        let data = Data(#"{"id":"paired-device","name":"iPhone","lastSeen":0}"#.utf8)
        let device = try JSONDecoder().decode(RememberedDevice.self, from: data)
        XCTAssertEqual(device.id, "paired-device")
        XCTAssertNil(device.networkAddress)
    }

    func testNetworkAddressSurvivesLibrarySaveAndCanBeCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var library = Library()
        library.devices = [RememberedDevice(id: "paired-device", name: "iPhone", lastSeen: Date(),
                                            networkAddress: "10.29.31.172")]
        try store.save(library)
        var restored = try store.load()
        XCTAssertEqual(restored.devices.first?.networkAddress, "10.29.31.172")
        restored.devices[0].networkAddress = nil
        try store.save(restored)
        XCTAssertNil(try store.load().devices.first?.networkAddress)
    }
}
