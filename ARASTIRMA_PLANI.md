# KV260: timeout sonrası DMA ve istekler arası izolasyon

Tarih: 29 Ekim 2026 · Durum: deney öncesi plan, v0.1

KV260 mevcut; henüz kurulmadı. Bu belge uygulama öncesi kapsamı, ölçüm yöntemini ve aşama geçişlerini belirler. Buradaki sayısal eşikler önerilen araştırma hedefleridir; ölçülmüş sonuç veya donanım garantisi değildir.

## 1. Araştırma sorusu ve sınanacak iddia

**Bir inference isteği timeout olduktan sonra, o işe ait DMA erişimleri veya veri akışı sonraki isteğin belleğini ve sonucunu etkileyebilir mi? Bu etki hangi yaşam döngüsü kurallarıyla, ne maliyetle engellenebilir?**

Üç ayrı sonuç aranacak:

1. Bellek bütünlüğü: A'ya ait yazı, B'ye verilmiş tamponu değiştiriyor mu?
2. Sonuç bütünlüğü: servis yanlış veya eski sonucu başarılı B yanıtı olarak kabul ediyor mu?
3. Gizlilik: B'nin istemciye dönen yanıtında yalnızca A'ya ait veri bulunuyor mu?

Bellek bozulması, yanlış sonucun kabulü ve veri sızıntısı ayrı raporlanır. Tamponun içindeki A verisini yalnızca laboratuvar gözlemcisinin görmesi, istemciye veri sızıntısı sayılmaz.

Hipotez: timeout ile donanım erişiminin sona ermesini aynı olay sayan tampon yönetimi bu sonuçlara yol açabilir. Tamponu erişimler bitene kadar ayırmak ve eski veri akışını temizlemek izolasyonu koruyabilir. Bu, KV260 veya AMD sürücüsünde bilinen bir açık iddiası değildir.

## 2. Kapsam ve saldırgan yetkileri

- Saldırgan, servis API'sinden istek gönderir; izin verilen boyutları, içerikleri ve gönderim zamanlarını seçebilir. İptal API'si eklenirse onu da kullanabilir.
- Root erişimi, ham DMA adresi seçimi, bitstream değiştirme ve fiziksel müdahale ilk kapsamın dışında.
- Geciktirme, kesik aktarım ve eski completion üretimi laboratuvar hata enjeksiyonudur. Saldırganın bunları gerçek sistemde tetikleyebildiği ayrıca gösterilmedikçe sonuç, hata altında izolasyon deneyi olarak adlandırılır.
- Deney, sürücünün DMA API'siyle ayırdığı ve ömrünü koruduğu deney tamponlarında yürür. Kullanım hakkı B'ye devredilse bile alttaki tahsis canlı tutulur. Komşu test tamponları da aynı kontrollü tahsisin içindedir.
- Tampon çevresindeki kontrol desenleri beklenmeyen yazıları tespit eder; erişimi engellemez. DMA'nın adres aralığını sınırlamak, gerekirse ayrı bir donanım koruması gerektirir.

## 3. İlk iş yükü ve mimari

İlk çekirdek: `y = W x`, INT8 girdiler ve ağırlıklar, INT32 biriktirme ve INT32 çıktı. Başlangıç boyutu `W: 64 × 64`, `x: 64`; çıktı 256 bayt. CPU referansı ile tüm çıktı baytları karşılaştırılır. Doyurma ve yeniden kuantizasyon ilk aşamada yoktur. Her istek farklı, kayıtlı bir rastgelelik tohumu kullanır.

Yol: istemci → Linux servisi → tampon/iş yönetimi → AXI DMA → AXI-Stream hesaplama çekirdeği → AXI DMA → çıktı tamponu.

Kontrol yolu: sürücünün yönettiği AXI-Lite kayıtları. Enjeksiyon kontrolleri servis istemcisine açılmaz. Başlangıçta tek DMA kanalı üzerinde seri donanım çalışması ve iki mantıksal istemci yeterlidir; B, donanımda beklerken yazılım tarafından bir tamponun sahibi yapılabilir.

