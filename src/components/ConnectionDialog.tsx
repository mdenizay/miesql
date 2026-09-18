import { useEffect, useState } from "react";
import { readText } from "@tauri-apps/plugin-clipboard-manager";
import { open as openFileDialog } from "@tauri-apps/plugin-dialog";
import { api } from "../lib/api";
import { DEFAULT_PORTS, errorText, type ConnectionProfile, type DatabaseKind } from "../lib/types";

interface Props {
  initial: ConnectionProfile;
  startInUrlMode: boolean;
  onSaved: (profiles: ConnectionProfile[]) => void;
  onClose: () => void;
}

const KINDS: DatabaseKind[] = ["postgres", "mysql", "mariadb", "sqlite", "redis", "mongodb"];
const KIND_LABELS: Record<DatabaseKind, string> = {
  postgres: "PostgreSQL",
  mysql: "MySQL",
  mariadb: "MariaDB",
  sqlite: "SQLite",
  redis: "Redis",
  mongodb: "MongoDB",
};

export function ConnectionDialog({ initial, startInUrlMode, onSaved, onClose }: Props) {
  const [draft, setDraft] = useState(initial);
  const [password, setPassword] = useState("");
  const [urlText, setUrlText] = useState("");
  const [urlOpen, setUrlOpen] = useState(startInUrlMode);
  const [urlNote, setUrlNote] = useState<{ kind: "ok" | "bad" | "hint"; text: string } | null>(null);
  const [warnings, setWarnings] = useState<string[]>([]);
  const [testState, setTestState] = useState<{ kind: "idle" | "busy" | "ok" | "bad"; text: string }>({
    kind: "idle",
    text: "",
  });

  const patch = (changes: Partial<ConnectionProfile>) => setDraft((d) => ({ ...d, ...changes }));

  // Most people arrive here straight from a hosting dashboard, so offer what is already
  // on the clipboard rather than making them paste it.
  useEffect(() => {
    if (!startInUrlMode) return;
    void (async () => {
      try {
        const clipboard = await readText();
        if (clipboard && (await api.looksLikeConnectionUrl(clipboard))) {
          setUrlText(clipboard.trim());
          setUrlNote({ kind: "hint", text: "Found a connection URL on the clipboard." });
        }
      } catch {
        // Clipboard access can be refused; that is not worth reporting.
      }
    })();
  }, [startInUrlMode]);

  async function applyUrl() {
    try {
      const parsed = await api.parseConnectionUrl(urlText);
      // Editing an existing connection keeps its identity, folder and colour; only what
      // the URL actually carries is replaced.
      setDraft({
        ...parsed.profile,
        id: draft.id,
        folder: draft.folder,
        colorHex: draft.colorHex,
        notes: draft.notes,
        name: draft.name || parsed.profile.name,
      });
      if (parsed.password) setPassword(parsed.password);
      setWarnings(parsed.warnings);
      setUrlNote({ kind: "ok", text: "Filled in from the URL. Review it before saving." });
      setTestState({ kind: "idle", text: "" });
    } catch (error) {
      setWarnings([]);
      setUrlNote({ kind: "bad", text: errorText(error) });
    }
  }

  async function chooseFile() {
    const picked = await openFileDialog({ multiple: false, directory: false });
    if (typeof picked === "string") {
      patch({ filePath: picked, name: draft.name || picked.split("/").pop()?.replace(/\.[^.]+$/, "") || "" });
    }
  }

  async function test() {
    setTestState({ kind: "busy", text: "Testing…" });
    try {
      const info = await api.testConnection(draft, password || undefined);
      setTestState({ kind: "ok", text: `${info.productName} ${info.version}` });
    } catch (error) {
      setTestState({ kind: "bad", text: errorText(error) });
    }
  }

  async function save() {
    try {
      onSaved(await api.saveProfile(draft, password || undefined));
      onClose();
    } catch (error) {
      setTestState({ kind: "bad", text: errorText(error) });
    }
  }

  const isFile = draft.kind === "sqlite";
  const invalid = isFile ? !draft.filePath : !draft.host || !draft.port;

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog">
        <h2>{initial.name || initial.host !== "127.0.0.1" ? "Edit Connection" : "New Connection"}</h2>
        <div className="dialog-body">
          <div>
            <button className="quiet" onClick={() => setUrlOpen((v) => !v)}>
              {urlOpen ? "▾" : "▸"} Add from URL
            </button>
            {urlOpen && (
              <div style={{ display: "flex", flexDirection: "column", gap: 6, marginTop: 6 }}>
                <input
                  value={urlText}
                  placeholder="postgres://user:password@host:5432/database"
                  style={{ fontFamily: "var(--mono)" }}
                  onChange={(e) => setUrlText(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && applyUrl()}
                />
                <div className="row">
                  <button onClick={applyUrl} disabled={!urlText.trim()}>Fill in fields</button>
                </div>
                {urlNote && (
                  <div className={urlNote.kind === "bad" ? "bad" : urlNote.kind === "ok" ? "good" : "hint"}>
                    {urlNote.text}
                  </div>
                )}
                {/* Anything understood but not honoured exactly is said out loud. */}
                {warnings.map((warning) => (
                  <div className="warn" key={warning}>{warning}</div>
                ))}
                {!urlNote && (
                  <div className="hint">
                    Understands postgres://, mysql://, mariadb://, sqlite://, redis://,
                    mongodb://, JDBC prefixes and the host=… key/value form.
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="field">
            <label>Name</label>
            <input value={draft.name} placeholder="My database" onChange={(e) => patch({ name: e.target.value })} />
          </div>

          <div className="field">
            <label>Type</label>
            <select
              value={draft.kind}
              onChange={(e) => {
                const kind = e.target.value as DatabaseKind;
                // Keep the port sensible when the engine changes by hand.
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
              <label>Database file</label>
              <div className="row">
                <input value={draft.filePath} onChange={(e) => patch({ filePath: e.target.value })} />
                <button onClick={chooseFile}>Browse…</button>
              </div>
            </div>
          ) : (
            <>
              <div className="row">
                <div className="field" style={{ flex: 1 }}>
                  <label>Host</label>
                  <input value={draft.host} onChange={(e) => patch({ host: e.target.value })} />
                </div>
                <div className="field" style={{ width: 90 }}>
                  <label>Port</label>
                  <input
                    value={draft.port}
                    onChange={(e) => patch({ port: Number(e.target.value) || 0 })}
                  />
                </div>
              </div>
              <div className="field">
                <label>Username</label>
                <input value={draft.username} onChange={(e) => patch({ username: e.target.value })} />
              </div>
              <div className="field">
                <label>Password</label>
                <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
              </div>
              <div className="field">
                <label>Database</label>
                <input value={draft.database} onChange={(e) => patch({ database: e.target.value })} />
              </div>
              <div className="field">
                <label>SSL</label>
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
                  onChange={(e) => patch({ savePassword: e.target.checked })}
                />
                Save password in the system credential store
              </label>
            </>
          )}

          <label className="check">
            <input type="checkbox" checked={draft.readOnly} onChange={(e) => patch({ readOnly: e.target.checked })} />
            Read-only connection
          </label>
          <div className="hint">Blocks INSERT, UPDATE, DELETE and DDL before they leave the app.</div>

          <div className="field">
            <label>Folder</label>
            <input value={draft.folder} placeholder="Production" onChange={(e) => patch({ folder: e.target.value })} />
          </div>
        </div>

        <div className="dialog-footer">
          <button onClick={test} disabled={testState.kind === "busy" || invalid}>Test</button>
          {testState.kind !== "idle" && (
            <div
              className={testState.kind === "bad" ? "bad" : testState.kind === "ok" ? "good" : "hint"}
              style={{ flex: 1, alignSelf: "center", maxHeight: 48, overflow: "auto" }}
            >
              {testState.text}
            </div>
          )}
          <div className="spacer" />
          <button onClick={onClose}>Cancel</button>
          <button className="primary" onClick={save} disabled={invalid}>Save</button>
        </div>
      </div>
    </div>
  );
}
