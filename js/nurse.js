/**
 * Nurse dashboard for assigned patient access and recording vitals.
 */

import { requireAuth, signOut } from './auth.js';
import { getInitials, formatDate, formatRole, showToast, debounce, escapeHtml } from './utils.js';
import { searchPatients } from './api/patients-api.js';
import { getMyInbox } from './api/transfers-api.js';
import { getPatientVitals, recordVitals } from './api/clinical-api.js';
import { supabase } from './supabase-client.js';

let selectedPatient = null;
let selectedEncounterId = null;

async function init() {
  const profile = await requireAuth();
  if (!profile) {
    window.location.href = '../index.html';
    return;
  }
  if (profile.role !== 'nurse') {
    window.location.href = '../index.html';
    return;
  }

  const initials = getInitials(profile.full_name);
  document.getElementById('sidebar-avatar').textContent = initials;
  document.getElementById('topbar-avatar').textContent = initials;
  document.getElementById('sidebar-name').textContent = profile.full_name;
  document.getElementById('sidebar-role').textContent = formatRole(profile.role);
  document.getElementById('topbar-name').textContent = profile.full_name;
  document.getElementById('dropdown-name').textContent = profile.full_name;
  document.getElementById('dropdown-role').textContent = formatRole(profile.role);

  document.querySelectorAll('.nav-item[data-view], .quick-action-btn[data-view]').forEach(button => {
    button.addEventListener('click', () => switchView(button.dataset.view));
  });
  document.getElementById('sidebar-toggle').addEventListener('click', () => {
    document.getElementById('sidebar').classList.toggle('mobile-open');
    document.getElementById('sidebar-overlay').classList.toggle('visible');
  });
  document.getElementById('sidebar-overlay').addEventListener('click', () => {
    document.getElementById('sidebar').classList.remove('mobile-open');
    document.getElementById('sidebar-overlay').classList.remove('visible');
  });
  document.getElementById('profile-btn').addEventListener('click', () => {
    document.getElementById('profile-menu').classList.toggle('open');
  });
  document.getElementById('sign-out-btn').addEventListener('click', handleSignOut);
  document.getElementById('dropdown-signout').addEventListener('click', handleSignOut);
  document.getElementById('patient-search').addEventListener('input', debounce(event => {
    loadPatients(event.target.value.trim());
  }, 350));
  document.getElementById('vitals-form').addEventListener('submit', saveVitals);
  await loadInbox();
}

function switchView(view) {
  document.querySelectorAll('.view-section').forEach(section => {
    section.style.display = section.id === `view-${view}` ? 'block' : 'none';
  });
  document.querySelectorAll('.nav-item[data-view]').forEach(button => {
    button.classList.toggle('active', button.dataset.view === view);
  });
  const titles = { overview: 'Nurse Dashboard', inbox: 'Patient Transfers', patients: 'Accessible Patients', vitals: 'Patient Vitals' };
  document.getElementById('page-title').textContent = titles[view] || 'Nurse Dashboard';
  document.getElementById('sidebar').classList.remove('mobile-open');
  document.getElementById('sidebar-overlay').classList.remove('visible');
  if (view === 'inbox') loadInbox();
  if (view === 'patients') loadPatients(document.getElementById('patient-search').value.trim());
}

async function handleSignOut() {
  await signOut();
  window.location.href = '../index.html';
}

async function loadInbox() {
  const { data, error } = await getMyInbox('active');
  const inbox = document.getElementById('inbox-list');
  const overview = document.getElementById('overview-inbox');
  if (error) {
    inbox.innerHTML = `<div class="error-state">${escapeHtml(error.message)}</div>`;
    overview.innerHTML = `<div class="error-state">${escapeHtml(error.message)}</div>`;
    return;
  }

  const items = data || [];
  const badge = document.getElementById('inbox-badge');
  badge.textContent = String(items.length);
  badge.style.display = items.length ? '' : 'none';
  const html = items.length ? items.map(transfer => {
    const patient = transfer.patient;
    const patientName = `${patient?.first_name || ''} ${patient?.middle_name ? `${patient.middle_name} ` : ''}${patient?.last_name || ''}`.trim();
    return `
      <div class="list-item">
        <div class="list-item-body">
          <div class="list-item-title">${escapeHtml(patientName || 'Patient')} · ${escapeHtml(patient?.hospital_number || '—')}</div>
          <div class="list-item-meta">From ${escapeHtml(transfer.sender?.full_name || 'staff')} · ${escapeHtml(transfer.status)} · ${formatDate(transfer.created_at, 'datetime')}</div>
          ${transfer.message ? `<div class="list-item-note">${escapeHtml(transfer.message)}</div>` : ''}
        </div>
        <div class="list-item-aside"><button class="btn btn-primary btn-sm open-patient-btn" data-transfer-id="${escapeHtml(transfer.id)}">Open patient</button></div>
      </div>`;
  }).join('') : '<div class="empty-state">No active patient transfers.</div>';

  inbox.innerHTML = html;
  overview.innerHTML = html;
  [inbox, overview].forEach(container => container.querySelectorAll('.open-patient-btn').forEach(button => {
    button.addEventListener('click', () => {
      const transfer = items.find(item => item.id === button.dataset.transferId);
      if (transfer?.patient) selectPatient(transfer.patient, transfer.encounter_id);
    });
  }));
}

