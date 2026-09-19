import type { Translate } from "../lib/i18n";
import type { UpdateStage } from "../lib/useUpdater";

interface Props {
  stage: UpdateStage;
  dismissed: boolean;
  t: Translate;
  onDismiss: () => void;
  onDownload: () => void;
  onInstall: () => void;
}

/**
 * The only place an update interrupts anything, and it never does more than occupy a strip
 * at the top. Nothing here restarts the app without a click.
 */
export function UpdateBanner({ stage, dismissed, t, onDismiss, onDownload, onInstall }: Props) {
  if (dismissed) return null;

  switch (stage.kind) {
    case "available":
      return (
        <div className="update-banner">
          <span>{t("update.available", stage.version)}</span>
          <button className="primary" onClick={onDownload}>{t("update.download")}</button>
          <div className="spacer" />
          <button className="quiet" onClick={onDismiss}>{t("update.later")}</button>
        </div>
      );
    case "downloading":
      return (
        <div className="update-banner">
          <span>{t("update.downloading", stage.version)}</span>
          <div className="progress"><div style={{ width: `${stage.percent}%` }} /></div>
          <span className="hint">{stage.percent}%</span>
        </div>
      );
    case "ready":
      return (
        <div className="update-banner">
          <span>{t("update.ready", stage.version)}</span>
          <button className="primary" onClick={onInstall}>{t("update.restart")}</button>
          <div className="spacer" />
          <button className="quiet" onClick={onDismiss}>{t("update.onNextLaunch")}</button>
        </div>
      );
    case "installing":
      return <div className="update-banner"><span>{t("update.installing")}</span></div>;
    default:
      // Idle, checking and failed stay silent here; a failed check is reported in Settings
      // rather than shoved in front of someone who is working.
      return null;
  }
}
