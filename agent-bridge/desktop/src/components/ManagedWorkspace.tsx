import { useEffect, useRef, useState } from "react";
import { normalizeError, type Bridge } from "../bridge";
import { applyThreadReplay, UnsupportedThreadSchemaError } from "../managedState";
import type { ManagedProject, ManagedThread, PairedDevice, ThreadSnapshot } from "../types";

const newId = () => crypto.randomUUID();
const providerLabel = (provider: string) => provider === "claude" ? "Claude" : provider === "codex" ? "Codex" : provider;
const active = (status: string) => ["queued", "starting", "running", "waiting_approval"].includes(status);
const statusText = (status: string) => ({ active: "进行中", idle: "就绪", attention: "结果待确认", queued: "等待执行", starting: "正在启动", running: "正在执行", waiting_approval: "等待批准", outcome_unknown: "结果待确认", completed: "已完成", interrupted: "已停止", failed: "执行失败" })[status] ?? status;
const cacheKey = (threadId: string) => `arclink-managed-thread:${threadId}`;
const switchKey = (threadId: string) => `arclink-managed-provider-switch:${threadId}`;
type PendingSwitch = { commandId: string; threadId: string; fromProviderId: string; toProviderId: string; expectedRevision: string };
function save(snapshot: ThreadSnapshot) {
  try { const raw = JSON.stringify(snapshot); if (raw.length < 2_000_000) window.localStorage.setItem(cacheKey(snapshot.thread.id), raw); } catch { /* Memory remains authoritative if local cache is unavailable. */ }
}

