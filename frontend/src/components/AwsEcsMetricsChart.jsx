import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
  CartesianGrid,
  Legend,
} from 'recharts';

function formatSeries(series = []) {
  return series.map((point) => {
    const dateLabel = new Date(point.timestamp).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    return {
      date: dateLabel,
      cpu: typeof point.cpu === 'number' ? Number(point.cpu.toFixed(2)) : null,
      memory: typeof point.memory === 'number' ? Number(point.memory.toFixed(2)) : null,
    };
  });
}

function EcsTooltip({ active, payload, label }) {
  if (!active || !payload?.length) return null;
  const cpu = payload.find((item) => item.dataKey === 'cpu');
  const memory = payload.find((item) => item.dataKey === 'memory');
  return (
    <div className="bg-[#1c1c1c] border border-[#333] rounded-md px-3.5 py-2.5 text-sm text-gray-200">
      <p className="m-0 mb-1 text-[#888]">{label}</p>
      {cpu?.value != null && (
        <p className="m-0 text-[#f59e0b]">CPU: {cpu.value.toFixed(2)}%</p>
      )}
      {memory?.value != null && (
        <p className="m-0 text-[#34d399]">Memory: {memory.value.toFixed(2)}%</p>
      )}
      {!cpu && !memory && <p className="m-0 text-[#555]">No data</p>}
    </div>
  );
}

export default function AwsEcsMetricsChart({ data }) {
  const chartData = formatSeries(data);

  if (!chartData.length) {
    return (
      <div className="bg-[#141414] border border-[#222] rounded-xl p-10 text-center text-[#444] text-sm">
        No ECS metrics available for this period.
      </div>
    );
  }

  const tickInterval = Math.max(1, Math.floor(chartData.length / 8)) - 1;

  return (
    <div className="bg-[#141414] border border-[#222] rounded-xl px-4 pt-6 pb-4">
      <ResponsiveContainer width="100%" height={300}>
        <LineChart data={chartData} margin={{ top: 4, right: 16, left: 0, bottom: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#1e1e1e" vertical={false} />
          <XAxis dataKey="date" tick={{ fill: '#555', fontSize: 12 }} tickLine={false} axisLine={false} interval={tickInterval} />
          <YAxis tick={{ fill: '#555', fontSize: 12 }} tickLine={false} axisLine={false} tickFormatter={(v) => `${v}%`} width={50} domain={[0, 'auto']} />
          <Tooltip content={<EcsTooltip />} cursor={{ stroke: '#333' }} />
          <Legend wrapperStyle={{ color: '#777', fontSize: 12 }} />
          <Line type="monotone" dataKey="cpu" stroke="#f59e0b" strokeWidth={2} dot={false} activeDot={{ r: 4 }} name="CPU %" />
          <Line type="monotone" dataKey="memory" stroke="#34d399" strokeWidth={2} dot={false} activeDot={{ r: 4 }} name="Memory %" />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
