import axios from 'axios';

export const apiClient = axios.create();

function applyBaseUrl(url) {
  if (url) {
    apiClient.defaults.baseURL = url;
  } else if (apiClient.defaults.baseURL) {
    delete apiClient.defaults.baseURL;
  }
}

export function initApiBaseUrl() {
  try {
    const saved = localStorage.getItem('apiBaseUrl');
    if (saved) applyBaseUrl(saved);
  } catch {
    // localStorage not available (SSR/tests) → ignore
  }
}

export function getApiBaseUrl() {
  try {
    return localStorage.getItem('apiBaseUrl') || '';
  } catch {
    return '';
  }
}

export function setApiBaseUrl(url) {
  const trimmed = url.trim().replace(/\/$/, '');
  if (trimmed) {
    const normalized = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
    localStorage.setItem('apiBaseUrl', normalized);
    applyBaseUrl(normalized);
  } else {
    localStorage.removeItem('apiBaseUrl');
    applyBaseUrl('');
  }
}
