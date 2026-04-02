import { useState, useCallback, useEffect } from 'react';
import { apiClient } from './api.js';
import CostSummary from './components/CostSummary.jsx';
import UsageChart from './components/UsageChart.jsx';
import ModelBreakdown from './components/ModelBreakdown.jsx';
import AwsCostSummary from './components/AwsCostSummary.jsx';
import AwsUsageChart from './components/AwsUsageChart.jsx';
import AwsServiceBreakdown from './components/AwsServiceBreakdown.jsx';
import AwsResourceList from './components/AwsResourceList.jsx';
import ClaudeCostSummary from './components/ClaudeCostSummary.jsx';
import ApiKeyModal from './components/ApiKeyModal.jsx';
import { useTheme } from './context/ThemeContext.jsx';

function toDateString(date) {
  return date.toISOString().slice(0, 10);
}

function getDefaultRange() {
  const end = new Date();
  const start = new Date();
  start.setDate(start.getDate() - 30);
  return { start: toDateString(start), end: toDateString(end) };
}

export default function App() {
  const defaultRange = getDefaultRange();
  const { dark, toggle } = useTheme();
  const [activeTab, setActiveTab] = useState('openai');
  const [dateRange, setDateRange] = useState(defaultRange);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(true);
  const [openaiKeyPreview, setOpenaiKeyPreview] = useState(null);
  const [claudeStatus, setClaudeStatus] = useState({ hasKey: false, keyPreview: null, hasOrgId: false, orgPreview: null });

  // OpenAI state
  const [costsData, setCostsData] = useState(null);
  const [subscription, setSubscription] = useState(null);
  const [account, setAccount] = useState(null);
  const [openaiLoading, setOpenaiLoading] = useState(false);
  const [openaiError, setOpenaiError] = useState(null);
  const [openaiSynced, setOpenaiSynced] = useState(false);

  // AWS state
  const [awsData, setAwsData] = useState(null);
  const [awsLoading, setAwsLoading] = useState(false);
  const [awsError, setAwsError] = useState(null);
  const [awsSynced, setAwsSynced] = useState(false);
  const [awsServices, setAwsServices] = useState([]);
  const [awsServicesError, setAwsServicesError] = useState(null);

  // Claude state
  const [claudeData, setClaudeData] = useState(null);
  const [claudeLoading, setClaudeLoading] = useState(false);
  const [claudeError, setClaudeError] = useState(null);
  const [claudeSynced, setClaudeSynced] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      let shouldOpen = false;
      try {
        const res = await apiClient.get('/api/config/status');
        if (!cancelled) {
          setOpenaiKeyPreview(res.data.keyPreview);
          if (!res.data.hasKey) shouldOpen = true;
        }
      } catch (err) {
        console.warn('Failed to load OpenAI status', err.message);
      }

      try {
        const res = await apiClient.get('/api/claude/config/status');
        if (!cancelled) {
          setClaudeStatus(res.data);
          if (!res.data.hasKey) shouldOpen = true;
        }
      } catch (err) {
        console.warn('Failed to load Claude status', err.message);
      }

      if (shouldOpen && !cancelled) setSettingsOpen(true);
    })();

    return () => { cancelled = true; };
  }, []);

  const fetchOpenAI = useCallback(async () => {
    setOpenaiLoading(true);
    setOpenaiError(null);
    try {
      const params = { start_date: dateRange.start, end_date: dateRange.end };
      const [costsRes, subRes, accountRes] = await Promise.all([
        apiClient.get('/api/costs', { params }),
        apiClient.get('/api/subscription'),
        apiClient.get('/api/account'),
      ]);
      setCostsData(costsRes.data);
      setSubscription(subRes.data);
      setAccount(accountRes.data);
      setOpenaiSynced(true);
    } catch (err) {
      setOpenaiError(err.response?.data?.error || err.message || 'Failed to fetch OpenAI data.');
    } finally {
      setOpenaiLoading(false);
    }
  }, [dateRange.start, dateRange.end]);

  const fetchAWS = useCallback(async () => {
    setAwsLoading(true);
    setAwsError(null);
    setAwsServicesError(null);
    try {
      const params = { start_date: dateRange.start, end_date: dateRange.end };
      const [costsRes, servicesRes] = await Promise.all([
        apiClient.get('/api/aws/costs', { params }),
        apiClient.get('/api/aws/services').catch((err) => {
          setAwsServicesError(err.response?.data?.error || err.message || 'Failed to load deployed services.');
          return { data: { items: [] } };
        }),
      ]);
      setAwsData(costsRes.data);
      setAwsServices(servicesRes.data?.items || []);
      setAwsSynced(true);
    } catch (err) {
      setAwsError(err.response?.data?.error || err.message || 'Failed to fetch AWS cost data.');
      setAwsServices([]);
    } finally {
      setAwsLoading(false);
    }
  }, [dateRange.start, dateRange.end]);

  const fetchClaude = useCallback(async () => {
    setClaudeLoading(true);
    setClaudeError(null);
    try {
      const params = { start_date: dateRange.start, end_date: dateRange.end };
      const res = await apiClient.get('/api/claude/costs', { params });
      setClaudeData(res.data);
      setClaudeSynced(true);
    } catch (err) {
      setClaudeError(err.response?.data?.error || err.message || 'Failed to fetch Claude cost data.');
    } finally {
      setClaudeLoading(false);
    }
  }, [dateRange.start, dateRange.end]);

  function handleDateChange(field, value) {
    setDateRange((prev) => ({ ...prev, [field]: value }));
  }

  const isOpenAI = activeTab === 'openai';
  const isAWS = activeTab === 'aws';
  const isClaude = activeTab === 'claude';
  const loading = isOpenAI ? openaiLoading : isAWS ? awsLoading : claudeLoading;
  const handleSync = isOpenAI ? fetchOpenAI : isAWS ? fetchAWS : fetchClaude;
  const accentColor = isOpenAI ? '#00d4aa' : isAWS ? '#f59e0b' : '#8b5cf6';
  const accentDark = isOpenAI ? '#00a882' : isAWS ? '#d97706' : '#7c3aed';
  const dateInputClass = 'bg-[var(--bg-surface-2)] border border-[var(--border-2)] rounded-md text-[var(--text-1)] px-3 py-1.5 text-sm outline-none cursor-pointer transition-colors focus:border-[var(--text-2)]';
  const dateInputStyle = { colorScheme: dark ? 'dark' : 'light' };

  return (
    <div className="min-h-screen bg-[var(--bg)] text-[var(--text-1)] transition-colors">
      <ApiKeyModal
        isOpen={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        openaiKeyPreview={openaiKeyPreview}
        onOpenAISaved={setOpenaiKeyPreview}
        claudeStatus={claudeStatus}
        onClaudeSaved={(next) => setClaudeStatus((prev) => ({ ...prev, ...next }))}
      />

      {/* Header */}
      <header
        className="border-b border-[var(--border)] px-10 py-5 flex items-center justify-between flex-wrap gap-4"
        style={{ backgroundColor: dark ? '#040e1d' : '#cbd5e1' }}
      >
        <div className="flex items-center gap-3">
          <div className="w-9 h-9 rounded-lg bg-gradient-to-br from-[#00d4aa] to-[#00a882] flex items-center justify-center text-[#0f0f0f] font-bold text-base">
            AI
          </div>
          <div>
            <h1 className="text-[var(--text-1)] font-semibold text-lg leading-tight tracking-tight m-0">
              Marcos Cost Dashboard
            </h1>
            <p className="text-[var(--text-3)] text-xs m-0 mt-0.5">Monitor your API spend and consumption</p>
          </div>
        </div>

        {/* Spend badge */}
        {isOpenAI && openaiSynced && (account?.name || account?.email || costsData?.total_usage != null) && (
          <div className="flex items-center gap-4 border-r border-[var(--border)] pr-4">
            {(account?.name || account?.email) && (
              <div className="flex items-center gap-1.5 text-sm">
                <span className="text-[var(--text-3)]">User</span>
                <span className="text-[var(--text-1)] font-medium">{account.name || account.email}</span>
              </div>
            )}
            {costsData?.total_usage != null && (
              <div className="flex items-center gap-1.5 text-sm">
                <span className="text-[var(--text-3)]">Spent</span>
                <span className="text-[#00d4aa] font-semibold">${(costsData.total_usage / 100).toFixed(2)}</span>
              </div>
            )}
          </div>
        )}
        {isAWS && awsSynced && awsData?.total_cost != null && (
          <div className="flex items-center gap-4 border-r border-[var(--border)] pr-4">
            <div className="flex items-center gap-1.5 text-sm">
              <span className="text-[var(--text-3)]">AWS Spent</span>
              <span className="text-[#f59e0b] font-semibold">${(awsData.total_cost / 100).toFixed(2)}</span>
            </div>
          </div>
        )}
        {isClaude && claudeSynced && claudeData?.total_cost != null && (
          <div className="flex items-center gap-4 border-r border-[var(--border)] pr-4">
            <div className="flex items-center gap-1.5 text-sm">
              <span className="text-[var(--text-3)]">Claude Spent</span>
              <span className="text-[#c4b5fd] font-semibold">${(claudeData.total_cost / 100).toFixed(2)}</span>
            </div>
          </div>
        )}

        <div className="flex items-center gap-3 flex-wrap">
          <span className="text-[var(--text-2)] text-sm">From</span>
          <input
            type="date"
            className={dateInputClass}
            style={dateInputStyle}
            value={dateRange.start}
            max={dateRange.end}
            onChange={(e) => handleDateChange('start', e.target.value)}
          />
          <span className="text-[var(--text-2)] text-sm">to</span>
          <input
            type="date"
            className={dateInputClass}
            style={dateInputStyle}
            value={dateRange.end}
            min={dateRange.start}
            max={toDateString(new Date())}
            onChange={(e) => handleDateChange('end', e.target.value)}
          />
          <button
            type="button"
            onClick={handleSync}
            disabled={loading}
            style={{ background: `linear-gradient(to right, ${accentColor}, ${accentDark})` }}
            className="text-[#0f0f0f] font-semibold px-4 py-2 rounded-md text-sm disabled:opacity-60 disabled:cursor-not-allowed transition-opacity hover:opacity-90"
          >
            {loading ? 'Syncing…' : 'Sync'}
          </button>
          <button
            type="button"
            onClick={toggle}
            title={dark ? 'Switch to light mode' : 'Switch to dark mode'}
            aria-label={dark ? 'Switch to light mode' : 'Switch to dark mode'}
            aria-pressed={dark}
            className={`transition-colors text-lg leading-none p-2 rounded-full border ${
              dark ? 'bg-[var(--bg-surface-3)]' : 'bg-[var(--bg-surface-2)]'
            } border-[var(--border)] text-[var(--text-2)] hover:text-[var(--text-1)] hover:bg-[var(--bg-surface-3)]`}
          >
            {dark ? '☀️' : '🌙'}
          </button>
          <button
            type="button"
            onClick={() => setSettingsOpen(true)}
            title="Settings"
            className="text-[var(--text-3)] hover:text-[#00d4aa] transition-colors p-1.5 rounded-md hover:bg-[var(--bg-surface-2)] text-lg leading-none"
          >
            ⚙
          </button>
        </div>
      </header>

      {/* Body: sidebar + main */}
      <div className="flex min-h-[calc(100vh-73px)]">

        {/* Sidebar */}
        <aside
          className={`shrink-0 flex flex-col transition-all duration-200 overflow-hidden border-r ${
            sidebarOpen ? 'w-52' : 'w-12'
          }`}
          style={{
            background: dark
              ? 'linear-gradient(to bottom, #040e1d, #1a3f72)'
              : 'linear-gradient(to bottom, #cbd5e1, #ffffff)',
            borderColor: dark ? '#1a3456' : '#d1d5db',
          }}
        >
          {/* Collapse toggle */}
          <div className="flex items-center justify-end px-2 py-3 border-b" style={{ borderColor: dark ? '#1a3456' : '#d1d5db' }}>
            <button
              onClick={() => setSidebarOpen((o) => !o)}
              title={sidebarOpen ? 'Collapse sidebar' : 'Expand sidebar'}
              className="text-[#9ca3af] hover:text-[#374151] dark:text-[#4a7fa8] dark:hover:text-[#93c5fd] hover:bg-[rgba(0,0,0,0.06)] dark:hover:bg-[rgba(255,255,255,0.07)] rounded-md p-1.5 transition-colors text-base leading-none"
            >
              {sidebarOpen ? '‹' : '›'}
            </button>
          </div>

          {/* Nav items */}
          <nav className="flex flex-col gap-1 p-2 flex-1">
            {[
              { id: 'openai', label: 'OpenAI', icon: '◎', accent: '#00d4aa', activeBgLight: 'rgba(0,0,0,0.06)',   activeBgDark: 'rgba(100,180,255,0.12)' },
              { id: 'aws',    label: 'AWS',    icon: '☁', accent: '#f59e0b', activeBgLight: 'rgba(0,0,0,0.06)',   activeBgDark: 'rgba(100,180,255,0.12)' },
              { id: 'claude', label: 'Claude', icon: '✦', accent: '#c084fc', activeBgLight: 'rgba(0,0,0,0.06)',   activeBgDark: 'rgba(100,180,255,0.12)' },
            ].map(({ id, label, icon, accent, activeBgLight, activeBgDark }) => {
              const active = activeTab === id;
              const activeBg = dark ? activeBgDark : activeBgLight;
              return (
                <button
                  key={id}
                  onClick={() => setActiveTab(id)}
                  title={!sidebarOpen ? label : undefined}
                  className={`flex items-center gap-3 px-2 py-2.5 rounded-lg text-sm font-medium transition-colors text-left w-full border-l-2 ${
                    active
                      ? 'text-[#111827] dark:text-[#e0f0ff]'
                      : 'border-transparent text-[#6b7280] dark:text-[#4a7fa8] hover:text-[#111827] dark:hover:text-[#93c5fd] hover:bg-[rgba(0,0,0,0.06)] dark:hover:bg-[rgba(255,255,255,0.07)]'
                  }`}
                  style={active ? { borderColor: accent, background: activeBg } : {}}
                >
                  <span className="shrink-0 text-base w-5 text-center" style={{ color: active ? accent : undefined }}>
                    {icon}
                  </span>
                  {sidebarOpen && <span className="truncate">{label}</span>}
                </button>
              );
            })}
          </nav>
        </aside>

        {/* Main */}
        <main className="flex-1 min-w-0 px-8 py-8">

        {/* OpenAI Tab */}
        {isOpenAI && (
          <>
            {openaiError && (
              <div className="bg-red-950 border border-red-800 rounded-lg px-5 py-4 text-red-400 text-sm mb-6 flex gap-2 items-start">
                <span className="font-semibold shrink-0">Error:</span><span>{openaiError}</span>
              </div>
            )}
            {openaiLoading ? (
              <div className="flex flex-col items-center justify-center py-24 gap-4 text-[var(--text-3)] text-sm">
                <div className="w-10 h-10 border-[3px] border-[var(--border)] border-t-[#00d4aa] rounded-full spinner" />
                <span>Fetching OpenAI usage data…</span>
              </div>
            ) : !openaiSynced ? (
              <div className="flex flex-col items-center justify-center py-24 gap-3 text-[var(--text-2)] text-sm">
                <span className="text-4xl">📊</span>
                <p className="m-0">Press <strong className="text-[#00d4aa]">Sync</strong> to load your OpenAI usage data.</p>
                {openaiKeyPreview
                  ? <p className="m-0 text-xs text-[var(--text-3)]">Key: <span className="font-mono text-[var(--text-2)]">{openaiKeyPreview}</span></p>
                  : <button onClick={() => setSettingsOpen(true)} className="mt-2 text-[#00d4aa] text-xs underline underline-offset-2 hover:opacity-80">No key configured — click to set up</button>
                }
              </div>
            ) : (
              <>
                {(costsData || subscription) && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Summary</p>
                    <CostSummary subscription={subscription} costsData={costsData} />
                  </section>
                )}
                {costsData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Daily Cost Over Time</p>
                    <UsageChart costsData={costsData} />
                  </section>
                )}
                {costsData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Cost by Model</p>
                    <ModelBreakdown costsData={costsData} />
                  </section>
                )}
                {openaiSynced && !costsData?.daily_costs?.length && !openaiError && (
                  <div className="text-center text-[var(--text-2)] text-sm py-16">No usage data found for the selected period.</div>
                )}
              </>
            )}
          </>
        )}

        {/* AWS Tab */}
        {isAWS && (
          <>
            {awsError && (
              <div className="bg-red-950 border border-red-800 rounded-lg px-5 py-4 text-red-400 text-sm mb-6 flex gap-2 items-start">
                <span className="font-semibold shrink-0">Error:</span><span>{awsError}</span>
              </div>
            )}
            {awsLoading ? (
              <div className="flex flex-col items-center justify-center py-24 gap-4 text-[var(--text-3)] text-sm">
                <div className="w-10 h-10 border-[3px] border-[var(--border)] border-t-[#f59e0b] rounded-full spinner" />
                <span>Fetching AWS cost data…</span>
              </div>
            ) : !awsSynced ? (
              <div className="flex flex-col items-center justify-center py-24 gap-3 text-[var(--text-2)] text-sm">
                <span className="text-4xl">☁️</span>
                <p className="m-0">Press <strong className="text-[#f59e0b]">Sync</strong> to load your AWS cost data.</p>
                <p className="m-0 text-xs text-[var(--text-3)]">Uses the <span className="font-mono text-[var(--text-2)]">aws-cloudy</span> profile or configured credentials.</p>
                <button onClick={() => setSettingsOpen(true)} className="mt-1 text-[#f59e0b] text-xs underline underline-offset-2 hover:opacity-80">
                  Configure AWS credentials
                </button>
              </div>
            ) : (
              <>
                {awsData && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Summary</p>
                    <AwsCostSummary awsData={awsData} />
                  </section>
                )}
                {awsData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Daily Cost Over Time</p>
                    <AwsUsageChart awsData={awsData} />
                  </section>
                )}
                {awsData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Cost by Service</p>
                    <AwsServiceBreakdown awsData={awsData} />
                  </section>
                )}
                {awsSynced && !awsData?.daily_costs?.length && !awsError && (
                  <div className="text-center text-[var(--text-2)] text-sm py-16">No AWS cost data found for the selected period.</div>
                )}
                <section className="mb-8">
                  <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Deployed Services</p>
                  {awsServicesError ? (
                    <div className="bg-amber-950 border border-amber-700 rounded-lg px-5 py-4 text-amber-300 text-sm flex gap-2 items-start">
                      <span className="font-semibold shrink-0">Services unavailable:</span><span>{awsServicesError}</span>
                    </div>
                  ) : awsServices.length > 0 ? (
                    <AwsResourceList items={awsServices} />
                  ) : (
                    <div className="text-[var(--text-2)] text-sm">No deployed services found.</div>
                  )}
                </section>
              </>
            )}
          </>
        )}

        {/* Claude Tab */}
        {isClaude && (
          <>
            {claudeError && (
              <div className="bg-red-950 border border-red-800 rounded-lg px-5 py-4 text-red-400 text-sm mb-6 flex gap-2 items-start">
                <span className="font-semibold shrink-0">Error:</span><span>{claudeError}</span>
              </div>
            )}
            {claudeLoading ? (
              <div className="flex flex-col items-center justify-center py-24 gap-4 text-[var(--text-3)] text-sm">
                <div className="w-10 h-10 border-[3px] border-[var(--border)] border-t-[#c084fc] rounded-full spinner" />
                <span>Fetching Claude cost data…</span>
              </div>
            ) : !claudeSynced ? (
              <div className="flex flex-col items-center justify-center py-24 gap-3 text-[var(--text-2)] text-sm">
                <span className="text-4xl">🤖</span>
                <p className="m-0">Press <strong className="text-[#c084fc]">Sync</strong> to pull Claude console costs.</p>
                {claudeStatus?.keyPreview
                  ? <p className="m-0 text-xs text-[var(--text-3)]">Key: <span className="font-mono text-[var(--text-2)]">{claudeStatus.keyPreview}</span></p>
                  : (
                    <button onClick={() => setSettingsOpen(true)} className="mt-2 text-[#c084fc] text-xs underline underline-offset-2 hover:opacity-80">
                      No Claude Admin key configured — click to set up
                    </button>
                  )}
              </div>
            ) : (
              <>
                {claudeData && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Summary</p>
                    <ClaudeCostSummary claudeData={claudeData} />
                  </section>
                )}
                {claudeData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Daily Cost Over Time</p>
                    <UsageChart costsData={claudeData} accentColor="#c084fc" gradientId="claude" />
                  </section>
                )}
                {claudeData?.daily_costs?.length > 0 && (
                  <section className="mb-8">
                    <p className="text-xs font-semibold text-[var(--text-3)] uppercase tracking-widest mb-3">Cost by Line Item</p>
                    <ModelBreakdown costsData={claudeData} accentColor="#c084fc" />
                  </section>
                )}
                {claudeSynced && !claudeData?.daily_costs?.length && !claudeError && (
                  <div className="text-center text-[var(--text-2)] text-sm py-16">No Claude billing data found for the selected period.</div>
                )}
              </>
            )}
          </>
        )}
      </main>
      </div>
    </div>
  );
}
