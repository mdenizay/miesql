import { useEffect, useState } from "react";
import { api } from "../lib/api";
import type { AppSettings } from "../lib/types";
import type { useUpdater } from "../lib/useUpdater";

interface Props {
  settings: AppSettings;
  onChange: (settings: AppSettings) => void;
  updater: ReturnType<typeof useUpdater>;
  onClose: () => void;
}

export function SettingsDialog({ settings, onChange, updater, onClose }: Props) {
  const [dataDir, setDataDir] = useState("");
  const patch = (changes: Partial<AppSettings>) => onChange({ ...settings, ...changes });

  useEffect(() => {
    void api.dataDirectory().then(setDataDir);
  }, []);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog">
        <h2>Settings</h2>
        <div className="dialog-body">
          <div className="field">
            <label>Appearance</label>
            <select value={settings.appearance} onChange={(e) => patch({ appearance: e.target.value as never })}>
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </div>

          <div className="row">
            <div className="field" style={{ flex: 1 }}>
              <label>Editor font size</label>
              <input
                type="number"
                value={settings.editorFontSize}
                onChange={(e) => patch({ editorFontSize: Number(e.target.value) || 13 })}
              />
            </div>
            <div className="field" style={{ flex: 1 }}>
              <label>Grid font size</label>
              <input
                type="number"
                value={settings.gridFontSize}
                onChange={(e) => patch({ gridFontSize: Number(e.target.value) || 12 })}
              />
            </div>
          </div>

          <label className="check">
            <input
              type="checkbox"
              checked={settings.showLineNumbers}
              onChange={(e) => patch({ showLineNumbers: e.target.checked })}
            />
            Show line numbers
          </label>
          <label className="check">
            <input
              type="checkbox"
              checked={settings.wrapLongLines}
              onChange={(e) => patch({ wrapLongLines: e.target.checked })}
            />
            Wrap long lines
          </label>

          <div className="field">
            <label>Maximum rows per query</label>
            <input
              type="number"
              value={settings.maxResultRows}
              onChange={(e) => patch({ maxResultRows: Number(e.target.value) || 50000 })}
            />
          </div>

          <hr style={{ border: 0, borderTop: "1px solid var(--border)", width: "100%" }} />

          <label className="check">
            <input
              type="checkbox"
              checked={settings.checkForUpdates}
              onChange={(e) => patch({ checkForUpdates: e.target.checked })}
            />
            Check for updates at launch
          </label>
          <label className="check">
            <input
              type="checkbox"
              checked={settings.downloadUpdatesAutomatically}
              disabled={!settings.checkForUpdates}
              onChange={(e) => patch({ downloadUpdatesAutomatically: e.target.checked })}
            />
            Download updates automatically
          </label>
          <div className="hint">
            An update is never applied on its own: it installs when you choose to restart,
            so it cannot interrupt a query.
          </div>

          <div className="row">
            <button onClick={() => void updater.checkNow()} disabled={updater.stage.kind === "checking"}>
              {updater.stage.kind === "checking" ? "Checking…" : "Check now"}
            </button>
            {updater.stage.kind === "failed" && <span className="bad">{updater.stage.message}</span>}
            {updater.stage.kind === "idle" && <span className="hint">Up to date.</span>}
            {updater.stage.kind === "ready" && <span className="good">{updater.stage.version} ready.</span>}
          </div>

          <hr style={{ border: 0, borderTop: "1px solid var(--border)", width: "100%" }} />

          <div className="hint">
            MieSQL stores everything on this device. It makes no network calls except to the
            databases you connect to and, if enabled above, the update check.
          </div>
          <div className="field">
            <label>Data is stored at</label>
            <input readOnly value={dataDir} style={{ fontFamily: "var(--mono)", fontSize: 11 }} />
          </div>
        </div>

        <div className="dialog-footer">
          <button className="primary" onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}
