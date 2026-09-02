#!/usr/bin/env swift
import Contacts
import Foundation

private let maxInputBytes = 48 * 1024
private let maxPersonIds = 7
private let maxValues = 16
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
}

private struct Response: Encodable {
    let ok: Bool
    let availableCount: Int?
    let deletedCount: Int?
    let updated: Bool?
    let error: String?
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

private func exactContact(_ identifier: String, in store: CNContactStore,
                          keys: [CNKeyDescriptor]) throws -> CNContact {
    let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
    guard contact.identifier == identifier else {
        throw failure("Contacts returned a different card", code: 9)
    }
    return contact
}

private func requireMissing(_ identifiers: [String], in store: CNContactStore) throws {
    for identifier in identifiers {
        do {
            _ = try exactContact(identifier, in: store,
                                 keys: [CNContactIdentifierKey as CNKeyDescriptor])
            throw failure("Contacts did not delete a selected source card", code: 19)
        } catch let error as NSError {
            if error.domain == CNErrorDomain
                    && error.code == CNError.Code.recordDoesNotExist.rawValue {
                continue
            }
            throw error
        }
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
    let raw = (error as NSError).localizedDescription
    let cleaned = raw.unicodeScalars.map { scalar -> Character in
        if CharacterSet.controlCharacters.contains(scalar) { return " " }
        return Character(String(scalar))
    }
    return String(String(cleaned).split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ").prefix(180))
}

do {
    let request = try JSONDecoder().decode(Request.self, from: boundedInput())
    guard ["available", "delete", "consolidate"].contains(request.operation) else {
        throw failure("Contacts mutation operation is invalid", code: 11)
    }
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
        throw failure("Contacts access is not authorized on the Mac", code: 12)
    }
    let store = CNContactStore()

    if request.operation == "available" || request.operation == "delete" {
        guard let identifiers = request.personUids else {
            throw failure("Contacts mutation card list is missing", code: 13)
        }
        try validateIds(identifiers)
        let contacts = try identifiers.map {
            try exactContact($0, in: store, keys: [CNContactIdentifierKey as CNKeyDescriptor])
        }
        if request.operation == "available" {
            emit(Response(ok: true, availableCount: contacts.count, deletedCount: nil,
                          updated: nil, error: nil))
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
                      updated: nil, error: nil))
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
    let save = CNSaveRequest()
    save.update(mutableTarget)
    for source in sources {
        guard let mutable = source.mutableCopy() as? CNMutableContact else {
            throw failure("Contacts returned a read-only source card", code: 18)
        }
        save.delete(mutable)
    }
    try store.execute(save)
    _ = try exactContact(targetUid, in: store,
                         keys: [CNContactIdentifierKey as CNKeyDescriptor])
    try requireMissing(sourceUids, in: store)
    emit(Response(ok: true, availableCount: nil, deletedCount: sources.count,
                  updated: true, error: nil))
} catch {
    emit(Response(ok: false, availableCount: nil, deletedCount: nil,
                  updated: nil, error: safeMessage(error)))
    exit(1)
}
