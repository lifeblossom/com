/**
 * Life Blossom Care and Cure Hospital — EMR System
 * Laboratory Technician Dashboard Controller
 *
 * Handles all views: Overview, Inbox, Lab Orders Queue,
 * Enter Results, My Results.
 */

import { requireAuth, signOut } from './auth.js';
import { supabase } from './supabase-client.js';
import {
  getInitials, formatRole, formatDate, calculateAge,
  getStatusBadgeClass, showToast, debounce, timeAgo,
  escapeHtml, formatTransferStatus, showLoading, showEmpty, showError,
} from './utils.js';
import {
  getMyInbox, countUnreadInbox, acknowledgeTransfer, updateTransferStatus,
} from './api/transfers-api.js';

// ─── State ────────────────────────────────────────────────────────────────────
let currentUser   = null; // Supabase auth user
let currentProfile = null; // profiles row
let currentView   = 'overview';
let inboxFilter   = 'active';
let orderFilter   = 'all';
let resultFilter  = 'all';

// Track lazy-load state
const loaded = {
  overview:      false,
  inbox:         false,
  orders:        false,
  'enter-results': false,
  'my-results':  false,
};

// ─── Helpers ──────────────────────────────────────────────────────────────────
function todayStart() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

// ─── Init ─────────────────────────────────────────────────────────────────────
async function init() {
  const profile = await requireAuth();
  if (!profile) { window.location.href = '../index.html'; return; }
  if (profile.role !== 'lab_technician') { window.location.href = '../index.html'; return; }

  const { data: { user } } = await supabase.auth.getUser();
  currentUser    = user;
  currentProfile = profile;

  initUI(profile);
  await Promise.all([loadOverview(), loadNotifications()]);
}

// ─── UI Bootstrap ─────────────────────────────────────────────────────────────
function initUI(profile) {
  const initials = getInitials(profile.full_name);

  ['sidebar-avatar', 'topbar-avatar'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = initials;
  });

  document.getElementById('sidebar-name').textContent   = profile.full_name;
  document.getElementById('sidebar-role').textContent   = formatRole(profile.role);
  document.getElementById('topbar-name').textContent    = profile.full_name;
  document.getElementById('dropdown-name').textContent  = profile.full_name;
  document.getElementById('dropdown-role').textContent  = formatRole(profile.role);

  // Sidebar toggle
  document.getElementById('sidebar-toggle').addEventListener('click', () => {
    document.getElementById('sidebar').classList.toggle('mobile-open');
    document.getElementById('sidebar-overlay').classList.toggle('visible');
  });
  document.getElementById('sidebar-overlay').addEventListener('click', () => {
    document.getElementById('sidebar').classList.remove('mobile-open');
    document.getElementById('sidebar-overlay').classList.remove('visible');
  });

  // Profile dropdown
  document.getElementById('profile-btn').addEventListener('click', () =>
    document.getElementById('profile-menu').classList.toggle('open'));
  document.addEventListener('click', e => {
    const menu = document.getElementById('profile-menu');
    if (menu && !menu.contains(e.target))
      menu.classList.remove('open');
  });

  // Sign out
  document.getElementById('sign-out-btn').addEventListener('click', handleSignOut);
  document.getElementById('dropdown-signout').addEventListener('click', handleSignOut);

  // Notification panel
  document.getElementById('notif-btn').addEventListener('click', () =>
    document.getElementById('notif-panel').classList.toggle('open'));
  document.getElementById('notif-close').addEventListener('click', () =>
    document.getElementById('notif-panel').classList.remove('open'));

  // Nav items
  document.querySelectorAll('.nav-item[data-view]').forEach(el => {
    el.addEventListener('click', e => {
      e.preventDefault();
      switchView(el.dataset.view);
    });
  });

  // Quick action buttons that carry a data-view attribute
  document.querySelectorAll('[data-view]:not(.nav-item)').forEach(el => {
    el.addEventListener('click', () => switchView(el.dataset.view));
  });

  // Inbox filter chips
  document.querySelectorAll('[data-inbox-filter]').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('[data-inbox-filter]').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      inboxFilter = chip.dataset.inboxFilter;
      loadInbox();
    });
  });

  // Order filter chips
  document.querySelectorAll('[data-order-filter]').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('[data-order-filter]').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      orderFilter = chip.dataset.orderFilter;
      loadOrders();
    });
  });

  // Result filter chips
  document.querySelectorAll('[data-result-filter]').forEach(chip => {
    chip.addEventListener('click', () => {
      document.querySelectorAll('[data-result-filter]').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      resultFilter = chip.dataset.resultFilter;
      loadMyResults();
    });
  });

  // Enter Results — search
  document.getElementById('results-search-btn').addEventListener('click', () => {
    const q = document.getElementById('results-order-search').value.trim();
    if (q) loadOrderForResults(q);
  });
  document.getElementById('results-order-search').addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      const q = e.target.value.trim();
      if (q) loadOrderForResults(q);
    }
  });

  // Patient panel modal close
  setupModalClose('patient-panel-overlay', 'patient-panel-close', 'patient-panel-dismiss');

  // Amend modal close
  setupModalClose('amend-modal-overlay', 'amend-modal-close', 'amend-modal-cancel');
  document.getElementById('amend-modal-confirm').addEventListener('click', confirmAmend);
}

