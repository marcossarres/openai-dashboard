import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';

function buildChartData(costsData) {
  if (!costsData?.daily_costs) return [];
  return costsData.daily_costs.map((day) => {
    const date = new Date(day.timestamp * 1000);
    const label = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    const totalCents = (day.line_items || []).reduce((sum, item) => sum + (item.cost || 0), 0);
    return { date: label, cost: parseFloat((totalCents / 100).toFixed(4)) };
  });
}

const CustomTooltip = ({ active, payload, label, accentColor }) => {
  if (!active || !payload?.length) return null;
  return (
    <div className="bg-[#1c1c1c] border border-[#333] rounded-md px-3.5 py-2.5 text-sm text-gray-200">
      <p className="m-0 mb-1 text-[#888]">{label}</p>
      <p className="m-0 font-semibold" style={{ color: accentColor }}>${payload[0].value.toFixed(4)}</p>
    </div>
  );
};

export default function UsageChart({ costsData, accentColor = '#00d4aa', gradientId = 'openai' }) {
  const data = buildChartData(costsData);

  if (!data.length) {
    return (
      <div className="bg-[#141414] border border-[#222] rounded-xl p-10 text-center text-[#444] text-sm">
        No daily cost data available for this period.
      </div>
    );
  }

  const tickInterval = Math.max(1, Math.floor(data.length / 8)) - 1;

  const gradId = `costGrad-${gradientId}`;

  return (
    <div className="bg-[#141414] border border-[#222] rounded-xl px-4 pt-6 pb-4">
      <ResponsiveContainer width="100%" height={280}>
        <AreaChart data={data} margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id={gradId} x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor={accentColor} stopOpacity={0.25} />
              <stop offset="95%" stopColor={accentColor} stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="3 3" stroke="#1e1e1e" vertical={false} />
          <XAxis
            dataKey="date"
            tick={{ fill: '#555', fontSize: 12 }}
            tickLine={false}
            axisLine={false}
            interval={tickInterval}
          />
          <YAxis
            tick={{ fill: '#555', fontSize: 12 }}
            tickLine={false}
            axisLine={false}
            tickFormatter={(v) => `$${v}`}
            width={52}
          />
          <Tooltip content={<CustomTooltip accentColor={accentColor} />} cursor={{ stroke: '#333' }} />
          <Area
            type="monotone"
            dataKey="cost"
            stroke={accentColor}
            strokeWidth={2}
            fill={`url(#${gradId})`}
            dot={false}
            activeDot={{ r: 4, fill: accentColor, stroke: '#0f0f0f', strokeWidth: 2 }}
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
