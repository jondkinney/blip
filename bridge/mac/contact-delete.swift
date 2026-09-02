#!/usr/bin/env swift
import Contacts
import Foundation

private let maxInputBytes = 16 * 1024
private let maxPersonIds = 7
private let allowedId = try! NSRegularExpression(pattern: "^[A-Za-z0-9._:-]{1,200}$")

private struct Request: Decodable {
    let operation: String
    let personUids: [String]
}

private struct Response: Encodable {
    let ok: Bool
    let availableCount: Int?
    let deletedCount: Int?
    let error: String?
}

private func emit(_ response: Response) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(response), data.count <= 4096 else {
        FileHandle.standardOutput.write(Data("{\"error\":\"Contacts deletion response failed\",\"ok\":false}".utf8))
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
            throw NSError(domain: "BlipContacts", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Contacts deletion request is too large"])
        }
        result.append(chunk)
    }
}

private func validate(_ request: Request) throws {
    guard request.operation == "available" || request.operation == "delete" else {
        throw NSError(domain: "BlipContacts", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Contacts deletion operation is invalid"])
    }
    guard !request.personUids.isEmpty, request.personUids.count <= maxPersonIds,
          Set(request.personUids).count == request.personUids.count else {
        throw NSError(domain: "BlipContacts", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Contacts deletion card list is invalid"])
    }
    for identifier in request.personUids {
        let range = NSRange(identifier.startIndex..<identifier.endIndex, in: identifier)
        guard allowedId.firstMatch(in: identifier, range: range)?.range == range else {
            throw NSError(domain: "BlipContacts", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Contacts deletion card id is invalid"])
        }
    }
}

private func exactContact(_ identifier: String, in store: CNContactStore) throws -> CNContact {
    let contact = try store.unifiedContact(
        withIdentifier: identifier,
        keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
    )
    guard contact.identifier == identifier else {
        throw NSError(domain: "BlipContacts", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Contacts returned a different card"])
    }
    return contact
}

private func safeMessage(_ error: Error) -> String {
    let raw = (error as NSError).localizedDescription
    let cleaned = raw.unicodeScalars.map { scalar -> Character in
        if CharacterSet.controlCharacters.contains(scalar) { return " " }
        return Character(String(scalar))
    }
    return String(cleaned).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(180).description
}

do {
    let request = try JSONDecoder().decode(Request.self, from: boundedInput())
    try validate(request)
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
        throw NSError(domain: "BlipContacts", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "Contacts access is not authorized on the Mac"])
    }

    let store = CNContactStore()
    let contacts = try request.personUids.map { try exactContact($0, in: store) }
    if request.operation == "available" {
        emit(Response(ok: true, availableCount: contacts.count, deletedCount: nil, error: nil))
        exit(0)
    }

    let save = CNSaveRequest()
    for contact in contacts {
        guard let mutable = contact.mutableCopy() as? CNMutableContact else {
            throw NSError(domain: "BlipContacts", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Contacts returned a read-only card"])
        }
        save.delete(mutable)
    }
    try store.execute(save)

    for identifier in request.personUids {
        do {
            _ = try exactContact(identifier, in: store)
            throw NSError(domain: "BlipContacts", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Contacts did not delete a selected source card"])
        } catch let error as NSError {
            if error.domain == CNErrorDomain && error.code == CNError.Code.recordDoesNotExist.rawValue {
                continue
            }
            throw error
        }
    }
    emit(Response(ok: true, availableCount: nil, deletedCount: contacts.count, error: nil))
} catch {
    emit(Response(ok: false, availableCount: nil, deletedCount: nil, error: safeMessage(error)))
    exit(1)
}