function setupModalClose(overlayId, closeId, cancelId) {
  const close = () => {
    const el = document.getElementById(overlayId);
    if (el) el.classList.remove('active');
  };
  document.getElementById(closeId)?.addEventListener('click', close);
  document.getElementById(cancelId)?.addEventListener('click', close);
  document.getElementById(overlayId)?.addEventListener('click', e => {
    if (e.target === document.getElementById(overlayId)) close();
  });
}

async function handleSignOut() {
  await signOut();
  window.location.href = '../index.html';
}

// ─── View Switching ───────────────────────────────────────────────────────────
function switchView(view) {
  currentView = view;

  document.querySelectorAll('.view-section').forEach(s => s.style.display = 'none');
  document.querySelectorAll('.nav-item[data-view]').forEach(n => n.classList.remove('active'));

  const section = document.getElementById(`view-${view}`);
  if (section) section.style.display = 'block';

  const navItem = document.querySelector(`.nav-item[data-view="${view}"]`);
  if (navItem) navItem.classList.add('active');

  const titles = {
    overview:       'Overview',
    inbox:          'Inbox',
    orders:         'Lab Orders Queue',
    'enter-results':'Enter Results',
    'my-results':   'My Results',
  };
  const titleEl = document.getElementById('page-title');
  if (titleEl) titleEl.textContent = titles[view] || 'Laboratory';

  // Lazy-load on first visit (always reload inbox/orders/results for freshness)
  if (view === 'overview' && !loaded.overview) { loaded.overview = true; loadOverview(); }
  if (view === 'inbox')          { loaded.inbox = true;         loadInbox(); }
  if (view === 'orders')         { loaded.orders = true;        loadOrders(); }
  if (view === 'enter-results' && !loaded['enter-results']) {
    loaded['enter-results'] = true;
    const area = document.getElementById('results-entry-area');
    if (area) showEmpty(area, 'Search for an order by order number to begin entering results.', '🔍');
  }
  if (view === 'my-results')     { loaded['my-results'] = true; loadMyResults(); }
}

// ─── Notifications ────────────────────────────────────────────────────────────
async function loadNotifications() {
  const count = await countUnreadInbox();
  const badge     = document.getElementById('notif-count');
  const navBadge  = document.getElementById('inbox-nav-badge');

  const display = count > 0 ? 'flex' : 'none';
  if (badge) {
    badge.textContent = count > 99 ? '99+' : count;
    badge.style.display = display;
  }
  if (navBadge) {
    navBadge.textContent  = count > 99 ? '99+' : count;
    navBadge.style.display = count > 0 ? 'inline-flex' : 'none';
  }

  // Populate notification panel list
  const { data } = await getMyInbox('active');
  const list = document.getElementById('notif-list');
  if (!list) return;

  if (!data || data.length === 0) {
    list.innerHTML = '<div class="empty-state" style="padding:1rem">No new notifications</div>';
    return;
  }

  list.innerHTML = data.slice(0, 10).map(t => {
    const patient = t.patient || {};
    const name    = `${patient.first_name || ''} ${patient.last_name || ''}`.trim() || 'Unknown';
    return `
      <div class="notif-item" style="padding:.75rem 1rem;border-bottom:1px solid var(--border-color);cursor:pointer" data-transfer-id="${escapeHtml(t.id)}">
        <div style="font-weight:600;font-size:.85rem">${escapeHtml(name)}</div>
        <div style="font-size:.8rem;color:var(--text-muted)">${escapeHtml(t.sender?.full_name || '—')} · ${timeAgo(t.created_at)}</div>
      </div>
    `;
  }).join('');

  list.querySelectorAll('.notif-item').forEach(item => {
    item.addEventListener('click', () => {
      document.getElementById('notif-panel').classList.remove('open');
      const transfer = data.find(t => t.id === item.dataset.transferId);
      if (transfer) openPatientPanel(transfer.patient, transfer);
    });
  });
}

