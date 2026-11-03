import Foundation
import XCTest
@testable import iADB

/// The SSDP wire format is easy to get subtly wrong — headers are
/// case-insensitive, line endings vary between firmwares, and the description
/// document is hand-rolled XML. These cover the parsing without a network.
final class SSDPTests: XCTestCase {
    private func datagram(_ lines: [String], terminator: String = "\r\n") -> Data {
        Data((lines.joined(separator: terminator) + terminator + terminator).utf8)
    }

    func testParsesATypicalDialResponse() throws {
        let data = datagram([
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "LOCATION: http://192.168.43.1:60000/ssdp/device-desc.xml",
            "SERVER: Linux/4.9 UPnP/1.0 Cling/2.0",
            "ST: urn:dial-multiscreen-org:service:dial:1",
            "USN: uuid:6f4c1a12::urn:dial-multiscreen-org:service:dial:1",
        ])

        let response = try XCTUnwrap(SSDPResponse.parse(data))
        XCTAssertEqual(response.statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(
            response.headers["location"],
            "http://192.168.43.1:60000/ssdp/device-desc.xml"
        )
        XCTAssertEqual(
            response.headers["st"],
            "urn:dial-multiscreen-org:service:dial:1"
        )
        XCTAssertEqual(response.headers["server"], "Linux/4.9 UPnP/1.0 Cling/2.0")
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let data = datagram([
            "HTTP/1.1 200 OK",
            "Location: http://10.0.0.1:8080/d.xml",
            "St: ssdp:all",
        ])

        let response = try XCTUnwrap(SSDPResponse.parse(data))
        XCTAssertEqual(response.headers["location"], "http://10.0.0.1:8080/d.xml")
        XCTAssertEqual(response.headers["st"], "ssdp:all")
    }

    func testToleratesBareLineFeedLineEndings() throws {
        let data = datagram([
            "HTTP/1.1 200 OK",
            "LOCATION: http://192.168.1.9:49152/desc.xml",
        ], terminator: "\n")

        let response = try XCTUnwrap(SSDPResponse.parse(data))
        XCTAssertEqual(response.headers["location"], "http://192.168.1.9:49152/desc.xml")
    }

    func testRejectsTrafficThatIsNotAnSSDPResponse() {
        XCTAssertNil(SSDPResponse.parse(Data("NOTIFY * HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(SSDPResponse.parse(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(SSDPResponse.parse(Data()))
    }

    func testMSearchCarriesTheRequiredHeaders() {
        let message = SSDPDiscovery.mSearch(target: "ssdp:all", mx: 2)

        XCTAssertTrue(message.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        XCTAssertTrue(message.contains("HOST: 239.255.255.250:1900\r\n"))
        // The quotes around ssdp:discover are mandatory; devices ignore the
        // search without them.
        XCTAssertTrue(message.contains("MAN: \"ssdp:discover\"\r\n"))
        XCTAssertTrue(message.contains("MX: 2\r\n"))
        XCTAssertTrue(message.contains("ST: ssdp:all\r\n"))
        XCTAssertTrue(message.hasSuffix("\r\n\r\n"))
    }

    func testDescriptionFriendlyNameIsPreferredOverModelName() {
        let service = SSDPService(
            host: "192.168.43.1",
            searchTarget: "ssdp:all",
            usn: "",
            server: nil,
            location: nil,
            friendlyName: "Living Room TV",
            modelName: "XR-75A80L"
        )

        XCTAssertEqual(service.displayName, "Living Room TV")
    }

    func testDescriptionFallsBackToModelName() {
        let service = SSDPService(
            host: "192.168.43.1",
            searchTarget: "ssdp:all",
            usn: "",
            server: nil,
            location: nil,
            friendlyName: "",
            modelName: "KD-55X85J"
        )

        XCTAssertEqual(service.displayName, "KD-55X85J")
    }

    func testDescriptionWithoutAnyNameReportsNil() {
        let service = SSDPService(
            host: "192.168.43.1",
            searchTarget: "ssdp:all",
            usn: "",
            server: nil,
            location: nil
        )

        XCTAssertNil(service.displayName)
    }

    func testTagValueReadsFriendlyName() {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>BRAVIA 4K</friendlyName>
            <modelName>XR-75A80L</modelName>
          </device>
        </root>
        """

        XCTAssertEqual(SSDPDiscovery.tagValue("friendlyName", in: xml), "BRAVIA 4K")
        XCTAssertEqual(SSDPDiscovery.tagValue("modelName", in: xml), "XR-75A80L")
    }

    func testTagValueTrimsSurroundingWhitespace() {
        let xml = "<device><friendlyName>\n   Car Head Unit\n </friendlyName></device>"
        XCTAssertEqual(SSDPDiscovery.tagValue("friendlyName", in: xml), "Car Head Unit")
    }

    func testTagValueRejectsEmptyAndMalformedDocuments() {
        XCTAssertNil(SSDPDiscovery.tagValue("friendlyName", in: "<device></device>"))
        XCTAssertNil(SSDPDiscovery.tagValue("friendlyName", in: "<friendlyName>   </friendlyName>"))
        // Unterminated element: no closing tag to cut at.
        XCTAssertNil(SSDPDiscovery.tagValue("friendlyName", in: "<friendlyName>oops"))
    }

    func testEveryDiscoverySourceHasALabel() {
        let sources: [DiscoverySource] = [.bonjour, .ssdp, .probe, .manual]
        for source in sources {
            XCTAssertFalse(source.label.isEmpty, "\(source) has no label")
        }
    }
}