İlk sürümde, seçilen DMA sağlayıcısının desteklediği tutarlı DMA tahsisi tercih edilir; CPU ve cihaz erişimlerinin gerekli sıralaması ayrıca kurulur. Streaming eşleme seçilirse sahiplik/senkronizasyon kuralları açıkça uygulanır. Cache görünürlüğü hatası, istekler arası izolasyon hatasıyla karıştırılmaz.

İlk iş yükü bir AI katmanının veri hareketini temsil eder. Sınıflandırma doğruluğu bu aşamada ölçülmez; küçük bir model daha sonra, sistem mekanizması doğrulandıktan sonra eklenir.

### Fiziksel olarak mümkün iki hata yolu

**Yol 1 — sürmekte olan eski DMA erişimi:** A'nın DMA işlemi sürerken servis timeout verir ve hâlâ canlı olan çıktı tahsisinin sahipliğini B'ye aktarır. B bu belleği başlatırken veya kullanırken A yazmaya devam eder. B'nin aynı DMA kanalında eşzamanlı çalışmasına gerek yoktur. Eski descriptor adresi, bellek sahipliği ve AXI yazım zamanlarıyla nedensellik doğrulanır.

**Yol 2 — yeni alıcıya ulaşan eski akış:** A'nın DMA alıcısı durdurulur; fakat çekirdek veya aradaki FIFO'da A verisi kalır. B için yeni alıcı başlatıldığında eski veri B tamponuna taşınabilir. Bu, eski descriptor'ın gecikmiş yazısından ayrı bir durumdur; yalnızca DMA alıcısını durdurmanın bütün veri yolunu temizlediği varsayılmaz.

Aktif DMA kanalını yeniden programlamanın güvenli veya destekli olduğu varsayılmaz. Donanım bu yolları engelliyorsa negatif sonuç kaydedilir; gerçekleşmeyen bir yarış zorla varmış gibi sunulmaz.

## 4. Karşılaştırılacak yönetim politikaları

| Politika | Davranış | Sınanacak nokta |
| --- | --- | --- |
| P0: erken yeniden kullanım | Timeout sonrası tampon sahipliği hemen B'ye aktarılır | Kontrollü pozitif kontrol; tahsis deney boyunca canlı kalır |
| P1: kimlik denetimi | P0 + yazılım completion kaydında iş kimliği ve nesil kontrolü | Eski bildirimi reddetmek bellek bozulmasını da önlüyor mu? |
| P2: güvenli yaşam döngüsü | Yeni gönderimi durdur; eski erişimleri sonlandır/senkronize et; kaynak ve FIFO'daki eski veriyi temizle; sonra tamponu yeniden ver | Her iki hata yolunda izolasyon ve maliyet |

P1'in kimliği, B için oluşturulmuş descriptor'a bağlanan A payload'ını kendiliğinden tanımaz. Verinin kendi kimliğini doğrulama ayrı bir savunmadır. Referans hesaplama ve laboratuvar işaretleri, P2'nin üretimde kullandığı bir doğruluk filtresi sayılmaz.

P2 durumları: `FREE → OWNED → IN_FLIGHT → COMPLETED → FREE`. Timeout kolu: `IN_FLIGHT → TIMED_OUT → QUIESCING → FREE`; durma/temizlenme doğrulanamıyorsa `FAULTED`. `FAULTED` tamponlar yeniden dağıtılmaz, yeni işler kontrollü biçimde reddedilir. Bu durum hizmet kaybı olarak ölçülür.

Sabit bir süre bekletmek tek başına güvenlik gerekçesi değildir. DMA API dönüşleri, ilgili DMA durumu, kaynak/FIFO temizleme protokolü ve veri yolu gözlemi birlikte değerlendirilir. İzleme kaydı kaybolmuş bir koşu, güvenli sonuç diye sayılmaz.

## 5. Deney matrisi