// ─── Overview ─────────────────────────────────────────────────────────────────
async function loadOverview() {
  // Stats
  const [pendingRes, inProgressRes, completedRes, draftsRes] = await Promise.all([
    supabase.from('laboratory_orders').select('id', { count: 'exact', head: true }).eq('status', 'pending'),
    supabase.from('laboratory_orders').select('id', { count: 'exact', head: true }).eq('status', 'in_progress'),
    supabase.from('laboratory_orders').select('id', { count: 'exact', head: true }).eq('status', 'completed').gte('updated_at', todayStart()),
    supabase.from('laboratory_results').select('id', { count: 'exact', head: true }).eq('status', 'draft').eq('performed_by', currentUser.id),
  ]);

  const setStatText = (id, val) => {
    const el = document.getElementById(id);
    if (el) el.textContent = val ?? 0;
  };

  setStatText('stat-pending',        pendingRes.count);
  setStatText('stat-inprogress',     inProgressRes.count);
  setStatText('stat-completed-today', completedRes.count);
  setStatText('stat-drafts',         draftsRes.count);

  // Recent orders
  const container = document.getElementById('overview-recent-orders');
  if (!container) return;
  showLoading(container, 'Loading recent orders…');

  const { data: orders, error } = await supabase
    .from('laboratory_orders')
    .select(`
      id, order_number, priority, status, created_at,
      patient:patients(first_name, last_name, hospital_number),
      laboratory_order_items(test_name, test_code),
      ordering_doctor:profiles(full_name)
    `)
    .order('created_at', { ascending: false })
    .limit(5);

  if (error) { showError(container, error.message); return; }
  if (!orders || orders.length === 0) { showEmpty(container, 'No recent lab orders.', '🧪'); return; }

  container.innerHTML = orders.map(o => renderOrderCard(o, true)).join('');
  bindOrderCardActions(container, orders);
}

// ─── Inbox ────────────────────────────────────────────────────────────────────
async function loadInbox() {
  const container = document.getElementById('inbox-list');
  if (!container) return;
  showLoading(container, 'Loading inbox…');

  const { data, error } = await getMyInbox(inboxFilter);
  if (error) { showError(container, error.message); return; }
  if (!data || data.length === 0) { showEmpty(container, 'No inbox items.'); return; }

  container.innerHTML = data.map(t => renderInboxItem(t)).join('');
  bindInboxItemActions(container, data);
}

function renderInboxItem(t) {
  const patient    = t.patient || {};
  const sender     = t.sender  || {};
  const name       = `${patient.first_name || ''} ${patient.last_name || ''}`.trim() || 'Unknown';
  const statusCls  = getStatusBadgeClass(t.status);

  return `
    <div class="list-item inbox-item" data-id="${escapeHtml(t.id)}" style="cursor:pointer">
      <div class="list-item-avatar">${getInitials(name)}</div>
      <div class="list-item-body">
        <div class="list-item-title">
          ${escapeHtml(name)}
          <span class="text-muted" style="font-weight:400"> · ${escapeHtml(patient.hospital_number || '')}</span>
        </div>
        <div class="list-item-meta">From: ${escapeHtml(sender.full_name || '—')}${sender.department ? ` (${escapeHtml(sender.department)})` : ''}</div>
        ${t.message ? `<div class="list-item-note">${escapeHtml(t.message)}</div>` : ''}
      </div>
      <div class="list-item-aside">
        <span class="badge ${statusCls}">${formatTransferStatus(t.status)}</span>
        <span class="text-muted" style="font-size:.75rem">${timeAgo(t.created_at)}</span>
        <div class="item-actions" style="margin-top:.4rem">
          ${t.status === 'sent'
            ? `<button class="btn btn-warning btn-xs ack-btn" data-id="${escapeHtml(t.id)}">Acknowledge</button>`
            : ''}
        </div>
      </div>
    </div>
  `;
}

function bindInboxItemActions(container, data) {
  container.querySelectorAll('.inbox-item').forEach(item => {
    item.addEventListener('click', e => {
      if (e.target.closest('.ack-btn')) return;
      const transfer = data.find(t => t.id === item.dataset.id);
      if (transfer) openPatientPanel(transfer.patient, transfer);
    });
  });

  container.querySelectorAll('.ack-btn').forEach(btn => {
    btn.addEventListener('click', async e => {
      e.stopPropagation();
      btn.disabled = true;
      const { error } = await acknowledgeTransfer(btn.dataset.id);
      if (error) { showToast(error.message, 'error'); btn.disabled = false; }
      else { showToast('Transfer acknowledged', 'success'); loadInbox(); loadNotifications(); }
    });
  });
}

// ─── Lab Orders Queue ─────────────────────────────────────────────────────────
async function loadOrders() {
  const container = document.getElementById('orders-list');
  if (!container) return;
  showLoading(container, 'Loading lab orders…');

  let query = supabase
    .from('laboratory_orders')
    .select(`
      id, order_number, priority, status, created_at, assigned_to,
      patient:patients(first_name, last_name, hospital_number),
      laboratory_order_items(id, test_name, test_code, status),
      ordering_doctor:profiles(full_name)
    `)
    .order('created_at', { ascending: false });

  if (orderFilter === 'assigned') {
    query = query.eq('assigned_to', currentUser.id);
  } else if (orderFilter !== 'all') {
    query = query.eq('status', orderFilter);
  }

  const { data: orders, error } = await query;
  if (error) { showError(container, error.message); return; }
  if (!orders || orders.length === 0) { showEmpty(container, 'No lab orders found.', '🧪'); return; }

  container.innerHTML = orders.map(o => renderOrderCard(o)).join('');
  bindOrderCardActions(container, orders);
}

