// Эмуляция JS-стадии platon в Node: node js_stage.js <in.json> <out.json>
// in.json: {es5, variables, requestParams, http_mode, work_dir}
//   http_mode "throw"  — на HTTP 4xx/5xx http.post/http.get бросают исключение с телом ответа
//                        в тексте (как RestTemplate: 404 Not Found: "{...}");
//   http_mode "return" — отдают разобранное тело ошибки как обычный ответ.
// Запросы идут через curl в настоящий тестовый стенд Uzum. Токен в лог и ошибки не пишется.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const cp = require('child_process');

const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const work = input.work_dir;
const calls = [];
const REASONS = {
    400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 405: 'Method Not Allowed',
    409: 'Conflict', 500: 'Internal Server Error', 502: 'Bad Gateway', 503: 'Service Unavailable'
};

function request(method, url, body, headers) {
    const bodyFile = path.join(work, 'js_body.json');
    const respFile = path.join(work, 'js_resp.json');
    try { fs.unlinkSync(respFile); } catch (e) { /* нет файла */ }
    const args = ['-sS', '-X', method, String(url), '-o', respFile, '-w', '%{http_code}', '--max-time', '30'];
    Object.keys(headers || {}).forEach(function (k) { args.push('-H', k + ': ' + headers[k]); });
    let sent = null;
    if (method !== 'GET') {
        sent = typeof body === 'string' ? body : JSON.stringify(body);
        fs.writeFileSync(bodyFile, sent, 'utf8');
        args.push('--data-binary', '@' + bodyFile);
    }
    let code;
    try {
        code = Number(cp.execFileSync('curl', args, {encoding: 'utf8'}).trim());
    } catch (e) {
        // текст как у ResourceAccessException; аргументы curl (с токеном) наружу не отдаём
        calls.push({method: method, url: String(url), http: null, body_type: typeof body});
        throw new Error('I/O error on ' + method + ' request for "' + url + '": curl exit ' + e.status);
    }
    const text = fs.existsSync(respFile) ? fs.readFileSync(respFile, 'utf8') : '';
    calls.push({method: method, url: String(url), http: code, body_type: typeof body, sent_bytes: sent ? Buffer.byteLength(sent) : 0});
    if (code >= 400 && input.http_mode !== 'return') {
        throw new Error(code + ' ' + (REASONS[code] || '') + ': "' + text + '"');
    }
    return text ? JSON.parse(text) : null;
}

const sandbox = {
    variables: input.variables || {},
    requestParams: input.requestParams || {},
    http: {
        post: function (url, body, headers) { return request('POST', url, body, headers); },
        get: function (url, headers) { return request('GET', url, undefined, headers); }
    },
    throws: {
        responseException: function (code, msg) { throw new Error(code + ': ' + msg); }
    }
};

let result = null;
let error = null;
try {
    result = vm.runInNewContext('(function(){' + input.es5 + '\n})()', sandbox, {timeout: 180000});
} catch (e) {
    error = String(e && e.message ? e.message : e);
}
fs.writeFileSync(process.argv[3], JSON.stringify({result: result, error: error, calls: calls}), 'utf8');
