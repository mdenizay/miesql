interface Props {
  title: string;
  message: string;
  confirmLabel: string;
  destructive?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/** Used for anything MieSQL cannot undo, so the consequence is stated before it happens. */
export function ConfirmDialog({
  title,
  message,
  confirmLabel,
  destructive,
  onConfirm,
  onCancel,
}: Props) {
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="dialog" style={{ width: 400 }}>
        <h2>{title}</h2>
        <div className="dialog-body">
          <div style={{ whiteSpace: "pre-wrap" }}>{message}</div>
        </div>
        <div className="dialog-footer">
          <button onClick={onCancel}>Cancel</button>
          <button className={destructive ? "danger" : "primary"} onClick={onConfirm}>
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
