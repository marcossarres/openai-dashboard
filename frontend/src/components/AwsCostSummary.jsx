function fmt(cents) {
  if (cents == null) return '—';
  return `$${(cents / 100).toFixed(2)}`;
}

export default function AwsCostSummary({ awsData }) {
  const totalCost = awsData?.total_cost != null ? fmt(awsData.total_cost) : '—';

  const allServices = new Map();
  for (const day of awsData?.daily_costs || []) {
    for (const svc of day.services || []) {
      allServices.set(svc.name, (allServices.get(svc.name) || 0) + svc.cost);
    }
  }
  const serviceCount = allServices.size;
  const topService = [...allServices.entries()].sort((a, b) => b[1] - a[1])[0];

  const cards = [
    { label: 'Total Cost', value: totalCost, sub: 'Selected date range', accent: true },
    { label: 'Services Used', value: serviceCount || '—', sub: 'Active billing services', accent: false },
    {
      label: 'Top Service',
      value: topService ? topService[0].split(' ').slice(0, 2).join(' ') : '—',
      sub: topService ? fmt(topService[1]) : 'No data',
      accent: false,
    },
    { label: 'Region', value: 'us-east-1', sub: 'Cost Explorer region', accent: false },
  ];

  return (
    <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
      {cards.map(({ label, value, sub, accent }) => (
        <div
          key={label}
          className={`rounded-xl border p-5 ${
            accent
              ? 'bg-gradient-to-br from-[#2a1a00] to-[#141414] border-[#4a3000]'
              : 'bg-[#141414] border-[#222]'
          }`}
        >
          <p className="text-xs font-semibold text-[#555] uppercase tracking-wider mb-2.5">{label}</p>
          <p className={`text-3xl font-bold tracking-tight leading-none ${accent ? 'text-[#f59e0b]' : 'text-white'}`}>
            {value}
          </p>
          <p className="text-xs text-[#444] mt-1.5">{sub}</p>
        </div>
      ))}
    </div>
  );
}
