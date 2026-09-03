#!/usr/bin/env swift
import Contacts
import Foundation

private let maxInputBytes = 48 * 1024
private let maxPersonIds = 7
private let maxValues = 16
private let maxNameHandles = 128
private let allowedId = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,200}$")
private let forbiddenDirectionals = Set<UInt32>(
    Array(0x202A...0x202E) + Array(0x2066...0x2069)
)

private struct LabeledValue: Decodable {
    let label: String
    let value: String
}

private struct PostalAddress: Decodable {
    let label: String
    let street: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let countryCode: String
}

private struct Card: Decodable {
    let firstName: String
    let middleName: String
    let lastName: String
    let nickname: String
    let organization: String
    let department: String
    let jobTitle: String
    let birthday: String
    let note: String
    let phones: [LabeledValue]
    let emails: [LabeledValue]
    let urls: [LabeledValue]
    let addresses: [PostalAddress]
}

private struct Request: Decodable {
    let operation: String
    let personUids: [String]?
    let targetUid: String?
    let sourceUids: [String]?
    let card: Card?
    let handles: [String]?
}

private struct ResolvedName: Encodable {
    let handle: String
    let name: String
    let shortName: String
}

private struct Response: Encodable {
    let ok: Bool
    let availableCount: Int?
    let deletedCount: Int?
    let updated: Bool?
    let error: String?
    let names: [ResolvedName]?
}

private func failure(_ message: String, code: Int) -> NSError {
    NSError(domain: "BlipContacts", code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func emit(_ response: Response) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response), data.count <= 4096 else {
        FileHandle.standardOutput.write(Data("{\"error\":\"Contacts mutation response failed\",\"ok\":false}".utf8))
        return
    }
    FileHandle.standardOutput.write(data)
}

private func boundedInput() throws -> Data {
    var result = Data()
    while true {
        let chunk = try FileHandle.standardInput.read(upToCount: 4096) ?? Data()
        if chunk.isEmpty { return result }
        if result.count + chunk.count > maxInputBytes {
            throw failure("Contacts mutation request is too large", code: 1)
        }
        result.append(chunk)
    }
}

private func validId(_ identifier: String) -> Bool {
    let range = NSRange(identifier.startIndex..<identifier.endIndex, in: identifier)
    return allowedId.firstMatch(in: identifier, range: range)?.range == range
}

private func validateIds(_ identifiers: [String], minimum: Int = 1) throws {
    guard identifiers.count >= minimum, identifiers.count <= maxPersonIds,
          Set(identifiers).count == identifiers.count else {
        throw failure("Contacts mutation card list is invalid", code: 2)
    }
    guard identifiers.allSatisfy(validId) else {
        throw failure("Contacts mutation card id is invalid", code: 3)
    }
}

private func validateText(_ value: String, maximum: Int, required: Bool = false) throws {
    guard value.count <= maximum, (!required || !value.isEmpty),
          value.unicodeScalars.allSatisfy({
              !CharacterSet.controlCharacters.contains($0)
                  && !forbiddenDirectionals.contains($0.value)
          }) else {
        throw failure("Contacts mutation contains an invalid field", code: 4)
    }
}