| Kod | Uyarım | Ölçülecek etki | Öncelik |
| --- | --- | --- | --- |
| E0 | Normal A/B işleri, timeout yok | CPU eşitliği ve performans tabanı | İlk |
| E1 | A alıcısı aktifken timeout ve tampon sahipliği devri | B belleğine eski yazı; yanlış sonuç kabulü | Ana |
| E2 | Alıcı durduktan sonra kaynak/FIFO'da kalan A verisi | Yeni B alıcısına eski payload | Ana |
| E3 | Eski veya yinelenen completion bildirimi | B'nin yanlış tamamlanmış sayılması | İkinci |
| E4 | Kısa çıktı, eksik paket sonu veya kapasiteyle uyuşmayan aktarım | Kısmi sonucun kabulü, kontrol deseni değişimi, kilitlenme | İkinci |
| E5 | Ardışık timeout; toparlanmanın başarısız olması | Havuz tükenmesi, hizmet kaybı ve güvenli duruş | İkinci |
| E6 | Temizlenmeden yeniden kullanılan tamponda A'ya özgü rastgele işaret | B yanıtında önceki işe ait veri | İkinci |

E4'te fazla veri gönderilmesi otomatik olarak tampon taşması sayılmaz; DMA'nın hata üretmesi veya durması da geçerli sonuçtur. Beklenen erişim sınırı ile gözlenen yazılar karşılaştırılır.

Önce E0–E2 ve P0–P2 tamamlanır. Tüm parametrelerin tam çarpımı ilk hedef değildir.

## 6. Ölçüm sözleşmesi

Temel birim **bir A/B deney çifti**. Her koşuda A/B içerikleri, B'nin beklenen çıktısı, sahiplik geçişleri ve hata programı önceden kaydedilir. B sonucu istemciye kopyalanırken alınan yanıt görüntüsü ile bütün donanım erişimleri bittikten sonraki tampon görüntüsü ayrı saklanır.

| Ölçüt | Tanım / payda |
| --- | --- |
| İstekler arası bellek bozulması | B sahipliği süresinde A kaynaklı yazı görülen çift / hedefli deney çifti |
| Sessiz yanlış sonuç | Başarılı kabul edilmiş fakat CPU referansından farklı B yanıtı / hedefli deney çifti |
| Kabul edilenler içindeki hata | Yanlış B yanıtı / başarılı kabul edilmiş B yanıtı; kabul sayısı sıfırsa tanımsız |
| Veri sızıntısı | B yanıtında yalnızca A'ya ait işaret bulunan çift / hedefli deney çifti; ayrıca sızan bayt miktarı |
| Tespit duyarlılığı | Savunmanın alarm verdiği, bağımsız gözlemle uygunsuzluğu doğrulanmış deneme / gözlemle doğrulanmış uygunsuz deneme |
| Yanlış alarm | Hata enjekte edilmeyen geçerli istekte güvenlik alarmı / geçerli temiz istek |
| Temiz hesap doğruluğu | CPU referansına tam eşit başarılı çıktı / başarılı temiz çıktı; reddedilenler ayrıca sayılır |
| Temiz iş başarısı | Doğru ve başarılı yanıtlanan temiz istek / gönderilen temiz istek |
| Toparlanma süresi | Timeout kaydından ilk doğru başarılı B yanıtına kadar süre; ardından 100 temiz işte tekrar doğrulama |
| Toparlanma başarısı | Önceden belirlenen süre bütçesinde toparlanan hata bölümü / hata bölümü |
| Gecikme | İstemci gönderiminden terminal yanıta p50/p95/p99; başarı, ret ve timeout ayrı |
| Faydalı iş hızı | Doğru ve başarılı iş / saniye; hata karışımı ve sunulan yük ile birlikte |
| Bellek maliyeti | Ayrılmış/karantinadaki tamponların anlık ve tepe baytları; havuz tükenme sayısı |
| Donanım maliyeti | Aynı saat hedefi ve derleme ayarlarında LUT, FF, BRAM, DSP ve zamanlama raporu |

Alarm, sadece timeout oldu diye içerik bozulmasının tespiti sayılmaz. Timeout alarmı ile yanlış payload/kimlik/uzunluk alarmı ayrı kodlanır. Koruma uygunsuzluğu oluşmadan engellerse bu ayrıca engellenen deneme olarak kaydedilir; duyarlılık paydası yapay biçimde genişletilmez.

