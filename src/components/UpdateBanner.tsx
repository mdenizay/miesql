import type { UpdateStage } from "../lib/useUpdater";

interface Props {
  stage: UpdateStage;
  dismissed: boolean;
  onDismiss: () => void;
  onDownload: () => void;
  onInstall: () => void;
}

/**
 * The only place an update interrupts anything, and it never does more than occupy a
 * strip at the top. Nothing here restarts the app without a click.
 */
export function UpdateBanner({ stage, dismissed, onDismiss, onDownload, onInstall }: Props) {
  if (dismissed) return null;

  switch (stage.kind) {
    case "available":
      return (
        <div className="update-banner">
          <span>MieSQL {stage.version} is available.</span>
          <button className="primary" onClick={onDownload}>Download</button>
          <div className="spacer" />
          <button className="quiet" onClick={onDismiss}>Later</button>
        </div>
      );
    case "downloading":
      return (
        <div className="update-banner">
          <span>Downloading {stage.version}…</span>
          <div className="progress"><div style={{ width: `${stage.percent}%` }} /></div>
          <span className="hint">{stage.percent}%</span>
        </div>
      );
    case "ready":
      return (
        <div className="update-banner">
          <span>MieSQL {stage.version} is ready to install.</span>
          <button className="primary" onClick={onInstall}>Restart now</button>
          <div className="spacer" />
          <button className="quiet" onClick={onDismiss}>On next launch</button>
        </div>
      );
    case "installing":
      return <div className="update-banner"><span>Installing…</span></div>;
    default:
      // Idle, checking and failed stay silent here; a failed check is reported in Settings
      // rather than shoved in front of someone who is working.
      return null;
  }
}
