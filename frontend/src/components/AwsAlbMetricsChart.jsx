import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';

function formatSeries(series = []) {
  return series.map((point) => ({
    date: new Date(point.timestamp).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }),
    requests: typeof point.requests === 'number' ? point.requests : 0,
  }));
}

function AlbTooltip({ active, payload, label }) {
  if (!active || !payload?.length) return null;
  return (
    <div className="bg-[#1c1c1c] border border-[#333] rounded-md px-3.5 py-2.5 text-sm text-gray-200">
      <p className="m-0 mb-1 text-[#888]">{label}</p>
      <p className="m-0 text-[#38bdf8] font-semibold">{payload[0].value.toLocaleString()} requests</p>
    </div>
  );
}

export default function AwsAlbMetricsChart({ data }) {
  const chartData = formatSeries(data);

  if (!chartData.length) {
    return (
      <div className="bg-[#141414] border border-[#222] rounded-xl p-10 text-center text-[#444] text-sm">
        No ALB metrics available for this period.
      </div>
    );
  }

  const tickInterval = Math.max(1, Math.floor(chartData.length / 8)) - 1;

  return (
    <div className="bg-[#141414] border border-[#222] rounded-xl px-4 pt-6 pb-4">
      <ResponsiveContainer width="100%" height={300}>
        <AreaChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
          <defs>
            <linearGradient id="albRequests" x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor="#38bdf8" stopOpacity={0.35} />
              <stop offset="95%" stopColor="#38bdf8" stopOpacity={0} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="3 3" stroke="#1e1e1e" vertical={false} />
          <XAxis dataKey="date" tick={{ fill: '#555', fontSize: 12 }} tickLine={false} axisLine={false} interval={tickInterval} />
          <YAxis tick={{ fill: '#555', fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => v.toLocaleString()} width={60} />
          <Tooltip content={<AlbTooltip />} cursor={{ stroke: '#333' }} />
          <Area
            type="monotone"
            dataKey="requests"
            stroke="#38bdf8"
            strokeWidth={2}
            fill="url(#albRequests)"
            dot={false}
            activeDot={{ r: 4, fill: '#38bdf8', stroke: '#0f0f0f', strokeWidth: 2 }}
            name="Requests"
          />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  );
}
