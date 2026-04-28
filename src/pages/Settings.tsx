import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { toast } from "@/hooks/use-toast";
import baseConfig from "../../scripts/52-vscode-folder-repair/config.json";
import {
  bridgeTokenSchema,
  bridgeUrlSchema,
  script52OptionsSchema,
} from "@/lib/configSchema";
import { diffJson, summarizeDiff, type DiffEntry } from "@/lib/jsonDiff";
import { DiffRow } from "@/components/DiffRow";

type Edition = "stable" | "insiders";
type BridgeStatus = "unknown" | "checking" | "online" | "offline";

const BRIDGE_KEY = "config-bridge-url";
const TOKEN_KEY = "config-bridge-token";
const SCRIPT_ID = "52";
const CONFIG_PATH = "scripts/52-vscode-folder-repair/config.json";
const PREVIEW_CACHE_KEY = `config-bridge-last-preview-${SCRIPT_ID}`;
const PREVIEW_CACHE_VERSION = 1;

interface CachedPreview {
  v: number;
  savedAt: number;       // epoch ms
  storedConfig: unknown; // bridge's copy at the time of preparation
  mergedPreview: unknown;
  diff: DiffEntry[];
  pendingPayload: typeof DEFAULT_PATCH;
}

const loadCachedPreview = (): CachedPreview | null => {
  try {
    const raw = localStorage.getItem(PREVIEW_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as CachedPreview;
    if (parsed?.v !== PREVIEW_CACHE_VERSION || !Array.isArray(parsed.diff)) return null;
    return parsed;
  } catch {
    return null;
  }
};

const saveCachedPreview = (snapshot: Omit<CachedPreview, "v" | "savedAt">) => {
  try {
    const payload: CachedPreview = {
      v: PREVIEW_CACHE_VERSION,
      savedAt: Date.now(),
      ...snapshot,
    };
    localStorage.setItem(PREVIEW_CACHE_KEY, JSON.stringify(payload));
  } catch {
    // localStorage can throw on quota/private mode — preview cache is best-effort
  }
};

const clearCachedPreview = () => {
  try {
    localStorage.removeItem(PREVIEW_CACHE_KEY);
  } catch {
    // ignore
  }
};

const formatRelativeTime = (epochMs: number): string => {
  const diff = Date.now() - epochMs;
  if (diff < 60_000) return "just now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
};

// Deep-merge mirrors the bridge's Merge-Config so the preview matches what
// will actually land on disk.
const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

const deepMerge = (base: unknown, patch: unknown): unknown => {
  if (!isPlainObject(base) || !isPlainObject(patch)) return patch;
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(patch)) {
    out[k] = k in out ? deepMerge(out[k], v) : v;
  }
  return out;
};

// Defaults derived from the stored model (config.json shipped in the repo).
// Booleans fall back to safe values when the baseline omits them.
const baseRecord = baseConfig as Record<string, unknown>;
const defaultEditions = Array.isArray(baseRecord.enabledEditions)
  ? (baseRecord.enabledEditions as Edition[])
  : (["stable"] as Edition[]);
const DEFAULTS = {
  edition: (defaultEditions[0] ?? "stable") as Edition,
  adminOnly: typeof baseRecord.requireAdmin === "boolean" ? (baseRecord.requireAdmin as boolean) : true,
  nonInteractive:
    typeof baseRecord.nonInteractive === "boolean" ? (baseRecord.nonInteractive as boolean) : false,
  requireSignature:
    typeof baseRecord.requireSignature === "boolean" ? (baseRecord.requireSignature as boolean) : false,
};
const DEFAULT_PATCH = {
  enabledEditions: [DEFAULTS.edition],
  requireAdmin: DEFAULTS.adminOnly,
  nonInteractive: DEFAULTS.nonInteractive,
  requireSignature: DEFAULTS.requireSignature,
};

