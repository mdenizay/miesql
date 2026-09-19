import { useEffect, useMemo, useState } from "react";
import { CheckCircleIcon, MagnifyingGlassIcon, TrashIcon, XCircleIcon } from "@heroicons/react/24/outline";
import { api } from "../lib/api";
import type { Translate } from "../lib/i18n";
import type { HistoryEntry, Snippet } from "../lib/types";

interface Props {
  t: Translate;
  onUse: (sql: string) => void;
  onClose: () => void;
}

/** Query history and saved snippets, both read from the local files the core writes. */
export function HistoryPanel({ t, onUse, onClose }: Props) {
  const [tab, setTab] = useState<"history" | "snippets">("history");
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [snippets, setSnippets] = useState<Snippet[]>([]);
  const [search, setSearch] = useState("");

  useEffect(() => {
    void api.getHistory().then(setHistory);
    void api.getSnippets().then(setSnippets);
  }, []);

  const filtered = useMemo(() => {
    const needle = search.trim().toLowerCase();
    if (!needle) return history;
    return history.filter((entry) => entry.sql.toLowerCase().includes(needle));
  }, [history, search]);

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog" style={{ width: 640, height: "70vh" }}>
        <h2>
          <button className={tab === "history" ? "primary" : ""} onClick={() => setTab("history")}>
            {t("history.title")}
          </button>
          <button className={tab === "snippets" ? "primary" : ""} onClick={() => setTab("snippets")}>
            {t("snippets.title")}
          </button>
          <div className="spacer" />
          {tab === "history" && history.length > 0 && (
            <button
              onClick={async () => {
                await api.clearHistory();
                setHistory([]);
              }}
            >
              <TrashIcon className="icon" />
              {t("history.clear")}
            </button>
          )}
        </h2>

        {tab === "history" && (
          <div style={{ padding: "8px 12px", borderBottom: "1px solid var(--border)" }}>
            <div style={{ position: "relative", display: "flex", alignItems: "center" }}>
              <MagnifyingGlassIcon
                className="icon"
                style={{ position: "absolute", left: 6, color: "var(--text-faint)" }}
              />
              <input
                value={search}
                placeholder={t("history.search")}
                style={{ paddingLeft: 26 }}
                onChange={(e) => setSearch(e.target.value)}
              />
            </div>
          </div>
        )}

        <div className="list">
          {tab === "history" &&
            (filtered.length === 0 ? (
              <div className="empty">{t("history.empty")}</div>
            ) : (
              filtered.map((entry) => (
                <div
                  key={entry.id}
                  className="list-item"
                  onDoubleClick={() => {
                    onUse(entry.sql);
                    onClose();
                  }}
                  title={t("history.insert")}
                >
                  <div className="meta">
                    {entry.succeeded ? (
                      <CheckCircleIcon className="icon" style={{ color: "var(--success)" }} />
                    ) : (
                      <XCircleIcon className="icon" style={{ color: "var(--danger)" }} />
                    )}
                    <span>{entry.connectionName}</span>
                    {entry.database && <span>· {entry.database}</span>}
                    <div className="spacer" />
                    <span>{new Date(entry.executedAt).toLocaleTimeString()}</span>
                    <span>{entry.durationMs.toFixed(0)} ms</span>
                  </div>
                  <div className="sql">{entry.sql.replace(/\s+/g, " ").trim()}</div>
                  {entry.errorMessage && <div className="bad">{entry.errorMessage}</div>}
                </div>
              ))
            ))}

          {tab === "snippets" &&
            (snippets.length === 0 ? (
              <div className="empty">{t("snippets.empty")}</div>
            ) : (
              snippets.map((snippet) => (
                <div
                  key={snippet.id}
                  className="list-item"
                  onDoubleClick={() => {
                    onUse(snippet.sql);
                    onClose();
                  }}
                >
                  <div className="meta">
                    <strong>{snippet.name}</strong>
                    <div className="spacer" />
                    <button
                      className="quiet"
                      onClick={async (event) => {
                        event.stopPropagation();
                        const next = snippets.filter((s) => s.id !== snippet.id);
                        setSnippets(next);
                        await api.setSnippets(next);
                      }}
                    >
                      <TrashIcon className="icon" />
                    </button>
                  </div>
                  <div className="sql">{snippet.sql.replace(/\s+/g, " ").trim()}</div>
                </div>
              ))
            ))}
        </div>

        <div className="dialog-footer">
          <div className="hint">{t("history.insert")}: ⏎⏎</div>
          <div className="spacer" />
          <button className="primary" onClick={onClose}>
            {t("general.close")}
          </button>
        </div>
      </div>
    </div>
  );
}
