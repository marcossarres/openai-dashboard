function fmt(cents) {
  if (cents == null) return '—';
  return `$${(cents / 100).toFixed(2)}`;
}

function fmtUsd(usd) {
  if (usd == null) return '—';
  return `$${Number(usd).toFixed(2)}`;
}

export default function CostSummary({ subscription, costsData }) {
  const totalCost = costsData?.total_usage != null ? fmt(costsData.total_usage) : '—';
  const hardLimit = subscription?.hard_limit_usd != null ? fmtUsd(subscription.hard_limit_usd) : '—';
  const softLimit = subscription?.soft_limit_usd != null ? fmtUsd(subscription.soft_limit_usd) : '—';
  const plan = subscription?.plan?.title || '—';

  const cards = [
    { label: 'Total Cost', value: totalCost, sub: 'Selected date range', accent: true },
    { label: 'Hard Limit', value: hardLimit, sub: 'Monthly maximum', accent: false },
    { label: 'Soft Limit', value: softLimit, sub: 'Warning threshold', accent: false },
    { label: 'Plan', value: plan, sub: 'Current billing plan', accent: false },
  ];

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
      {cards.map(({ label, value, sub, accent }) => (
        <div
          key={label}
          className={`rounded-xl border p-5 transition-colors ${
            accent
              ? 'bg-gradient-to-br from-[#dff8f1] to-[#f3fbf8] border-[#b5e8db] dark:from-[#0d2420] dark:to-[#141414] dark:border-[#1a4a3a]'
              : 'bg-[var(--bg-surface-2)] border-[var(--border)]'
          }`}
        >
          <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-wider mb-2.5">
            {label}
          </p>
          <p className={`text-3xl font-bold tracking-tight leading-none ${accent ? 'text-[#00d4aa]' : 'text-[var(--text-1)]'}`}>
            {value}
          </p>
          <p className="text-xs text-[var(--text-2)] mt-1.5">{sub}</p>
        </div>
      ))}
    </div>
  );
}
