'use strict';
(() => {
  const en = {
    intentional: 'Intentionally vulnerable', workspace: 'WORKSPACE', labTitle: 'Hardware Security Lab',
    tagline: 'Real requests, real DMA, observable product impact.', checking: 'Checking device',
    coreShape: 'INT8 core shape', servicePolicy: 'Service policy', scenario: 'HARDWARE SCENARIO',
    scenarioTitle: 'Late buffer reuse', scenarioDescription: 'A times out. Its buffer is assigned to B. A’s delayed write arrives after the handoff.',
    boundary: 'Broken boundary', boundaryText: 'A completed calculation is not necessarily the current request’s result.',
    policy: 'SERVICE POLICY', p0: 'Vulnerable service', p0Detail: 'Reuse early. Accept the late result as B.',
    p1: 'Identity check', p1Detail: 'Reject A’s reply; inspect the memory effect.',
    p2: 'Protected service', p2Detail: 'Drain old accesses before assigning B.',
    previousSettings: 'Previous request & fault settings', previousPart: 'Previous part A',
    surfaceShort: 'Surface', dimensionShort: 'Dimension', temperatureShort: 'Temperature', vibrationShort: 'Vibration',
    delay: 'A output delay (core cycles)', timeout: 'Service timeout (ms)',
    delayHint: 'Delay runs on the core. Timestamps come from the real driver.',
    labScope: 'Controlled fault injection in our custom accelerator and service. Not a disclosed AMD product vulnerability.',
    liveExperiment: 'LIVE EXPERIMENT', qualityControl: 'Product quality control', hardwareRequired: 'Hardware required',
    waitingConnection: 'Waiting for the device. No hardware data, no product result.', currentRequest: 'CURRENT REQUEST',
    partName: 'Product / part name', measurements: 'Deviation measurements', measurementScale: '0 = ideal · 100 = highest deviation',
    surface: 'Surface deviation', dimension: 'Dimensional deviation', temperature: 'Temperature deviation', vibration: 'Vibration deviation',
    rule: 'Quality gate: score ≥ 700 / 1,000 → accept', run: 'Run on hardware',
    emptyTitle: 'The right answer. For the wrong request.',
    emptyDescription: 'Submit B’s measurements to inspect the actual hardware result, its request identity and the resulting product decision.',
    browser: 'Browser', boardService: 'Board service', noFallback: 'No canned output or simulation fallback.',
    stillWaiting: 'The transfer is still active. Its buffer is retained; no new job was admitted.',
    noProductResult: 'No product result was produced.', failureHint: 'Device access or validation failed. No replacement result is generated.',
    correctB: 'Correct result for B', controlVerified: 'Independent hardware control · CPU reference verified', deliveredB: 'Delivered to request B',
    productImpact: 'PRODUCT IMPACT', modelNote: 'Illustrative quality-gate rule, not a trained industrial model. The score is calculated by the INT8 hardware core.',
    observability: 'OBSERVABILITY', transactionEvidence: 'Transaction evidence', waiting: 'WAITING',
    evidenceIntro: 'Inspect actual DMA output and request identity. An incorrect product decision requires verified hardware evidence.',
    noTransactions: 'No hardware transactions yet.', timeline: 'REQUEST TIMELINE', relativeTime: 'Relative to A’s hardware submission',
    timestampScope: 'DMA time is callback observation, not the physical DDR write instant.', rawEvidence: 'Raw evidence record',
    download: 'Download request record', sessionLog: 'SESSION LOG', noRequest: 'No request submitted.',
    footer: 'VulnLM Hardware · Local, authorised hardware security experiments.',
    accept: 'ACCEPT', reject: 'REJECT', notDelivered: 'NOT DELIVERED', noOutput: 'NO RESULT',
    offline: 'Device offline', deviceNotReady: 'Device not ready', deviceReady: 'Real device ready', deviceBusy: 'Processing on KV260', serverOffline: 'Board service unavailable',
    linux_required: 'Run this service on the KV260’s Linux system. This computer has no hardware result to return.',
    device_unavailable: 'The KV260 device is unavailable. Load the matching driver and check /dev/kv260-lab.',
    not_ready: 'The device is busy, quarantined or faulted.', capture_required: 'Rebuild the driver with frame-capture support.',
    lab_disabled: 'Load the driver with allow_lab=1 before starting the experiment.', ready: 'Real KV260 device ready. Requests will execute on the FPGA.',
    windowMiss: 'WINDOW MISSED', hardwareTag: 'REAL DEVICE · P{policy}', readHardware: 'ACTUAL HARDWARE OUTPUT',
    noWindow: 'FAULT WINDOW NOT OBSERVED', noWrongOutput: 'No incorrect reply was delivered.',
    wrongDecision: 'Wrong result. Wrong product decision.', crossedReply: 'B received A’s result.', protectedReply: 'The late result was not delivered to B.',
    missedDescription: 'The transfer finished early or the ownership window could not be verified. This run does not establish reproduction.',
    crossedDescription: 'The output calculated for {a} was used as the reply to {b}. This is a request-association error, not an arithmetic error.',
    p1Description: 'Identity checking rejected A’s reply. The early buffer handoff still affected memory; B was then computed on hardware.',
    p2Description: 'The buffer was retained until A’s accesses drained. B was then computed on hardware and received its own result.',
    sourceA: 'Actual DMA output from {label}', sourceB: 'Own DMA output for {label}',
    impactNoReply: 'No product decision was delivered.', impactFalseAccept: 'A product that should be rejected was accepted.',
    impactFalseReject: 'A product that should be accepted was rejected.', impactSameDecision: 'Wrong score; the decision happens to be unchanged.',
    impactSameScore: 'Wrong request association; the scores happen to match.', impactCorrect: 'B received its own verified result.',
    retryWindow: 'Adjust the delay or timeout and run a new hardware request.',
    scoreComparison: 'B control: {expected}. Delivered: {delivered}. Acceptance threshold: {threshold}.',
    eventSubmit: 'A submitted to hardware', eventTimeout: 'Service observed A’s timeout', eventEarlyHandoff: 'Buffer logically assigned to B',
    eventSafeHandoff: 'A drained; buffer assigned to B', eventDma: 'A output DMA completion observed', eventB: 'B completed its own DMA transfer',
    proofSource: 'Evidence source', proofRequest: 'Request record', proofShape: 'Actual core', proofIdentity: 'A job ID / generation',
    proofTimeout: 'Timeout observed', proofGuard: 'Guard-pattern errors', proofChanged: 'Bytes changed after early B handoff',
    noEarlyOwner: 'No early B ownership', proofAHash: 'A DMA output SHA-256', proofBHash: 'B control output SHA-256',
    proofCycles: 'A core cycles', proofSaved: 'Persistent record', saved: 'Saved', checkRecord: 'Check server record', yes: 'Yes', no: 'No',
    processingTag: 'RUNNING', baselineTitle: 'Verifying B on hardware', protectedTitle: 'Computing B’s own result', captureTitle: 'Waiting for A’s delayed transfer',
    starting: 'Starting the real device call.', baselineMessage: 'B was submitted for an independent hardware control calculation.',
    captureMessage: 'A is delayed on the core; the driver observes timeout and buffer ownership.',
    protectedMessage: 'A was rejected as B’s reply; B is now executing on the core.',
    misdeliveryMessage: 'The vulnerable service delivered A’s late hardware output as B’s reply.',
    apiError: 'The board service could not be reached.', connectionLost: '{error} The hardware request is not considered cancelled; check its state when connectivity returns.',
  };
  const tr = {
    intentional:'Kasıtlı zafiyetli laboratuvar',workspace:'ÇALIŞMA ALANI',labTitle:'Donanım Güvenliği Labı',tagline:'Gerçek istekler, gerçek DMA, gözlenebilir ürün etkisi.',checking:'Aygıt kontrol ediliyor',
    coreShape:'INT8 çekirdek boyutu',servicePolicy:'Hizmet politikası',scenario:'DONANIM SENARYOSU',scenarioTitle:'Gecikmiş tampon kullanımı',scenarioDescription:'A zaman aşımına uğrar. Tampon B’ye verilir. A’nın gecikmiş yazısı devirden sonra gelir.',
    boundary:'Aşılan sınır',boundaryText:'Tamamlanan bir hesap, güncel isteğin sonucu olmayabilir.',policy:'HİZMET POLİTİKASI',p0:'Zafiyetli hizmet',p0Detail:'Erken yeniden kullan. Geç sonucu B olarak kabul et.',p1:'Kimlik denetimi',p1Detail:'A yanıtını reddet; bellek etkisini ayrıca gözle.',p2:'Korumalı hizmet',p2Detail:'Eski erişimleri bitirmeden tamponu B’ye verme.',
    previousSettings:'Önceki istek ve hata ayarları',previousPart:'Önceki ürün A',surfaceShort:'Yüzey',dimensionShort:'Boyut',temperatureShort:'Isı',vibrationShort:'Titreşim',delay:'A çıktı gecikmesi (çekirdek çevrimi)',timeout:'Hizmet timeout’u (ms)',delayHint:'Gecikme çekirdekte uygulanır. Zaman damgaları gerçek sürücüden gelir.',labScope:'Özel hızlandırıcı ve hizmetimizde kontrollü hata enjeksiyonu. AMD ürününde keşfedilmiş açık iddiası değildir.',
    liveExperiment:'CANLI DENEY',qualityControl:'Ürün kalite kontrolü',hardwareRequired:'Donanım gerekli',waitingConnection:'Aygıt bekleniyor. Donanım verisi olmadan ürün sonucu gösterilmez.',currentRequest:'GÜNCEL İSTEK',partName:'Ürün / parça adı',measurements:'Sapma ölçümleri',measurementScale:'0 = ideal · 100 = en yüksek sapma',surface:'Yüzey sapması',dimension:'Boyut sapması',temperature:'Isı sapması',vibration:'Titreşim sapması',rule:'Kalite eşiği: puan ≥ 700 / 1.000 → kabul',run:'Donanımda çalıştır',
    emptyTitle:'Doğru sonuç. Yanlış istek için.',emptyDescription:'Gerçek donanım çıktısını, istek kimliğini ve ürüne verilen kararı incelemek için B’nin ölçümlerini gönder.',browser:'Tarayıcı',boardService:'Kart sunucusu',noFallback:'Önceden hazırlanmış çıktı veya simülasyon yolu yok.',stillWaiting:'Aktarım henüz bitmedi. Tampon korunuyor; yeni iş açılmadı.',noProductResult:'Ürün sonucu üretilmedi.',failureHint:'Aygıt erişimi veya doğrulama başarısız. Yerine sonuç üretilmez.',
    correctB:'B için doğru sonuç',controlVerified:'Bağımsız kart kontrolü · CPU referansı doğrulandı',deliveredB:'B isteğine teslim edilen',productImpact:'ÜRÜN ETKİSİ',modelNote:'Etkiyi görünür kılan örnek kalite kuralıdır; eğitilmiş endüstriyel model değildir. Puan INT8 donanım çekirdeğinde hesaplanır.',
    observability:'GÖZLEMLENEBİLİRLİK',transactionEvidence:'İşlem kanıtı',waiting:'BEKLİYOR',evidenceIntro:'Gerçek DMA çıktısını ve istek kimliğini incele. Yanlış ürün kararı iddiası doğrulanmış donanım kanıtı gerektirir.',noTransactions:'Henüz donanım işlemi yok.',timeline:'İSTEK ZAMAN ÇİZGİSİ',relativeTime:'A’nın donanıma gönderimine göre',timestampScope:'DMA zamanı callback gözlemidir; fiziksel DDR yazma anı değildir.',rawEvidence:'Ham kanıt kaydı',download:'İstek kaydını indir',sessionLog:'OTURUM GÜNLÜĞÜ',noRequest:'Henüz istek gönderilmedi.',footer:'VulnLM Hardware · Yerel, yetkili donanım güvenliği deneyleri.',
    accept:'KABUL',reject:'RET',notDelivered:'TESLİM EDİLMEDİ',noOutput:'SONUÇ YOK',offline:'Kart bağlı değil',deviceNotReady:'Aygıt hazır değil',deviceReady:'Gerçek aygıt hazır',deviceBusy:'KV260’ta işleniyor',serverOffline:'Kart sunucusuna erişilemiyor',
    linux_required:'Sunucuyu KV260’ın Linux sisteminde çalıştır. Bu bilgisayarda döndürülecek donanım sonucu yok.',device_unavailable:'KV260 aygıtına erişilemiyor. Eşleşen sürücüyü ve /dev/kv260-lab yolunu kontrol et.',not_ready:'Kart meşgul, karantinada veya hata durumunda.',capture_required:'Sürücüyü frame-capture desteğiyle yeniden derle.',lab_disabled:'Deneyden önce sürücüyü allow_lab=1 ile yükle.',ready:'Gerçek KV260 aygıtı hazır. İstekler FPGA’da çalışacak.',
    windowMiss:'PENCERE KAÇTI',hardwareTag:'GERÇEK AYGIT · P{policy}',readHardware:'GERÇEK DONANIM ÇIKTISI',noWindow:'HATA PENCERESİ GÖZLENMEDİ',noWrongOutput:'Yanlış çıktı teslim edilmedi.',wrongDecision:'Yanlış sonuç. Yanlış ürün kararı.',crossedReply:'B’ye A’nın sonucu teslim edildi.',protectedReply:'Geç sonuç B’ye teslim edilmedi.',
    missedDescription:'Aktarım erken tamamlandı veya sahiplik penceresi doğrulanamadı. Bu koşu zafiyetin yeniden üretildiğini göstermez.',crossedDescription:'{a} için hesaplanan çıktı, {b} yanıtı olarak kullanıldı. Hesap hatası değil, istek eşleme hatası.',p1Description:'Kimlik denetimi A yanıtını reddetti. Erken tampon devri belleği etkiledi; ardından B donanımda hesaplandı.',p2Description:'A’nın erişimleri bitene kadar tampon bekletildi. Ardından B donanımda hesaplandı ve kendi sonucunu aldı.',sourceA:'{label} isteğinin gerçek DMA çıktısı',sourceB:'{label} isteğinin kendi DMA çıktısı',
    impactNoReply:'Ürün kararı teslim edilmedi.',impactFalseAccept:'Reddedilmesi gereken ürün kabul edildi.',impactFalseReject:'Kabul edilmesi gereken ürün reddedildi.',impactSameDecision:'Skor yanlış; bu girdilerde karar aynı kaldı.',impactSameScore:'İstek eşlemesi yanlış; skorlar tesadüfen aynı.',impactCorrect:'B’nin kendi doğrulanmış sonucu teslim edildi.',retryWindow:'Gecikme/timeout ayarını değiştirerek yeni donanım koşusu başlat.',scoreComparison:'B kontrolü: {expected}. Teslim edilen: {delivered}. Kabul eşiği: {threshold}.',
    eventSubmit:'A donanımda başlatıldı',eventTimeout:'Hizmet A için timeout gözledi',eventEarlyHandoff:'Tampon mantıksal olarak B’ye verildi',eventSafeHandoff:'A boşaldı; tampon B’ye verildi',eventDma:'A çıkış DMA tamamlanması gözlendi',eventB:'B kendi DMA aktarımını tamamladı',
    proofSource:'Kanıt kaynağı',proofRequest:'İstek kaydı',proofShape:'Gerçek çekirdek',proofIdentity:'A iş kimliği / nesil',proofTimeout:'Gözlenen timeout',proofGuard:'Kontrol deseni hataları',proofChanged:'Erken B devrinden sonra değişen bayt',noEarlyOwner:'B erken sahip değil',proofAHash:'A DMA çıktısı SHA-256',proofBHash:'B kontrol çıktısı SHA-256',proofCycles:'A çekirdek çevrimi',proofSaved:'Kalıcı kayıt',saved:'Kaydedildi',checkRecord:'Sunucu kaydını kontrol et',yes:'Evet',no:'Hayır',
    processingTag:'ÇALIŞIYOR',baselineTitle:'B girdisi kartta doğrulanıyor',protectedTitle:'B kendi sonucu için çalışıyor',captureTitle:'A’nın gecikmiş aktarımı bekleniyor',starting:'Gerçek aygıt çağrısı başlatılıyor.',baselineMessage:'B bağımsız kontrol hesabına gönderildi.',captureMessage:'A çekirdekte geciktiriliyor; sürücü timeout ve tampon sahipliğini izliyor.',protectedMessage:'A, B yanıtı olarak reddedildi; B çekirdekte hesaplanıyor.',misdeliveryMessage:'Zafiyetli hizmet A’nın geç donanım çıktısını B yanıtı olarak teslim etti.',apiError:'Kart sunucusuna erişilemedi.',connectionLost:'{error} Donanım isteği iptal edilmiş sayılmaz; bağlantı geri geldiğinde durumunu kontrol et.',
  };
  let language = 'en-GB';
  try { if (localStorage.getItem('vulnlm-hardware-language') === 'tr') language = 'tr'; } catch (_) {}
  function t(key, parameters = {}) {
    const text = (language === 'tr' ? tr[key] : en[key]) ?? en[key] ?? key;
    return text.replace(/\{(\w+)\}/g, (_, name) => String(parameters[name] ?? `{${name}}`));
  }
  function apply() {
    document.documentElement.lang = language;
    document.querySelectorAll('[data-i18n]').forEach(node => { node.textContent = t(node.dataset.i18n); });
    document.querySelectorAll('[data-lang]').forEach(button => {
      const active = button.dataset.lang === language;
      button.classList.toggle('active', active); button.setAttribute('aria-pressed', String(active));
    });
  }
  window.VulnLMI18n = { t, apply, get language() { return language; } };
  document.querySelectorAll('[data-lang]').forEach(button => button.addEventListener('click', () => {
    language = button.dataset.lang === 'tr' ? 'tr' : 'en-GB';
    try { localStorage.setItem('vulnlm-hardware-language', language); } catch (_) {}
    apply(); document.dispatchEvent(new CustomEvent('vulnlm:language'));
  }));
  apply();
})();
