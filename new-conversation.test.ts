import { describe, expect, test } from "bun:test";
import { addRecipient, removeRecipient, recipient, conversationTitle, MAX_RECIPIENTS } from "./new-conversation";

describe("new conversation recipient selection", () => {
  const alice = { name: "Alice", handle: "+15551234567" };
  const bob = { name: "Bob", handle: "bob@example.com" };
  test("adding people retains earlier recipients until the explicit start", () => {
    const first = addRecipient([], alice);
    const second = addRecipient(first.recipients, bob);
    expect(first.recipients).toEqual([alice]);
    expect(second).toEqual({ recipients: [alice, bob], error: "" });
    expect(conversationTitle(second.recipients)).toBe("Alice & Bob");
    expect(removeRecipient(second.recipients, alice.handle)).toEqual([bob]);
  });
  test("duplicate handles are rejected without collapsing distinct addresses", () => {
    expect(addRecipient([bob], { ...bob, handle: "BOB@example.com" }).error).toBe("Already added");
    expect(addRecipient([bob], { ...bob, handle: "+15551234567" }).recipients).toHaveLength(2);
  });
  test("invalid, oversized, control-bearing, and multi-address entries are rejected", () => {
    for (const handle of ["", "chat123", "a@example.com,b@example.com", "a\n@example.com", "a".repeat(255), "a@example.com;body=x"])
      expect(recipient({ handle })).toBeNull();
    for (const value of [null, [], 5, "a@example.com", { handle: 5 }]) expect(recipient(value)).toBeNull();
    expect(recipient({ handle: bob.handle, name: "A\u202eB\nC" })?.name).toBe("A B C");
  });
  test("the recipient count has a hard boundary and removing one releases a slot", () => {
    let selected: typeof bob[] = [];
    for (let i = 0; i < MAX_RECIPIENTS; i++) selected = addRecipient(selected, { name: "Person", handle: `p${i}@example.com` }).recipients;
    expect(addRecipient(selected, alice).error).toContain("at most");
    expect(addRecipient(removeRecipient(selected, selected[0].handle), alice).recipients).toHaveLength(MAX_RECIPIENTS);
  });
});