async function loadPatients(query) {
  const container = document.getElementById('patients-list');
  container.innerHTML = '<div class="loading-state">Loading authorized patient records...</div>';
  const { data, error } = await searchPatients(query);
  if (error) {
    container.innerHTML = `<div class="error-state">${escapeHtml(error.message)}</div>`;
    return;
  }
  if (!data?.length) {
    container.innerHTML = '<div class="empty-state">No accessible patients found. Open a patient from an assigned transfer.</div>';
    return;
  }
  container.innerHTML = data.map(patient => `
    <div class="list-item">
      <div class="list-item-body">
        <div class="list-item-title">${escapeHtml(`${patient.first_name} ${patient.last_name}`)}</div>
        <div class="list-item-meta">${escapeHtml(patient.hospital_number)} · ${escapeHtml(patient.sex || '—')}</div>
      </div>
      <div class="list-item-aside"><button class="btn btn-primary btn-sm select-patient-btn" data-patient-id="${escapeHtml(patient.id)}">Select</button></div>
    </div>`).join('');
  container.querySelectorAll('.select-patient-btn').forEach(button => {
    button.addEventListener('click', () => {
      const patient = data.find(item => item.id === button.dataset.patientId);
      if (patient) selectPatient(patient, null);
    });
  });
}

function selectPatient(patient, encounterId) {
  selectedPatient = patient;
  selectedEncounterId = encounterId || null;
  const name = `${patient.first_name || ''} ${patient.middle_name ? `${patient.middle_name} ` : ''}${patient.last_name || ''}`.trim();
  document.getElementById('selected-patient').textContent = `${name} · ${patient.hospital_number || '—'}`;
  switchView('vitals');
  loadRecentVitals();
}

async function loadRecentVitals() {
  const container = document.getElementById('recent-vitals');
  if (!selectedPatient) {
    container.innerHTML = '<div class="empty-state">Select a patient to view measurements.</div>';
    return;
  }
  container.innerHTML = '<div class="loading-state">Loading measurements...</div>';
  const { data, error } = await getPatientVitals(selectedPatient.id, selectedEncounterId);
  if (error) {
    container.innerHTML = `<div class="error-state">${escapeHtml(error.message)}</div>`;
    return;
  }
  if (!data?.length) {
    container.innerHTML = '<div class="empty-state">No measurements recorded for this encounter.</div>';
    return;
  }
  container.innerHTML = data.slice(0, 10).map(vital => `
    <div class="list-item">
      <div class="list-item-body">
        <div class="list-item-title">${vital.bp_systolic && vital.bp_diastolic ? `${vital.bp_systolic}/${vital.bp_diastolic} mmHg · ` : ''}${vital.pulse_rate ? `${vital.pulse_rate} bpm · ` : ''}${vital.temperature ? `${vital.temperature} °C` : 'Vitals'}</div>
        <div class="list-item-meta">${formatDate(vital.created_at, 'datetime')} · ${escapeHtml(vital.recorded_by_profile?.full_name || 'Staff')}</div>
        ${vital.notes ? `<div class="list-item-note">${escapeHtml(vital.notes)}</div>` : ''}
      </div>
    </div>`).join('');
}

function numericValue(id) {
  const value = document.getElementById(id).value;
  return value === '' ? null : Number(value);
}

async function saveVitals(event) {
  event.preventDefault();
  if (!selectedPatient) {
    showToast('Select a patient before recording vitals.', 'warning');
    return;
  }
  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) {
    showToast(userError?.message || 'Your session has expired. Sign in again.', 'error');
    return;
  }

  const payload = {
    patient_id: selectedPatient.id,
    encounter_id: selectedEncounterId,
    recorded_by: user.id,
    bp_systolic: numericValue('nurse-bp-systolic'),
    bp_diastolic: numericValue('nurse-bp-diastolic'),
    pulse_rate: numericValue('nurse-pulse'),
    respiratory_rate: numericValue('nurse-resp'),
    temperature: numericValue('nurse-temp'),
    oxygen_saturation: numericValue('nurse-spo2'),
    weight: numericValue('nurse-weight'),
    height: numericValue('nurse-height'),
    blood_glucose: numericValue('nurse-glucose'),
    pain_score: numericValue('nurse-pain'),
    notes: document.getElementById('nurse-vitals-notes').value.trim() || null,
  };
  const measured = Object.entries(payload).some(([key, value]) =>
    !['patient_id', 'encounter_id', 'recorded_by', 'notes'].includes(key) && value !== null
  );
  if (!measured) {
    showToast('Enter at least one measurement.', 'warning');
    return;
  }

  const button = document.getElementById('save-vitals-btn');
  button.disabled = true;
  try {
    const { error } = await recordVitals(payload);
    if (error) {
      showToast(error.message, 'error');
      return;
    }
    document.getElementById('vitals-form').reset();
    showToast('Vitals recorded.', 'success');
    loadRecentVitals();
  } catch (err) {
    console.error('Recording patient vitals failed:', err);
    showToast('Unable to record vitals. Please try again.', 'error');
  } finally {
    button.disabled = false;
  }
}

document.addEventListener('DOMContentLoaded', init);