function renderOrderCard(o, compact = false) {
  const patient = o.patient || {};
  const items   = o.laboratory_order_items || [];
  const doctor  = o.ordering_doctor || {};

  const priorityCls = o.priority === 'stat'   ? 'badge-danger'
                    : o.priority === 'urgent' ? 'badge-warning'
                    :                           'badge-info';
  const statusCls   = getStatusBadgeClass(o.status);

  const isAssignedToMe = o.assigned_to === currentUser?.id;
  const isPending      = o.status === 'pending';
  const isInProgress   = o.status === 'in_progress' && isAssignedToMe;

  return `
    <div class="list-item order-card" data-order-id="${escapeHtml(o.id)}">
      <div class="list-item-body">
        <div class="list-item-title">
          Order #${escapeHtml(o.order_number || o.id.slice(0, 8))} —
          ${escapeHtml(patient.first_name || '')} ${escapeHtml(patient.last_name || '')}
          <span class="badge ${priorityCls}" style="margin-left:.5rem">${escapeHtml((o.priority || 'routine').toUpperCase())}</span>
        </div>
        <div class="list-item-meta">
          HN: ${escapeHtml(patient.hospital_number || '—')} · ${formatDate(o.created_at, 'datetime')}
          ${doctor.full_name ? ` · Dr. ${escapeHtml(doctor.full_name)}` : ''}
        </div>
        <div style="margin-top:.35rem;font-size:.82rem">
          <strong>Tests:</strong>
          ${items.length ? items.map(i => `<span style="display:inline-block;margin:.1rem .25rem;padding:.1rem .45rem;border-radius:4px;background:var(--bg-secondary)">${escapeHtml(i.test_name)}${i.test_code ? ` (${escapeHtml(i.test_code)})` : ''}</span>`).join('') : '—'}
        </div>
      </div>
      <div class="list-item-aside">
        <span class="badge ${statusCls}">${escapeHtml(o.status || '')}</span>
        ${!compact ? `
          <div class="item-actions" style="margin-top:.5rem;display:flex;flex-direction:column;gap:.35rem">
            ${isPending
              ? `<button class="btn btn-primary btn-xs assign-me-btn" data-order-id="${escapeHtml(o.id)}">Assign to Me</button>`
              : ''}
            ${isInProgress
              ? `<button class="btn btn-success btn-xs enter-results-btn" data-order-id="${escapeHtml(o.id)}" data-order-number="${escapeHtml(o.order_number || '')}">Enter Results</button>`
              : ''}
          </div>
        ` : ''}
      </div>
    </div>
  `;
}

function bindOrderCardActions(container, orders) {
  container.querySelectorAll('.assign-me-btn').forEach(btn => {
    btn.addEventListener('click', async e => {
      e.stopPropagation();
      btn.disabled = true;
      btn.textContent = 'Assigning…';
      const { error } = await supabase
        .from('laboratory_orders')
        .update({ assigned_to: currentUser.id, status: 'in_progress' })
        .eq('id', btn.dataset.orderId);
      if (error) {
        showToast(error.message, 'error');
        btn.disabled = false;
        btn.textContent = 'Assign to Me';
      } else {
        showToast('Order assigned to you', 'success');
        loadOrders();
        loadOverview();
      }
    });
  });

  container.querySelectorAll('.enter-results-btn').forEach(btn => {
    btn.addEventListener('click', async e => {
      e.stopPropagation();
      const orderNum = btn.dataset.orderNumber || btn.dataset.orderId;
      switchView('enter-results');
      await loadOrderForResults(orderNum || btn.dataset.orderId);
    });
  });
}