Tamponun sonraki bir yazıyla düzelmiş olması, aradaki A yazısını yok saydırmaz. Donanım izleme veya sürücü olayıyla doğrulanamayan nedensellik, kesin çapraz yazı diye sınıflandırılmaz. Kontrol desenleri yalnızca kapsadıkları alan hakkında kanıt sağlar.

## 7. Deney protokolü ve tekrarlar

1. **Pilot:** her politika için 1.000 temiz iş; P0 ile E1 ve E2 için 500'er A/B çifti. Amaç doğru zaman pencerelerini ve donanımda gerçekleşebilirliği bulmak. Pilot verisi nihai doğrulama verisinden ayrılır.
2. **Parametreleri sabitle:** E0 gecikmelerinden timeout eşiğini seç ve kaydet. Pilot için başlangıç önerisi `T = 2 × temiz p99`; gerçek saat, boyut ve sistem yüküne göre doğrulanır. Toparlanma bütçesi ilk öneri olarak `10 × T`; normal toparlanma bundan uzunsa pilotta gerekçeyle revize edilir ve doğrulama öncesi dondurulur.
3. **Zamanlama taraması:** eski yazı/veri gelişi ile B sahipliği devri arasındaki farkı kullan. Negatif, sıfıra yakın ve pozitif farklar tara; sadece geçen süreye değil gözlenen olaylara göre sınıflandır. Pilot sonrası sabitlenen sınır ve yüksek risk koşullarını doğrulamada ayrı raporla.
4. **Ana doğrulama:** E1 ve E2'nin seçilmiş her koşulunda, her politika için 10.000 A/B çifti. 5 × 2.000'lik bloklar, farklı tohumlar, blok başlangıcında bilinen donanım durumu; politika sırası dönüşümlü/rastgele. Aynı veri ve hata programı politikalar arasında eşleştirilir; gerçekleşen zamanlar ayrıca ölçülür.
5. **Hizmet maliyeti:** politika başına 10.000 temiz istek; ardından ayrı %1 ve %10 hata programlı koşular. Hedefler P0 temiz kapasitesinin yaklaşık %25, %50 ve %80'i. Sunulan yük sabitlenir; P2 daha yavaşsa kuyrukta büyüme veya ret ayrıca görünür. Kapalı döngü mikro ölçüm ile sabit geliş hızlı yük deneyi ayrılır.
6. **Gözlem bitişi:** her çiftte tüm eski erişimler ve eski akış sonlandırılıp doğrulanmadan çift başarılı sayılmaz. Belirlenen gözlem bütçesinde bu sağlanamazsa koşu `incomplete/faulted` kaydedilir; başarısız toparlanma paydasında kalır.
7. **Raporlama:** her oran için pay ve payda, %95 güven aralığı, blok sonuçları ve koşul bilgisi. Gecikme kuyrukları ve başarısız koşular atılmaz. Süre bütçesinde toparlanmayanlar, başarılıların ortalamasından ayrı başarısızlık olarak raporlanır.

Bağımsız Bernoulli denemeleri varsayımı altında 10.000 denemede sıfır olay, tek taraflı %95 üst sınırın yaklaşık %0,03 olması demektir: `1 − 0,05^(1/N)`. Bu bir güvenlik garantisi değildir. Ardışık yarışlar korelasyonluysa bu sınır doğrudan genellenmez; blok farkları ve bağımlılık raporlanır. Farklı koşulların denemeleri tek bir güven oranı için gelişigüzel birleştirilmez.

## 8. Başarı ve aşama geçiş ölçütleri

