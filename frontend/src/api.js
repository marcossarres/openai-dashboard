import axios from 'axios';

export function initApiBaseUrl() {
  const saved = localStorage.getItem('apiBaseUrl');
  if (saved) axios.defaults.baseURL = saved;
}

export function getApiBaseUrl() {
  return localStorage.getItem('apiBaseUrl') || '';
}

export function setApiBaseUrl(url) {
  const trimmed = url.trim().replace(/\/$/, '');
  if (trimmed) {
    const normalized = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
    localStorage.setItem('apiBaseUrl', normalized);
    axios.defaults.baseURL = normalized;
  } else {
    localStorage.removeItem('apiBaseUrl');
    delete axios.defaults.baseURL;
  }
}