// ─── Enter Results ────────────────────────────────────────────────────────────
async function loadOrderForResults(searchTerm) {
  const area = document.getElementById('results-entry-area');
  if (!area) return;
  showLoading(area, 'Searching for order…');

  // Search by order_number first, fallback to id prefix
  let { data: orders, error } = await supabase
    .from('laboratory_orders')
    .select(`
      id, order_number, priority, status, patient_id,
      patient:patients(id, first_name, last_name, hospital_number, date_of_birth, sex),
      laboratory_order_items(id, test_name, test_code, status)
    `)
    .ilike('order_number', `%${searchTerm}%`)
    .limit(5);

  if (error) { showError(area, error.message); return; }

  // If no results, try by id
  if (!orders || orders.length === 0) {
    const fallback = await supabase
      .from('laboratory_orders')
      .select(`
        id, order_number, priority, status, patient_id,
        patient:patients(id, first_name, last_name, hospital_number, date_of_birth, sex),
        laboratory_order_items(id, test_name, test_code, status)
      `)
      .eq('id', searchTerm)
      .limit(1);
    orders = fallback.data;
    error  = fallback.error;
  }

  if (error) { showError(area, error.message); return; }
  if (!orders || orders.length === 0) { showEmpty(area, `No order found matching "${escapeHtml(searchTerm)}".`, '🔍'); return; }

  // If multiple matches, show a picker
  if (orders.length > 1) {
    renderOrderPicker(area, orders);
    return;
  }

  renderResultsForm(area, orders[0]);
}

function renderOrderPicker(area, orders) {
  area.innerHTML = `
    <div style="padding:1rem">
      <p style="margin-bottom:.75rem">Multiple orders found. Select one:</p>
      <div>
        ${orders.map(o => {
          const p = o.patient || {};
          return `
            <div class="list-item" data-order-id="${escapeHtml(o.id)}" style="cursor:pointer;margin-bottom:.5rem">
              <div class="list-item-body">
                <div class="list-item-title">Order #${escapeHtml(o.order_number || o.id.slice(0, 8))}</div>
                <div class="list-item-meta">${escapeHtml(p.first_name || '')} ${escapeHtml(p.last_name || '')} · HN: ${escapeHtml(p.hospital_number || '—')}</div>
              </div>
              <div class="list-item-aside"><span class="badge ${getStatusBadgeClass(o.status)}">${escapeHtml(o.status)}</span></div>
            </div>
          `;
        }).join('')}
      </div>
    </div>
  `;
  area.querySelectorAll('[data-order-id]').forEach(item => {
    item.addEventListener('click', () => {
      const order = orders.find(o => o.id === item.dataset.orderId);
      if (order) renderResultsForm(area, order);
    });
  });
}

async function renderResultsForm(area, order) {
  const p = order.patient || {};
  const items = order.laboratory_order_items || [];

  // Fetch any existing draft results for this order
  const { data: existingResults } = await supabase
    .from('laboratory_results')
    .select('*')
    .eq('order_id', order.id)
    .eq('performed_by', currentUser.id);

  const resultsMap = {};
  (existingResults || []).forEach(r => { resultsMap[r.order_item_id] = r; });

  const patientName = `${p.first_name || ''} ${p.last_name || ''}`.trim() || 'Unknown';

  area.innerHTML = `
    <!-- Patient Info Header -->
    <div style="background:var(--bg-secondary,#f8fafc);border:1px solid var(--border-color);border-radius:10px;padding:1rem;margin-bottom:1.25rem">
      <div style="display:flex;align-items:center;gap:.75rem;margin-bottom:.5rem">
        <div class="list-item-avatar" style="width:42px;height:42px;font-size:1rem">${getInitials(patientName)}</div>
        <div>
          <div style="font-weight:700;font-size:1rem">${escapeHtml(patientName)}</div>
          <div style="font-size:.82rem;color:var(--text-muted)">
            HN: ${escapeHtml(p.hospital_number || '—')} ·
            ${p.date_of_birth ? calculateAge(p.date_of_birth) : '—'} ·
            ${escapeHtml(p.sex || '—')}
          </div>
        </div>
        <div style="margin-left:auto;text-align:right">
          <div style="font-size:.82rem;font-weight:600">Order #${escapeHtml(order.order_number || order.id.slice(0, 8))}</div>
          <span class="badge ${getStatusBadgeClass(order.status)}">${escapeHtml(order.status)}</span>
        </div>
      </div>
    </div>

    <!-- Results Entry Table -->
    <div id="results-items-table">
      ${items.length === 0
        ? '<div class="empty-state">No test items on this order.</div>'
        : items.map(item => {
          const existing = resultsMap[item.id] || {};
          return `
            <div class="result-entry-row" data-item-id="${escapeHtml(item.id)}" style="background:var(--bg-secondary,#f8fafc);border:1px solid var(--border-color);border-radius:8px;padding:.85rem;margin-bottom:.75rem">
              <div style="font-weight:600;margin-bottom:.6rem;font-size:.92rem">
                🧬 ${escapeHtml(item.test_name)}${item.test_code ? ` <span style="color:var(--text-muted);font-weight:400;font-size:.8rem">(${escapeHtml(item.test_code)})</span>` : ''}
              </div>
              <div style="display:grid;grid-template-columns:1fr 1fr 1fr auto;gap:.5rem;align-items:center">
                <div>
                  <label style="font-size:.75rem;color:var(--text-muted)">Result Value *</label>
                  <input type="text" class="form-control result-value" placeholder="e.g. 5.4" value="${escapeHtml(existing.result_value || '')}" />
                </div>
                <div>
                  <label style="font-size:.75rem;color:var(--text-muted)">Unit</label>
                  <input type="text" class="form-control result-unit" placeholder="e.g. mmol/L" value="${escapeHtml(existing.unit || '')}" />
                </div>
                <div>
                  <label style="font-size:.75rem;color:var(--text-muted)">Reference Range</label>
                  <input type="text" class="form-control result-ref-range" placeholder="e.g. 3.5–5.5" value="${escapeHtml(existing.reference_range || '')}" />
                </div>
                <div style="text-align:center">
                  <label style="font-size:.75rem;color:var(--text-muted);display:block">Abnormal</label>
                  <input type="checkbox" class="result-abnormal" style="width:18px;height:18px;margin-top:.3rem" ${existing.is_abnormal ? 'checked' : ''} />
                </div>
              </div>
            </div>
          `;
        }).join('')}
    </div>

    <!-- Action Buttons -->
    ${items.length > 0 ? `
      <div style="display:flex;gap:.75rem;margin-top:1rem">
        <button id="save-draft-btn" class="btn btn-ghost" data-order-id="${escapeHtml(order.id)}" data-patient-id="${escapeHtml(order.patient_id)}">💾 Save Draft</button>
        <button id="finalize-results-btn" class="btn btn-primary" data-order-id="${escapeHtml(order.id)}" data-patient-id="${escapeHtml(order.patient_id)}">✅ Finalize Results</button>
      </div>
    ` : ''}
  `;

  // Bind action buttons
  document.getElementById('save-draft-btn')?.addEventListener('click', () =>
    saveResults(order, items, 'draft'));
  document.getElementById('finalize-results-btn')?.addEventListener('click', () =>
    saveResults(order, items, 'finalized'));
}