- **Kurulum geçişi:** seri konsol/ağ erişimi, imaj ve firmware sürümleri kayıtlı; CPU–FPGA normal DMA aktarımı tekrarlanabilir.
- **Temel doğruluk:** 10.000 temiz istekte tüm başarılı çıktılar CPU ile tam eşit; beklenmeyen ret veya timeout yok. Sorun varsa hata enjeksiyonuna geçilmez.
- **Deney geçerliliği:** P0'da E1/E2 yollarından donanımın izin verdiği en az biri, zaman çizgisi ve veri iziyle tekrar üretilebilir. Üretilemezse mekanizma yeniden değerlendirilir; savunmanın başarılı olduğu sonucu çıkarılmaz.
- **İzolasyon hedefi:** P2'de seçilen her doğrulama koşulunda sıfır gözlenen çapraz yazı, sıfır sessiz yanlış sonuç ve sıfır istemciye sızıntı. Hangi olayın engellendiği ve hangi olayın yalnızca reddedildiği açıklanır.
- **Hizmet hedefi:** toparlanabilen enjeksiyonlarda belirlenen bütçede toparlanma; kalıcı hatada tamponların güvenli durumda tutulması. Kalıcı hatada hizmet durması raporlanır, başarılı toparlanma sayılmaz.
- **Başlangıç performans bütçesi:** temiz yükte p99 gecikme artışı ≤ %10 ve faydalı iş hızı kaybı ≤ %10. Bunlar tasarım hedefi; aşıldığında sonuç saklanmaz, güvenlik/maliyet dengesi değerlendirilir. P0 hatalı veri yolu için hız referansı olsa da güvenlik referansı değildir.
- **Kaynak bütçesi:** ilk sentezden önce mutlak LUT/BRAM sınırı uydurulmaz. Ölçüm mantığı ile savunma mantığının kaynakları ayrı, aynı derleme koşullarıyla raporlanır. Yalnız yazılımdaki P2 için FPGA ek maliyeti olmayabilir.

## 9. Kayıtlar ve üretilecek grafikler

Her koşu kaydı: `run_id, block_id, seed, policy, experiment, fault_type, requested_fault_time, observed_fault_time, request_id, client_id, generation, buffer_id, buffer_owner, input_bytes, output_capacity, returned_bytes, t_submit, t_hw_start, t_timeout, t_owner_change, t_dma_quiesced, t_source_clean, t_response, deadline, status, alarm_code, expected_digest, response_digest, final_buffer_digest, guard_changed, stale_marker_bytes, trace_complete`.

Ayrı olay izi, DMA yazılarının zaman/aralıklarını, AXI el sıkışmalarını ve bekleyen işlem sayaçlarını tutar. Kısmi AXI kabulü göz önünde tutulur; yalnızca tek bir idle bitiyle tüm veri yolunun sustuğu varsayılmaz. Gizlilik işareti her A için rastgele üretilir; yanlışlıkla eşleşme B/temiz kontrollerle sınanır. Hash eşitliği hızlı karşılaştırma içindir; uyuşmazlıkta bayt farkı da tutulur.

CPU olayları monotonik saatle; FPGA olayları çevrim sayacıyla ölçülür. İki saatin ilişkisi ve ölçüm çözünürlüğü kalibre edilir; doğrudan birbirinden çıkarılmaz. Kernel/IP sürümleri, device tree, bitstream özeti, saatler, derleyici ayarları ve gözlem araçlarının durumu koşu manifestine eklenir.

İlk rapordaki dört grafik:

1. Gecikmiş olayın zamanına göre çapraz yazı ve sessiz yanlış sonuç oranları; P0/P1/P2.
2. Temiz ve hatalı yüklerde p99 gecikme ile doğru iş/saniye.
3. Timeout sonrası toparlanma dağılımı ve toparlanamayan bölümlerin oranı.
4. Karantinadaki bellek miktarı ve havuz tükenmesi; varsa ayrı FPGA kaynak karşılaştırması.

## 10. Uygulama sırası ve bağımlılıklar

| Aşama | Çıktı | Bitirme koşulu |
| --- | --- | --- |
| A0: kurulum | Kart erişimi, kayıtlı imaj/firmware, derleme ortamı seçimi | Normal açılış ve yeniden üretilebilir temel ortam |
| A1: bilgisayar modeli | Aynı durum makinesiyle kontrollü olay modeli | P0/P1/P2 farkı ve log formatı anlaşılır; donanım sonucu iddia edilmez |
| A2: normal donanım | DMA + küçük INT8 çekirdek + CPU referansı | Temel doğruluk geçişi |
| A3: hata mekanizması | E1/E2 enjeksiyonu ve zaman çizgileri | Gerçekleşebilir hata yolunun kanıtı |
| A4: savunma ve doğrulama | Sabit parametrelerle karşılaştırmalı koşular | Ölçüm paydaları ve tüm terminal durumları kayıtlı |
| A5: araştırma değerlendirmesi | Grafikler, maliyetler, sınırlamalar | Gerçek sürücü/runtime incelemesine veya küçük modele geçiş kararı |

