import Foundation
import CryptoKit

// The exported key is Sparkle's modern format: base64 of a 32-byte Ed25519 seed.
// CryptoKit implements standard Ed25519; no custom cryptography or dependencies.
func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
let args = CommandLine.arguments
if args.count != 6 { fail("Expected DMG, private-key file, mounted app, source plist, and appcast path.") }
let dmg = URL(fileURLWithPath: args[1])
let keyURL = URL(fileURLWithPath: args[2])
let app = URL(fileURLWithPath: args[3])
let source = URL(fileURLWithPath: args[4])
let output = URL(fileURLWithPath: args[5])
func plist(_ url: URL) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any] else {
        fail("Invalid release plist.")
    }
    return value
}
do {
    let info = try plist(app.appendingPathComponent("Contents/Info.plist"))
    let expected = try plist(source)
    guard let version = info["CFBundleVersion"] as? String,
          let shortVersion = info["CFBundleShortVersionString"] as? String,
          version == expected["CFBundleVersion"] as? String,
          shortVersion == expected["CFBundleShortVersionString"] as? String,
          info["CFBundleIdentifier"] as? String == "com.oscar.margherita",
          info["SUFeedURL"] as? String == expected["SUFeedURL"] as? String,
          info["SUEnableAutomaticChecks"] as? Bool == true,
          FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Sparkle").path)
    else { fail("The DMG is not the current Sparkle-enabled release. Rebuild it first.") }
    guard version.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else {
        fail("Version must contain only numbers and dots.")
    }
    let text = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: text), seed.count == 32 else { fail("Expected a Sparkle 32-byte private seed file.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard publicKey == expected["SUPublicEDKey"] as? String,
          publicKey == info["SUPublicEDKey"] as? String else {
        fail("Signing key does not match the app. Nothing was published.")
    }
    let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("Signature verification failed.") }
    let ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let document = try XMLDocument(contentsOf: output, options: [.nodeLoadExternalEntitiesNever])
    guard let channel = document.rootElement()?.elements(forName: "channel").first else { fail("Invalid appcast channel.") }
    // Replace this version, retaining older entries. No upload happens here.
    for item in channel.elements(forName: "item") {
        if item.elements(forLocalName: "version", uri: ns).first?.stringValue == version { item.detach() }
    }
    let item = XMLElement(name: "item")
    func child(_ name: String, _ value: String) { item.addChild(XMLElement(name: name, stringValue: value)) }
    child("title", "Margherita " + shortVersion)
    child("sparkle:version", version)
    child("sparkle:shortVersionString", shortVersion)
    child("sparkle:minimumSystemVersion", "13.0")
    let date = DateFormatter()
    date.locale = Locale(identifier: "en_US_POSIX")
    date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    child("pubDate", date.string(from: Date()))
    let enclosure = XMLElement(name: "enclosure")
    let attributes = ["url": "https://github.com/oscmo1/margherita/releases/download/v\(shortVersion)/Margherita-\(shortVersion).dmg",
                      "sparkle:edSignature": signature.base64EncodedString(),
                      "length": String(data.count), "type": "application/octet-stream"]
    for (name, value) in attributes { enclosure.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    item.addChild(enclosure)
    channel.insertChild(item, at: 0)
    try document.xmlData(options: .nodePrettyPrint).write(to: output, options: .atomic)
    print("Signed and verified Margherita \(shortVersion). Updated appcast.xml.")
    print("Upload this exact DMG to release v\(shortVersion), then upload appcast.xml to the repository main branch.")
    print("Keep the private key outside GitHub and back it up securely. Do not remake the DMG after signing.")
} catch { fail("Release signing failed: \(error.localizedDescription)") }
