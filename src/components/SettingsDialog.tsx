import { useEffect, useState } from "react";
import { api } from "../lib/api";
import { LANGUAGES, type LanguageCode, type Translate } from "../lib/i18n";
import type { AppSettings } from "../lib/types";
import type { useUpdater } from "../lib/useUpdater";

interface Props {
  settings: AppSettings;
  t: Translate;
  onChange: (settings: AppSettings) => void;
  updater: ReturnType<typeof useUpdater>;
  onClose: () => void;
}

export function SettingsDialog({ settings, t, onChange, updater, onClose }: Props) {
  const [dataDir, setDataDir] = useState("");
  const patch = (changes: Partial<AppSettings>) => onChange({ ...settings, ...changes });

  useEffect(() => {
    void api.dataDirectory().then(setDataDir);
  }, []);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog">
        <h2>{t("settings.title")}</h2>
        <div className="dialog-body">
          <div className="field">
            <label>{t("settings.appearance")}</label>
            <select value={settings.appearance} onChange={(e) => patch({ appearance: e.target.value as never })}>
              <option value="system">{t("settings.system")}</option>
              <option value="light">{t("settings.light")}</option>
              <option value="dark">{t("settings.dark")}</option>
            </select>
          </div>

          <div className="field">
            <label>{t("settings.language")}</label>
            <select
              value={settings.languageCode}
              onChange={(e) => patch({ languageCode: e.target.value as LanguageCode })}
            >
              {LANGUAGES.map((language) => (
                <option key={language.code} value={language.code}>
                  {language.label}
                </option>
              ))}
            </select>
          </div>

          <div className="row">
            <div className="field" style={{ flex: 1 }}>
              <label>{t("settings.editorFont")}</label>
              <input
                type="number"
                value={settings.editorFontSize}
                onChange={(e) => patch({ editorFontSize: Number(e.target.value) || 13 })}
              />
            </div>
            <div className="field" style={{ flex: 1 }}>
              <label>{t("settings.gridFont")}</label>
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
            {t("settings.lineNumbers")}
          </label>
          <label className="check">
            <input
              type="checkbox"
              checked={settings.wrapLongLines}
              onChange={(e) => patch({ wrapLongLines: e.target.checked })}
            />
            {t("settings.wrapLines")}
          </label>

          <div className="row">
            <div className="field" style={{ flex: 1 }}>
              <label>{t("settings.pageSize")}</label>
              <input
                type="number"
                value={settings.pageSize}
                onChange={(e) => patch({ pageSize: Number(e.target.value) || 200 })}
              />
            </div>
            <div className="field" style={{ flex: 1 }}>
              <label>{t("settings.maxRows")}</label>
              <input
                type="number"
                value={settings.maxResultRows}
                onChange={(e) => patch({ maxResultRows: Number(e.target.value) || 50000 })}
              />
            </div>
          </div>

          <label className="check">
            <input
              type="checkbox"
              checked={settings.confirmDestructiveStatements}
              onChange={(e) => patch({ confirmDestructiveStatements: e.target.checked })}
            />
            {t("settings.confirmDestructive")}
          </label>

          <hr className="divider" />

          <label className="check">
            <input
              type="checkbox"
              checked={settings.checkForUpdates}
              onChange={(e) => patch({ checkForUpdates: e.target.checked })}
            />
            {t("settings.checkUpdates")}
          </label>
          <label className="check">
            <input
              type="checkbox"
              checked={settings.downloadUpdatesAutomatically}
              disabled={!settings.checkForUpdates}
              onChange={(e) => patch({ downloadUpdatesAutomatically: e.target.checked })}
            />
            {t("settings.autoDownload")}
          </label>
          <div className="hint">{t("settings.updateHint")}</div>

          <div className="row">
            <button onClick={() => void updater.checkNow()} disabled={updater.stage.kind === "checking"}>
              {t("settings.checkNow")}
            </button>
            {updater.stage.kind === "failed" && <span className="bad">{updater.stage.message}</span>}
            {updater.stage.kind === "idle" && <span className="hint">{t("settings.upToDate")}</span>}
            {updater.stage.kind === "ready" && (
              <span className="good">{t("update.ready", updater.stage.version)}</span>
            )}
          </div>

          <hr className="divider" />
          <div className="hint">{t("settings.privacy")}</div>
          <div className="field">
            <label>{t("settings.dataLocation")}</label>
            <input readOnly value={dataDir} style={{ fontFamily: "var(--mono)", fontSize: 11 }} />
          </div>
        </div>

        <div className="dialog-footer">
          <div className="spacer" />
          <button className="primary" onClick={onClose}>{t("general.done")}</button>
        </div>
      </div>
    </div>
  );
}
