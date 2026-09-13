const BOMATI_MISSED_STOP_CONFIG = Object.freeze({
  firebaseRootUrl: 'https://bumati-default-rtdb.asia-southeast1.firebasedatabase.app/operations/missedStops',
  sheetName: '무정차 기록',
  settingsSheetName: '회사 설정',
  syncHandlerName: 'syncMissedStopLogs'
});

const BOMATI_MISSED_STOP_HEADERS = Object.freeze([
  '사건 ID',
  '발생 시각',
  '회사명',
  '회사 식별 아이디',
  '노선',
  '차량명',
  '차량 ID',
  '차종',
  '기사 Roblox 사용자명',
  '기사 표시명',
  '기사 UserId',
  '운전석 이름',
  '정류장명',
  '정류장 고유번호',
  '노선 정류장 순번',
  '하차벨 종류',
  '벨 입력자',
  '벨 작동 사유',
  '벨 작동 시각',
  '정류장 최소거리 (studs)',
  '통과속도 (studs/s)',
  '관찰시간 (초)',
  '버스 X',
  '버스 Y',
  '버스 Z',
  '서버 세션',
  'PlaceId',
  'PlaceVersion',
  '검토상태',
  '조치내용',
  '담당자',
  '시트 기록 시각'
]);

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('BOMATI')
    .addItem('회사 설정 시트 준비', 'prepareCompanySheet')
    .addItem('회사 식별 아이디 생성', 'generateCompanyIdentifier')
    .addSeparator()
    .addItem('무정차 기록 연동 시작', 'setupMissedStopLogging')
    .addItem('지금 기록 가져오기', 'syncMissedStopLogs')
    .addItem('연동 테스트 기록 생성', 'createConnectionTestRecord')
    .addToUi();
}

function prepareCompanySheet() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error('연동할 Google Sheet를 연 상태에서 실행해야 합니다.');
  }

  PropertiesService.getScriptProperties().setProperty('BOMATI_SPREADSHEET_ID', spreadsheet.getId());
  const logSheet = ensureMissedStopSheet_(spreadsheet);
  const settingsSheet = ensureCompanySettingsSheet_(spreadsheet);
  arrangeCompanySheets_(spreadsheet, logSheet, settingsSheet);
  spreadsheet.setActiveSheet(settingsSheet);
  spreadsheet.toast('두 번째 탭에 회사명을 입력한 뒤 BOMATI 메뉴에서 식별 아이디를 생성하세요.', 'BOMATI', 8);
}

function generateCompanyIdentifier() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error('연동할 Google Sheet를 연 상태에서 실행해야 합니다.');
  }

  PropertiesService.getScriptProperties().setProperty('BOMATI_SPREADSHEET_ID', spreadsheet.getId());
  const logSheet = ensureMissedStopSheet_(spreadsheet);
  const settingsSheet = ensureCompanySettingsSheet_(spreadsheet);
  arrangeCompanySheets_(spreadsheet, logSheet, settingsSheet);

  const companyName = String(settingsSheet.getRange('B3').getDisplayValue() || '').trim();
  if (!companyName) {
    spreadsheet.setActiveSheet(settingsSheet);
    SpreadsheetApp.getUi().alert('회사 설정', '두 번째 탭의 B3 셀에 회사명을 먼저 입력해 주세요.', SpreadsheetApp.getUi().ButtonSet.OK);
    return;
  }

  const currentId = String(settingsSheet.getRange('B4').getDisplayValue() || '').trim();
  if (currentId) {
    const response = SpreadsheetApp.getUi().alert(
      '회사 식별 아이디 재생성',
      '식별 아이디를 바꾸면 기존 아이디로 기록된 사건은 이 시트에 더 이상 들어오지 않습니다. 새로 생성할까요?',
      SpreadsheetApp.getUi().ButtonSet.YES_NO
    );
    if (response !== SpreadsheetApp.getUi().Button.YES) {
      return;
    }
  }

  const companyId = `company_${Utilities.getUuid().replace(/-/g, '').toLowerCase()}`;
  settingsSheet.getRange('B4').setValue(companyId).setNumberFormat('@');
  settingsSheet.getRange('B8').setFormula('=B4').setNumberFormat('@');
  spreadsheet.setActiveSheet(settingsSheet);
  spreadsheet.toast('회사 식별 아이디를 생성했습니다. B3/B4 값을 각 Bus Model 속성에 복사하세요.', 'BOMATI', 8);
}

