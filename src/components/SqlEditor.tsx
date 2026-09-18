import { useEffect, useRef } from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { autocompletion, completionKeymap, type CompletionSource } from "@codemirror/autocomplete";
import { sql, PostgreSQL, MySQL, SQLite, type SQLDialect } from "@codemirror/lang-sql";
import type { DatabaseKind } from "../lib/types";

interface Props {
  value: string;
  onChange: (value: string) => void;
  onRun: () => void;
  kind: DatabaseKind;
  fontSize: number;
  showLineNumbers: boolean;
  wrapLines: boolean;
  /** Table and column names from the loaded tree, so completion knows the schema. */
  schema: Record<string, string[]>;
}

function dialectFor(kind: DatabaseKind): SQLDialect {
  switch (kind) {
    case "mysql":
    case "mariadb":
      return MySQL;
    case "sqlite":
      return SQLite;
    default:
      return PostgreSQL;
  }
}

export function SqlEditor(props: Props) {
  const host = useRef<HTMLDivElement>(null);
  const view = useRef<EditorView | null>(null);
  const language = useRef(new Compartment());
  const theme = useRef(new Compartment());
  // Held in a ref so the run shortcut always calls the current handler without having to
  // rebuild the editor on every render.
  const onRun = useRef(props.onRun);
  onRun.current = props.onRun;

  useEffect(() => {
    if (!host.current || view.current) return;

    const state = EditorState.create({
      doc: props.value,
      extensions: [
        history(),
        highlightActiveLine(),
        props.showLineNumbers ? lineNumbers() : [],
        props.wrapLines ? EditorView.lineWrapping : [],
        autocompletion(),
        keymap.of([
          // ⌘↩ / Ctrl+↩ runs, the pair every SQL client uses.
          { key: "Mod-Enter", run: () => { onRun.current(); return true; }, preventDefault: true },
          indentWithTab,
          ...defaultKeymap,
          ...historyKeymap,
          ...completionKeymap,
        ]),
        language.current.of(sql({ dialect: dialectFor(props.kind), schema: props.schema })),
        theme.current.of(EditorView.theme({ "&": { fontSize: `${props.fontSize}px` } })),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) props.onChange(update.state.doc.toString());
        }),
      ],
    });

    view.current = new EditorView({ state, parent: host.current });
    return () => {
      view.current?.destroy();
      view.current = null;
    };
    // Built once; the pieces that change are swapped through compartments below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Swap the dialect and completion schema when the connection changes.
  useEffect(() => {
    view.current?.dispatch({
      effects: language.current.reconfigure(
        sql({ dialect: dialectFor(props.kind), schema: props.schema }),
      ),
    });
  }, [props.kind, props.schema]);

  useEffect(() => {
    view.current?.dispatch({
      effects: theme.current.reconfigure(
        EditorView.theme({ "&": { fontSize: `${props.fontSize}px` } }),
      ),
    });
  }, [props.fontSize]);

  // Only push text in when it came from outside — otherwise typing would fight the state.
  useEffect(() => {
    const current = view.current?.state.doc.toString();
    if (view.current && current !== props.value) {
      view.current.dispatch({
        changes: { from: 0, to: view.current.state.doc.length, insert: props.value },
      });
    }
  }, [props.value]);

  return <div ref={host} style={{ height: "100%" }} />;
}

export type { CompletionSource };
