const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(path.join(__dirname, '../../index.html'), 'utf8');
for (const match of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) new vm.Script(match[1]);
function extract(name) {
  const start = html.indexOf(`    function ${name}(`);
  assert.notEqual(start, -1, name);
  return html.slice(start, html.indexOf('\n    }', start) + 6);
}
const pending = { status: 'pending', reservedAt: 123, alertSound: 'classic', alertDurationSeconds: 15 };
let remote = { ...pending };
let transactionCount = 0;
const ctx = vm.createContext({
  console, window: {}, navigator: {}, clearInterval() {}, clearTimeout() {},
  reservationAlertRepeatTimer: null, reservationAlertStopTimer: null,
  entry: { key: 'bus-1', reservation: pending },
  db: { ref(key) {
    assert.equal(key, 'radar/reservations/bus-1');
    return { transaction(fn) {
      transactionCount++;
      const next = fn(remote);
      if (next) remote = next;
      return Promise.resolve({ committed: !!next });
    } };
  } },
  syncNativeReservationWatch() {}, showToast() {}, renderReservationSheet() {},
  buses: new Map([['bus-1', { id: 'bus-1' }]]),
  findReservationEntryForBus() { return ctx.entry; },
  localStorage: { setItem() {} },
  reservationNotificationModes: new Map(), reservationAlertPreferences: new Map(),
  defaultReservationNotificationMode: 'swipe',
  defaultReservationAlertPreference: { sound: 'classic', durationSeconds: 15 },
  RESERVATION_NOTIFICATION_MODES: { BANNER: 'banner', SWIPE: 'swipe' },
  RESERVATION_ALERT_SOUNDS: { CLASSIC: 'classic', GENTLE: 'gentle', URGENT: 'urgent' },
  RESERVATION_MODE_STORAGE_KEY: 'mode', RESERVATION_ALERT_STORAGE_KEY: 'sound'
});
const names = ['isActiveReservation', 'isTrackedReservation', 'updatePendingReservationAlert',
  'normalizeReservationNotificationMode', 'setReservationNotificationMode',
  'normalizeReservationAlertSound', 'normalizeReservationAlertDuration',
  'getReservationAlertPreference', 'setReservationAlertPreference', 'stopReservationAlertFeedback',
  'syncNativeReservationWatch', 'checkTriggeredReservations'];
vm.runInContext(names.map(extract).join('\n'), ctx);
vm.runInContext("setReservationNotificationMode('bus-1', 'banner'); setReservationAlertPreference('bus-1', {durationSeconds:30})", ctx);
assert.equal(remote.notificationMode, 'banner');
assert.equal(remote.alertDurationSeconds, 30);
assert.equal(remote.alertSound, 'classic');
vm.runInContext("setReservationAlertPreference('bus-1', {sound:'urgent'})", ctx);
assert.equal(remote.alertDurationSeconds, 30, 'Changing sound must preserve current duration');
assert.equal(remote.alertSound, 'urgent');
remote = { ...remote, status: 'triggered' };
vm.runInContext("setReservationAlertPreference('bus-1', {sound:'gentle'})", ctx);
assert.equal(remote.status, 'triggered', 'Settings must not revive completed reservation');
assert.equal(remote.alertSound, 'urgent', 'Transaction must reject a concurrently triggered reservation');
ctx.entry.reservation = { ...remote };
const count = transactionCount;
vm.runInContext("setReservationNotificationMode('bus-1', 'swipe'); setReservationAlertPreference('bus-1', {durationSeconds:5})", ctx);
assert.equal(transactionCount, count, 'Completed reservation edits only change next-reservation preferences');
assert.equal(ctx.defaultReservationAlertPreference.durationSeconds, 5);
assert.equal(vm.runInContext('isTrackedReservation(entry.reservation)', ctx), true);
const dismissed = [];
ctx.window.BumatiAndroid = { dismissReservationAlert: token => dismissed.push(token) };
ctx.activeNativeAlertToken = 'bus-1@123';
vm.runInContext('stopReservationAlertFeedback(); stopReservationAlertFeedback()', ctx);
assert.deepEqual(dismissed, ['bus-1@123']);
let starts = 0, stops = 0, banners = 0;
ctx.window.BumatiAndroid = {
  startReservationWatch() { starts++; }, stopReservationWatch() { stops++; }, isAlertDismissed: () => false
};
ctx.currentReservations = { 'bus-1': { ...remote } };
ctx.cancellingReservationKeys = new Set();
ctx.notifiedReservationKeys = new Set();
ctx.notifyMobileBell = () => {};
ctx.showBellAlert = ctx.showSwipeBellAlert = () => { banners++; };
vm.runInContext('syncNativeReservationWatch(); checkTriggeredReservations(); checkTriggeredReservations()', ctx);
assert.equal(starts, 1);
assert.equal(stops, 0, 'Triggered state must not stop Android playback service');
assert.equal(banners, 1);
ctx.currentReservations['bus-1'].reservedAt = 456;
vm.runInContext('checkTriggeredReservations()', ctx);
assert.equal(banners, 2, 'A second trip on the same bus gets its own alert');
ctx.currentReservations = {};
vm.runInContext('syncNativeReservationWatch()', ctx);
assert.equal(stops, 1);
console.log('PASS: JS syntax, editable pending/completed settings, race guard, native dismissal, watch lifecycle, repeat trips');