function setupMissedStopLogging() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error('연동할 Google Sheet를 연 상태에서 실행해야 합니다.');
  }

  PropertiesService.getScriptProperties().setProperty('BOMATI_SPREADSHEET_ID', spreadsheet.getId());
  const logSheet = ensureMissedStopSheet_(spreadsheet);
  const settingsSheet = ensureCompanySettingsSheet_(spreadsheet);
  arrangeCompanySheets_(spreadsheet, logSheet, settingsSheet);
  getCompanyConfig_(settingsSheet);

  ScriptApp.getProjectTriggers().forEach((trigger) => {
    if (trigger.getHandlerFunction() === BOMATI_MISSED_STOP_CONFIG.syncHandlerName) {
      ScriptApp.deleteTrigger(trigger);
    }
  });
  ScriptApp.newTrigger(BOMATI_MISSED_STOP_CONFIG.syncHandlerName)
    .timeBased()
    .everyMinutes(1)
    .create();

  syncMissedStopLogs();
  spreadsheet.toast('Firebase 무정차 기록을 1분마다 가져오도록 설정했습니다.', 'BOMATI', 6);
}

function createConnectionTestRecord() {
  const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error('연동할 Google Sheet를 연 상태에서 실행해야 합니다.');
  }

  PropertiesService.getScriptProperties().setProperty('BOMATI_SPREADSHEET_ID', spreadsheet.getId());
  const logSheet = ensureMissedStopSheet_(spreadsheet);
  const settingsSheet = ensureCompanySettingsSheet_(spreadsheet);
  const company = getCompanyConfig_(settingsSheet);
  const occurredAtMs = Date.now();
  const eventId = `sheet-test-${occurredAtMs}-${Utilities.getUuid().replace(/-/g, '').slice(0, 8)}`;
  const event = {
    type: 'missed_stop',
    source: 'google_sheets_connection_test',
    isConnectionTest: true,
    eventId,
    occurredAtMs,
    createdAtMs: occurredAtMs,
    exportStatus: 'pending',
    company,
    server: { sessionId: 'google-sheets-test', placeId: 0, placeVersion: 0 },
    bus: { id: 'connection-test', name: '연동 테스트 차량', route: 'TEST', floorType: 'low' },
    driver: { userId: '', userName: 'Google Sheet', displayName: '연동 테스트', seatName: '' },
    stop: { id: 'TEST-STOP', index: 0, name: '연동 테스트 정류장', x: 0, y: 0, z: 0 },
    bell: {
      bellType: 'normal',
      triggeredBy: 'Google Sheet',
      triggerReason: 'CONNECTION_TEST',
      triggeredAtMs: occurredAtMs
    },
    passage: {
      approachStartedAtMs: occurredAtMs,
      minimumDistanceStuds: 0,
      passSpeedStudsPerSecond: 0,
      observedSeconds: 0,
      busX: 0,
      busY: 0,
      busZ: 0
    }
  };

  writeFirebaseEvent_(company.id, event);
  syncMissedStopLogs();
  deleteFirebaseEvent_(company.id, eventId);
  spreadsheet.setActiveSheet(logSheet);
  spreadsheet.toast('연동 테스트가 완료되었습니다. 첫 번째 탭의 마지막 행을 확인하세요.', 'BOMATI', 8);
}

function syncMissedStopLogs() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) {
    return;
  }

  try {
    const spreadsheetId = PropertiesService.getScriptProperties().getProperty('BOMATI_SPREADSHEET_ID');
    if (!spreadsheetId) {
      throw new Error('먼저 setupMissedStopLogging 함수를 한 번 실행해 주세요.');
    }

    const spreadsheet = SpreadsheetApp.openById(spreadsheetId);
    const sheet = ensureMissedStopSheet_(spreadsheet);
    const settingsSheet = ensureCompanySettingsSheet_(spreadsheet);
    const company = getCompanyConfig_(settingsSheet);
    const events = fetchMissedStopEvents_(company.id);
    const existingIds = getExistingEventIds_(sheet);
    const importedAt = new Date();

    const newEvents = Object.keys(events)
      .map((key) => events[key])
      .filter((event) => event
        && event.type === 'missed_stop'
        && event.eventId
        && event.company
        && String(event.company.id) === company.id
        && !existingIds.has(String(event.eventId)))
      .sort((first, second) => Number(first.occurredAtMs || 0) - Number(second.occurredAtMs || 0));

    if (newEvents.length === 0) {
      return;
    }

    const rows = newEvents.map((event) => toSheetRow_(event, importedAt));
    const startRow = Math.max(sheet.getLastRow() + 1, 2);
    const requiredLastRow = startRow + rows.length - 1;
    if (requiredLastRow > sheet.getMaxRows()) {
      sheet.insertRowsAfter(sheet.getMaxRows(), requiredLastRow - sheet.getMaxRows());
    }
    sheet.getRange(startRow, 1, rows.length, BOMATI_MISSED_STOP_HEADERS.length).setValues(rows);
    applyMissedStopDataFormatting_(sheet, startRow, rows.length);
    SpreadsheetApp.flush();

    markEventsAsExported_(company.id, newEvents, importedAt.getTime());
  } finally {
    lock.releaseLock();
  }
}

