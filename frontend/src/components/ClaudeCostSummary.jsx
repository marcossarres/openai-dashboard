function fmt(cents) {
  if (cents == null) return '—';
  return `$${(cents / 100).toFixed(2)}`;
}

export default function ClaudeCostSummary({ claudeData }) {
  const totalCents = claudeData?.total_cost ?? null;
  const totalCost = fmt(totalCents);
  const dailyCosts = claudeData?.daily_costs || [];
  const dayCount = dailyCosts.length;
  const avgDaily = dayCount ? fmt(Math.round((totalCents || 0) / dayCount)) : '—';

  const uniqueItems = new Set();
  let sampleCurrency = 'USD';
  for (const day of dailyCosts) {
    for (const item of day.line_items || []) {
      if (item.name) uniqueItems.add(item.name);
      if (item.currency) sampleCurrency = item.currency;
    }
  }

  const cards = [
    { label: 'Total Cost', value: totalCost, sub: 'Selected date range', accent: true },
    { label: 'Avg Daily', value: avgDaily, sub: 'Average spend per day', accent: false },
    { label: 'Line Items', value: uniqueItems.size || '—', sub: 'Unique charges', accent: false },
    { label: 'Currency', value: sampleCurrency || 'USD', sub: 'Reported currency', accent: false },
  ];

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
      {cards.map(({ label, value, sub, accent }) => (
        <div
          key={label}
          className={`rounded-xl border p-5 ${
            accent
              ? 'bg-gradient-to-br from-[#1d0f2d] to-[#141414] border-[#422060]'
              : 'bg-[#141414] border-[#222]'
          }`}
        >
          <p className="text-xs font-semibold text-[#555] uppercase tracking-wider mb-2.5">{label}</p>
          <p className={`text-3xl font-bold tracking-tight leading-none ${accent ? 'text-[#c084fc]' : 'text-white'}`}>
            {value}
          </p>
          <p className="text-xs text-[#444] mt-1.5">{sub}</p>
        </div>
      ))}
    </div>
  );
}
