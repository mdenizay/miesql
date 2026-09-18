import { useEffect, useState } from "react";
import { readText } from "@tauri-apps/plugin-clipboard-manager";
import { open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { api } from "../lib/api";
import type { Translate } from "../lib/i18n";
import { DEFAULT_PORTS, errorText, type ConnectionProfile, type DatabaseKind } from "../lib/types";

interface Props {
  initial: ConnectionProfile;
  startInUrlMode: boolean;
  t: Translate;
  credentialStore: boolean;
  onSaved: (profiles: ConnectionProfile[]) => void;
  onClose: () => void;
}

const KINDS: DatabaseKind[] = ["postgres", "mysql", "mariadb", "sqlite", "redis"];
const KIND_LABELS: Record<string, string> = {
  postgres: "PostgreSQL",
  mysql: "MySQL",
  mariadb: "MariaDB",
  sqlite: "SQLite",
  redis: "Redis",
  mongodb: "MongoDB",
};

export function ConnectionDialog({
  initial,
  startInUrlMode,
  t,
  credentialStore,
  onSaved,
  onClose,
}: Props) {
  const [draft, setDraft] = useState(initial);
  const [password, setPassword] = useState("");
  const [sshPassword, setSshPassword] = useState("");
  const [urlText, setUrlText] = useState("");
  const [urlOpen, setUrlOpen] = useState(startInUrlMode);
  const [note, setNote] = useState<{ kind: "ok" | "bad" | "hint"; text: string } | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const [test, setTest] = useState<{ kind: "idle" | "busy" | "ok" | "bad"; text: string }>({
    kind: "idle",
    text: "",
  });

  const patch = (changes: Partial<ConnectionProfile>) => setDraft((d) => ({ ...d, ...changes }));
  const isFile = draft.kind === "sqlite";

  useEffect(() => {
    if (!startInUrlMode) return;
    void (async () => {
      try {
        const clipboard = await readText();
        if (clipboard && (await api.looksLikeConnectionUrl(clipboard))) {
          setUrlText(clipboard.trim());
          setNote({ kind: "hint", text: t("connection.urlClipboard") });
        }
      } catch {
        // Clipboard access can be refused; not worth reporting.
      }
    })();
  }, [startInUrlMode, t]);

  async function applyUrl() {
    try {
      const parsed = await api.parseConnectionUrl(urlText);
      // Editing keeps identity, folder and tunnel settings; only what the URL carries moves.
      setDraft({
        ...parsed.profile,
        id: draft.id,
        folder: draft.folder,
        colorHex: draft.colorHex,
        notes: draft.notes,
        name: draft.name || parsed.profile.name,
        sshEnabled: draft.sshEnabled,
        sshHost: draft.sshHost,
        sshPort: draft.sshPort,
        sshUsername: draft.sshUsername,
        sshKeyPath: draft.sshKeyPath,
      });
      if (parsed.password) setPassword(parsed.password);
      setWarnings(parsed.warnings);
      setNote({ kind: "ok", text: t("connection.urlApplied") });
      setTest({ kind: "idle", text: "" });
    } catch (e) {
      setWarnings([]);
      setNote({ kind: "bad", text: errorText(e) });
    }
  }

  const invalid =
    (isFile ? !draft.filePath : !draft.host || !draft.port) ||
    (draft.sshEnabled && !draft.sshHost);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" style={{ maxHeight: "88vh" }}>
        <h2>{initial.name || initial.host !== "127.0.0.1" ? t("connection.edit") : t("connection.new")}</h2>
        <div className="dialog-body">
          <div>
            <button className="quiet" onClick={() => setUrlOpen((v) => !v)}>
              {urlOpen ? "▾" : "▸"} {t("connection.addFromUrl")}
            </button>
            {urlOpen && (
              <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 6 }}>
                <input
                  value={urlText}
                  placeholder={t("connection.urlPlaceholder")}
                  style={{ fontFamily: "var(--mono)" }}
                  onChange={(e) => setUrlText(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && applyUrl()}
                />
                <div className="row">
                  <button onClick={applyUrl} disabled={!urlText.trim()}>
                    {t("connection.fillFields")}
                  </button>
                </div>
                {note && (
                  <div className={note.kind === "bad" ? "bad" : note.kind === "ok" ? "good" : "hint"}>
                    {note.text}
                  </div>
                )}
                {/* Anything understood but not honoured exactly is said out loud. */}
                {warnings.map((warning) => (
                  <div className="warn" key={warning}>{warning}</div>
                ))}
                {!note && <div className="hint">{t("connection.urlHelp")}</div>}
              </div>
            )}
          </div>

          <div className="field">
            <label>{t("connection.name")}</label>
            <input value={draft.name} onChange={(e) => patch({ name: e.target.value })} />
          </div>

          <div className="field">
            <label>{t("connection.type")}</label>
            <select
              value={draft.kind}
              onChange={(e) => {
                const kind = e.target.value as DatabaseKind;
                patch({ kind, port: DEFAULT_PORTS[kind] });
              }}
            >
              {KINDS.map((kind) => (
                <option key={kind} value={kind}>{KIND_LABELS[kind]}</option>
              ))}
            </select>
          </div>

          {isFile ? (
            <div className="field">
              <label>{t("connection.file")}</label>
              <div className="row">
                <input value={draft.filePath} onChange={(e) => patch({ filePath: e.target.value })} />
                <button
                  onClick={async () => {
                    const picked = await openFileDialog({ multiple: false, directory: false });
                    if (typeof picked === "string") {
                      patch({
                        filePath: picked,
                        name: draft.name || picked.split("/").pop()?.replace(/\.[^.]+$/, "") || "",
                      });
                    }
                  }}
                >
                  {t("general.browse")}
                </button>
              </div>
            </div>
          ) : (
            <>
              <div className="row">
                <div className="field" style={{ flex: 1 }}>
                  <label>{t("connection.host")}</label>
                  <input value={draft.host} onChange={(e) => patch({ host: e.target.value })} />
                </div>
                <div className="field" style={{ width: 90 }}>
                  <label>{t("connection.port")}</label>
                  <input
                    value={draft.port}
                    onChange={(e) => patch({ port: Number(e.target.value) || 0 })}
                  />
                </div>
              </div>
              <div className="field">
                <label>{t("connection.user")}</label>
                <input value={draft.username} onChange={(e) => patch({ username: e.target.value })} />
              </div>
              <div className="field">
                <label>{t("connection.password")}</label>
                <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
              </div>
              <div className="field">
                <label>{t("connection.database")}</label>
                <input value={draft.database} onChange={(e) => patch({ database: e.target.value })} />
              </div>
              <div className="field">
                <label>{t("connection.ssl")}</label>
                <select value={draft.sslMode} onChange={(e) => patch({ sslMode: e.target.value as never })}>
                  <option value="disable">Disable</option>
                  <option value="prefer">Prefer</option>
                  <option value="require">Require</option>
                </select>
              </div>
              <label className="check">
                <input
                  type="checkbox"
                  checked={draft.savePassword}
                  disabled={!credentialStore}
                  onChange={(e) => patch({ savePassword: e.target.checked })}
                />
                {t("connection.savePassword")}
              </label>
              {!credentialStore && <div className="warn">{t("connection.noCredentialStore")}</div>}
            </>
          )}

          <label className="check">
            <input type="checkbox" checked={draft.readOnly} onChange={(e) => patch({ readOnly: e.target.checked })} />
            {t("connection.readOnly")}
          </label>
          <div className="hint">{t("connection.readOnlyHint")}</div>

          {!isFile && (
            <>
              <hr className="divider" />
              <div className="section-title">{t("ssh.section")}</div>
              <label className="check">
                <input
                  type="checkbox"
                  checked={draft.sshEnabled}
                  onChange={(e) => patch({ sshEnabled: e.target.checked })}
                />
                {t("ssh.enabled")}
              </label>
              {draft.sshEnabled && (
                <>
                  <div className="hint">{t("ssh.hostHint")}</div>
                  <div className="row">
                    <div className="field" style={{ flex: 1 }}>
                      <label>{t("ssh.host")}</label>
                      <input value={draft.sshHost} onChange={(e) => patch({ sshHost: e.target.value })} />
                    </div>
                    <div className="field" style={{ width: 90 }}>
                      <label>{t("ssh.port")}</label>
                      <input
                        value={draft.sshPort}
                        onChange={(e) => patch({ sshPort: Number(e.target.value) || 22 })}
                      />
                    </div>
                  </div>
                  <div className="field">
                    <label>{t("ssh.user")}</label>
                    <input value={draft.sshUsername} onChange={(e) => patch({ sshUsername: e.target.value })} />
                  </div>
                  <div className="field">
                    <label>{t("ssh.keyPath")}</label>
                    <div className="row">
                      <input value={draft.sshKeyPath} onChange={(e) => patch({ sshKeyPath: e.target.value })} />
                      <button
                        onClick={async () => {
                          const picked = await openFileDialog({ multiple: false, directory: false });
                          if (typeof picked === "string") patch({ sshKeyPath: picked });
                        }}
                      >
                        {t("general.browse")}
                      </button>
                    </div>
                  </div>
                  <div className="field">
                    <label>{t("ssh.password")}</label>
                    <input
                      type="password"
                      value={sshPassword}
                      onChange={(e) => setSshPassword(e.target.value)}
                    />
                  </div>
                  <div className="hint">{t("ssh.keyHint")}</div>
                </>
              )}
            </>
          )}

          <hr className="divider" />
          <div className="field">
            <label>{t("connection.folder")}</label>
            <input value={draft.folder} onChange={(e) => patch({ folder: e.target.value })} />
          </div>
        </div>

        <div className="dialog-footer">
          <button
            disabled={test.kind === "busy" || invalid}
            onClick={async () => {
              setTest({ kind: "busy", text: "…" });
              try {
                const info = await api.testConnection(draft, password || undefined, sshPassword || undefined);
                setTest({ kind: "ok", text: `${info.productName} ${info.version}` });
              } catch (e) {
                setTest({ kind: "bad", text: errorText(e) });
              }
            }}
          >
            {t("general.test")}
          </button>
          {test.kind !== "idle" && (
            <div
              className={test.kind === "bad" ? "bad" : test.kind === "ok" ? "good" : "hint"}
              style={{ flex: 1, alignSelf: "center", maxHeight: 48, overflow: "auto" }}
            >
              {test.text}
            </div>
          )}
          <div className="spacer" />
          <button onClick={onClose}>{t("general.cancel")}</button>
          <button
            className="primary"
            disabled={invalid}
            onClick={async () => {
              try {
                onSaved(
                  await api.saveProfile(draft, password || undefined, sshPassword || undefined),
                );
                onClose();
              } catch (e) {
                setTest({ kind: "bad", text: errorText(e) });
              }
            }}
          >
            {t("general.save")}
          </button>
        </div>
      </div>
    </div>
  );
}