function ensureMissedStopSheet_(spreadsheet) {
  let sheet = spreadsheet.getSheetByName(BOMATI_MISSED_STOP_CONFIG.sheetName);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(BOMATI_MISSED_STOP_CONFIG.sheetName);
  }
  if (sheet.getMaxColumns() < BOMATI_MISSED_STOP_HEADERS.length) {
    sheet.insertColumnsAfter(sheet.getMaxColumns(), BOMATI_MISSED_STOP_HEADERS.length - sheet.getMaxColumns());
  }

  const headerRange = sheet.getRange(1, 1, 1, BOMATI_MISSED_STOP_HEADERS.length);
  headerRange.setValues([Array.from(BOMATI_MISSED_STOP_HEADERS)]);
  headerRange
    .setBackground('#0f2742')
    .setFontColor('#ffffff')
    .setFontWeight('bold')
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle');
  sheet.setFrozenRows(1);
  sheet.setRowHeight(1, 34);

  const widths = [230, 150, 160, 300, 72, 130, 230, 72, 150, 130, 105, 105, 150, 125, 110, 95, 110, 210, 150, 145, 135, 105, 80, 80, 80, 230, 110, 110, 95, 220, 110, 150];
  widths.forEach((width, index) => sheet.setColumnWidth(index + 1, width));

  if (sheet.getMaxRows() < 2) {
    sheet.insertRowsAfter(1, 1);
  }
  const statusRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(['미확인', '확인 중', '조치 완료', '오탐', '연동 테스트'], true)
    .setAllowInvalid(false)
    .build();
  sheet.getRange(2, 29, sheet.getMaxRows() - 1, 1).setDataValidation(statusRule);

  const filter = sheet.getFilter();
  if (filter && (
    filter.getRange().getNumColumns() !== BOMATI_MISSED_STOP_HEADERS.length
    || filter.getRange().getNumRows() !== sheet.getMaxRows()
  )) {
    filter.remove();
  }
  if (!sheet.getFilter()) {
    sheet.getRange(1, 1, sheet.getMaxRows(), BOMATI_MISSED_STOP_HEADERS.length).createFilter();
  }

  return sheet;
}

function ensureCompanySettingsSheet_(spreadsheet) {
  let sheet = spreadsheet.getSheetByName(BOMATI_MISSED_STOP_CONFIG.settingsSheetName);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(BOMATI_MISSED_STOP_CONFIG.settingsSheetName);
  }
  if (sheet.getMaxColumns() < 4) {
    sheet.insertColumnsAfter(sheet.getMaxColumns(), 4 - sheet.getMaxColumns());
  }

  sheet.getRange('A1:D1').breakApart();
  sheet.getRange('A1:D1').merge();
  sheet.getRange('A1')
    .setValue('BOMATI 회사 설정')
    .setBackground('#0f2742')
    .setFontColor('#ffffff')
    .setFontWeight('bold')
    .setFontSize(15)
    .setHorizontalAlignment('left');
  sheet.setRowHeight(1, 40);

  sheet.getRange('A3').setValue('회사명').setFontWeight('bold');
  sheet.getRange('A4').setValue('회사 식별 아이디').setFontWeight('bold');
  sheet.getRange('B3:B4').setBackground('#fff4d6').setNumberFormat('@');
  sheet.getRange('B4').setNote('BOMATI 메뉴의 회사 식별 아이디 생성 기능으로 만듭니다. 다른 회사와 공유하지 말고 해당 회사의 Bus Model에만 입력하세요.');

  sheet.getRange('A6:D6').breakApart();
  sheet.getRange('A6:D6').merge();
  sheet.getRange('A6').setValue('Roblox Bus Model에 입력할 String 속성').setFontWeight('bold').setBackground('#dce9f7');
  sheet.getRange('A7').setValue('CompanyName').setFontWeight('bold');
  sheet.getRange('A8').setValue('CompanyId').setFontWeight('bold');
  sheet.getRange('B7').setFormula('=B3').setNumberFormat('@');
  sheet.getRange('B8').setFormula('=B4').setNumberFormat('@');

  sheet.getRange('A10').setValue('설정 상태').setFontWeight('bold');
  sheet.getRange('B10').setFormula('=IF(AND(B3<>"",B4<>""),"설정 완료","회사명과 식별 아이디 필요")');
  sheet.getRange('A12:D12').breakApart();
  sheet.getRange('A12:D12').merge();
  sheet.getRange('A12').setValue('회사 식별 아이디는 데이터가 들어갈 회사를 구분하는 값입니다. 실제 인증 비밀번호나 보안키로 사용하지 않습니다.').setWrap(true).setFontColor('#526173');
  sheet.setRowHeight(12, 44);

  sheet.setColumnWidth(1, 185);
  sheet.setColumnWidth(2, 360);
  sheet.setColumnWidth(3, 120);
  sheet.setColumnWidth(4, 120);
  sheet.setFrozenRows(1);
  return sheet;
}