const Settings = () => {
  const [edition, setEdition] = useState<Edition>(DEFAULTS.edition);
  const [adminOnly, setAdminOnly] = useState(DEFAULTS.adminOnly);
  const [nonInteractive, setNonInteractive] = useState(DEFAULTS.nonInteractive);
  const [requireSignature, setRequireSignature] = useState(DEFAULTS.requireSignature);

  const [bridgeUrl, setBridgeUrl] = useState(
    () => localStorage.getItem(BRIDGE_KEY) ?? "http://127.0.0.1:7531",
  );
  const [bridgeToken, setBridgeToken] = useState(
    () => localStorage.getItem(TOKEN_KEY) ?? "",
  );
  const [bridgeStatus, setBridgeStatus] = useState<BridgeStatus>("unknown");
  const [isSaving, setIsSaving] = useState(false);

  // Diff/confirm state
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [diff, setDiff] = useState<DiffEntry[]>([]);
  const [storedConfig, setStoredConfig] = useState<unknown>(null);
  const [mergedPreview, setMergedPreview] = useState<unknown>(null);
  const [pendingPayload, setPendingPayload] = useState<typeof DEFAULT_PATCH | null>(null);
  const [cachedSavedAt, setCachedSavedAt] = useState<number | null>(null);
  const [isPreparing, setIsPreparing] = useState(false);

  // The patch we POST to the bridge — only the fields the user can change.
  const patch = useMemo(
    () => ({
      enabledEditions: [edition],
      requireAdmin: adminOnly,
      nonInteractive,
      requireSignature,
    }),
    [edition, adminOnly, nonInteractive, requireSignature],
  );

  // Local preview = baseline (file shipped in repo) merged with patch.
  // The diff dialog uses the bridge's live copy instead.
  const localPreview = useMemo(
    () => deepMerge(baseConfig as Record<string, unknown>, patch),
    [patch],
  );

  useEffect(() => { localStorage.setItem(BRIDGE_KEY, bridgeUrl); }, [bridgeUrl]);
  useEffect(() => { localStorage.setItem(TOKEN_KEY, bridgeToken); }, [bridgeToken]);

  // Restore the last successful preview snapshot from localStorage so the user
  // can re-open the diff dialog immediately without round-tripping the bridge.
  useEffect(() => {
    const cached = loadCachedPreview();
    if (!cached) return;
    setStoredConfig(cached.storedConfig);
    setMergedPreview(cached.mergedPreview);
    setDiff(cached.diff);
    setPendingPayload(cached.pendingPayload);
    setCachedSavedAt(cached.savedAt);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const probe = async () => {
      setBridgeStatus("checking");
      try {
        const r = await fetch(`${bridgeUrl.replace(/\/$/, "")}/health`, { method: "GET" });
        if (!cancelled) setBridgeStatus(r.ok ? "online" : "offline");
      } catch {
        if (!cancelled) setBridgeStatus("offline");
      }
    };
    probe();
    return () => { cancelled = true; };
  }, [bridgeUrl]);

  const handleDownload = () => {
    try {
      const blob = new Blob([JSON.stringify(localPreview, null, 2)], { type: "application/json" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "config.json";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      toast({
        title: "config.json generated",
        description: `Drop it into ${CONFIG_PATH} to apply.`,
      });
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      toast({
        title: "Download failed",
        description: `path: ${CONFIG_PATH} — reason: ${reason}`,
        variant: "destructive",
      });
    }
  };

  // Reset form to defaults from the stored model and open the review dialog
  // so the user sees exactly what will change before the PATCH is sent.
  const handleResetToDefaults = async () => {
    setEdition(DEFAULTS.edition);
    setAdminOnly(DEFAULTS.adminOnly);
    setNonInteractive(DEFAULTS.nonInteractive);
    setRequireSignature(DEFAULTS.requireSignature);
    // Use the explicit defaults patch instead of waiting for state to flush.
    await handlePrepareSave(DEFAULT_PATCH);
  };

  // STEP 1: validate, pull current stored config, compute diff, open dialog
  const handlePrepareSave = async (override?: typeof patch) => {
    const payload = override ?? patch;
    // Client-side validation (mirrors server Zod surface)
    const opts = script52OptionsSchema.safeParse(payload);
    if (!opts.success) {
      const first = opts.error.issues[0];
      toast({
        title: "Invalid options",
        description: `${first.path.join(".") || "options"} — ${first.message}`,
        variant: "destructive",
      });
      return;
    }
    const url = bridgeUrlSchema.safeParse(bridgeUrl);
    if (!url.success) {
      toast({
        title: "Invalid bridge URL",
        description: url.error.issues[0].message,
        variant: "destructive",
      });
      return;
    }
    const tok = bridgeTokenSchema.safeParse(bridgeToken);
    if (!tok.success) {
      toast({
        title: "Invalid bridge token",
        description: tok.error.issues[0].message,
        variant: "destructive",
      });
      return;
    }

    setIsPreparing(true);
    const endpoint = `${url.data.replace(/\/$/, "")}/config?script=${SCRIPT_ID}`;
    try {
      const headers: Record<string, string> = {};
      if (tok.data) headers["X-Bridge-Token"] = tok.data;

      const res = await fetch(endpoint, { method: "GET", headers });
      let current: unknown = {};
      if (res.ok) {
        const text = await res.text();
        try {
          // Bridge returns the raw file contents as a JSON string
          const parsedOuter = JSON.parse(text);
          current = typeof parsedOuter === "string" ? JSON.parse(parsedOuter) : parsedOuter;
        } catch {
          current = {};
        }
      } else if (res.status !== 404) {
        const data = await res.json().catch(() => ({}));
        const reason =
          (data as { reason?: string; error?: string }).reason ??
          (data as { error?: string }).error ??
          `HTTP ${res.status}`;
        throw new Error(`path: ${endpoint} — reason: ${reason}`);
      }

      const next = deepMerge(current, payload);
      const entries = diffJson(current, next).filter((e) => e.kind !== "unchanged");

      setStoredConfig(current);
      setMergedPreview(next);
      setDiff(entries);
      setPendingPayload(payload);
      setCachedSavedAt(Date.now());
      saveCachedPreview({
        storedConfig: current,
        mergedPreview: next,
        diff: entries,
        pendingPayload: payload,
      });
      setConfirmOpen(true);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      setBridgeStatus("offline");
      toast({
        title: "Could not load current config",
        description: reason.includes("path:")
          ? reason
          : `path: ${endpoint} — reason: ${reason}. Is config-bridge.ps1 running?`,
        variant: "destructive",
      });
    } finally {
      setIsPreparing(false);
    }
  };

  // STEP 2: user confirmed — actually PATCH
  const handleConfirmSave = async () => {
    setIsSaving(true);
    const endpoint = `${bridgeUrl.replace(/\/$/, "")}/config?script=${SCRIPT_ID}`;
    try {
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (bridgeToken) headers["X-Bridge-Token"] = bridgeToken;
      const res = await fetch(endpoint, {
        method: "PATCH",
        headers,
        body: JSON.stringify(pendingPayload ?? patch),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        const path = (data as { path?: string }).path ?? CONFIG_PATH;
        const reason =
          (data as { reason?: string; error?: string }).reason ??
          (data as { error?: string }).error ??
          `HTTP ${res.status}`;
        throw new Error(`path: ${path} — reason: ${reason}`);
      }
      const savedPath = (data as { path?: string }).path ?? CONFIG_PATH;
      const bytes = (data as { bytes?: number }).bytes ?? "?";
      toast({
        title: "Saved to local config.json",
        description: `${savedPath} (${bytes} bytes) — ${diff.length} change(s) applied`,
      });
      setBridgeStatus("online");
      setConfirmOpen(false);
      // Saved successfully — the cached preview no longer reflects unsaved work.
      clearCachedPreview();
      setCachedSavedAt(null);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      setBridgeStatus("offline");
      toast({
        title: "Bridge save failed",
        description: reason.includes("path:")
          ? reason
          : `path: ${endpoint} — reason: ${reason}. Is config-bridge.ps1 running?`,
        variant: "destructive",
      });
    } finally {
      setIsSaving(false);
    }
  };

  const summary = summarizeDiff(diff);

  return (
    <main className="min-h-screen bg-background px-6 py-12">
      <div className="mx-auto max-w-2xl space-y-6">
        <header className="space-y-2">
          <Link to="/" className="text-sm text-muted-foreground hover:text-foreground">
            ← Back
          </Link>
          <h1 className="text-3xl font-bold tracking-tight">Script 52 settings</h1>
          <p className="text-sm text-muted-foreground">
            Configure VS Code folder context-menu repair. Saving asks for
            confirmation and shows the exact diff against{" "}
            <code className="rounded bg-muted px-1 py-0.5 text-xs">{CONFIG_PATH}</code>.
          </p>
        </header>

        <Card>
          <CardHeader>
            <CardTitle>Edition</CardTitle>
            <CardDescription>Which VS Code build to target.</CardDescription>
          </CardHeader>
          <CardContent>
            <RadioGroup
              value={edition}
              onValueChange={(v) => setEdition(v as Edition)}
              className="grid grid-cols-2 gap-3"
            >
              <Label
                htmlFor="ed-stable"
                className="flex cursor-pointer items-center gap-3 rounded-md border border-border p-4 hover:bg-accent"
              >
                <RadioGroupItem id="ed-stable" value="stable" />
                <div>
                  <div className="font-medium">Stable</div>
                  <div className="text-xs text-muted-foreground">Open with Code</div>
                </div>
              </Label>
              <Label
                htmlFor="ed-insiders"
                className="flex cursor-pointer items-center gap-3 rounded-md border border-border p-4 hover:bg-accent"
              >
                <RadioGroupItem id="ed-insiders" value="insiders" />
                <div>
                  <div className="font-medium">Insiders</div>
                  <div className="text-xs text-muted-foreground">Open with Code - Insiders</div>
                </div>
              </Label>
            </RadioGroup>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Behavior</CardTitle>
            <CardDescription>Switches passed to script 52 at run time.</CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            <ToggleRow
              id="admin"
              label="Admin-only"
              hint="Refuse to run unless launched from an elevated PowerShell."
              checked={adminOnly}
              onChange={setAdminOnly}
            />
            <Separator />
            <ToggleRow
              id="ci"
              label="Non-interactive (CI mode)"
              hint="Suppress all prompts. Safe defaults are used."
              checked={nonInteractive}
              onChange={setNonInteractive}
            />
            <Separator />
            <ToggleRow
              id="sig"
              label="Require Authenticode signature"
              hint="Verify the VS Code executable is signed before writing registry."
              checked={requireSignature}
              onChange={setRequireSignature}
            />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Preview</CardTitle>
            <CardDescription>
              Local merge against the in-repo baseline (the diff dialog compares
              against the live file on disk).
            </CardDescription>
          </CardHeader>
          <CardContent>
            <pre className="max-h-72 overflow-auto rounded-md bg-muted p-4 text-xs">
              {JSON.stringify(localPreview, null, 2)}
            </pre>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              Local bridge
              <StatusDot status={bridgeStatus} />
            </CardTitle>
            <CardDescription>
              Run <code className="rounded bg-muted px-1 py-0.5 text-xs">.\tools\config-bridge.ps1</code>{" "}
              on your machine, then save directly to {CONFIG_PATH}.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="space-y-1">
                <Label htmlFor="bridge-url" className="text-xs">Bridge URL</Label>
                <Input
                  id="bridge-url"
                  value={bridgeUrl}
                  onChange={(e) => setBridgeUrl(e.target.value)}
                  placeholder="http://127.0.0.1:7531"
                  maxLength={255}
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="bridge-token" className="text-xs">
                  X-Bridge-Token <span className="text-muted-foreground">(optional)</span>
                </Label>
                <Input
                  id="bridge-token"
                  type="password"
                  value={bridgeToken}
                  onChange={(e) => setBridgeToken(e.target.value)}
                  placeholder="leave blank if -Token not set"
                  maxLength={256}
                />
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              Status:{" "}
              <span className="font-medium text-foreground">{bridgeStatus}</span>
              {bridgeStatus === "offline" &&
                " — start the bridge with .\\tools\\config-bridge.ps1 from the repo root."}
            </p>
          </CardContent>
        </Card>

        {cachedSavedAt !== null && diff.length > 0 && (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-md border border-dashed border-border bg-muted/40 px-4 py-3 text-sm">
            <div className="space-y-0.5">
              <p className="font-medium">Last preview cached</p>
              <p className="text-xs text-muted-foreground">
                {summarizeDiff(diff).total} change(s) prepared {formatRelativeTime(cachedSavedAt)} —
                no fresh bridge call needed.
              </p>
            </div>
            <div className="flex gap-2">
              <Button
                size="sm"
                variant="outline"
                onClick={() => setConfirmOpen(true)}
              >
                Show last preview
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => {
                  clearCachedPreview();
                  setCachedSavedAt(null);
                  setDiff([]);
                  setStoredConfig(null);
                  setMergedPreview(null);
                  setPendingPayload(null);
                }}
              >
                Discard
              </Button>
            </div>
          </div>
        )}

        <div className="flex flex-wrap justify-end gap-3">
          <Button variant="outline" asChild>
            <Link to="/">Cancel</Link>
          </Button>
          <Button
            variant="outline"
            onClick={handleResetToDefaults}
            disabled={isPreparing || isSaving || bridgeStatus !== "online"}
            title="Revert option fields to the defaults from the stored model"
          >
            Reset to defaults
          </Button>
          <Button variant="secondary" onClick={handleDownload}>
            Download config.json
          </Button>
          <Button
            onClick={() => handlePrepareSave()}
            disabled={isPreparing || isSaving || bridgeStatus !== "online"}
          >
            {isPreparing ? "Loading current…" : "Review & save"}
          </Button>
        </div>
      </div>

      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent className="max-w-2xl">
          <DialogHeader>
            <DialogTitle>Confirm changes to config.json</DialogTitle>
            <DialogDescription>
              {summary.total === 0
                ? "No effective changes — the merge would leave the file identical."
                : `${summary.total} change(s): ${summary.added} added, ${summary.changed} modified, ${summary.removed} removed.`}{" "}
              Target: <code className="text-xs">{CONFIG_PATH}</code>
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-3">
            <div className="max-h-64 overflow-auto rounded-md border border-border">
              {diff.length === 0 ? (
                <p className="p-4 text-sm text-muted-foreground">
                  Stored config already matches your selection.
                </p>
              ) : (
                <ul className="divide-y divide-border font-mono text-xs">
                  {diff.map((d) => (
                    <li key={d.path} className="px-3 py-2">
                      <DiffRow entry={d} />
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <details className="text-xs">
              <summary className="cursor-pointer text-muted-foreground hover:text-foreground">
                Show full merged JSON
              </summary>
              <pre className="mt-2 max-h-56 overflow-auto rounded-md bg-muted p-3">
                {JSON.stringify(mergedPreview ?? storedConfig, null, 2)}
              </pre>
            </details>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmOpen(false)} disabled={isSaving}>
              Cancel
            </Button>
            <Button
              onClick={handleConfirmSave}
              disabled={isSaving || diff.length === 0}
            >
              {isSaving ? "Saving…" : `Confirm & save (${summary.total})`}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </main>
  );
};

const ToggleRow = ({
  id,
  label,
  hint,
  checked,
  onChange,
}: {
  id: string;
  label: string;
  hint: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) => (
  <div className="flex items-start justify-between gap-4">
    <div className="space-y-0.5">
      <Label htmlFor={id} className="text-sm font-medium">
        {label}
      </Label>
      <p className="text-xs text-muted-foreground">{hint}</p>
    </div>
    <Switch id={id} checked={checked} onCheckedChange={onChange} />
  </div>
);

const StatusDot = ({ status }: { status: BridgeStatus }) => {
  const color =
    status === "online"
      ? "bg-green-500"
      : status === "checking"
      ? "bg-yellow-500 animate-pulse"
      : status === "offline"
      ? "bg-red-500"
      : "bg-muted-foreground";
  return (
    <span
      aria-label={`bridge ${status}`}
      className={`inline-block h-2.5 w-2.5 rounded-full ${color}`}
    />
  );
};

// DiffRow lives in src/components/DiffRow.tsx — imported above.

export default Settings;
