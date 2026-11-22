import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { bridge } from "../bridge";
import type { ThreadReplay, ThreadSnapshot } from "../types";
import { ManagedWorkspace } from "./ManagedWorkspace";
const initial=():ThreadSnapshot=>({environment_id:"env",sequence:"1",has_older_messages:false,thread:{id:"thread",project_id:"project",provider_id:"codex",title:"Shared test",cwd:"/tmp",status:"idle",revision:"1",created_at:"now",updated_at:"now"},messages:[],runs:[],approvals:[]});
function fixture(state=initial()){const api={...bridge,managedEnvironment:vi.fn().mockResolvedValue({capabilities:["managed_execution_v1","managed_claude_v1"]}),managedCreateThread:vi.fn().mockImplementation(async (_id:string,_project:string,title:string,provider:string)=>({...state.thread,title,provider_id:provider})),managedProjects:vi.fn().mockResolvedValue([{id:"project",name:"Test project",canonical_root:"/tmp",created_at:"now",updated_at:"now"}]),managedThreads:vi.fn().mockResolvedValue([state.thread]),managedSnapshot:vi.fn().mockResolvedValue(state),managedWait:vi.fn().mockReturnValue(new Promise<ThreadReplay>(()=>{})),managedSend:vi.fn().mockResolvedValue({})};return api}
async function open(api:ReturnType<typeof fixture>){render(<ManagedWorkspace api={api} devices={[]}/>);fireEvent.click(await screen.findByRole("button",{name:/Shared test/}));await screen.findByRole("textbox",{name:"共享对话消息"});await waitFor(()=>expect(api.managedWait).toHaveBeenCalled());}
beforeEach(() => {
  const values = new Map<string, string>();
  Object.defineProperty(window, "localStorage", { configurable: true, value: { getItem: (key: string) => values.get(key) ?? null, setItem: (key: string, value: string) => values.set(key, value), removeItem: (key: string) => values.delete(key), clear: () => values.clear() } });
});
afterEach(()=>{cleanup();vi.useRealTimers();});
test("accepted send remains accepted when follow-up snapshot fails",async()=>{const api=fixture();await open(api);api.managedSnapshot.mockRejectedValue({code:"timeout",message:"Snapshot timed out"});fireEvent.change(screen.getByRole("textbox",{name:"共享对话消息"}),{target:{value:"hello"}});fireEvent.click(screen.getByRole("button",{name:"发送"}));await screen.findByText("Snapshot timed out");expect(screen.queryByText(/发送结果尚未确认/)).not.toBeInTheDocument();expect(screen.getByRole("textbox",{name:"共享对话消息"})).toHaveValue("");});
test("unknown runs disable send and hide interruption",async()=>{const state=initial();state.runs=[{id:"run",thread_id:"thread",status:"outcome_unknown",revision:"2"}];const api=fixture(state);await open(api);fireEvent.change(screen.getByRole("textbox",{name:"共享对话消息"}),{target:{value:"next"}});expect(screen.getByRole("button",{name:"发送"})).toBeDisabled();expect(screen.queryByRole("button",{name:"停止执行"})).not.toBeInTheDocument();});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}
test("late replay reconciles uncertain send without another command", async () => {
  const api = fixture();
  const replay = deferred<ThreadReplay>();
  api.managedWait.mockReturnValueOnce(replay.promise);
  await open(api);
  api.managedSend.mockRejectedValue({ code: "timeout", message: "Send timed out" });
  fireEvent.change(screen.getByRole("textbox", { name: "共享对话消息" }), { target: { value: "hello" } });
  fireEvent.click(screen.getByRole("button", { name: "发送" }));
  await screen.findByText(/发送结果尚未确认/);
  const messageId = api.managedSend.mock.calls[0][2];
  await act(async () => replay.resolve({ environment_id: "env", thread_id: "thread", sequence: "2", has_more: false, events: [{ sequence: "2", aggregate_id: "message", event_type: "message.created", schema_version: 1, payload: { id: "message", thread_id: "thread", run_id: "run", client_message_id: messageId, role: "user", content: { text: "hello" }, revision: "1" } }] }));
  await waitFor(() => expect(screen.queryByText(/发送结果尚未确认/)).not.toBeInTheDocument());
  expect(screen.getByRole("textbox", { name: "共享对话消息" })).toHaveValue("");
  expect(api.managedSend).toHaveBeenCalledTimes(1);
});
test("unsupported schema stops the subscription loop", async () => {
  const api = fixture();
  const replay = deferred<ThreadReplay>();
  api.managedWait.mockReturnValueOnce(replay.promise);
  await open(api);
  vi.useFakeTimers();
  await act(async () => replay.resolve({ environment_id: "env", thread_id: "thread", sequence: "2", has_more: false, events: [{ sequence: "2", aggregate_id: "thread", event_type: "thread.updated", schema_version: 99, payload: {} }] }));
  expect(screen.getByText("客户端需要更新才能读取会话事件。")).toBeInTheDocument();
  await act(async () => { await vi.advanceTimersByTimeAsync(1600); });
  expect(api.managedWait).toHaveBeenCalledTimes(1);
  expect(api.managedSnapshot).toHaveBeenCalledTimes(1);
});

