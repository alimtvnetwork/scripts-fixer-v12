import type { DiffEntry } from "@/lib/jsonDiff";
import { Badge } from "@/components/ui/badge";

// Human-friendly formatter used by the confirm-changes dialog.
// Renders booleans as Yes/No pills, arrays as comma-separated chips, objects
// as compact key:value lists, and falls back to JSON for everything else.
// Changes show side-by-side before/after columns instead of a raw JSON blob.

const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

const ValueCell = ({ value }: { value: unknown }) => {
  if (value === undefined) {
    return <span className="text-muted-foreground italic">unset</span>;
  }
  if (value === null) {
    return <span className="text-muted-foreground italic">null</span>;
  }
  if (typeof value === "boolean") {
    return (
      <Badge
        variant={value ? "default" : "secondary"}
        className="font-mono text-[10px] uppercase"
      >
        {value ? "Yes" : "No"}
      </Badge>
    );
  }
  if (typeof value === "string") {
    return value.length === 0 ? (
      <span className="text-muted-foreground italic">empty string</span>
    ) : (
      <span className="font-mono">"{value}"</span>
    );
  }
  if (typeof value === "number") {
    return <span className="font-mono">{value}</span>;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return <span className="text-muted-foreground italic">empty list</span>;
    }
    return (
      <div className="flex flex-wrap gap-1">
        {value.map((item, i) => (
          <Badge key={i} variant="outline" className="font-mono text-[10px]">
            {typeof item === "string" ? item : JSON.stringify(item)}
          </Badge>
        ))}
      </div>
    );
  }
  if (isPlainObject(value)) {
    const entries = Object.entries(value);
    if (entries.length === 0) {
      return <span className="text-muted-foreground italic">empty object</span>;
    }
    return (
      <ul className="space-y-0.5">
        {entries.map(([k, v]) => (
          <li key={k} className="font-mono text-[11px]">
            <span className="text-muted-foreground">{k}:</span>{" "}
            <span>{typeof v === "string" ? `"${v}"` : JSON.stringify(v)}</span>
          </li>
        ))}
      </ul>
    );
  }
  return <span className="font-mono">{JSON.stringify(value)}</span>;
};

const KindLabel = ({ kind }: { kind: DiffEntry["kind"] }) => {
  const tone =
    kind === "added"
      ? "bg-green-500/15 text-green-700 dark:text-green-400 border-green-500/30"
      : kind === "removed"
        ? "bg-red-500/15 text-red-700 dark:text-red-400 border-red-500/30"
        : "bg-amber-500/15 text-amber-700 dark:text-amber-400 border-amber-500/30";
  return (
    <span
      className={`inline-flex items-center rounded border px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${tone}`}
    >
      {kind}
    </span>
  );
};

export const DiffRow = ({ entry }: { entry: DiffEntry }) => {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center gap-2">
        <KindLabel kind={entry.kind} />
        <span className="font-mono text-xs text-foreground">{entry.path}</span>
      </div>
      <div className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
        {entry.kind !== "added" && (
          <>
            <span className="text-red-600 dark:text-red-400">before</span>
            <div className="min-w-0">
              <ValueCell value={entry.before} />
            </div>
          </>
        )}
        {entry.kind !== "removed" && (
          <>
            <span className="text-green-600 dark:text-green-400">after</span>
            <div className="min-w-0">
              <ValueCell value={entry.after} />
            </div>
          </>
        )}
      </div>
    </div>
  );
};

export default DiffRow;