function arrangeCompanySheets_(spreadsheet, logSheet, settingsSheet) {
  spreadsheet.setActiveSheet(logSheet);
  spreadsheet.moveActiveSheet(1);
  spreadsheet.setActiveSheet(settingsSheet);
  spreadsheet.moveActiveSheet(2);
}

function getCompanyConfig_(settingsSheet) {
  const name = String(settingsSheet.getRange('B3').getDisplayValue() || '').trim();
  const id = String(settingsSheet.getRange('B4').getDisplayValue() || '').trim();
  if (!name) {
    throw new Error('두 번째 탭 회사 설정!B3에 회사명을 입력해 주세요.');
  }
  if (!/^[A-Za-z0-9_-]{12,80}$/.test(id)) {
    throw new Error('BOMATI 메뉴의 회사 식별 아이디 생성 기능으로 회사 설정!B4 값을 만들어 주세요.');
  }
  return { name, id };
}

function fetchMissedStopEvents_(companyId) {
  const companyUrl = `${BOMATI_MISSED_STOP_CONFIG.firebaseRootUrl}/${encodeURIComponent(companyId)}.json`;
  const response = UrlFetchApp.fetch(companyUrl, {
    method: 'get',
    muteHttpExceptions: true,
    headers: { Accept: 'application/json' }
  });
  const responseCode = response.getResponseCode();
  if (responseCode < 200 || responseCode >= 300) {
    throw new Error(`Firebase 무정차 기록 읽기 실패: HTTP ${responseCode} ${response.getContentText()}`);
  }

  const body = response.getContentText();
  if (!body || body === 'null') {
    return {};
  }
  const parsed = JSON.parse(body);
  return parsed && typeof parsed === 'object' ? parsed : {};
}

function writeFirebaseEvent_(companyId, event) {
  const eventUrl = `${BOMATI_MISSED_STOP_CONFIG.firebaseRootUrl}/${encodeURIComponent(companyId)}/${encodeURIComponent(event.eventId)}.json`;
  const response = UrlFetchApp.fetch(eventUrl, {
    method: 'put',
    contentType: 'application/json',
    payload: JSON.stringify(event),
    muteHttpExceptions: true
  });
  const responseCode = response.getResponseCode();
  if (responseCode < 200 || responseCode >= 300) {
    throw new Error(`Firebase 회사 경로 쓰기 실패: HTTP ${responseCode} ${response.getContentText()}`);
  }
}

function deleteFirebaseEvent_(companyId, eventId) {
  const eventUrl = `${BOMATI_MISSED_STOP_CONFIG.firebaseRootUrl}/${encodeURIComponent(companyId)}/${encodeURIComponent(eventId)}.json`;
  const response = UrlFetchApp.fetch(eventUrl, {
    method: 'delete',
    muteHttpExceptions: true
  });
  const responseCode = response.getResponseCode();
  if (responseCode < 200 || responseCode >= 300) {
    console.error(`Firebase 연동 테스트 데이터 정리 실패: HTTP ${responseCode} ${response.getContentText()}`);
  }
}

function getExistingEventIds_(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) {
    return new Set();
  }
  const values = sheet.getRange(2, 1, lastRow - 1, 1).getDisplayValues();
  return new Set(values.map((row) => String(row[0] || '').trim()).filter(Boolean));
}