private func resolvedNames(_ handles: [String], in store: CNContactStore) throws -> [ResolvedName] {
    guard !handles.isEmpty, handles.count <= maxNameHandles,
          Set(handles).count == handles.count else {
        throw failure("Contacts name request is invalid", code: 21)
    }
    let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]
    func normalized(_ value: String) -> String {
        if value.contains("@") { return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let digits = value.filter(\.isNumber)
        return digits.count >= 10 ? String(digits.suffix(10)) : digits
    }
    var wanted: [String: String] = [:]
    for handle in handles where wanted[normalized(handle)] == nil {
        wanted[normalized(handle)] = handle
    }
    var found: [String: ResolvedName] = [:]
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.unifyResults = true
    try store.enumerateContacts(with: request) { contact, _ in
        let keys = contact.phoneNumbers.map { normalized($0.value.stringValue) }
            + contact.emailAddresses.map { normalized($0.value as String) }
        let hits = Set(keys).intersection(wanted.keys)
        if hits.isEmpty { return }
        let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let full = !formatted.isEmpty ? formatted
            : (!contact.organizationName.isEmpty ? contact.organizationName : contact.nickname)
        if full.isEmpty { return }
        let short = !contact.givenName.isEmpty ? contact.givenName
            : (!contact.nickname.isEmpty ? contact.nickname : full)
        for key in hits where found[key] == nil {
            found[key] = ResolvedName(handle: wanted[key]!, name: full, shortName: short)
        }
    }
    var result: [ResolvedName] = []
    for handle in handles {
        try validateText(handle, maximum: 320, required: true)
        if let name = found[normalized(handle)] {
            result.append(ResolvedName(handle: handle, name: name.name, shortName: name.shortName))
        }
    }
    return result
}

private func validateLabeled(_ values: [LabeledValue]) throws {
    guard values.count <= maxValues else {
        throw failure("Contacts mutation has too many field values", code: 5)
    }
    for item in values {
        try validateText(item.label, maximum: 80)
        try validateText(item.value, maximum: 320, required: true)
    }
}

private func validateCard(_ card: Card) throws {
    for value in [card.firstName, card.middleName, card.lastName, card.nickname] {
        try validateText(value, maximum: 160)
    }
    for value in [card.organization, card.department, card.jobTitle] {
        try validateText(value, maximum: 320)
    }
    try validateText(card.birthday, maximum: 10)
    try validateText(card.note, maximum: 1000)
    guard !card.firstName.isEmpty || !card.lastName.isEmpty
            || !card.nickname.isEmpty || !card.organization.isEmpty else {
        throw failure("Contact needs a name, nickname, or organization", code: 6)
    }
    try validateLabeled(card.phones)
    try validateLabeled(card.emails)
    try validateLabeled(card.urls)
    guard card.addresses.count <= maxValues else {
        throw failure("Contacts mutation has too many postal addresses", code: 7)
    }
    for address in card.addresses {
        try validateText(address.label, maximum: 80)
        try validateText(address.street, maximum: 320)
        try validateText(address.city, maximum: 320)
        try validateText(address.state, maximum: 320)
        try validateText(address.postalCode, maximum: 80)
        try validateText(address.country, maximum: 160)
        try validateText(address.countryCode, maximum: 8)
        guard !address.street.isEmpty || !address.city.isEmpty || !address.state.isEmpty
                || !address.postalCode.isEmpty || !address.country.isEmpty else {
            throw failure("Contacts mutation contains an empty postal address", code: 8)
        }
    }
}

private let mutationKeys: [CNKeyDescriptor] = [
    CNContactIdentifierKey as CNKeyDescriptor,
    CNContactGivenNameKey as CNKeyDescriptor,
    CNContactMiddleNameKey as CNKeyDescriptor,
    CNContactFamilyNameKey as CNKeyDescriptor,
    CNContactNicknameKey as CNKeyDescriptor,
    CNContactOrganizationNameKey as CNKeyDescriptor,
    CNContactDepartmentNameKey as CNKeyDescriptor,
    CNContactJobTitleKey as CNKeyDescriptor,
    CNContactBirthdayKey as CNKeyDescriptor,
    CNContactPhoneNumbersKey as CNKeyDescriptor,
    CNContactEmailAddressesKey as CNKeyDescriptor,
    CNContactUrlAddressesKey as CNKeyDescriptor,
    CNContactPostalAddressesKey as CNKeyDescriptor
]

private func exactContacts(_ identifiers: [String], in store: CNContactStore,
                           keys: [CNKeyDescriptor]) throws -> [CNContact] {
    let request = CNContactFetchRequest(keysToFetch: keys)
    request.predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
    request.unifyResults = false
    var byIdentifier: [String: CNContact] = [:]
    try store.enumerateContacts(with: request) { contact, _ in
        guard identifiers.contains(contact.identifier), byIdentifier[contact.identifier] == nil else {
            return
        }
        byIdentifier[contact.identifier] = contact
    }
    return identifiers.compactMap { byIdentifier[$0] }
}

