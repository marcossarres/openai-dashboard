import {
  PieChart,
  Pie,
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

const CustomTooltip = ({ active, payload, accentColor }) => {
  if (!active || !payload?.length) return null;
  const { model, cost } = payload[0].payload;
  return (
    <div className="bg-[#1c1c1c] border border-[#333] rounded-md px-3.5 py-2.5 text-sm text-gray-200 max-w-[240px]">
      <p className="m-0 mb-1 text-[#888] break-words">{model}</p>
      <p className="m-0 font-semibold" style={{ color: accentColor }}>${cost.toFixed(4)}</p>
    </div>
  );
};

export default function ModelBreakdown({ costsData, accentColor = '#00d4aa' }) {
  const data = aggregateByModel(costsData);

  if (!data.length) {
    return (
      <div className="bg-[#141414] border border-[#222] rounded-xl p-10 text-center text-[#444] text-sm">
        No model cost data available for this period.
      </div>
    );
  }

  return (
    <div className="bg-[#141414] border border-[#222] rounded-xl px-4 pt-6 pb-6 flex flex-col gap-6">
      <ResponsiveContainer width="100%" height={280}>
        <PieChart>
          <Pie
            data={data}
            dataKey="cost"
            nameKey="model"
            cx="50%"
            cy="50%"
            innerRadius={70}
            outerRadius={110}
            paddingAngle={2}
            stroke="#0f0f0f"
          >
            {data.map((entry, index) => (
              <Cell key={entry.model} fill={PALETTE[index % PALETTE.length]} fillOpacity={0.9} />
            ))}
          </Pie>
          <Tooltip content={<CustomTooltip accentColor={accentColor} />} />
        </PieChart>
      </ResponsiveContainer>

      {/* Legend */}
      <div className="grid grid-cols-2 md:grid-cols-3 gap-2">
        {data.map(({ model, cost }, index) => (
          <div key={model} className="flex items-center gap-2 text-xs text-[#888]">
            <span
              className="w-2.5 h-2.5 rounded-sm shrink-0"
              style={{ background: PALETTE[index % PALETTE.length] }}
            />
            <span className="flex-1 overflow-hidden text-ellipsis whitespace-nowrap" title={model}>
              {model}
            </span>
            <span className="text-gray-200 font-semibold shrink-0">${cost.toFixed(4)}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