function toSheetRow_(event, importedAt) {
  const company = event.company || {};
  const bus = event.bus || {};
  const driver = event.driver || {};
  const stop = event.stop || {};
  const bell = event.bell || {};
  const passage = event.passage || {};
  const server = event.server || {};

  return [
    String(event.eventId),
    toDateOrBlank_(event.occurredAtMs),
    stringOrBlank_(company.name),
    stringOrBlank_(company.id),
    stringOrBlank_(bus.route),
    stringOrBlank_(bus.name),
    stringOrBlank_(bus.id),
    bus.floorType === 'high' ? '고상' : bus.floorType === 'low' ? '저상' : stringOrBlank_(bus.floorType),
    stringOrBlank_(driver.userName),
    stringOrBlank_(driver.displayName),
    numberOrBlank_(driver.userId),
    stringOrBlank_(driver.seatName),
    stringOrBlank_(stop.name),
    stringOrBlank_(stop.id),
    numberOrBlank_(stop.index),
    bell.bellType === 'special' ? '장애인 벨' : bell.bellType === 'normal' ? '일반 벨' : stringOrBlank_(bell.bellType),
    stringOrBlank_(bell.triggeredBy),
    stringOrBlank_(bell.triggerReason),
    toDateOrBlank_(bell.triggeredAtMs),
    numberOrBlank_(passage.minimumDistanceStuds),
    numberOrBlank_(passage.passSpeedStudsPerSecond),
    numberOrBlank_(passage.observedSeconds),
    numberOrBlank_(passage.busX),
    numberOrBlank_(passage.busY),
    numberOrBlank_(passage.busZ),
    stringOrBlank_(server.sessionId),
    numberOrBlank_(server.placeId),
    numberOrBlank_(server.placeVersion),
    event.isConnectionTest === true ? '연동 테스트' : '미확인',
    '',
    '',
    importedAt
  ];
}

function applyMissedStopDataFormatting_(sheet, startRow, rowCount) {
  sheet.getRange(startRow, 1, rowCount, BOMATI_MISSED_STOP_HEADERS.length)
    .setVerticalAlignment('middle')
    .setWrap(false);
  sheet.getRange(startRow, 2, rowCount, 1).setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange(startRow, 19, rowCount, 1).setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange(startRow, 20, rowCount, 3).setNumberFormat('0.0');
  sheet.getRange(startRow, 23, rowCount, 3).setNumberFormat('0.0');
  sheet.getRange(startRow, 32, rowCount, 1).setNumberFormat('yyyy-mm-dd hh:mm:ss');
  const statusRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(['미확인', '확인 중', '조치 완료', '오탐', '연동 테스트'], true)
    .setAllowInvalid(false)
    .build();
  sheet.getRange(startRow, 29, rowCount, 1)
    .setDataValidation(statusRule)
    .setBackground('#fff4d6');
}

function markEventsAsExported_(companyId, events, exportedAtMs) {
  const requests = [];
  events.forEach((event) => {
    const eventKey = encodeURIComponent(String(event.eventId));
    const baseUrl = `${BOMATI_MISSED_STOP_CONFIG.firebaseRootUrl}/${encodeURIComponent(companyId)}/${eventKey}`;
    requests.push({
      url: `${baseUrl}/exportStatus.json`,
      method: 'put',
      contentType: 'application/json',
      payload: JSON.stringify('synced'),
      muteHttpExceptions: true
    });
    requests.push({
      url: `${baseUrl}/exportedAtMs.json`,
      method: 'put',
      contentType: 'application/json',
      payload: JSON.stringify(exportedAtMs),
      muteHttpExceptions: true
    });
  });

  const responses = UrlFetchApp.fetchAll(requests);
  responses.forEach((response) => {
    const responseCode = response.getResponseCode();
    if (responseCode < 200 || responseCode >= 300) {
      console.error(`Firebase 내보내기 상태 갱신 실패: HTTP ${responseCode} ${response.getContentText()}`);
    }
  });
}

function toDateOrBlank_(value) {
  const timestamp = Number(value);
  return Number.isFinite(timestamp) && timestamp > 0 ? new Date(timestamp) : '';
}

function numberOrBlank_(value) {
  if (value === null || value === undefined || value === '') {
    return '';
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : '';
}

function stringOrBlank_(value) {
  return value === null || value === undefined ? '' : String(value);
}
