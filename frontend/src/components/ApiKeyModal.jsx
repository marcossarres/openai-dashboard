import { useState, useEffect } from 'react';
import { apiClient, getApiBaseUrl, setApiBaseUrl } from '../api.js';

function OpenAITab({ keyPreview, onSaved, onClose }) {
  const [key, setKey] = useState('');
  const [show, setShow] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(false);

  async function handleSave(e) {
    e.preventDefault();
    if (!key.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const res = await apiClient.post('/api/config/key', { key: key.trim() });
      setSuccess(true);
      onSaved(res.data.keyPreview);
      setTimeout(onClose, 1000);
    } catch (err) {
      setError(err.response?.data?.error || err.message || 'Failed to save key');
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSave} className="px-6 py-5 flex flex-col gap-4">
      <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-lg px-4 py-3 text-sm flex items-center justify-between">
        <span className="text-[var(--text-3)]">Current key</span>
        <span className="text-[var(--text-2)] font-mono text-xs">
          {keyPreview || <span className="text-red-500">Not set</span>}
        </span>
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">New API Key</label>
        <div className="relative">
          <input
            type={show ? 'text' : 'password'}
            value={key}
            onChange={(e) => setKey(e.target.value)}
            placeholder="sk-admin-..."
            className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#00d4aa] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors pr-16"
            autoFocus
          />
          <button
            type="button"
            onClick={() => setShow((s) => !s)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-[var(--text-3)] hover:text-[var(--text-1)] text-xs transition-colors"
          >
            {show ? 'Hide' : 'Show'}
          </button>
        </div>
        <p className="text-[var(--text-2)] text-xs">
          Requires an Admin key (<span className="font-mono text-[var(--text-3)]">sk-admin-...</span>).
          Generate one at platform.openai.com/api-keys.
        </p>
      </div>

      {error && <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-2.5 text-red-400 text-sm">{error}</div>}
      {success && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Key saved successfully!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={onClose} className="flex-1 bg-[var(--bg-surface-3)] border border-[var(--border-2)] text-[var(--text-2)] hover:text-[var(--text-1)] rounded-lg py-2.5 text-sm transition-colors">
          Cancel
        </button>
        <button type="submit" disabled={saving || !key.trim()} className="flex-1 bg-gradient-to-r from-[#00d4aa] to-[#00a882] text-[#0f0f0f] font-semibold rounded-lg py-2.5 text-sm disabled:opacity-50 disabled:cursor-not-allowed transition-opacity hover:opacity-90">
          {saving ? 'Saving…' : 'Save Key'}
        </button>
      </div>
    </form>
  );
}

function ClaudeTab({ status, onSaved, onClose }) {
  const [key, setKey] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [orgId, setOrgId] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(false);

  async function handleSave(e) {
    e.preventDefault();
    if (!key.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const payload = { key: key.trim() };
      if (orgId?.trim()) payload.orgId = orgId.trim();
      const res = await apiClient.post('/api/claude/config/key', payload);
      setSuccess(true);
      onSaved({
        hasKey: true,
        keyPreview: res.data.keyPreview,
        hasOrgId: Boolean(res.data.orgPreview),
        orgPreview: res.data.orgPreview,
      });
      setTimeout(onClose, 1000);
    } catch (err) {
      setError(err.response?.data?.error || err.message || 'Failed to save Claude credentials');
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSave} className="px-6 py-5 flex flex-col gap-4">
      <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-lg px-4 py-3 text-sm flex items-center justify-between">
        <span className="text-[var(--text-3)]">Current key</span>
        <span className="text-[var(--text-2)] font-mono text-xs">
          {status?.keyPreview || <span className="text-red-500">Not set</span>}
        </span>
      </div>
      <div className="flex items-center justify-between text-xs text-[var(--text-2)]">
        <span>Org ID</span>
        <span className="font-mono text-[var(--text-3)]">{status?.orgPreview || '—'}</span>
      </div>
      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">Admin API Key</label>
        <div className="relative">
          <input
            type={showKey ? 'text' : 'password'}
            value={key}
            onChange={(e) => setKey(e.target.value)}
            placeholder="sk-ant-admin-..."
            className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#c084fc] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors pr-16"
            autoFocus
          />
          <button
            type="button"
            onClick={() => setShowKey((s) => !s)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-[var(--text-3)] hover:text-[var(--text-1)] text-xs transition-colors"
          >
            {showKey ? 'Hide' : 'Show'}
          </button>
        </div>
        <p className="text-[var(--text-2)] text-xs">
          Requires an Anthropic Admin API key. Create one at <span className="font-mono text-[var(--text-2)]">platform.claude.com/settings/admin-keys</span>.
        </p>
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">Organization ID (optional)</label>
        <input
          type="text"
          value={orgId}
          onChange={(e) => setOrgId(e.target.value)}
          placeholder="org_..."
          className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#c084fc] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors"
        />
        <p className="text-[var(--text-2)] text-xs">Only needed for multi-org setups. Leave blank to use your Admin key's default organization.</p>
      </div>

      {error && <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-2.5 text-red-400 text-sm">{error}</div>}
      {success && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Claude credentials saved!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={onClose} className="flex-1 bg-[var(--bg-surface-3)] border border-[var(--border-2)] text-[var(--text-2)] hover:text-[var(--text-1)] rounded-lg py-2.5 text-sm transition-colors">
          Cancel
        </button>
        <button
          type="submit"
          disabled={saving || !key.trim()}
          className="flex-1 bg-gradient-to-r from-[#c084fc] to-[#7c3aed] text-[#0f0f0f] font-semibold rounded-lg py-2.5 text-sm disabled:opacity-50 disabled:cursor-not-allowed transition-opacity hover:opacity-90"
        >
          {saving ? 'Saving…' : 'Save Claude Key'}
        </button>
      </div>
    </form>
  );
}

function AwsTab({ onClose }) {
  const [status, setStatus] = useState(null);
  const [accessKeyId, setAccessKeyId] = useState('');
  const [secretAccessKey, setSecretAccessKey] = useState('');
  const [region, setRegion] = useState('us-east-1');
  const [showSecret, setShowSecret] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(false);

  useEffect(() => {
    apiClient.get('/api/aws/config/status').then((res) => {
      setStatus(res.data);
      if (res.data.region) setRegion(res.data.region);
    }).catch(() => {});
  }, []);

  async function handleSave(e) {
    e.preventDefault();
    if (!accessKeyId.trim() || !secretAccessKey.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const res = await apiClient.post('/api/aws/config/credentials', {
        accessKeyId: accessKeyId.trim(),
        secretAccessKey: secretAccessKey.trim(),
        region: region.trim() || 'us-east-1',
      });
      setSuccess(true);
      setStatus({ hasCredentials: true, accessKeyPreview: res.data.accessKeyPreview, region: res.data.region });
      setTimeout(onClose, 1000);
    } catch (err) {
      setError(err.response?.data?.error || err.message || 'Failed to save credentials');
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={handleSave} className="px-6 py-5 flex flex-col gap-4">
      {status && (
        <div className="bg-[var(--bg-surface-2)] border border-[var(--border)] rounded-lg px-4 py-3 text-sm flex items-center justify-between">
          <span className="text-[var(--text-3)]">Current credentials</span>
          <span className="text-[var(--text-2)] font-mono text-xs">
            {status.hasCredentials
              ? <><span className="text-[#00d4aa]">{status.accessKeyPreview}</span> <span className="text-[var(--text-3)]">({status.region})</span></>
              : <span className="text-[var(--text-3)]">Using aws-cloudy profile</span>}
          </span>
        </div>
      )}

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">Access Key ID</label>
        <input
          type="text"
          value={accessKeyId}
          onChange={(e) => setAccessKeyId(e.target.value)}
          placeholder="AKIA..."
          className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors"
          autoFocus
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">Secret Access Key</label>
        <div className="relative">
          <input
            type={showSecret ? 'text' : 'password'}
            value={secretAccessKey}
            onChange={(e) => setSecretAccessKey(e.target.value)}
            placeholder="••••••••••••••••••••••••••••••••••••••••"
            className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors pr-16"
          />
          <button
            type="button"
            onClick={() => setShowSecret((s) => !s)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-[var(--text-3)] hover:text-[var(--text-1)] text-xs transition-colors"
          >
            {showSecret ? 'Hide' : 'Show'}
          </button>
        </div>
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">Region</label>
        <input
          type="text"
          value={region}
          onChange={(e) => setRegion(e.target.value)}
          placeholder="us-east-1"
          className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors"
        />
        <p className="text-[var(--text-2)] text-xs">
          Leave blank to use the <span className="font-mono text-[var(--text-3)]">aws-cloudy</span> profile from ~/.aws/credentials.
        </p>
      </div>

      {error && <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-2.5 text-red-400 text-sm">{error}</div>}
      {success && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Credentials saved successfully!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={onClose} className="flex-1 bg-[var(--bg-surface-3)] border border-[var(--border-2)] text-[var(--text-2)] hover:text-[var(--text-1)] rounded-lg py-2.5 text-sm transition-colors">
          Cancel
        </button>
        <button
          type="submit"
          disabled={saving || !accessKeyId.trim() || !secretAccessKey.trim()}
          className="flex-1 bg-gradient-to-r from-[#f59e0b] to-[#d97706] text-[#0f0f0f] font-semibold rounded-lg py-2.5 text-sm disabled:opacity-50 disabled:cursor-not-allowed transition-opacity hover:opacity-90"
        >
          {saving ? 'Saving…' : 'Save Credentials'}
        </button>
      </div>
    </form>
  );
}

function ConnectionTab({ onClose }) {
  const [url, setUrl] = useState(getApiBaseUrl);
  const [saved, setSaved] = useState(false);

  function handleSave(e) {
    e.preventDefault();
    setApiBaseUrl(url);
    setSaved(true);
    setTimeout(onClose, 1000);
  }

  function handleClear() {
    setUrl('');
    setApiBaseUrl('');
    setSaved(true);
    setTimeout(onClose, 1000);
  }

  return (
    <form onSubmit={handleSave} className="px-6 py-5 flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[var(--text-2)] font-medium uppercase tracking-wider">API Base URL</label>
        <input
          type="text"
          value={url}
          onChange={(e) => { setUrl(e.target.value); setSaved(false); }}
          placeholder="http://localhost:3001"
          className="w-full bg-[var(--bg-surface-3)] border border-[var(--border-2)] focus:border-[var(--text-2)] rounded-lg px-4 py-2.5 text-sm text-[var(--text-1)] font-mono outline-none transition-colors"
          autoFocus
        />
        <p className="text-[var(--text-2)] text-xs">
          Include host and port, e.g. <span className="font-mono text-[var(--text-3)]">http://localhost:3001</span>. Leave empty to use relative paths (default proxy).
        </p>
      </div>

      {saved && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Saved!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={handleClear} className="bg-[var(--bg-surface-3)] border border-[var(--border-2)] text-[var(--text-3)] hover:text-[var(--text-1)] rounded-lg py-2.5 text-sm transition-colors px-4">
          Reset
        </button>
        <button type="button" onClick={onClose} className="flex-1 bg-[var(--bg-surface-3)] border border-[var(--border-2)] text-[var(--text-2)] hover:text-[var(--text-1)] rounded-lg py-2.5 text-sm transition-colors">
          Cancel
        </button>
        <button type="submit" className="flex-1 bg-[var(--bg-surface-3)] hover:bg-[var(--bg-surface-2)] text-[var(--text-1)] font-semibold rounded-lg py-2.5 text-sm transition-colors">
          Save
        </button>
      </div>
    </form>
  );
}

export default function ApiKeyModal({ isOpen, onClose, openaiKeyPreview, onOpenAISaved, claudeStatus, onClaudeSaved }) {
  const [tab, setTab] = useState('openai');

  useEffect(() => {
    if (isOpen) setTab('openai');
  }, [isOpen]);

  if (!isOpen) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <div className="bg-[var(--bg-surface)] border border-[var(--border)] rounded-2xl w-full max-w-md mx-4 shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-5 border-b border-[var(--border)]">
          <div>
            <h2 className="text-[var(--text-1)] font-semibold text-base m-0">Settings</h2>
            <p className="text-[var(--text-3)] text-xs mt-0.5 m-0">Configure API credentials</p>
          </div>
          <button onClick={onClose} className="text-[var(--text-3)] hover:text-[var(--text-1)] transition-colors text-xl leading-none p-1">✕</button>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-[var(--border)]">
          <button
            onClick={() => setTab('openai')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'openai' ? 'text-[#00d4aa] border-b-2 border-[#00d4aa]' : 'text-[var(--text-3)] hover:text-[var(--text-1)]'}`}
          >
            OpenAI
          </button>
          <button
            onClick={() => setTab('claude')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'claude' ? 'text-[#c084fc] border-b-2 border-[#c084fc]' : 'text-[var(--text-3)] hover:text-[var(--text-1)]'}`}
          >
            Claude
          </button>
          <button
            onClick={() => setTab('aws')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'aws' ? 'text-[#f59e0b] border-b-2 border-[#f59e0b]' : 'text-[var(--text-3)] hover:text-[var(--text-1)]'}`}
          >
            AWS
          </button>
          <button
            onClick={() => setTab('connection')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'connection' ? 'text-[var(--text-1)] border-b-2 border-[var(--border-2)]' : 'text-[var(--text-3)] hover:text-[var(--text-1)]'}`}
          >
            Connection
          </button>
        </div>

        {tab === 'openai' && <OpenAITab keyPreview={openaiKeyPreview} onSaved={onOpenAISaved} onClose={onClose} />}
        {tab === 'claude' && <ClaudeTab status={claudeStatus} onSaved={onClaudeSaved} onClose={onClose} />}
        {tab === 'aws' && <AwsTab onClose={onClose} />}
        {tab === 'connection' && <ConnectionTab onClose={onClose} />}
      </div>
    </div>
  );
}
