import { useEffect, useRef } from "react";

export interface MenuItem {
  label: string;
  onSelect: () => void;
  icon?: React.ComponentType<{ className?: string }>;
  danger?: boolean;
  disabled?: boolean;
  separatorBefore?: boolean;
}

interface Props {
  x: number;
  y: number;
  items: MenuItem[];
  onClose: () => void;
}

export function ContextMenu({ x, y, items, onClose }: Props) {
  const menu = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const dismiss = (event: MouseEvent) => {
      if (!menu.current?.contains(event.target as Node)) onClose();
    };
    const onKey = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    // Capture, so a click anywhere closes the menu before it reaches what is underneath.
    document.addEventListener("mousedown", dismiss, true);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", dismiss, true);
      document.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  // Keep the menu on screen when it is opened near an edge.
  const style: React.CSSProperties = {
    left: Math.min(x, window.innerWidth - 230),
    top: Math.min(y, window.innerHeight - items.length * 28 - 16),
  };

  return (
    <div className="context-menu" ref={menu} style={style}>
      {items.map((item, index) => (
        <div key={`${item.label}-${index}`}>
          {item.separatorBefore && <div className="context-separator" />}
          <button
            className={`context-item${item.danger ? " danger" : ""}`}
            disabled={item.disabled}
            onClick={() => {
              item.onSelect();
              onClose();
            }}
          >
            {item.icon ? <item.icon className="icon" /> : <span className="icon" />}
            {item.label}
          </button>
        </div>
      ))}
    </div>
  );
}
