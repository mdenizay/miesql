import { useCallback, useEffect, useRef, useState } from "react";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";

export type UpdateStage =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "available"; version: string; notes: string }
  | { kind: "downloading"; version: string; percent: number }
  | { kind: "ready"; version: string }
  | { kind: "installing" }
  | { kind: "failed"; message: string };

interface Options {
  enabled: boolean;
  downloadAutomatically: boolean;
}

/**
 * Update handling, deliberately split into download and install.
 *
 * A database client that restarts itself while a migration is halfway through would be
 * worse than one that updates a day late, so nothing here ever relaunches on its own:
 * the new version is fetched quietly in the background, and the only automatic step stops
 * at "ready". Applying it is one click, at a moment the user picks.
 */
export function useUpdater({ enabled, downloadAutomatically }: Options) {
  const [stage, setStage] = useState<UpdateStage>({ kind: "idle" });
  const [dismissed, setDismissed] = useState(false);
  const pending = useRef<Update | null>(null);

  const download = useCallback(async (update: Update) => {
    setStage({ kind: "downloading", version: update.version, percent: 0 });
    try {
      let total = 0;
      let received = 0;
      await update.download((event) => {
        if (event.event === "Started") {
          total = event.data.contentLength ?? 0;
        } else if (event.event === "Progress") {
          received += event.data.chunkLength;
          const percent = total > 0 ? Math.min(100, Math.round((received / total) * 100)) : 0;
          setStage({ kind: "downloading", version: update.version, percent });
        }
      });
      setStage({ kind: "ready", version: update.version });
    } catch (error) {
      setStage({ kind: "failed", message: String(error) });
    }
  }, []);

  const runCheck = useCallback(
    async (automatic: boolean) => {
      setStage({ kind: "checking" });
      try {
        const update = await check();
        if (!update) {
          setStage({ kind: "idle" });
          return false;
        }
        pending.current = update;
        setDismissed(false);
        if (automatic && downloadAutomatically) {
          await download(update);
        } else {
          setStage({ kind: "available", version: update.version, notes: update.body ?? "" });
        }
        return true;
      } catch (error) {
        // A failed check is not worth interrupting anyone over — most often it just means
        // there is no network. It stays visible in Settings.
        setStage({ kind: "failed", message: String(error) });
        return false;
      }
    },
    [download, downloadAutomatically],
  );

  const startDownload = useCallback(async () => {
    if (pending.current) await download(pending.current);
  }, [download]);

  const installAndRestart = useCallback(async () => {
    if (!pending.current) return;
    setStage({ kind: "installing" });
    try {
      await pending.current.install();
      await relaunch();
    } catch (error) {
      setStage({ kind: "failed", message: String(error) });
    }
  }, []);

  useEffect(() => {
    if (!enabled) return;
    // A few seconds after launch, so the check never competes with the first connection.
    const timer = setTimeout(() => void runCheck(true), 4000);
    return () => clearTimeout(timer);
    // Only ever runs once per launch; re-checks are manual, from Settings.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled]);

  return {
    stage,
    dismissed,
    dismiss: () => setDismissed(true),
    checkNow: () => runCheck(false),
    startDownload,
    installAndRestart,
  };
}