function collectResultRows(items) {
  const rows = [];
  let valid = true;

  items.forEach(item => {
    const row = document.querySelector(`.result-entry-row[data-item-id="${CSS.escape(item.id)}"]`);
    if (!row) return;

    const value = row.querySelector('.result-value')?.value.trim();
    if (!value) { valid = false; return; }

    rows.push({
      order_item_id:   item.id,
      result_value:    value,
      unit:            row.querySelector('.result-unit')?.value.trim()      || null,
      reference_range: row.querySelector('.result-ref-range')?.value.trim() || null,
      is_abnormal:     row.querySelector('.result-abnormal')?.checked       || false,
    });
  });

  return { rows, valid };
}

async function saveResults(order, items, status) {
  const { rows, valid } = collectResultRows(items);
  if (!valid || rows.length === 0) {
    showToast('Please enter result values for all tests', 'warning');
    return;
  }

  const saveDraftBtn    = document.getElementById('save-draft-btn');
  const finalizeBtn     = document.getElementById('finalize-results-btn');
  if (saveDraftBtn)  saveDraftBtn.disabled  = true;
  if (finalizeBtn)   finalizeBtn.disabled   = true;

  const now = new Date().toISOString();

  const upsertPayload = rows.map(r => ({
    order_item_id:   r.order_item_id,
    order_id:        order.id,
    patient_id:      order.patient_id,
    result_value:    r.result_value,
    unit:            r.unit,
    reference_range: r.reference_range,
    is_abnormal:     r.is_abnormal,
    status,
    performed_by:    currentUser.id,
    performed_at:    now,
  }));

  const { error: upsertError } = await supabase
    .from('laboratory_results')
    .upsert(upsertPayload, { onConflict: 'order_item_id,performed_by' });

  if (upsertError) {
    showToast(upsertError.message, 'error');
    if (saveDraftBtn)  saveDraftBtn.disabled  = false;
    if (finalizeBtn)   finalizeBtn.disabled   = false;
    return;
  }

  if (status === 'finalized') {
    const { error: orderError } = await supabase
      .from('laboratory_orders')
      .update({ status: 'completed' })
      .eq('id', order.id);
    if (orderError) {
      showToast(`Results saved but order status update failed: ${orderError.message}`, 'warning');
    } else {
      showToast('Results finalized and order marked completed', 'success');
    }
  } else {
    showToast('Draft saved successfully', 'success');
  }

  if (saveDraftBtn)  saveDraftBtn.disabled  = false;
  if (finalizeBtn)   finalizeBtn.disabled   = false;

  // Reload after finalize to reflect new status
  if (status === 'finalized') {
    loaded['my-results'] = false;
    loaded.overview      = false;
    const area = document.getElementById('results-entry-area');
    if (area) showEmpty(area, 'Results finalized. Search for another order to continue.', '✅');
    document.getElementById('results-order-search').value = '';
  }
}

