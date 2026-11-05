import { useEffect, useState } from "react";
import type { Snapshot } from "../types";

// The timer only advances an already observed duration; it never polls the daemon.
export function useUptime(snapshot: Snapshot | null) {
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    setElapsed(0);
    if (!snapshot?.status.running) return;
    const receivedAt = performance.now();
    const timer = window.setInterval(
      () => setElapsed(Math.floor((performance.now() - receivedAt) / 1000)),
      1000,
    );
    return () => window.clearInterval(timer);
  }, [snapshot]);
  return (snapshot?.status.uptime_secs ?? 0) + elapsed;
}
