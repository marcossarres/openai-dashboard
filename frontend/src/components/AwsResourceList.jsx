import { useState } from 'react';

const POSITIVE_STATES = [
  'active', 'available', 'healthy', 'deployed', 'alias_set', 'https_enabled',
  'update_complete', 'create_complete', 'exists', 'issued',
];
const WARNING_STATES = ['empty', 'no_https_rule', 'update_in_progress', 'create_in_progress', 'pending_validation'];
const NEGATIVE_STATES = ['not_found', 'unknown', 'failed', 'error', 'rollback_complete', 'rollback_in_progress'];

function classifyStatus(status) {
  if (!status) return 'neutral';
  const n = status.toString().toLowerCase().replace(/\s+/g, '_');
  if (POSITIVE_STATES.includes(n)) return 'positive';
  if (NEGATIVE_STATES.includes(n)) return 'negative';
  if (WARNING_STATES.includes(n)) return 'warning';
  // fraction like "2/2" → positive if equal, warning if partial, negative if 0
  const frac = n.match(/^(\d+)\/(\d+)$/);
  if (frac) {
    const [, a, b] = frac.map(Number);
    if (a === b && b > 0) return 'positive';
    if (a === 0) return 'negative';
    return 'warning';
  }
  return 'neutral';
}

const CLASS = {
  positive: 'text-emerald-400',
  negative: 'text-red-400',
  warning: 'text-amber-400',
  neutral: 'text-[var(--text-1)]',
};

function statusClass(status) {
  return CLASS[classifyStatus(status)] ?? CLASS.neutral;
}

// Worst rank: negative > warning > neutral > positive
const RANK = { negative: 0, warning: 1, neutral: 2, positive: 3 };

function groupSummaryStatus(items) {
  if (items.length === 1) return items[0].status;
  const statuses = items.map((i) => i.status);
  const unique = [...new Set(statuses)];
  if (unique.length === 1) return unique[0];
  // return worst
  return statuses.reduce((worst, s) => {
    return RANK[classifyStatus(s)] < RANK[classifyStatus(worst)] ? s : worst;
  });
}

const SERVICE_ORDER = ['CFN', 'ECS', 'ASG', 'ALB', 'CWL', 'ECR', 'S3', 'CFD', 'R53', 'ACM', 'SG'];

function groupItems(items) {
  const map = new Map();
  for (const item of items) {
    if (!map.has(item.serviceType)) map.set(item.serviceType, []);
    map.get(item.serviceType).push(item);
  }
  // sort by SERVICE_ORDER, then alphabetically for unknown types
  return [...map.entries()].sort(([a], [b]) => {
    const ia = SERVICE_ORDER.indexOf(a);
    const ib = SERVICE_ORDER.indexOf(b);
    if (ia === -1 && ib === -1) return a.localeCompare(b);
    if (ia === -1) return 1;
    if (ib === -1) return -1;
    return ia - ib;
  });
}

function GroupRow({ serviceType, groupItems: gItems, isLast }) {
  const [open, setOpen] = useState(false);
  const single = gItems.length === 1;
  const summaryStatus = groupSummaryStatus(gItems);
  const summaryClass = statusClass(summaryStatus);

  return (
    <>
      {/* Group header row */}
      <div
        className={`grid items-center px-5 py-3 border-[var(--border)] ${!isLast || open ? 'border-b' : ''} ${
          !single ? 'cursor-pointer hover:bg-[var(--bg-surface-3)] transition-colors select-none' : ''
        }`}
        style={{ gridTemplateColumns: '120px minmax(0,1fr) 120px' }}
        onClick={!single ? () => setOpen((o) => !o) : undefined}
      >
        {/* Type + chevron */}
        <div className="flex items-center gap-2">
          {!single && (
            <span
              className="text-[var(--text-3)] text-xl transition-transform duration-150 inline-block leading-none"
              style={{ transform: open ? 'rotate(90deg)' : 'rotate(0deg)' }}
            >
              ›
            </span>
          )}
          <span className="font-semibold text-[var(--text-2)] text-sm">{serviceType}</span>
          {!single && (
            <span className="text-[10px] font-medium text-[var(--text-3)] bg-[var(--bg-surface-3)] rounded-full px-1.5 py-0.5 leading-none">
              {gItems.length}
            </span>
          )}
        </div>

        {/* Component summary */}
        <span className="text-sm text-[var(--text-1)] truncate pr-4">
          {single ? gItems[0].component : gItems.map((i) => i.component).join(', ')}
        </span>

        {/* Status */}
        <span className={`text-sm font-semibold text-right ${summaryClass}`}>
          {summaryStatus || '—'}
        </span>
      </div>

      {/* Expanded subitems */}
      {!single && open && gItems.map((item, idx) => (
        <div
          key={`${item.serviceType}-${item.component}-${idx}`}
          className={`grid items-center pl-10 pr-5 py-2.5 border-[var(--border)] ${
            idx < gItems.length - 1 || !isLast ? 'border-b' : ''
          } bg-[var(--bg-surface-2)]`}
          style={{ gridTemplateColumns: '120px minmax(0,1fr) 120px' }}
        >
          <span className="text-xs text-[var(--text-3)]">{item.serviceType}</span>
          <span className="text-sm text-[var(--text-1)] truncate pr-4">{item.component}</span>
          <span className={`text-sm font-semibold text-right ${statusClass(item.status)}`}>
            {item.status || '—'}
          </span>
        </div>
      ))}
    </>
  );
}

export default function AwsResourceList({ items = [] }) {
  if (!items.length) {
    return (
      <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-xl px-5 py-6 text-sm text-[var(--text-2)]">
        No resource information available.
      </div>
    );
  }

  const groups = groupItems(items);

  return (
    <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-xl overflow-hidden">
      {/* Header */}
      <div
        className="grid px-5 py-3 text-[10px] font-semibold tracking-[0.3em] text-[var(--text-3)] uppercase border-b border-[var(--border)]"
        style={{ gridTemplateColumns: '120px minmax(0,1fr) 120px' }}
      >
        <span>Service</span>
        <span>Component</span>
        <span className="text-right">Status</span>
      </div>

      {/* Groups */}
      {groups.map(([serviceType, gItems], idx) => (
        <GroupRow
          key={serviceType}
          serviceType={serviceType}
          groupItems={gItems}
          isLast={idx === groups.length - 1}
        />
      ))}
    </div>
  );
}