// ─── My Results ───────────────────────────────────────────────────────────────
async function loadMyResults() {
  const container = document.getElementById('my-results-list');
  if (!container) return;
  showLoading(container, 'Loading your results…');

  let query = supabase
    .from('laboratory_results')
    .select(`
      id, result_value, unit, reference_range, is_abnormal, status,
      performed_at, amendment_note,
      order_item:laboratory_order_items(test_name, test_code),
      patient:patients(first_name, last_name, hospital_number)
    `)
    .eq('performed_by', currentUser.id)
    .order('performed_at', { ascending: false });

  if (resultFilter !== 'all') query = query.eq('status', resultFilter);

  const { data, error } = await query;
  if (error) { showError(container, error.message); return; }
  if (!data || data.length === 0) { showEmpty(container, 'No results found.', '🧪'); return; }

  container.innerHTML = data.map(r => renderResultCard(r)).join('');

  // Bind amend buttons
  container.querySelectorAll('.amend-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const r = data.find(x => x.id === btn.dataset.resultId);
      if (r) openAmendModal(r);
    });
  });
}

function renderResultCard(r) {
  const patient    = r.patient   || {};
  const orderItem  = r.order_item || {};
  const statusCls  = getStatusBadgeClass(r.status);
  const patName    = `${patient.first_name || ''} ${patient.last_name || ''}`.trim() || 'Unknown';

  return `
    <div class="list-item result-card" data-result-id="${escapeHtml(r.id)}">
      <div class="list-item-body">
        <div class="list-item-title">
          🧬 ${escapeHtml(orderItem.test_name || '—')}
          ${orderItem.test_code ? `<span class="text-muted" style="font-weight:400;font-size:.82rem"> (${escapeHtml(orderItem.test_code)})</span>` : ''}
          ${r.is_abnormal ? `<span class="badge badge-danger" style="margin-left:.5rem">⚠ Abnormal</span>` : ''}
        </div>
        <div class="list-item-meta">
          ${escapeHtml(patName)} · HN: ${escapeHtml(patient.hospital_number || '—')}
        </div>
        <div style="margin-top:.4rem;font-size:.85rem">
          <strong>Result:</strong> ${escapeHtml(r.result_value || '—')} ${escapeHtml(r.unit || '')}
          ${r.reference_range ? `<span class="text-muted"> (Ref: ${escapeHtml(r.reference_range)})</span>` : ''}
        </div>
        ${r.amendment_note ? `<div class="list-item-note" style="margin-top:.3rem">📝 Amendment note: ${escapeHtml(r.amendment_note)}</div>` : ''}
        <div class="list-item-meta" style="margin-top:.3rem">${r.performed_at ? formatDate(r.performed_at, 'datetime') : '—'}</div>
      </div>
      <div class="list-item-aside">
        <span class="badge ${statusCls}">${escapeHtml(r.status || '')}</span>
        ${r.status === 'finalized'
          ? `<button class="btn btn-ghost btn-xs amend-btn" data-result-id="${escapeHtml(r.id)}" style="margin-top:.5rem">✏️ Amend</button>`
          : ''}
      </div>
    </div>
  `;
}

// ─── Amend Modal ──────────────────────────────────────────────────────────────
let amendTargetId = null;

function openAmendModal(result) {
  amendTargetId = result.id;

  const setVal = (id, val) => {
    const el = document.getElementById(id);
    if (el) {
      if (el.type === 'checkbox') el.checked = Boolean(val);
      else el.value = val || '';
    }
  };

  setVal('amend-result-id',       result.id);
  setVal('amend-result-value',    result.result_value);
  setVal('amend-result-unit',     result.unit);
  setVal('amend-reference-range', result.reference_range);
  setVal('amend-is-abnormal',     result.is_abnormal);
  setVal('amend-note',            '');

  document.getElementById('amend-modal-overlay').classList.add('active');
}

async function confirmAmend() {
  if (!amendTargetId) return;

  const getValue = id => {
    const el = document.getElementById(id);
    return el ? (el.type === 'checkbox' ? el.checked : el.value.trim()) : null;
  };

  const note = getValue('amend-note');
  if (!note) { showToast('Please enter an amendment note explaining the change', 'warning'); return; }

  const btn = document.getElementById('amend-modal-confirm');
  btn.disabled = true;
  btn.textContent = 'Saving…';

  const { error } = await supabase
    .from('laboratory_results')
    .update({
      result_value:    getValue('amend-result-value')    || null,
      unit:            getValue('amend-result-unit')      || null,
      reference_range: getValue('amend-reference-range') || null,
      is_abnormal:     getValue('amend-is-abnormal'),
      status:          'amended',
      amendment_note:  note,
      performed_at:    new Date().toISOString(),
    })
    .eq('id', amendTargetId);

  btn.disabled = false;
  btn.textContent = 'Confirm Amendment';

  if (error) { showToast(error.message, 'error'); return; }

  showToast('Result amended successfully', 'success');
  document.getElementById('amend-modal-overlay').classList.remove('active');
  amendTargetId = null;
  loadMyResults();
  loadOverview();
}