export function ManagedWorkspace({ api, devices }: { api: Bridge; devices: PairedDevice[] }) {
  const [projects, setProjects] = useState<ManagedProject[]>([]);
  const [projectId, setProjectId] = useState("");
  const [threads, setThreads] = useState<ManagedThread[]>([]);
  const [threadId, setThreadId] = useState("");
  const [snapshot, setSnapshot] = useState<ThreadSnapshot | null>(null);
  const [draft, setDraft] = useState("");
  const [name, setName] = useState("");
  const [path, setPath] = useState("");
  const [title, setTitle] = useState("");
  const [providerId, setProviderId] = useState("codex");
  const [claudeSupported, setClaudeSupported] = useState(false);
  const [providerSwitchSupported, setProviderSwitchSupported] = useState(false);
  const [creatingProject, setCreatingProject] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [connected, setConnected] = useState(false);
  const [uncertain, setUncertain] = useState(false);
  const [switchStorageBlocked, setSwitchStorageBlocked] = useState(false);
  const [pendingSwitch, setPendingSwitch] = useState<PendingSwitch | null>(null);
  const generation = useRef(0);
  const current = useRef<ThreadSnapshot | null>(null);
  const pendingMessage = useRef<string | null>(null);
  const project = projects.find(p => p.id === projectId);
  const running = snapshot?.runs?.some(run => active(run.status)) ?? false;
  const uncertainRun = snapshot?.runs?.some(run => run.status === "outcome_unknown") ?? false;
  const publish = (next: ThreadSnapshot) => {
    current.current = next; setSnapshot(next); save(next);
    if (pendingMessage.current && next.messages.some(message => message.client_message_id === pendingMessage.current)) {
      pendingMessage.current = null; setUncertain(false); setDraft("");
    }
  };

  async function loadProjects() {
    const rows = await api.managedProjects();
    setProjects(rows);
    setProjectId(previous => rows.some(p => p.id === previous) ? previous : rows[0]?.id ?? "");
  }
  useEffect(() => {
    let cancelled = false;
    void api.managedEnvironment().then(value => { if (!cancelled) { setClaudeSupported(value.capabilities.includes("managed_claude_v1")); setProviderSwitchSupported(value.capabilities.includes("managed_provider_switch_v1")); } }).catch(() => { if (!cancelled) { setClaudeSupported(false); setProviderSwitchSupported(false); } });
    const refresh = async () => {
      try { const rows = await api.managedProjects(); if (!cancelled) { setProjects(rows); setProjectId(previous => rows.some(p => p.id === previous) ? previous : rows[0]?.id ?? ""); } }
      catch (cause) { if (!cancelled) setError(normalizeError(cause).message); }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [api]);
  useEffect(() => {
    let cancelled = false;
    setThreads([]); setThreadId("");
    if (!projectId) return;
    const refresh = async () => {
      try { const rows = await api.managedThreads(projectId); if (!cancelled) setThreads(rows); }
      catch (cause) { if (!cancelled) setError(normalizeError(cause).message); }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 3000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [api, projectId]);
  useEffect(() => {
    const epoch = ++generation.current;
    pendingMessage.current = null;
    setSnapshot(null); current.current = null; setConnected(false); setUncertain(false); setDraft(""); setError(null);
    setSwitchStorageBlocked(false);
    try {
      const raw = window.localStorage.getItem(switchKey(threadId));
      const pending = raw ? JSON.parse(raw) as PendingSwitch : null;
      if (pending && (pending.threadId !== threadId || !pending.commandId || !pending.toProviderId || !pending.expectedRevision)) throw new Error("Invalid pending switch");
      setPendingSwitch(pending);
    } catch { setPendingSwitch(null); setSwitchStorageBlocked(true); }
    if (!threadId) return;
    try { const raw = window.localStorage.getItem(cacheKey(threadId)); if (raw) { const cached = JSON.parse(raw) as ThreadSnapshot; if (cached.thread.id === threadId) publish(cached); } } catch { /* Fetch a clean snapshot below. */ }
    let cancelled = false;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    const valid = () => !cancelled && generation.current === epoch;
    const run = async () => {
      let state: ThreadSnapshot | null = null;
      while (valid()) {
        try {
          const authoritative = current.current;
          if (state && authoritative && authoritative.thread.id === threadId && BigInt(authoritative.sequence) >= BigInt(state.sequence)) state = authoritative;
          if (!state) state = await api.managedSnapshot(threadId);
          if (!valid()) return;
          publish(state); setConnected(true);
          const replay = await api.managedWait(state.environment_id, threadId, state.sequence);
          if (!valid()) return;
          const base: ThreadSnapshot = current.current && current.current.thread.id === threadId && BigInt(current.current.sequence) >= BigInt(state.sequence) ? current.current : state;
          const next: ThreadSnapshot = BigInt(base.sequence) > BigInt(replay.sequence) ? base : applyThreadReplay(base, replay);
          state = next;
          publish(next); setError(null);
        } catch (cause) {
          if (!valid()) return;
          setConnected(false);
          const failure = normalizeError(cause);
          if (failure.code === "resync_required") { state = null; continue; }
          setError(failure.message);
          if (cause instanceof UnsupportedThreadSchemaError) return;
          await new Promise<void>(resolve => { retryTimer = setTimeout(resolve, 1500); });
          state = null;
        }
      }
    };
    void run();
    return () => { cancelled = true; if (retryTimer) clearTimeout(retryTimer); };
  }, [api, threadId]);

  async function action(operation: () => Promise<unknown>) {
    if (busy) return;
    const epoch = generation.current;
    setBusy(true); setError(null); setNotice(null);
    try { await operation(); }
    catch (cause) { if (generation.current === epoch) setError(normalizeError(cause).message); }
    finally { setBusy(false); }
  }
  async function send() {
    if (!snapshot || !draft.trim() || busy || running || uncertainRun || uncertain || pendingSwitch || switchStorageBlocked || !connected) return;
    const original = draft;
    const epoch = generation.current;
    const commandId = newId(); const messageId = newId();
    pendingMessage.current = messageId;
    setBusy(true); setError(null);
    try {
      await api.managedSend(commandId, snapshot.thread.id, messageId, original, snapshot.thread.revision);
      if (generation.current === epoch) {
        pendingMessage.current = null;
        setDraft("");
        try { const latest = await api.managedSnapshot(snapshot.thread.id); if (generation.current === epoch) publish(latest); }
        catch (refreshCause) { if (generation.current === epoch) setError(normalizeError(refreshCause).message); }
      }
    } catch (cause) {
      if (generation.current !== epoch) return;
      const failure = normalizeError(cause);
      if (["outcome_unknown", "timeout", "network_error", "disconnected"].includes(failure.code)) {
        if (current.current?.messages.some(message => message.client_message_id === messageId)) {
          pendingMessage.current = null; setDraft(""); setUncertain(false); return;
        }
        setUncertain(true);
        // Retain the exact IDs. Reconciliation checks the stored user message;
        // it never creates a new command or blindly replays the text.
        try {
          const latest = await api.managedSnapshot(snapshot.thread.id);
          if (generation.current !== epoch) return;
          publish(latest);
          if (latest.messages.some(message => message.client_message_id === messageId)) { setDraft(""); setUncertain(false); }
        } catch { /* Explicit status remains visible. */ }
      } else { pendingMessage.current = null; }
      setError(failure.message);
    } finally { setBusy(false); }
  }
  async function switchProvider(target: string, retry?: PendingSwitch) {
    if (!snapshot || busy || switchStorageBlocked || (!retry && (pendingSwitch || uncertain || running || uncertainRun || snapshot.thread.status !== "idle" || snapshot.approvals?.some(value => value.state === "pending"))) || !connected) return;
    if (!retry && target === snapshot.thread.provider_id) return;
    const epoch = generation.current;
    const command = retry ?? { commandId: newId(), threadId: snapshot.thread.id, fromProviderId: snapshot.thread.provider_id, toProviderId: target, expectedRevision: snapshot.thread.revision };
    let accepted = false;
    setBusy(true); setError(null);
    try {
      window.localStorage.setItem(switchKey(command.threadId), JSON.stringify(command));
      setPendingSwitch(command);
      await api.managedProviderSet(command.commandId, command.threadId, command.toProviderId, null, command.expectedRevision);
      accepted = true;
      const latest = await api.managedSnapshot(command.threadId);
      window.localStorage.removeItem(switchKey(command.threadId));
      if (generation.current !== epoch) return;
      if (!current.current || BigInt(latest.sequence) >= BigInt(current.current.sequence)) publish(latest);
      setPendingSwitch(null);
    } catch (cause) {
      const failure = normalizeError(cause);
      if (!accepted && !["outcome_unknown", "timeout", "network_error", "disconnected"].includes(failure.code)) {
        try { window.localStorage.removeItem(switchKey(command.threadId)); } catch { /* Storage failure occurs before dispatch. */ }
        if (generation.current === epoch) setPendingSwitch(null);
      }
      if (generation.current === epoch) setError(failure.message);
    } finally { setBusy(false); }
  }
  async function older() {
    if (!snapshot) return;
    const original = snapshot.thread.id;
    const page = await api.managedHistory(original, snapshot.messages[0]?.id ?? null);
    if (current.current?.thread.id !== original) return;
    const next = current.current;
    const existing = new Set(next.messages.map(message => message.id));
    publish({ ...next, messages: [...page.messages.filter(message => !existing.has(message.id)), ...next.messages], has_older_messages: page.has_more });
  }
  return <div className="managed-workspace">
    <aside className="managed-sidebar">
      <div className="section-head"><h2>共享项目</h2><button className="text-button" onClick={() => setCreatingProject(value => !value)}>添加</button></div>
      {creatingProject && <form className="managed-form" onSubmit={event => { event.preventDefault(); void action(async () => { const created = await api.managedCreateProject(newId(), path.trim(), name.trim()); await loadProjects(); setProjectId(created.id); setCreatingProject(false); setName(""); setPath(""); }); }}>
        <label>项目名称<input value={name} onChange={event => setName(event.target.value)} required maxLength={128} /></label>
        <label>Mac 项目路径<input value={path} onChange={event => setPath(event.target.value)} placeholder="/Users/…/project" required /></label>
        <button className="button primary" disabled={busy}>创建项目</button>
      </form>}
      {projects.map(p => <button className={`managed-row ${projectId === p.id ? "active" : ""}`} key={p.id} onClick={() => setProjectId(p.id)}>{p.name}</button>)}
      {!projects.length && <p className="subtle">添加一个 Mac 本地项目，即可与手机共同使用。</p>}
      {project && <><p className="subtle managed-path" title={project.canonical_root}>{project.canonical_root}</p><details><summary>共享给设备</summary>{devices.length ? devices.map(device => <button key={device.device_id} className="managed-row" disabled={busy} onClick={() => void action(async () => { await api.managedShareProject(project.id, device.device_id); setNotice(`已允许 ${device.name} 访问项目`); })}>{device.name}<span>授予访问</span></button>) : <p className="subtle">请先配对手机。</p>}</details>
        <div className="section-head"><h2>共享对话</h2></div>
        <form className="managed-form" onSubmit={event => { event.preventDefault(); void action(async () => { if (providerId === "claude" && !claudeSupported) return; const created = await api.managedCreateThread(newId(), projectId, title.trim() || "新对话", providerId); setThreads(await api.managedThreads(projectId)); setThreadId(created.id); setTitle(""); setProviderId("codex"); }); }}><label>Agent<select aria-label="对话 Agent" value={providerId} onChange={event => setProviderId(event.target.value)}><option value="codex">Codex</option><option value="claude" disabled={!claudeSupported}>Claude{claudeSupported ? "" : "（需更新 Mac）"}</option></select></label><input aria-label="新对话标题" value={title} onChange={event => setTitle(event.target.value)} placeholder="新对话标题" maxLength={128} /><button className="button secondary" disabled={busy}>新建对话</button></form>
      </>}
      {threads.map(t => <button className={`managed-row ${threadId === t.id ? "active" : ""}`} key={t.id} onClick={() => setThreadId(t.id)}><span>{t.title}</span><small>{providerLabel(t.provider_id)} · {statusText(t.status)}</small></button>)}
    </aside>
    <section className="managed-chat">
      {snapshot ? <><div className="section-head"><h2>{snapshot.thread.title}</h2><span className="subtle">{providerLabel(snapshot.thread.provider_id)} · {connected ? statusText(snapshot.thread.status) : "重新连接中"}</span><label className="subtle">Agent<select aria-label="当前对话 Agent" value={snapshot.thread.provider_id} disabled={!providerSwitchSupported || busy || running || uncertainRun || uncertain || !!pendingSwitch || switchStorageBlocked || snapshot.thread.status !== "idle" || snapshot.approvals?.some(value => value.state === "pending") || !connected} onChange={event => { const target = event.target.value; void switchProvider(target); }}><option value="codex">Codex</option><option value="claude" disabled={!claudeSupported}>Claude{claudeSupported ? "" : "（需更新 Mac）"}</option></select></label></div>
        {running && <button className="text-button" disabled={busy || !connected} onClick={() => void action(() => api.managedInterrupt(newId(), snapshot.thread.id))}>停止执行</button>}
        <div className="managed-messages" aria-live="polite">
          {snapshot.has_older_messages && <button className="text-button" disabled={busy} onClick={() => void action(older)}>加载更早消息</button>}
        {snapshot.messages.map(message => <article className={`managed-message ${message.role}`} key={message.id}><small>{message.content.type === "provider_switch" ? `${providerLabel(message.content.from_provider_id ?? "")} → ${providerLabel(message.content.to_provider_id ?? "")}` : message.role === "user" ? "你" : message.role === "tool" ? message.content.tool_name ?? "工具" : message.role === "summary" ? "公开摘要" : (message.content.provider_id ? providerLabel(message.content.provider_id) : "历史助手")}</small><div>{message.content.text ?? ""}</div>{message.content.failed === true && <small className="danger-text">执行失败</small>}</article>)}
          {snapshot.approvals?.filter(approval => approval.state === "pending").map(approval => <article className="managed-approval" key={approval.id}><strong>需要批准 · {approval.kind}</strong><p>{approval.target}</p><pre>{approval.detail}</pre><div className="managed-actions"><button className="button secondary" disabled={busy || !connected} onClick={() => void action(() => api.managedApproval(newId(), snapshot.thread.id, approval.id, false))}>拒绝</button><button className="button primary" disabled={busy || !connected} onClick={() => void action(() => api.managedApproval(newId(), snapshot.thread.id, approval.id, true))}>批准这一次</button></div></article>)}
        </div>
        {uncertain && <p role="status" className="subtle">发送结果尚未确认。已暂停再次发送，请等待同步或在 Mac 检查执行状态。</p>}
        {switchStorageBlocked && <p role="alert">无法读取 Agent 切换记录。请恢复本地存储后重新打开对话，发送已暂停。</p>}
        {pendingSwitch && <p role="status" className="subtle">正在确认 Agent 切换：{providerLabel(pendingSwitch.fromProviderId)} → {providerLabel(pendingSwitch.toProviderId)}。同步完成前已暂停发送。<button className="text-button" disabled={busy || !connected} onClick={() => void switchProvider(pendingSwitch.toProviderId, pendingSwitch)}>重新确认切换</button></p>}
        <div className="managed-composer"><textarea aria-label="共享对话消息" value={draft} onChange={event => setDraft(event.target.value)} placeholder={`给 ${providerLabel(snapshot.thread.provider_id)} 发消息…`} maxLength={262144} /><button className="button primary" disabled={busy || !draft.trim() || running || uncertainRun || uncertain || !!pendingSwitch || switchStorageBlocked || !connected} onClick={() => void send()}>{busy ? "处理中…" : "发送"}</button></div>
      </> : <div className="loading-state"><p>{threadId ? "正在同步对话…" : "选择或新建对话，手机与 Mac 将共享消息和执行状态。"}</p></div>}
      {error && <p className="danger-text" role="alert">{error}</p>}{notice && <p role="status" className="subtle">{notice}</p>}
    </section>
  </div>;
}