Önce A0–A4 hedeflenir. Takvim, derleme bilgisayarı ve karta erişim netleştikten sonra tahmin edilir. Henüz yazılım kurulumu, firmware güncellemesi veya bitstream yüklemesi yapılmadı.

Kurulum için başlangıç adayı Kria Ubuntu 24.04. Özel çekirdek/DMA sürücüsü derleme ve yükleme imkânı doğrulanınca sürüm sabitlenecek; gerekirse uyumlu AMD embedded Linux/BSP akışı seçilecek. Vivado/IP, firmware, kernel ve device tree birlikte kayıt altına alınacak. FPGA derleme makinesi ayrıca belirlenecek.

## 11. Teknik dayanaklar ve açık kararlar

- Linux DMAengine sağlayıcı sözleşmesi, sonlandırmanın asenkron olabileceğini; senkronizasyonun önceki descriptor belleğine erişimin bitmesini sağlaması gerektiğini açıklar. Bu nedenle timeout tek başına tamponu yeniden verme koşulu olamaz. Seçilen sürücünün gerçek uygulaması ayrıca incelenecek. [Linux DMAengine provider](https://docs.kernel.org/driver-api/dmaengine/provider.html)
- Tutarlı DMA belleği gerekli bellek sıralamasını ortadan kaldırmaz. İlk hatasız aktarımda cache sahipliği, uygun DMA API kullanımı ve bariyerler doğrulanacak. [Linux DMA API](https://docs.kernel.org/core-api/dma-api-howto.html)
- AXI DMA'nın stop/reset işlemleri bekleyen aktarım ve komutlarla ilgili davranış tanımlar; reset isteği verilmesi ile temizlenmenin bitmesi ayrılır. Bu davranış tüm özel çekirdeğin/FIFO'nun temizlendiği anlamına gelmez. [AMD AXI DMA S2MM kontrolü, PG021](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_DMACR-S2MM-DMA-Control-Register-Offset-30h)
- SMMU ikinci genişletme adayıdır. PL yolu ve stream ID eşlemeleri doğrulanmadan etkin koruma varsayılmaz. Aynı eşlemeye yeniden verilen bir tamponda iş nesli ayrımı otomatik sağlanmaz. İlk P2 değerlendirmesi SMMU'ya bağımlı kurulmaz. [AMD PL master ve stream ID rehberi](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/18842066/Xen%2Band%2BPL%2BMasters)
- AMD'nin KV260 Linux başlangıç tablosu 24.04 ve 22.04 için farklı hazır uygulama desteği gösterir. İlk projenin özel küçük çekirdeği için hazır DPU uygulaması şart değildir. İmaj, boot firmware ve özel sürücü uyumu kurulumda kontrol edilecek. [AMD KV260 Linux seçenekleri](https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/linux_boot.html), [Kria imaj/firmware tablosu](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/1641152513/Kria%2BSOMs%2BStarter%2BKits)

Kendi sistemimizde bilerek eklenen P0 hatası mekanizmayı ve ölçüm yöntemini doğrular. Yayın yeniliği henüz gösterilmiş değildir; sonraki adım ilgili literatür ve gerçek sürücü/runtime yaşam döngülerini incelemek olur. Kartta üretilmeyen hata ve başarısız savunma sonuçları da raporun parçasıdır.

## 12. Uygulama durumu — 29 Ekim 2026

İlk INT8 SystemVerilog çekirdeği ve test düzeneği eklendi. AXI-Stream hesaplama, kontrollü ilk çıktı gecikmesi, paket hataları ve koordineli reset varsayımı altında yerel toparlanma simülasyonda sınandı. [RTL arayüzü](docs/RTL_ARAYUZU.md) ve [simülasyon sonuçları](SIMULASYON_SONUCLARI.md) ayrı belgelerde tutuluyor. A0 kart kurulumu ve gerçek DMA entegrasyonu henüz tamamlanmadı; bu çalışma E1/E2 veya P2 için donanım kanıtı değildir.

AXI-Lite kontrol bloğu ve çekirdekle birleşik üst modül eklendi. Yazılımdan START/gecikme ayarı, kalıcı done/fault olayları, terminal iş kaydı ve aynı anda yakalanan sayaç görüntüsü simülasyonda doğrulandı. [Kayıt haritası](docs/AXI_LITE_KAYITLARI.md) gelecekteki sürücü sözleşmesini tanımlar; çekirdek tamamlanması ile DMA/DDR tamamlanması ayrı olaylar olarak tutulur.

## 13. E1 model doğrulaması — 30 Ekim 2026

A1'in E1 bölümü, SystemVerilog S2MM/RAM modelleri ve gerçek hesap/kontrol RTL'iyle çalıştırıldı. Dört boyutta 36 kontrollü koşuda P0/P1 tamponu erken devrettikleri için eski yazılara izin verdi; P1 eski tamamlanmayı reddetti fakat belleği koruyamadı. P2 normal boşaltmayı bekleyerek bu koşullarda çapraz yazıyı önledi. [Deney yöntemi](docs/DMA_DENEYI.md) ve [sonuçlar](results/reuse/RAPOR.md) kaydedildi. E2 ve kalıcı takılma/resetle toparlanma henüz doğrulanmadı.

Kart mevcut ve henüz kurulmadı. Kullanıcı Vivado'nun son sürümünün bulunduğunu belirtti; tam sürüm/derleme numarası ilk derleme manifestine eklenecek. Sürüm numarası tahmin edilmedi. A0/A2 için [gerçek DMA entegrasyon planı](docs/KV260_DMA_ENTEGRASYONU.md) hazırlandı; Vivado kart projesi, DMA sürücüsü ve bitstream henüz üretilmedi. Model sonucu donanım aşaması geçiş ölçütlerini karşılamış sayılmaz.

## 14. Sistem kaynakları ve E2 — 31 Ekim 2026

Vivado proje/SG DMA bağlantı üreticisi, 100 MHz/HP0 tasarımıyla eşleşen device tree örtüsü, Linux DMAengine istemcisi, sabit ABI'lı kullanıcı aracı, firmware paketleyicisi, kart koşu kaydedicisi ve analiz aracı eklendi. Yocto/EDF/PetaLinux modül/araç tarifleri de hazırlandı; gerçek BSP imajı henüz derlenmedi.

ARM64 Linux 6.12.113 başlıklarıyla modül, W=1 ve uyarıları hata sayarak derlendi. C aracı Mac ve ARM64 Linux'ta; yedi host araç testi; device tree fixture uygulaması ve tüm RTL matrisi geçti. E2'de dört boyut × üç politika = 12 koşu eklendi: alıcı tek başına resetlenince B descriptor'ı eski A stream'ini P0/P1'de kabul etti; P2 kaynağı boşaltıp B'yi doğru çalıştırdı.

Normal sürücü yolu yalnız P2'dir. P0/P1 E1 deneyi, özel sentetik tampon ve root/CAP_SYS_RAWIO ile sınırlıdır. Kalıcı DMA takılmasında tampon korunur; çağrı ve cihaz kaldırma beklemede kalabilir. Bu durum başarılı toparlanma sayılmaz. Arka planda toparlanma/havuz, gerçek kart E2/ILA, sabit geliş hızlı yük ve SMMU deneyleri tamamlanmadı. [Güncel kurulum](docs/SISTEM_KURULUMU.md) ve [yerel sistem raporu](results/system/RAPOR.md).

Bu Mac'te Vivado yok; geliştirme bilgisayarına ve karta erişim bilgisi istendi. Vivado komut/IP doğrulaması, sentez/uygulama, eşleşen Linux/firmware ve gerçek DMA doğruluk deneyleri yapılmadan A0/A2–A4 tamamlanmış sayılmaz.
