# AXI-Lite kontrolü ve yazılım sözleşmesi

Üst modül: `kv260_matvec`. Kontrol alt modülü: `matvec_axil_ctrl`. AXI-Lite ve AXI-Stream arayüzleri aynı `aclk` ve aktif düşük senkron `aresetn` kullanır. Veri yolu 32 bit; çevre birimi içindeki adres yolu 12 bittir (4 KiB pencere). Vivado proje scriptinde PS taban adresi `0xA0010000` olarak seçilmiştir; gerçek araçta adres haritası henüz doğrulanmadı.

Bu modül bir DMA değildir. Bellek adresi almaz ve DDR'ye erişmez. KV260 block design scripti ve Linux DMAengine istemcisi eklendi; bitstream/kart doğrulaması henüz yapılmadı. [Kurulum](SISTEM_KURULUMU.md).

## İşlem kuralları

- Yazma adresi (AW) ve verisi (W) bağımsız alınır. AW önce, W önce veya aynı çevrimde gelebilir. Her iki parça gelmeden yazma uygulanmaz ve B yanıtı üretilmez.
- Aynı anda bir yazma ve bir okuma bekleyebilir; iki yön birbirini engellemez. Bir yönün mevcut yanıtı kabul edilmeden o yönde başka işlem alınmaz.
- B/R yanıtları, alıcı hazır olmasa da üretilir ve kabul edilene kadar sabit kalır. Yazma etkisi, iki parçanın birleştirildiği anda oluşur; BREADY beklenmez.
- Bütün kayıt adresleri 4 bayta hizalıdır. Hizalı olmayan erişim, tanımsız adres ve salt okunur kayda yazma `SLVERR` döndürür. Hatalı okumanın verisi sıfırdır; adresin üst bitleri göz ardı edilerek aynalama yapılmaz.
- `WSTRB[n]`, yazılacak `WDATA[8n+:8]` baytını seçer. Yazılabilir bir kayıtta sıfır WSTRB durum değiştirmez. Salt okunur/tanımsız kayda sıfır WSTRB ile yazma da SLVERR'dir.
- `AWPROT/ARPROT` erişim yetkisi denetlemez. MMIO penceresi ve hata enjeksiyon ayarları sistemde güvenilen sürücüye ayrılmalıdır.

