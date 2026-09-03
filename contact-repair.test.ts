import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("./bridge/mac/contact-repair.js", import.meta.url), "utf8")
  .replace(/^#![^\n]*\n/, "");
let contactsApplication: any = null;
const repair = new Function(
  "ObjC",
  "Application",
  source + "\nreturn { normalizeRequest: normalizeRequest, perform: perform, setCard: setCard };",
)({ import() {} }, () => contactsApplication) as {
  normalizeRequest: (request: any) => any;
  perform: (request: any) => any;
  setCard: (contacts: any, person: any, card: any) => void;
};

function scalar(initial = "") {
  let value = initial;
  const property = (() => value) as (() => string) & { set: (next: string) => void };
  property.set = (next: string) => { value = next; };
  return property;
}

function labeled(label: string, value: string) {
  return { label: () => label, value: () => value };
}

function fixture() {
  const originalPhone = labeled("_$!<Apple Watch>!$_", "+1 (920) 632-3055");
  const phones = [originalPhone];
  const person: any = {
    firstName: scalar("Matthew"), middleName: scalar(""), lastName: scalar("Kinney"),
    nickname: scalar(), organization: scalar(), department: scalar(), jobTitle: scalar(),
    note: scalar(), birthDate: scalar(), phones: () => phones,
    emails: () => [], urls: () => [], addresses: () => [],
  };
  const removed: any[] = [];
  const added: any[] = [];
  const contacts: any = {
    remove(entry: any) {
      removed.push(entry);
      phones.splice(phones.indexOf(entry), 1);
    },
    Phone(properties: any) {
      return labeled(properties.label || "", properties.value);
    },
    Email(properties: any) { return labeled(properties.label || "", properties.value); },
    Url(properties: any) { return labeled(properties.label || "", properties.value); },
    Address(properties: any) { return properties; },
    add(entry: any) { added.push(entry); phones.push(entry); },
  };
  const card = {
    firstName: "Matthew", middleName: "Jonathan", lastName: "Kinney",
    nickname: "", organization: "", department: "", jobTitle: "",
    birthday: "", note: "",
    phones: [{ label: "_$!<Apple Watch>!$_", value: "+1 (920) 632-3055" }],
    emails: [], urls: [], addresses: [],
  };
  return { contacts, person, card, originalPhone, removed, added };
}

describe("Contacts.app edit reconciliation", () => {
  test("discarding a pending edit explicitly quits Contacts without saving", () => {
    let quitArgument: any = null;
    contactsApplication = {
      running: () => true,
      unsaved: () => true,
      quit: (argument: any) => { quitArgument = argument; },
    };
    expect(repair.perform(repair.normalizeRequest({ operation: "discard-unsaved" })))
      .toEqual({ ok: true, discarded: true });
    expect(quitArgument).toEqual({ saving: "no" });
  });

  test("a scalar-only edit preserves the existing phone field", () => {
    const f = fixture();
    repair.setCard(f.contacts, f.person, f.card);
    expect(f.removed).toEqual([]);
    expect(f.added).toEqual([]);
    expect(f.person.middleName()).toBe("Jonathan");
  });

  test("a changed collection removes the concrete field object before replacing it", () => {
    const f = fixture();
    f.card.phones[0].value = "+1 (920) 632-9999";
    repair.setCard(f.contacts, f.person, f.card);
    expect(f.removed).toEqual([f.originalPhone]);
    expect(f.added).toHaveLength(1);
    expect(f.added[0].value()).toBe("+1 (920) 632-9999");
  });
});