test("creates a Claude thread using explicit provider identity", async () => {
  const api = fixture();
  await open(api);
  fireEvent.change(screen.getByRole("combobox", { name: "对话 Agent" }), { target: { value: "claude" } });
  fireEvent.change(screen.getByRole("textbox", { name: "新对话标题" }), { target: { value: "Claude task" } });
  fireEvent.click(screen.getByRole("button", { name: "新建对话" }));
  await waitFor(() => expect(api.managedCreateThread).toHaveBeenCalledWith(expect.any(String), "project", "Claude task", "claude"));
});

test("older hosts keep Claude creation unavailable", async () => {
  const api = fixture();
  api.managedEnvironment.mockResolvedValue({ capabilities: ["managed_execution_v1"] });
  await open(api);
  screen.getAllByRole("option", { name: "Claude（需更新 Mac）" }).forEach(option => expect(option).toBeDisabled());
});

test("Claude conversation identifies assistant and composer", async () => {
  const state = initial();
  state.thread.provider_id = "claude";
  state.messages = [{ id: "answer", thread_id: "thread", run_id: "run", client_message_id: null, role: "assistant", content: { text: "Hello", provider_id: "claude" }, revision: "1" }];
  await open(fixture(state));
  expect(screen.getByRole("textbox", { name: "共享对话消息" })).toHaveAttribute("placeholder", "给 Claude 发消息…");
  expect(screen.getByText("Hello").closest("article")).toHaveTextContent("Claude");
});

function switchingFixture() {
  const api = fixture();
  api.managedEnvironment.mockResolvedValue({ capabilities: ["managed_execution_v1", "managed_claude_v1", "managed_provider_switch_v1"] });
  return { ...api, managedProviderSet: vi.fn().mockResolvedValue(initial().thread) };
}
test("switches provider in the same thread and preserves draft and attribution", async () => {
  const api = switchingFixture(); await open(api);
  fireEvent.change(screen.getByRole("textbox", { name: "共享对话消息" }), { target: { value: "continue" } });
  const next = initial(); next.sequence = "3"; next.thread.provider_id = "claude";
  next.messages = [{ id: "answer", thread_id: "thread", run_id: null, client_message_id: null, role: "assistant", content: { text: "old answer", provider_id: "codex" }, revision: "1" }];
  api.managedSnapshot.mockResolvedValue(next);
  fireEvent.change(screen.getByRole("combobox", { name: "当前对话 Agent" }), { target: { value: "claude" } });
  await waitFor(() => expect(api.managedProviderSet).toHaveBeenCalledWith(expect.any(String), "thread", "claude", null, "1"));
  await waitFor(() => expect(screen.getByRole("combobox", { name: "当前对话 Agent" })).toHaveValue("claude"));
  expect(screen.getByText("old answer").closest("article")).toHaveTextContent("Codex");
  expect(screen.getByRole("textbox", { name: "共享对话消息" })).toHaveValue("continue");
});
test("unknown switch persists and retries the original command after remount", async () => {
  const api = switchingFixture(); api.managedProviderSet.mockRejectedValueOnce({ code: "timeout", message: "Switch timeout" }); await open(api);
  fireEvent.change(screen.getByRole("combobox", { name: "当前对话 Agent" }), { target: { value: "claude" } }); await screen.findByRole("button", { name: "重新确认切换" });
  const original = api.managedProviderSet.mock.calls[0]; cleanup(); await open(api);
  fireEvent.change(screen.getByRole("textbox", { name: "共享对话消息" }), { target: { value: "wait" } }); expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
  fireEvent.click(screen.getByRole("button", { name: "重新确认切换" })); await waitFor(() => expect(api.managedProviderSet).toHaveBeenCalledTimes(2)); expect(api.managedProviderSet.mock.calls[1]).toEqual(original);
});
test("busy conversations disable provider switching", async () => { const state = initial(); state.thread.status = "active"; await open(fixture(state)); expect(screen.getByRole("combobox", { name: "当前对话 Agent" })).toBeDisabled(); });

test("corrupt pending switch storage blocks sending and provider changes", async () => {
  const api = switchingFixture();
  window.localStorage.setItem("arclink-managed-provider-switch:thread", "invalid-json");
  await open(api);
  await screen.findByText(/无法读取 Agent 切换记录/);
  fireEvent.change(screen.getByRole("textbox", { name: "共享对话消息" }), { target: { value: "wait" } });
  expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
  expect(screen.getByRole("combobox", { name: "当前对话 Agent" })).toBeDisabled();
  expect(api.managedProviderSet).not.toHaveBeenCalled();
});
test("unattributed historical answers keep a generic label", async () => {
  const state = initial(); state.thread.provider_id = "claude";
  state.messages = [{ id: "old", thread_id: "thread", run_id: null, client_message_id: null, role: "assistant", content: { text: "legacy answer" }, revision: "1" }];
  await open(fixture(state));
  expect(screen.getByText("legacy answer").closest("article")).toHaveTextContent("历史助手");
});