AXI sinyallerinin anlamları için [AMD AXI4-Lite arayüz açıklaması](https://docs.amd.com/r/en-US/pg016_v_tc/AXI4-Lite-Interface-Signals) temel alınmıştır.

## Kayıt haritası

RW: okuma/yazma; RO: salt okuma; CMD: komut, okumada sıfır; W1C: yazılan 1 biti temizler, 0 değiştirmez.

| Ofset | Kayıt | Tür | İçerik |
| --- | --- | --- | --- |
| `0x000` | ID | RO | `0x4D565831` (MVX1) |
| `0x004` | VERSION | RO | `0x00010001` (1.0.1) |
| `0x008` | CONTROL | CMD | Bit 0: START; diğer etkin bitler SLVERR |
| `0x00C` | STATUS | RO | Aşağıdaki durum bitleri |
| `0x010` | CFG_JOB_ID | RW | Sonraki işin 32 bit kimliği |
| `0x014` | CFG_GENERATION | RW | Sonraki işin 32 bit nesli |
| `0x018` | CFG_DELAY_CYCLES | RW | İlk çıktıya eklenecek çevrim sayısı |
| `0x01C` | IRQ_ENABLE | RW | Bit 0: done; bit 1: fault; diğer bitler okunurken 0 |
| `0x020` | IRQ_STATUS | W1C | Bit 0: kalıcı done olayı; bit 1: kalıcı fault olayı |
| `0x024` | ERROR_CODE | RO | Çekirdeğin güncel hata kodu, alt 3 bit |
| `0x028` | ACTIVE_JOB_ID | RO | Çekirdeğin başlatırken aldığı kimlik |
| `0x02C` | ACTIVE_GENERATION | RO | Çekirdeğin başlatırken aldığı nesil |
| `0x030` | ROWS | RO | Derleme zamanında belirlenen satır sayısı |
| `0x034` | COLS | RO | Derleme zamanında belirlenen sütun sayısı |
| `0x038` | INPUT_BYTES | RO | `(ROWS+1) × COLS`, varsayılan 4160 |
| `0x03C` | OUTPUT_BYTES | RO | `ROWS × 4`, varsayılan 256 |
| `0x040` | SNAPSHOT | CMD | Bit 0: mevcut metrikleri bir anda kopyala |
| `0x044` | SNAP_SEQUENCE | RO | Kabul edilen snapshot sayacı |
| `0x048` | SNAP_JOB_ID | RO | Yakalanan iş kimliği |
| `0x04C` | SNAP_GENERATION | RO | Yakalanan nesil |
| `0x050` | SNAP_INPUT_BEATS | RO | Yakalanan giriş sayacı |
| `0x054` | SNAP_OUTPUT_BEATS | RO | Yakalanan çıkış sayacı |
| `0x058` | SNAP_ELAPSED_LO | RO | Yakalanan toplam çevrimin alt 32 biti |
| `0x05C` | SNAP_ELAPSED_HI | RO | Yakalanan toplam çevrimin üst 32 biti |
| `0x060` | SNAP_STALL_LO | RO | Yakalanan geri basınç çevriminin alt 32 biti |
| `0x064` | SNAP_STALL_HI | RO | Yakalanan geri basınç çevriminin üst 32 biti |
| `0x068` | SNAP_STATUS | RO | Yakalanan STATUS |
| `0x06C` | LAST_SEQUENCE | RO | Tamamlanma/hata kaydı sayacı |
| `0x070` | LAST_JOB_ID | RO | Son terminal olayın iş kimliği |
| `0x074` | LAST_GENERATION | RO | Son terminal olayın nesli |
| `0x078` | LAST_ERROR_CODE | RO | Başarıda 0, hatada çekirdek kodu |
| `0x07C` | LAST_INPUT_BEATS | RO | Son terminal olayın giriş sayacı |
| `0x080` | LAST_OUTPUT_BEATS | RO | Son terminal olayın çıkış sayacı |
| `0x084` | LAST_ELAPSED_LO | RO | Son terminal olayın toplam çevrimi, alt |
| `0x088` | LAST_ELAPSED_HI | RO | Son terminal olayın toplam çevrimi, üst |
| `0x08C` | LAST_STALL_LO | RO | Son terminal olayın geri basınç çevrimi, alt |
| `0x090` | LAST_STALL_HI | RO | Son terminal olayın geri basınç çevrimi, üst |
| `0x094` | LAST_OUTCOME | RO | 0: kayıt yok; 1: normal tamamlanma; 2: fault |
| `0x098` | RECOVERY | CMD | 1: abort/drain reset; 2: DMA boşaldıktan sonra resetten çıkış |
| `0x09C` | RECOVERY_STATUS | RO | Bit 0: aktif reset; bit 1: stream paketleri boşaldı |
| `0x0A0` | RECOVERY_COUNT | RO | Tamamlanan resetten çıkış sayacı |
| `0x0A4` | FEATURES | RO | Bit 0: recovery; bit 1: alıcı öncesi tutma kapısı; değer 3 |
| `0x0A8` | STREAM_STATE | RO | Bit 0: kaynakta bekleyen çıktı; bit 1: giriş tamam; bit 2: çıkış tamam |
| `0x0AC` | STREAM_OUTPUT | RO | Kabul edilmiş çıktı beat sayısı |
| `0x0B0` | RECEIVE_HOLD | RW | 1: kaynak çıktısını DMA önünde tut; yalnız idle iken 1 yapılabilir |

SNAPSHOT komutunun bit 0 dışındaki etkin bitleri de SLVERR'dir. IRQ_ENABLE/IRQ_STATUS yalnız alt iki biti kullanır ve yalnız WSTRB[0] etkinse değişir.

STATUS bitleri:

| Bit | Anlamı |
| --- | --- |
| 0 | BUSY: çekirdek meşgul veya yeni START çekirdeğe iletiliyor |
| 1 | READY: şu anda yeni iş başlatılabilir |
| 2 | FAULT: çekirdek reset bekleyen hata durumunda |
| 3 | DONE_PENDING: IRQ_STATUS[0] |
| 4 | FAULT_PENDING: IRQ_STATUS[1] |
| 31:5 | 0 |

Hata durumunda BUSY ve FAULT birlikte 1, READY 0'dır. IRQ_STATUS bitini temizlemek FAULT durumunu ortadan kaldırmaz.

## Başlatma, olay ve ölçüm davranışları

START'ın uygulandığı anda çekirdek hazır değilse veya fault durumundaysa SLVERR döner. Bekleyen iş kuyruğu veya otomatik başlatma yoktur. CONTROL=0 bir işlemsiz komuttur. Abort/drain reset ayrı RECOVERY kaydındadır.

CFG kayıtları iş çalışırken yazılabilir; yeni değerler sonraki START içindir. Çekirdek geçerli işin ayarlarını başlangıçta aldığı için çalışan işin kimliği, nesli ve gecikmesi değişmez. START yanıtının kabulünü geciktirmek başlatmayı geciktirmez.

IRQ, `IRQ_ENABLE & IRQ_STATUS` içindeki herhangi bir bit 1 olduğunda yükselen seviyedir. Maskelenmiş olay da kaydedilir; maskesi sonradan açılabilir. Normal tamamlanma çekirdeğin done darbesinden; fault ise FAULT'a girişten bir kez yakalanır. Olay ve W1C aynı saat kenarına denk gelirse **yeni olay kazanır**. Devam eden FAULT, onaydan sonra her çevrim yeniden olay üretmez.

LAST kayıtları terminal olayda birlikte yakalanır. Onay, yapılandırma yazıları ve sonraki START bu kayıtları silmez. Bir sonraki terminal olay yeni kayıtla değiştirir. Bu bir sonuç kuyruğu değildir: sürücü kaydı okuyup ilgili işi eşleştirmeli, sonra onaylamalı ve işleri uygun sırada başlatmalıdır.

SNAPSHOT, komutun uygulandığı kenardaki mevcut metrikleri kopyalar. Sonradan çekirdek sayacı artsa veya 32 bit sınırını geçse de iki yarı aynı zamana aittir. SNAP kayıtları yalnız sonraki SNAPSHOT veya sistem resetiyle değişir. Birden fazla yazılım okuyucusu bu işlemi kilitle/seri erişimle korumalıdır. Sequence sayaçları 32 bittir ve sarabilir; global tekil kimlik değildir. Sistem reseti bütün kontrol kayıtlarını sıfırlar.

AR kabulünde okunan değer kayıtlı R yanıtına alınır. Yanıt bekletilirken canlı kayıt değişse de yanıt değişmez. Eşzamanlı okuma/yazmada okuma, o kenardan önceki kayıt değerini görür. LAST ve IRQ_STATUS, çekirdeğin son stream el sıkışmasından sonraki saat kenarında yakalanır.

## Sürücü akışı

1. ID, VERSION ve boyutları oku; önceki terminal kaydını tüket ve ilgili IRQ bitini onayla.
2. Tamponları ayır/eşle; DMA alıcısını doğru çıktı kapasitesiyle hazırla. CFG_JOB_ID, CFG_GENERATION ve CFG_DELAY_CYCLES yaz.
3. START=1 yaz ve başarılı AXI yanıtını kontrol et. Ardından tam giriş paketini gönder. Donanım bağlantısında MM2S/S2MM sırası seçilen DMA sözleşmesine göre doğrulanacak.
4. IRQ_STATUS veya irq ile çekirdek olayını izle. Canlı metrik gerekiyorsa SNAPSHOT=1 yaz, yazma yanıtından sonra SNAP kayıtlarını oku.
5. Terminal olayda LAST_SEQUENCE, LAST_JOB_ID, LAST_GENERATION ve LAST_OUTCOME kaydını beklenen işle eşleştir.
6. **DMA'nın DDR aktarımının bittiğini ve gerekli CPU–DMA senkronizasyonunu ayrıca doğrula.** Ancak bundan sonra bellekteki sonuç tüketilebilir. Çekirdek IRQ'su bu adımın yerine geçmez.
7. Kaydı okuduktan sonra yalnız ilgili IRQ_STATUS bitine 1 yazarak onayla.

Timeout sürücüdeki abort/drain reset yolunu tetikler. RECOVERY, AXI-Lite veya bellek veri yolunu resetlemez; hesap çekirdeğini resetlerken DMA paketlerini tamamlar. Belleği yeniden vermeden önce iki DMA callback’i, senkronizasyon, guard kontrolü ve RECOVERY_STATUS=3 gerekir. Ancak sonra RELEASE yazılır. Ayrıntılı [toparlanma sözleşmesi](RECOVERY_E2.md).
