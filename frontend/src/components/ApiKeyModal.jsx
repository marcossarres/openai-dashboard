import { useState, useEffect } from 'react';
import axios from 'axios';

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
      const res = await axios.post('/api/config/key', { key: key.trim() });
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
      <div className="bg-[#1a1a1a] border border-[#262626] rounded-lg px-4 py-3 text-sm flex items-center justify-between">
        <span className="text-[#555]">Current key</span>
        <span className="text-gray-400 font-mono text-xs">
          {keyPreview || <span className="text-red-500">Not set</span>}
        </span>
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[#666] font-medium uppercase tracking-wider">New API Key</label>
        <div className="relative">
          <input
            type={show ? 'text' : 'password'}
            value={key}
            onChange={(e) => setKey(e.target.value)}
            placeholder="sk-admin-..."
            className="w-full bg-[#111] border border-[#333] focus:border-[#00d4aa] rounded-lg px-4 py-2.5 text-sm text-gray-200 font-mono outline-none transition-colors pr-16"
            autoFocus
          />
          <button
            type="button"
            onClick={() => setShow((s) => !s)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-[#555] hover:text-gray-300 text-xs transition-colors"
          >
            {show ? 'Hide' : 'Show'}
          </button>
        </div>
        <p className="text-[#444] text-xs">
          Requires an Admin key (<span className="font-mono text-[#555]">sk-admin-...</span>).
          Generate one at platform.openai.com/api-keys.
        </p>
      </div>

      {error && <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-2.5 text-red-400 text-sm">{error}</div>}
      {success && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Key saved successfully!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={onClose} className="flex-1 bg-[#1c1c1c] border border-[#333] text-gray-400 hover:text-gray-200 rounded-lg py-2.5 text-sm transition-colors">
          Cancel
        </button>
        <button type="submit" disabled={saving || !key.trim()} className="flex-1 bg-gradient-to-r from-[#00d4aa] to-[#00a882] text-[#0f0f0f] font-semibold rounded-lg py-2.5 text-sm disabled:opacity-50 disabled:cursor-not-allowed transition-opacity hover:opacity-90">
          {saving ? 'Saving…' : 'Save Key'}
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
    axios.get('/api/aws/config/status').then((res) => {
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
      const res = await axios.post('/api/aws/config/credentials', {
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
        <div className="bg-[#1a1a1a] border border-[#262626] rounded-lg px-4 py-3 text-sm flex items-center justify-between">
          <span className="text-[#555]">Current credentials</span>
          <span className="text-gray-400 font-mono text-xs">
            {status.hasCredentials
              ? <><span className="text-[#00d4aa]">{status.accessKeyPreview}</span> <span className="text-[#555]">({status.region})</span></>
              : <span className="text-[#888]">Using aws-cloudy profile</span>}
          </span>
        </div>
      )}

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[#666] font-medium uppercase tracking-wider">Access Key ID</label>
        <input
          type="text"
          value={accessKeyId}
          onChange={(e) => setAccessKeyId(e.target.value)}
          placeholder="AKIA..."
          className="w-full bg-[#111] border border-[#333] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-gray-200 font-mono outline-none transition-colors"
          autoFocus
        />
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[#666] font-medium uppercase tracking-wider">Secret Access Key</label>
        <div className="relative">
          <input
            type={showSecret ? 'text' : 'password'}
            value={secretAccessKey}
            onChange={(e) => setSecretAccessKey(e.target.value)}
            placeholder="••••••••••••••••••••••••••••••••••••••••"
            className="w-full bg-[#111] border border-[#333] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-gray-200 font-mono outline-none transition-colors pr-16"
          />
          <button
            type="button"
            onClick={() => setShowSecret((s) => !s)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-[#555] hover:text-gray-300 text-xs transition-colors"
          >
            {showSecret ? 'Hide' : 'Show'}
          </button>
        </div>
      </div>

      <div className="flex flex-col gap-1.5">
        <label className="text-xs text-[#666] font-medium uppercase tracking-wider">Region</label>
        <input
          type="text"
          value={region}
          onChange={(e) => setRegion(e.target.value)}
          placeholder="us-east-1"
          className="w-full bg-[#111] border border-[#333] focus:border-[#f59e0b] rounded-lg px-4 py-2.5 text-sm text-gray-200 font-mono outline-none transition-colors"
        />
        <p className="text-[#444] text-xs">
          Leave blank to use the <span className="font-mono text-[#555]">aws-cloudy</span> profile from ~/.aws/credentials.
        </p>
      </div>

      {error && <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-2.5 text-red-400 text-sm">{error}</div>}
      {success && <div className="bg-emerald-950 border border-emerald-800 rounded-lg px-4 py-2.5 text-emerald-400 text-sm">Credentials saved successfully!</div>}

      <div className="flex gap-3 pt-1">
        <button type="button" onClick={onClose} className="flex-1 bg-[#1c1c1c] border border-[#333] text-gray-400 hover:text-gray-200 rounded-lg py-2.5 text-sm transition-colors">
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

export default function ApiKeyModal({ isOpen, onClose, keyPreview, onSaved }) {
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
      <div className="bg-[#161616] border border-[#2a2a2a] rounded-2xl w-full max-w-md mx-4 shadow-2xl">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-5 border-b border-[#222]">
          <div>
            <h2 className="text-white font-semibold text-base m-0">Settings</h2>
            <p className="text-[#555] text-xs mt-0.5 m-0">Configure API credentials</p>
          </div>
          <button onClick={onClose} className="text-[#555] hover:text-gray-300 transition-colors text-xl leading-none p-1">✕</button>
        </div>

        {/* Tabs */}
        <div className="flex border-b border-[#222]">
          <button
            onClick={() => setTab('openai')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'openai' ? 'text-[#00d4aa] border-b-2 border-[#00d4aa]' : 'text-[#555] hover:text-gray-300'}`}
          >
            OpenAI
          </button>
          <button
            onClick={() => setTab('aws')}
            className={`flex-1 py-3 text-sm font-medium transition-colors ${tab === 'aws' ? 'text-[#f59e0b] border-b-2 border-[#f59e0b]' : 'text-[#555] hover:text-gray-300'}`}
          >
            AWS
          </button>
        </div>

        {tab === 'openai'
          ? <OpenAITab keyPreview={keyPreview} onSaved={onSaved} onClose={onClose} />
          : <AwsTab onClose={onClose} />
        }
      </div>
    </div>
  );
}
