import XCTest
@testable import Tono

@MainActor
final class ContactsAccessTests: XCTestCase {
    private final class MockContactsStore: ContactsStoreProviding {
        var status: TonoContactsAuthorization
        var requestResult: Bool
        var recipients: [Recipient]
        var requestCount = 0

        init(
            status: TonoContactsAuthorization,
            requestResult: Bool = true,
            recipients: [Recipient] = []
        ) {
            self.status = status
            self.requestResult = requestResult
            self.recipients = recipients
        }

        func authorizationStatus() -> TonoContactsAuthorization { status }

        func requestAccess() async throws -> Bool {
            requestCount += 1
            status = requestResult ? .full : .denied
            return requestResult
        }

        func fetchRecipients() throws -> [Recipient] { recipients }
    }

    override func setUp() {
        super.setUp()
        SharedStore.defaults.removeObject(forKey: SharedKeys.recipients)
    }

    override func tearDown() {
        SharedStore.defaults.removeObject(forKey: SharedKeys.recipients)
        super.tearDown()
    }

    func testOneShotAuthorizationUsesInjectedStoreAndRefreshesStatus() async {
        let store = MockContactsStore(status: .notRequested)
        let model = ContactsAccessModel(store: store)

        await model.requestSystemAccess()
        await model.requestSystemAccess()

        XCTAssertEqual(model.status, .full)
        XCTAssertEqual(store.requestCount, 1)
    }

    func testLimitedReviewFetchesOnlySyntheticAccessibleRecipients() {
        let synthetic = Recipient(label: "Synthetic Alex", voiceHint: "Design at Example", contactIdentifier: "contact-1")
        let store = MockContactsStore(status: .limited, recipients: [synthetic])
        let model = ContactsAccessModel(store: store)

        model.prepareImportReview()

        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertEqual(model.candidates.first?.contactIdentifier, "contact-1")
    }

    func testImportDeduplicatesStableContactIdentifierWithoutDeletingMemory() {
        let manual = Recipient(label: "Mom", voiceHint: "warm")
        RecipientMemory.save([manual])
        let first = Recipient(label: "Alex", contactIdentifier: "contact-1")
        let renamedSameContact = Recipient(label: "Alexander", contactIdentifier: "contact-1")

        XCTAssertEqual(RecipientMemory.importContacts([first, renamedSameContact]), 1)
        let saved = RecipientMemory.all()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.contains(where: { $0.id == manual.id }))
        XCTAssertEqual(saved.filter { $0.contactIdentifier == "contact-1" }.count, 1)
    }

    func testLegacyRecipientPayloadDecodesWithoutContactIdentifier() throws {
        let id = UUID()
        let data = """
        [{"id":"\(id.uuidString)","label":"Legacy","preferSafer":false}]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([Recipient].self, from: data)

        XCTAssertNil(decoded.first?.contactIdentifier)
    }
}
