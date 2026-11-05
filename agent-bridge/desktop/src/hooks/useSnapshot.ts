import { useCallback, useEffect, useRef, useState } from "react";
import { normalizeError, type Bridge } from "../bridge";
import type { BridgeError, Snapshot } from "../types";

export function newerSnapshot(
  previous: Snapshot | null,
  incoming: Snapshot,
): Snapshot {
  if (!previous || incoming.service_instance !== previous.service_instance)
    return incoming;
  return BigInt(incoming.revision) >= BigInt(previous.revision)
    ? incoming
    : previous;
}

export function useSnapshot(
  api: Bridge,
  onSettings: () => void,
  onExit: () => void,
) {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<BridgeError | null>(null);
  const [loading, setLoading] = useState(true);
  const lifecycle = useRef(0);
  const request = useRef(0);
  const retiredInstances = useRef(new Set<string>());
  const currentSnapshot = useRef<Snapshot | null>(null);
  const accept = useCallback((next: Snapshot) => {
    if (retiredInstances.current.has(next.service_instance)) return;
    const previous = currentSnapshot.current;
    if (previous && previous.service_instance !== next.service_instance)
      retiredInstances.current.add(previous.service_instance);
    const accepted = newerSnapshot(previous, next);
    currentSnapshot.current = accepted;
    setSnapshot(accepted);
    setLoading(false);
    setError(null);
  }, []);
  const refresh = useCallback(async () => {
    const owner = lifecycle.current;
    const id = ++request.current;
    try {
      const next = await api.snapshot();
      if (owner === lifecycle.current && id === request.current) accept(next);
    } catch (cause) {
      if (owner === lifecycle.current && id === request.current) {
        setError(normalizeError(cause));
        setLoading(false);
      }
    }
  }, [api, accept]);
  useEffect(() => {
    const owner = ++lifecycle.current;
    let unlisten: (() => void) | undefined;
    void api
      .subscribe(
        (next) => {
          if (owner === lifecycle.current) {
            ++request.current;
            accept(next);
          }
        },
        () => {
          if (owner === lifecycle.current) void refresh();
        },
        onSettings,
        onExit,
      )
      .then((cleanup) => {
        if (owner !== lifecycle.current) cleanup();
        else {
          unlisten = cleanup;
          void refresh();
        }
      })
      .catch((cause) => {
        if (owner === lifecycle.current) {
          setError(normalizeError(cause));
          setLoading(false);
        }
      });
    const onFocus = () => {
      void refresh();
    };
    window.addEventListener("focus", onFocus);
    return () => {
      ++lifecycle.current;
      ++request.current;
      unlisten?.();
      window.removeEventListener("focus", onFocus);
    };
  }, [api, accept, onSettings, onExit, refresh]);
  return { snapshot, error, loading, refresh };
}
