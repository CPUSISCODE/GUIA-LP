const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {webcrypto} = require('node:crypto');
const {JSDOM} = require('jsdom');
const ArchiveClient = require('./archive-client.cjs');
const html = fs.readFileSync(path.join(__dirname, '../index.html'), 'utf8');
const archive = fs.readFileSync(path.join(__dirname, '../xml-archive.js'), 'utf8');
const app = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].at(-1)[1];
const XML = '<?xml version="1.0" encoding="UTF-8"?><nfeProc><NFe><infNFe Id="NFe' + '1'.repeat(44) + '"><ide><mod>55</mod><nNF>123</nNF></ide><emit><xNome>Fornecedor de teste</xNome><CRT>3</CRT><enderEmit><UF>SP</UF></enderEmit></emit><det nItem="1"><prod><cProd>1</cProd><xProd>Arroz de teste</xProd><NCM>10063021</NCM><CFOP>6102</CFOP><uCom>UN</uCom><qCom>2</qCom><vUnCom>10</vUnCom><vProd>20</vProd></prod></det><total><ICMSTot><vNF>20</vNF></ICMSTot></total></infNFe></NFe></nfeProc>';
const tick = () => new Promise(resolve => setTimeout(resolve, 10));
async function waitFor(check){ for(let i=0;i<100;i++){ if(check()) return; await tick(); } throw new Error('Timed out'); }
async function boot(t, client = new ArchiveClient()){
  const dom = new JSDOM(html, {runScripts:'outside-only', url:'https://guialp.test/'});
  t.after(() => dom.window.close());
  const w = dom.window;
  w.File = File;
  Object.defineProperty(w.crypto, 'subtle', {value:webcrypto.subtle});
  w.HTMLElement.prototype.scrollIntoView = () => {};
  w.HTMLAnchorElement.prototype.click = () => {};
  w.URL.createObjectURL = blob => { w.downloaded = blob; return 'blob:test'; };
  w.URL.revokeObjectURL = () => {};
  w.sbClient = client;
  w.eval(archive); w.eval(app);
  w.aplicarBaseNcm([{ncm:'10063021', descricao:'Arroz', segmento:null, monofasico:null}]);
  w.lpXmlArchive.setUser('owner-a');
  await waitFor(() => w.document.getElementById('lpArchiveStatus').textContent.startsWith('Guardados'));
  return {w, client, el:id => w.document.getElementById(id)};
}
async function upload(ctx, file){
  Object.defineProperty(ctx.el('lpXmlFile'), 'files', {value:[file], configurable:true});
  ctx.el('lpXmlFile').dispatchEvent(new ctx.w.Event('change'));
  await waitFor(() => !ctx.el('lpXmlFile').disabled);
}

test('Importação guarda bytes originais e metadados; limpar preserva histórico e outra sessão reabre', async t => {
  const ctx = await boot(t);
  const file = new File(['\ufeff' + XML], 'nota-original.xml');
  await upload(ctx, file);
  assert.match(ctx.el('lpArchiveReceipt').textContent, /com sucesso/);
  assert.equal(ctx.client.records.length, 1);
  assert.deepEqual(Buffer.from(ctx.client.records[0].xml_base64, 'base64'), Buffer.from(await file.arrayBuffer()));
  assert.equal(ctx.client.records[0].numero_nota, '123');
  assert.equal(ctx.client.records[0].valor_total, 20);
  assert.equal(ctx.el('lpXmlItemsBody').children.length, 1);
  ctx.el('lpClearXmlBtn').click();
  assert.equal(ctx.el('lpXmlTableWrap').style.display, 'none');
  assert.equal(ctx.el('lpArchiveBody').children.length, 1);
  const next = await boot(t, ctx.client);
  next.el('lpArchiveBody').querySelector('button').click();
  await waitFor(() => next.el('lpXmlTableWrap').style.display === 'block');
  assert.match(next.el('lpXmlEmitInfo').textContent, /Fornecedor de teste/);
  next.el('lpArchiveBody').querySelectorAll('button')[1].click();
  await waitFor(() => !!next.w.downloaded);
  assert.deepEqual(Buffer.from(await next.w.downloaded.arrayBuffer()), Buffer.from(await file.arrayBuffer()));
});

