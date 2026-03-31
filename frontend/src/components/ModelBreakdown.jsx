import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Cell,
  ResponsiveContainer,
} from 'recharts';

const PALETTE = [
  '#00d4aa', '#00a882', '#3b82f6', '#8b5cf6', '#f59e0b',
  '#ef4444', '#06b6d4', '#ec4899', '#84cc16', '#f97316',
];

function aggregateByModel(costsData) {
  if (!costsData?.daily_costs) return [];
  const map = new Map();
  for (const day of costsData.daily_costs) {
    for (const item of day.line_items || []) {
      const model = item.name || 'Unknown';
      map.set(model, (map.get(model) || 0) + (item.cost || 0));
    }
  }
  return Array.from(map.entries())
    .map(([model, costCents]) => ({ model, cost: parseFloat((costCents / 100).toFixed(4)) }))
    .sort((a, b) => b.cost - a.cost);
}

function truncate(str, max = 20) {
  return str.length > max ? str.slice(0, max) + '…' : str;
}

const CustomTooltip = ({ active, payload, accentColor }) => {
  if (!active || !payload?.length) return null;
  const { model, cost } = payload[0].payload;
  return (
    <div
      className="rounded-md px-3.5 py-2.5 text-sm max-w-[240px]"
      style={{
        background: 'var(--tooltip-bg)',
        border: `1px solid var(--tooltip-bdr)`,
        color: 'var(--tooltip-text)'
      }}
    >
      <p className="m-0 mb-1 text-[var(--tooltip-sub)] break-words">{model}</p>
      <p className="m-0 font-semibold" style={{ color: accentColor }}>${cost.toFixed(4)}</p>
    </div>
  );
};

export default function ModelBreakdown({ costsData, accentColor = '#00d4aa' }) {
  const data = aggregateByModel(costsData);

  if (!data.length) {
    return (
      <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-xl p-10 text-center text-[var(--text-2)] text-sm">
        No model cost data available for this period.
      </div>
    );
  }

  const chartData = data.map((d) => ({ ...d, shortModel: truncate(d.model) }));

  return (
    <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-xl px-4 pt-6 pb-6 flex flex-col gap-6 transition-colors">
      <ResponsiveContainer width="100%" height={280}>
        <BarChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 40 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" vertical={false} />
          <XAxis
            dataKey="shortModel"
            tick={{ fill: 'var(--chart-axis)', fontSize: 11 }}
            tickLine={false}
            axisLine={false}
            angle={-35}
            textAnchor="end"
            interval={0}
          />
          <YAxis
            tick={{ fill: 'var(--chart-axis)', fontSize: 12 }}
            tickLine={false}
            axisLine={false}
            tickFormatter={(v) => `$${v}`}
            width={52}
          />
          <Tooltip content={<CustomTooltip accentColor={accentColor} />} cursor={{ fill: 'var(--bg-surface-3)' }} />
          <Bar dataKey="cost" radius={[4, 4, 0, 0]}>
            {chartData.map((_, index) => (
              <Cell key={index} fill={PALETTE[index % PALETTE.length]} fillOpacity={0.85} />
            ))}
          </Bar>
        </BarChart>
      </ResponsiveContainer>

      {/* Legend */}
      <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
        {data.map(({ model, cost }, index) => (
          <div key={model} className="flex items-center gap-2 text-xs text-[var(--text-3)]">
            <span
              className="w-2.5 h-2.5 rounded-sm shrink-0"
              style={{ background: PALETTE[index % PALETTE.length] }}
            />
            <span className="flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={model}>
              {model}
            </span>
            <span className="text-[var(--text-1)] font-semibold shrink-0">${cost.toFixed(4)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
