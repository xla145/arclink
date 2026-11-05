import { useCallback, useEffect, useRef, useState } from "react";
import { normalizeError, type Bridge } from "../bridge";
import type { BridgeError, UpdateStatus } from "../types";

export function useUpdate(api: Bridge, preview: boolean) {
  const [status, setStatus] = useState<UpdateStatus | null>(null);
  const [pollError, setPollError] = useState<BridgeError | null>(null);
  const [error, setError] = useState<BridgeError | null>(null);
  const live = useRef(false);
  const revision = useRef(-1n);
  const apply = useCallback((next: UpdateStatus) => {
    if (!live.current || BigInt(next.revision) < revision.current) return;
    revision.current = BigInt(next.revision);
    setStatus(next);
  }, []);
  useEffect(() => {
    live.current = true;
    revision.current = -1n;
    if (preview)
      return () => {
        live.current = false;
      };
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    // Polling also recovers progress after WebView suspension or a missed response.
    // Native commands enqueue work and return immediately; no long IPC timeout.
    const poll = async () => {
      try {
        const next = await api.updateStatus();
        if (!cancelled) {
          apply(next);
          setPollError(null);
        }
      } catch (cause) {
        if (!cancelled) setPollError(normalizeError(cause));
      } finally {
        if (!cancelled) timer = setTimeout(() => void poll(), 1000);
      }
    };
    void api
      .checkUpdate(true)
      .then((next) => {
        if (!cancelled) apply(next);
      })
      .catch((cause) => {
        if (!cancelled) setError(normalizeError(cause));
      });
    void poll();
    return () => {
      cancelled = true;
      live.current = false;
      clearTimeout(timer);
    };
  }, [api, apply, preview]);
  const run = useCallback(
    async (operation: () => Promise<UpdateStatus>) => {
      setError(null);
      try {
        apply(await operation());
      } catch (cause) {
        if (live.current) setError(normalizeError(cause));
      }
    },
    [apply],
  );
  return { status, error: error ?? pollError, run };
}
