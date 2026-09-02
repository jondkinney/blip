#!/usr/bin/osascript -l JavaScript
/*
 * Supported Contacts.app mutation boundary for Blip.
 *
 * The Python bridge sends one bounded JSON request on stdin. Raw Contacts
 * identifiers and field values never appear in argv, and this helper emits a
 * small JSON result only. It deliberately refuses to save while Contacts has
 * unrelated unsaved changes.
 */
ObjC.import("Foundation");

const MAX_INPUT_BYTES = 16 * 1024;
const MAX_OUTPUT_BYTES = 48 * 1024;
const MAX_FIELDS = 8;
const MAX_PERSON_IDS = 64;
const MAX_COMPARE_CARDS = 8;
const MAX_VALUES_PER_KIND = 16;
const UNSAFE = /[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g;

function boundedString(value, label, maximum) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum)
    throw new Error(label + " is invalid");
  const cleaned = value.replace(UNSAFE, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) throw new Error(label + " is invalid");
  return cleaned;
}

function normalizePhone(value) {
  const digits = boundedString(value, "phone value", 320).replace(/\D/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

function normalizeEmail(value) {
  return boundedString(value, "email value", 320).toLowerCase();
}

function readRequest() {
  const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
  if (Number(data.length) > MAX_INPUT_BYTES) throw new Error("repair request is too large");
  const source = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  let parsed;
  try { parsed = JSON.parse(String(source)); }
  catch (_) { throw new Error("repair request is not valid JSON"); }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("repair request must be an object");
  return parsed;
}

function normalizeRequest(value) {
  const operation = value.operation === "available" || value.operation === "describe"
    || value.operation === "inspect" || value.operation === "remove"
    || value.operation === "undo" ? value.operation : "";
  if (!operation) throw new Error("repair operation is invalid");
  if (operation === "available") {
    if (!Array.isArray(value.personUids) || value.personUids.length < 1
        || value.personUids.length > MAX_PERSON_IDS)
      throw new Error("person id list is invalid");
    const seen = {};
    const personUids = value.personUids.map(function(uid) {
      const normalized = boundedString(uid, "person id", 200);
      if (seen[normalized]) throw new Error("person id list contains a duplicate");
      seen[normalized] = true;
      return normalized;
    });
    return { operation: operation, personUids: personUids };
  }
  if (operation === "describe") {
    if (!Array.isArray(value.personUids) || value.personUids.length < 1
        || value.personUids.length > MAX_COMPARE_CARDS)
      throw new Error("comparison card list is invalid");
    const seen = {};
    const personUids = value.personUids.map(function(uid) {
      const normalized = boundedString(uid, "person id", 200);
      if (seen[normalized]) throw new Error("comparison card list contains a duplicate");
      seen[normalized] = true;
      return normalized;
    });
    return { operation: operation, personUids: personUids };
  }
  const uid = boundedString(value.personUid, "person id", 200);
  const kind = value.kind === "phone" || value.kind === "email" ? value.kind : "";
  if (!kind) throw new Error("repair kind is invalid");
  const key = boundedString(value.key, "handle key", 320);
  const request = { operation: operation, personUid: uid, kind: kind, key: key, fields: [] };
  if (operation === "remove" || operation === "undo") {
    if (!Array.isArray(value.fields) || value.fields.length < 1 || value.fields.length > MAX_FIELDS)
      throw new Error("repair field list is invalid");
    request.fields = value.fields.map(function(field) {
      if (!field || typeof field !== "object" || Array.isArray(field))
        throw new Error("repair field is invalid");
      return {
        id: operation === "remove" ? boundedString(field.id, "field id", 200) : "",
        value: boundedString(field.value, "field value", 320),
        label: typeof field.label === "string"
          ? field.label.replace(UNSAFE, " ").replace(/\s+/g, " ").trim().slice(0, 80) : ""
      };
    });
  }
  return request;
}

function peopleForId(contacts, uid) {
  const people = contacts.people.whose({ id: uid })();
  if (!Array.isArray(people) || people.length !== 1)
    throw new Error("the exact Contacts card is unavailable");
  return people[0];
}

function normalizedValue(kind, value) {
  return kind === "email" ? normalizeEmail(value) : normalizePhone(value);
}

function matchingFields(person, kind, key) {
  const entries = kind === "email" ? person.emails() : person.phones();
  const matches = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    let value;
    try { value = boundedString(entry.value(), "field value", 320); }
    catch (_) { continue; }
    if (normalizedValue(kind, value) !== key) continue;
    const id = boundedString(entry.id(), "field id", 200);
    let label = "";
    try {
      const rawLabel = entry.label();
      if (typeof rawLabel === "string")
        label = rawLabel.replace(UNSAFE, " ").replace(/\s+/g, " ").trim().slice(0, 80);
    } catch (_) { /* labels are optional */ }
    matches.push({ specifier: entry, id: id, value: value, label: label });
    if (matches.length > MAX_FIELDS) throw new Error("too many matching fields on this card");
  }
  return matches;
}

function publicFields(fields) {
  return fields.map(function(field) {
    return { id: field.id, value: field.value, label: field.label };
  });
}

function optionalString(value, label, maximum) {
  if (value === null || value === undefined) return "";
  if (typeof value !== "string") throw new Error(label + " is invalid");
  if (value.length > maximum) throw new Error(label + " is too long");
  return value.replace(UNSAFE, " ").replace(/\s+/g, " ").trim();
}

function personString(person, property, label, maximum) {
  try { return optionalString(person[property](), label, maximum); }
  catch (error) {
    if (String(error).indexOf("is too long") >= 0) throw error;
    return "";
  }
}

function labeledValues(person, property, label) {
  const entries = person[property]();
  if (!Array.isArray(entries) || entries.length > MAX_VALUES_PER_KIND)
    throw new Error("too many " + label + " values on one card");
  return entries.map(function(entry) {
    const value = optionalString(entry.value(), label + " value", 320);
    let entryLabel = "";
    try { entryLabel = optionalString(entry.label(), label + " label", 80); }
    catch (_) { entryLabel = ""; }
    return { label: entryLabel, value: value };
  }).filter(function(entry) { return entry.value !== ""; });
}

function addressValues(person) {
  const entries = person.addresses();
  if (!Array.isArray(entries) || entries.length > MAX_VALUES_PER_KIND)
    throw new Error("too many address values on one card");
  return entries.map(function(entry) {
    function piece(property, label) {
      try { return optionalString(entry[property](), label, 320); }
      catch (_) { return ""; }
    }
    return {
      label: piece("label", "address label"),
      street: piece("street", "street"),
      city: piece("city", "city"),
      state: piece("state", "state"),
      postalCode: piece("zip", "postal code"),
      country: piece("country", "country"),
      countryCode: piece("countryCode", "country code")
    };
  }).filter(function(entry) {
    return entry.street || entry.city || entry.state || entry.postalCode || entry.country;
  });
}

function birthDateValue(person) {
  let value;
  try { value = person.birthDate(); } catch (_) { return ""; }
  if (value === null || value === undefined) return "";
  const date = new Date(value);
  if (isNaN(date.getTime())) return "";
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const year = date.getFullYear();
  return year < 1800 ? "--" + month + "-" + day : String(year).padStart(4, "0") + "-" + month + "-" + day;
}

function describePerson(person) {
  return {
    displayName: personString(person, "name", "display name", 160),
    firstName: personString(person, "firstName", "first name", 160),
    middleName: personString(person, "middleName", "middle name", 160),
    lastName: personString(person, "lastName", "last name", 160),
    nickname: personString(person, "nickname", "nickname", 160),
    organization: personString(person, "organization", "organization", 320),
    department: personString(person, "department", "department", 320),
    jobTitle: personString(person, "jobTitle", "job title", 320),
    birthday: birthDateValue(person),
    note: personString(person, "note", "note", 1000),
    phones: labeledValues(person, "phones", "phone"),
    emails: labeledValues(person, "emails", "email"),
    urls: labeledValues(person, "urls", "URL"),
    addresses: addressValues(person)
  };
}

function sameFieldSet(actual, expected) {
  if (actual.length !== expected.length) return false;
  const left = actual.map(function(field) { return field.id; }).sort();
  const right = expected.map(function(field) { return field.id; }).sort();
  for (let i = 0; i < left.length; i++) if (left[i] !== right[i]) return false;
  return true;
}

function addField(contacts, person, kind, field) {
  const properties = { value: field.value };
  if (field.label) properties.label = field.label;
  const entry = kind === "email" ? contacts.Email(properties) : contacts.Phone(properties);
  contacts.add(entry, { to: person });
}

function perform(request) {
  if (request.operation === "available") {
    // The object layer exposes only cards that Contacts can actually address;
    // raw per-account databases can retain inactive cache rows.
    ObjC.import("AddressBook");
    const book = $.ABAddressBook.sharedAddressBook;
    const available = request.personUids.filter(function(uid) {
      try {
        const person = book.recordForUniqueId($(uid));
        const value = ObjC.unwrap(person);
        return value !== undefined && value !== null;
      } catch (_) {
        return false;
      }
    });
    return { ok: true, available: available };
  }
  const Contacts = Application("Contacts");
  if (request.operation === "describe") {
    const cards = request.personUids.map(function(uid) {
      return describePerson(peopleForId(Contacts, uid));
    });
    return { ok: true, cards: cards };
  }
  const person = peopleForId(Contacts, request.personUid);
  const current = matchingFields(person, request.kind, request.key);

  if (request.operation === "inspect") {
    if (current.length < 1) throw new Error("this handle is no longer on the selected card");
    return { ok: true, fieldCount: current.length, fields: publicFields(current) };
  }

  if (Contacts.unsaved())
    throw new Error("Contacts has unsaved changes; finish or discard them on the Mac first");

  if (request.operation === "remove") {
    if (!sameFieldSet(current, request.fields))
      throw new Error("the selected card changed; review it again before removing anything");
    for (let i = current.length - 1; i >= 0; i--)
      Contacts.remove(current[i].specifier, { from: person });
    try {
      Contacts.save();
    } catch (error) {
      for (let i = 0; i < request.fields.length; i++) addField(Contacts, person, request.kind, request.fields[i]);
      try { Contacts.save(); } catch (_) { /* preserve the original failure */ }
      throw error;
    }
    if (matchingFields(person, request.kind, request.key).length !== 0)
      throw new Error("Contacts did not remove the selected handle");
    return { ok: true, removed: true, fieldCount: current.length };
  }

  if (current.length > 0)
    return { ok: true, restored: true, alreadyPresent: true, fieldCount: current.length };
  for (let i = 0; i < request.fields.length; i++) addField(Contacts, person, request.kind, request.fields[i]);
  Contacts.save();
  const restored = matchingFields(person, request.kind, request.key);
  if (restored.length < 1) throw new Error("Contacts did not restore the selected handle");
  return { ok: true, restored: true, alreadyPresent: false, fieldCount: restored.length };
}

function run() {
  try {
    const result = perform(normalizeRequest(readRequest()));
    const output = JSON.stringify(result);
    if ($.NSString.alloc.initWithUTF8String(output).lengthOfBytesUsingEncoding($.NSUTF8StringEncoding) > MAX_OUTPUT_BYTES)
      throw new Error("repair response is too large");
    return output;
  } catch (error) {
    const message = String(error && error.message ? error.message : error)
      .replace(UNSAFE, " ").replace(/\s+/g, " ").trim().slice(0, 180)
      || "Contacts repair failed";
    return JSON.stringify({ ok: false, error: message });
  }
}