test('Reenvio e cópia com outro nome não duplicam a NF-e', async t => {
  const ctx = await boot(t);
  await upload(ctx, new File([XML], 'um.xml'));
  await upload(ctx, new File([XML], 'copia.xml'));
  assert.equal(ctx.client.records.length, 1);
  assert.match(ctx.el('lpArchiveReceipt').textContent, /já está guardado/);
});

test('Falha de gravação é explícita e cálculo continua; reenvio salva após conexão voltar', async t => {
  const ctx = await boot(t);
  ctx.client.error = {code:'NETWORK'};
  await upload(ctx, new File([XML], 'nota.xml'));
  assert.equal(ctx.client.records.length, 0);
  assert.match(ctx.el('lpArchiveReceipt').textContent, /não foi guardado|tentar salvar/i);
  assert.equal(ctx.el('lpXmlTableWrap').style.display, 'block');
  ctx.client.error = null;
  await upload(ctx, new File([XML], 'nota.xml'));
  assert.equal(ctx.client.records.length, 1);
});

test('Arquivo inválido, DTD e limite de tamanho não são gravados', async t => {
  const ctx = await boot(t);
  for(const xml of ['<errado>', '<!DOCTYPE x [<!ENTITY ext SYSTEM "file:///etc/passwd">]>' + XML]){
    await upload(ctx, new File([xml], 'invalido.xml'));
    assert.match(ctx.el('lpArchiveReceipt').textContent, /não guardado/);
  }
  await upload(ctx, new File([new Uint8Array(ctx.w.lpXmlArchive.maxBytes + 1)], 'grande.xml'));
  assert.equal(ctx.client.records.length, 0);
  assert.match(ctx.el('lpXmlErrorArea').textContent, /até 5 MB/);
});

test('Paginação, busca e renderização segura de nomes do XML', async t => {
  const ctx = await boot(t);
  for(let i=0;i<25;i++) ctx.client.records.push({id:String(i),user_id:'owner-a',nome_arquivo:'nota-' + i + '.xml',fornecedor:i === 24 ? '<img src=x onerror=alert(1)>' : 'Empresa',numero_nota:String(i),created_at:new Date().toISOString(),valor_total:10});
  await ctx.w.lpXmlArchive.refresh();
  assert.equal(ctx.el('lpArchiveBody').children.length, 20);
  ctx.el('lpArchiveNext').click();
  await waitFor(() => ctx.el('lpArchiveBody').children.length === 5);
  assert.equal(ctx.el('lpArchiveBody').querySelectorAll('img').length, 0);
  ctx.el('lpArchiveSearch').value = 'nota-24';
  ctx.el('lpArchiveSearch').dispatchEvent(new ctx.w.Event('input'));
  await waitFor(() => ctx.el('lpArchiveBody').children.length === 1);
  assert.match(ctx.el('lpArchiveBody').textContent, /nota-24/);
});

test('Resposta tardia não repõe XMLs nem cálculo depois do logout', async t => {
  const ctx = await boot(t);
  await upload(ctx, new File([XML], 'nota.xml'));
  let release;
  ctx.client.readBarrier = new Promise(resolve => { release = resolve; });
  const pending = ctx.w.lpXmlArchive.refresh();
  ctx.w.lpXmlArchive.setUser(null);
  release(); await pending;
  assert.equal(ctx.el('lpArchiveBody').children.length, 0);
  assert.equal(ctx.el('lpXmlTableWrap').style.display, 'none');
  assert.match(ctx.el('lpArchiveStatus').textContent, /Entre na sua conta/);
  ctx.w.lpXmlArchive.setUser('owner-b');
  await tick();
  assert.equal(ctx.el('lpArchiveBody').children.length, 0);
});