private func exactContact(_ identifier: String, in store: CNContactStore,
                          keys: [CNKeyDescriptor]) throws -> CNContact {
    let contacts = try exactContacts([identifier], in: store, keys: keys)
    guard contacts.count == 1, contacts[0].identifier == identifier else {
        throw failure("A selected Contacts source card no longer exists", code: 9)
    }
    return contacts[0]
}

private func containerIdentifier(for contact: CNContact, in store: CNContactStore) throws -> String {
    let predicate = CNContainer.predicateForContainerOfContact(withIdentifier: contact.identifier)
    let containers = try store.containers(matching: predicate)
    guard containers.count == 1 else {
        throw failure("Contacts could not identify a selected card's account", code: 20)
    }
    return containers[0].identifier
}

private func requireMissing(_ identifiers: [String], in store: CNContactStore) throws {
    let remaining = try exactContacts(
        identifiers, in: store, keys: [CNContactIdentifierKey as CNKeyDescriptor]
    )
    if !remaining.isEmpty {
        throw failure("Contacts did not delete every selected source card", code: 19)
    }
}

private func dateComponents(_ value: String) throws -> DateComponents? {
    if value.isEmpty { return nil }
    let yearless = value.hasPrefix("--")
    let pattern = yearless ? "^--[0-9]{2}-[0-9]{2}$" : "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw failure("Contact birthday is invalid", code: 10)
    }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    let month = yearless ? parts[0] : parts[1]
    let day = yearless ? parts[1] : parts[2]
    guard (1...12).contains(month), (1...31).contains(day) else {
        throw failure("Contact birthday is invalid", code: 10)
    }
    var result = DateComponents()
    if !yearless { result.year = parts[0] }
    result.month = month
    result.day = day
    return result
}

private func apply(_ card: Card, to contact: CNMutableContact) throws {
    contact.givenName = card.firstName
    contact.middleName = card.middleName
    contact.familyName = card.lastName
    contact.nickname = card.nickname
    contact.organizationName = card.organization
    contact.departmentName = card.department
    contact.jobTitle = card.jobTitle
    contact.birthday = try dateComponents(card.birthday)
    contact.phoneNumbers = card.phones.map {
        CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label,
                       value: CNPhoneNumber(stringValue: $0.value))
    }
    contact.emailAddresses = card.emails.map {
        CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: $0.value as NSString)
    }
    contact.urlAddresses = card.urls.map {
        CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: $0.value as NSString)
    }
    contact.postalAddresses = card.addresses.map {
        let address = CNMutablePostalAddress()
        address.street = $0.street
        address.city = $0.city
        address.state = $0.state
        address.postalCode = $0.postalCode
        address.country = $0.country
        address.isoCountryCode = $0.countryCode
        return CNLabeledValue(label: $0.label.isEmpty ? nil : $0.label, value: address.copy() as! CNPostalAddress)
    }
}