// ─── Patient Panel Modal ──────────────────────────────────────────────────────
async function openPatientPanel(patient, transfer) {
  if (!patient) return;

  const overlay  = document.getElementById('patient-panel-overlay');
  const content  = document.getElementById('patient-panel-content');
  if (!overlay || !content) return;

  overlay.classList.add('active');
  showLoading(content, 'Loading patient info…');

  const name = `${patient.first_name || ''} ${patient.last_name || ''}`.trim() || 'Unknown';

  // Fetch pending lab orders for this patient
  const { data: labOrders, error: labError } = await supabase
    .from('laboratory_orders')
    .select(`
      id, order_number, priority, status, created_at,
      laboratory_order_items(test_name, test_code)
    `)
    .eq('patient_id', patient.id)
    .in('status', ['pending', 'in_progress'])
    .order('created_at', { ascending: false });

  content.innerHTML = `
    <!-- Patient Demographics -->
    <div style="display:flex;align-items:center;gap:.75rem;margin-bottom:1rem;padding-bottom:1rem;border-bottom:1px solid var(--border-color)">
      <div class="list-item-avatar" style="width:50px;height:50px;font-size:1.1rem">${getInitials(name)}</div>
      <div>
        <div style="font-weight:700;font-size:1.05rem">${escapeHtml(name)}</div>
        <div style="font-size:.83rem;color:var(--text-muted)">
          HN: ${escapeHtml(patient.hospital_number || '—')}
          ${patient.date_of_birth ? ` · ${calculateAge(patient.date_of_birth)}` : ''}
          ${patient.sex ? ` · ${escapeHtml(patient.sex)}` : ''}
        </div>
        ${patient.phone   ? `<div style="font-size:.82rem">📞 ${escapeHtml(patient.phone)}</div>` : ''}
        ${patient.address ? `<div style="font-size:.82rem">📍 ${escapeHtml(patient.address)}</div>` : ''}
      </div>
    </div>

    <!-- Transfer Info -->
    ${transfer ? `
      <div style="background:var(--bg-secondary,#f8fafc);border-radius:8px;padding:.75rem;margin-bottom:1rem;font-size:.84rem">
        <div style="font-weight:600;margin-bottom:.3rem">Transfer Info</div>
        <div>From: <strong>${escapeHtml(transfer.sender?.full_name || '—')}</strong>${transfer.sender?.department ? ` (${escapeHtml(transfer.sender.department)})` : ''}</div>
        <div>Status: <span class="badge ${getStatusBadgeClass(transfer.status)}">${formatTransferStatus(transfer.status)}</span></div>
        ${transfer.message ? `<div style="margin-top:.35rem;color:var(--text-muted)">"${escapeHtml(transfer.message)}"</div>` : ''}
        <div style="color:var(--text-muted);margin-top:.3rem">${timeAgo(transfer.created_at)}</div>
      </div>
    ` : ''}

    <!-- Pending Lab Orders -->
    <div>
      <div style="font-weight:600;margin-bottom:.6rem">Pending / In-Progress Lab Orders</div>
      ${labError ? `<div class="error-state" style="font-size:.83rem">${escapeHtml(labError.message)}</div>` :
        (!labOrders || labOrders.length === 0)
          ? '<div class="empty-state" style="font-size:.83rem">No pending lab orders for this patient.</div>'
          : labOrders.map(o => {
              const its = o.laboratory_order_items || [];
              return `
                <div style="border:1px solid var(--border-color);border-radius:8px;padding:.65rem;margin-bottom:.5rem">
                  <div style="font-weight:600;font-size:.88rem">
                    Order #${escapeHtml(o.order_number || o.id.slice(0, 8))}
                    <span class="badge badge-${o.priority === 'stat' ? 'danger' : o.priority === 'urgent' ? 'warning' : 'info'}" style="margin-left:.4rem">${escapeHtml((o.priority || 'routine').toUpperCase())}</span>
                    <span class="badge ${getStatusBadgeClass(o.status)}" style="margin-left:.3rem">${escapeHtml(o.status)}</span>
                  </div>
                  <div style="font-size:.8rem;color:var(--text-muted);margin-top:.25rem">
                    ${formatDate(o.created_at, 'datetime')}
                  </div>
                  <div style="font-size:.81rem;margin-top:.3rem">
                    ${its.length ? its.map(i => `<span style="display:inline-block;margin:.1rem .2rem;padding:.1rem .4rem;border-radius:4px;background:var(--bg-secondary)">${escapeHtml(i.test_name)}</span>`).join('') : '—'}
                  </div>
                </div>
              `;
            }).join('')
      }
    </div>
  `;
}

// ─── Bootstrap ────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', init);
