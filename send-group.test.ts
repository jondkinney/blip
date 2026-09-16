import { expect, test } from "bun:test";
import { groupRequest, sendGroup, MAX_GROUP_RESPONSE } from "./send-group";
import { groupDraft, createdGroup, remapPending } from "./new-conversation";
import { readFileSync } from "node:fs";
const people = [{name:"Alice",handle:"alice@example.com"},{name:"Bob",handle:"bob@example.com"}];
const request = {recipients:people.map(p=>p.handle), text:"Synthetic fixture"};
const success = {ok:true, chat:"chat123", guid:"iMessage;+;chat123"};
test("group drafts never invent a sendable GUID", () => {
  const draft = groupDraft(people,"123-4")!;
  expect(draft.guid).toBe(""); expect(draft.handle).toBe(""); expect(draft.recipients).toEqual(people);
  expect(groupDraft([people[0]],"123")).toBeNull(); expect(groupDraft(people,"../bad")).toBeNull();
  expect(createdGroup(success)).toEqual({chat:"chat123",guid:"iMessage;+;chat123",service:"iMessage"});
  expect(createdGroup({...success,guid:"iMessage;-;alice@example.com"})).toBeNull();
  expect(createdGroup({...success,chat:"other"})).toBeNull();
  expect(remapPending([{chat:draft.chat,localId:"1"},{chat:"other",localId:"2"}],draft.chat,"chat123"))
    .toEqual([{chat:"chat123",localId:"1"},{chat:"other",localId:"2"}]);
});
test("the first message and recipients travel on bounded stdin, not argv", () => {
  const run:any=(file:string,args:string[],options:any)=>{
    expect(file.endsWith("/bin/imsg-send")).toBe(true);
    expect(args).toEqual(["--new-group-stdin","--yes"]);
    expect(JSON.parse(options.input)).toEqual(request);
    expect(options.maxBuffer).toBe(MAX_GROUP_RESPONSE);
    return {status:0,stdout:JSON.stringify(success)};
  };
  expect(sendGroup(request,run)).toEqual({...success,service:"iMessage"});
});
test("bad recipients and oversized bodies never reach the bridge", () => {
  for(const value of [null,{}, {...request,recipients:["a@example.com"]}, {...request,recipients:["a@example.com","A@example.com"]}, {...request,text:"a".repeat(4001)}])
    expect(()=>groupRequest(value)).toThrow();
});
test("ambiguous sends cannot claim failure-before-send or expose stderr", () => {
  const run:any=()=>({status:255,stderr:"private source text"});
  expect(sendGroup(request,run).uncertain).toBe(true);
  expect(JSON.stringify(sendGroup(request,run))).not.toContain("private source text");
  const failed:any=()=>({status:1,stdout:JSON.stringify({ok:false,error:"Cannot verify recipients",uncertain:false})});
  expect(sendGroup(request,failed)).toEqual({ok:false,error:"Cannot verify recipients",uncertain:false});
});
// Execute the exact portable JavaScript used inside JXA, with a synthetic AX
// tree. No Messages process, contacts, or conversations are involved.
const py=readFileSync(new URL("./bridge/mac/group_compose.py",import.meta.url),"utf8");
const js=py.split("UI_SCRIPT = r'''\n")[1].split("\n'''")[0];
function uiFixture(labels:string[], bodyValue="", focused=true, prepareOnly=true, afterFill?:string[]) {
  let sent = 0;
  const body:any={role:()=>"AXTextField",uiElements:()=>[],attributes:{byName:(name:string)=>({value:()=>name==="AXIdentifier"?"messageBodyField":name==="AXFocused"?focused:null})}};
  Object.defineProperty(body,"value",{get:()=>()=>bodyValue,set:(value:string)=>{bodyValue=value;if(afterFill)labels=afterFill;}});
  const field:any={role:()=>"AXTextField",attributes:{byName:()=>({value:()=>null})},popUpButtons:()=>labels.map(label=>({attributes:{byName:(name:string)=>({value:()=>name==="AXUserInputLabels"?[label]:null})}})),uiElements:()=>[]};
  const win:any={role:()=>"AXWindow",attributes:{byName:()=>({value:()=>null})},uiElements:()=>[field,body]};
  const process:any={windows:Object.assign(()=>[win],{0:win}),frontmost:()=>focused};
  const events:any={processes:{byName:()=>process},keyCode:()=>{sent++;}};
  const app:any={activate:()=>{},running:()=>true};
  const api=new Function("Application","delay","request","console",js.replace("JSON.stringify(main());","return {matches,verifyRecipients,checkDraft,main};"))((name:string)=>name.includes("systemevents")?events:app,()=>{}, {...request,prepareOnly}, {log:()=>{}});
  return {...api, sent:()=>sent};
}
test("native compose refuses wrong or collapsed recipients", () => {
  expect(uiFixture(["Alice alice@example.com","Bob bob@example.com"]).main()).toEqual({ok:true,prepared:true});
  for(const labels of [["alice@example.com"],["alice@example.com","mallory@example.com"],["alice@example.com","alice@example.com"],["alice@example.com bob@example.com","bob@example.com"]])
    expect(uiFixture(labels).main().ok).toBe(false);
});
test("native labels verify exact emails and formatted phones", () => {
  const {matches}=uiFixture([]);
  expect(matches("Alice alice@example.com", "alice@example.com")).toBe(true);
  expect(matches("notalice@example.com", "alice@example.com")).toBe(false);
  expect(matches("Mobile +1 (555) 123-4567", "+15551234567")).toBe(true);
  expect(matches("Mobile +44 555 123 4567", "+15551234567")).toBe(false);
});
test("an existing native compose draft is preserved", () => {
  const ui=uiFixture(["alice@example.com","bob@example.com"],"Unsent fixture");
  expect(ui.checkDraft().ok).toBe(false); expect(ui.main().ok).toBe(false);
});
test("native send rechecks recipients and focus after filling the draft", () => {
  const good=uiFixture(request.recipients,"",true,false);
  expect(good.main()).toEqual({ok:true,submitted:true}); expect(good.sent()).toBe(1);
  const unfocused=uiFixture(request.recipients,"",false,false);
  expect(unfocused.main().ok).toBe(false); expect(unfocused.sent()).toBe(0);
  const changed=uiFixture(request.recipients,"",true,false,["alice@example.com","other@example.com"]);
  expect(changed.main()).toMatchObject({ok:false,uncertain:false}); expect(changed.sent()).toBe(0);
});