private func safeMessage(_ error: Error) -> String {
    let nsError = error as NSError
    let raw: String
    if nsError.domain == NSCocoaErrorDomain && nsError.code == 134092 {
        raw = "Contacts rejected a save that crossed contact accounts"
    } else {
        raw = nsError.localizedDescription
    }
    let cleaned = raw.unicodeScalars.map { scalar -> Character in
        if CharacterSet.controlCharacters.contains(scalar) { return " " }
        return Character(String(scalar))
    }
    return String(String(cleaned).split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ").prefix(180))
}

do {
    let request = try JSONDecoder().decode(Request.self, from: boundedInput())
    guard ["available", "delete", "consolidate", "names"].contains(request.operation) else {
        throw failure("Contacts mutation operation is invalid", code: 11)
    }
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
        throw failure("Contacts access is not authorized on the Mac", code: 12)
    }
    let store = CNContactStore()

    if request.operation == "names" {
        guard let handles = request.handles else {
            throw failure("Contacts name request is missing", code: 22)
        }
        emit(Response(ok: true, availableCount: nil, deletedCount: nil,
                      updated: nil, error: nil,
                      names: try resolvedNames(handles, in: store)))
        exit(0)
    }

    if request.operation == "available" || request.operation == "delete" {
        guard let identifiers = request.personUids else {
            throw failure("Contacts mutation card list is missing", code: 13)
        }
        try validateIds(identifiers)
        let contacts = try exactContacts(
            identifiers, in: store, keys: [CNContactIdentifierKey as CNKeyDescriptor]
        )
        guard contacts.count == identifiers.count else {
            throw failure("A selected Contacts source card no longer exists", code: 9)
        }
        if request.operation == "available" {
            emit(Response(ok: true, availableCount: contacts.count, deletedCount: nil,
                          updated: nil, error: nil, names: nil))
            exit(0)
        }
        let save = CNSaveRequest()
        for contact in contacts {
            guard let mutable = contact.mutableCopy() as? CNMutableContact else {
                throw failure("Contacts returned a read-only card", code: 14)
            }
            save.delete(mutable)
        }
        try store.execute(save)
        try requireMissing(identifiers, in: store)
        emit(Response(ok: true, availableCount: nil, deletedCount: contacts.count,
                      updated: nil, error: nil, names: nil))
        exit(0)
    }

    guard let targetUid = request.targetUid, validId(targetUid),
          let sourceUids = request.sourceUids, let card = request.card else {
        throw failure("Contacts consolidation request is incomplete", code: 15)
    }
    try validateIds(sourceUids)
    guard !sourceUids.contains(targetUid) else {
        throw failure("Contacts consolidation target is also a source", code: 16)
    }
    try validateCard(card)
    let target = try exactContact(targetUid, in: store, keys: mutationKeys)
    guard let mutableTarget = target.mutableCopy() as? CNMutableContact else {
        throw failure("Contacts returned a read-only target card", code: 17)
    }
    try apply(card, to: mutableTarget)
    let sources = try sourceUids.map {
        try exactContact($0, in: store, keys: [CNContactIdentifierKey as CNKeyDescriptor])
    }
    let targetContainer = try containerIdentifier(for: target, in: store)
    let sourceContainers = try sources.map { try containerIdentifier(for: $0, in: store) }
    if sourceContainers.allSatisfy({ $0 == targetContainer }) {
        let save = CNSaveRequest()
        save.update(mutableTarget)
        for source in sources {
            guard let mutable = source.mutableCopy() as? CNMutableContact else {
                throw failure("Contacts returned a read-only source card", code: 18)
            }
            save.delete(mutable)
        }
        try store.execute(save)
    } else {
        // Contacts can reject a single CNSaveRequest that spans account-backed
        // persistent stores. Save the complete survivor first so no source data
        // is lost, then delete sources in one request per backing container.
        let update = CNSaveRequest()
        update.update(mutableTarget)
        try store.execute(update)

        var grouped: [String: [CNContact]] = [:]
        for (source, container) in zip(sources, sourceContainers) {
            grouped[container, default: []].append(source)
        }
        for contacts in grouped.values {
            let deletion = CNSaveRequest()
            for source in contacts {
                guard let mutable = source.mutableCopy() as? CNMutableContact else {
                    throw failure("Contacts returned a read-only source card", code: 18)
                }
                deletion.delete(mutable)
            }
            try store.execute(deletion)
        }
    }
    _ = try exactContact(targetUid, in: store,
                         keys: [CNContactIdentifierKey as CNKeyDescriptor])
    try requireMissing(sourceUids, in: store)
    emit(Response(ok: true, availableCount: nil, deletedCount: sources.count,
                  updated: true, error: nil, names: nil))
} catch {
    emit(Response(ok: false, availableCount: nil, deletedCount: nil,
                  updated: nil, error: safeMessage(error), names: nil))
    exit(1)
}
