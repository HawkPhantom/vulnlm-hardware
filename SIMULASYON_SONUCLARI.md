# İlk RTL doğrulaması

Tarih: 29 Ekim 2026. Araç: Icarus Verilog 12.0 stable, SystemVerilog 2012 modu (`-g2012 -Wall`). Çalışma ortamı: macOS / Apple Silicon. Testler çekirdek düzeyindedir; KV260, Vivado sentezi veya gerçek DMA/DDR aktarımı içermez.

## Sonuçlar

Tohum: `20261029`. Her boyutta 20 ek rastgele iş ve aynı sabit aritmetik, protokol, hata/reset senaryoları çalıştırıldı.

| ROWS × COLS | Başlatılan iş | Kontrol grubu | Simülasyon çevrimi | Sonuç |
| --- | --- | --- | --- | --- |
| 1 × 4 | 47 | 56 | 1.717 | PASS |
| 3 × 12 | 47 | 56 | 5.597 | PASS |
| 16 × 16 | 47 | 56 | 30.575 | PASS |
| 64 × 64 | 47 | 56 | 455.293 | PASS |

İş sayısı normal tamamlanan işler yanında bilerek hatalı gönderilen ve resetle kesilen işleri de içerir. Kontrol grubu sayısı, referansla karşılaştırılan beat veya assertion sayısı değildir. Bu ilk çekirdek testlerinin derleme ve çalıştırmalarında uyarı/hata raporlanmadı.

Geç çıktı senaryosunda laboratuvar istemcisi bir timeout anı kaydetti; donanım iptal komutu almadığı için aynı kimlikteki iş daha sonra doğru sonucu üretti. Bu, yaşam döngüsü varsayımını göstermek içindir; başka isteğin belleğinin bozulduğu sonucu çıkarılmaz.

Tam test listesi [README.md](README.md), arayüz sözleşmesi [docs/RTL_ARAYUZU.md](docs/RTL_ARAYUZU.md) içinde.

## Yeniden çalıştırma

Sistem kurulumunu değiştirmeden bu oturum için geçici klasöre derlenen simülatörle kullanılan komut:

```sh
make test-matrix \
  IVERILOG=/private/tmp/hardware_secx-iverilog-12/bin/iverilog \
  VVP=/private/tmp/hardware_secx-iverilog-12/bin/vvp
```

Geçici klasör daha sonra temizlenebilir. Kalıcı kurulu Icarus Verilog varsa `make test-matrix` yeterlidir. Ham çıktı `build/test-matrix.log` dosyasındadır; `build/` üretilen dosyalar içindir ve sürüm kontrolüne alınmaz.

## Doğrulanan kaynaklar

SHA-256:

```text
rtl/axis_int8_matvec.sv
8b35c2b7e383dbe78cf3d76c4aa7476d28d433b77113e99e6f55a6415ce1c8b4

sim/tb_axis_int8_matvec.sv
85c0d1246cf216082c3fe1ece890be324d2b2e2868b583657acfd119470f5323
```

Kaynaklar değişirse bu rapor o değişikliğin doğrulaması sayılmaz. Sentezlenmiş kaynak tüketimi, gerçek saat frekansı, DMA erişimlerinin durması ve araştırma planındaki 10.000 A/B deneyinin sonuçları henüz ölçülmedi.

## AXI-Lite kontrol ve entegrasyon doğrulaması

29 Ekim 2026'da aynı simülatör ve `SEED=20261029` ile kontrol bloğu ve üst modül eklendikten sonra `make test-matrix` yeniden çalıştırıldı. Çekirdek kaynakları ve önceki referans test düzeneği değişmedi. Toplam 9 PASS satırı: bir kontrol testi, dört çekirdek testi ve dört birleşik çevre birimi testi.

Kontrol birimi: **56 tamamlanan yazma, 123 tamamlanan okuma**, bir kabul edilmiş START; sonuç PASS. Resetle bilerek kesilen işlemler tamamlanan işlem sayılarına dahil değildir.

Kontrol testleri:

- AW önce, W önce ve aynı anda adres/veri kabulü; kabulden sonra giriş pinleri değiştirilse de doğru işlem.
- Geciktirilmiş BREADY/RREADY altında sabit ve tekrarlanmayan yanıtlar; okuma ve yazmanın eşzamanlı ilerlemesi.
- 32 farklı WSTRB/veri birleşimi; sıfır strobe; salt okunur, hizasız ve tanımsız adreslerde SLVERR.
- START'ın tek darbe olarak üretilmesi, busy sırasında reddedilmesi ve sıfır strobe/ayrılmış komut bitlerinin işi başlatmaması.
- Canlı kayıt değişirken önceden kabul edilen okuma yanıtının sabit kalması.
- Yapay 64 bit sayaç taşması boyunca atomik ve değişmeden saklanan snapshot.
- IRQ maskeleme, maskeliyken olay saklama, W1C ve olay/onay aynı kenara denk geldiğinde yeni olayın korunması.
- Fault'un her çevrim yeniden bildirilmemesi; terminal kayıtların kimlik, hata ve metrik alanları.
- Yalnız AW veya yalnız W alınmışken reset; bekleyen B ve R yanıtlarında reset.

| Birleşik çevre birimi | Tamamlanan AXI-Lite yazma/okuma | Ölçülen gecikme farkı | Sonuç |
| --- | --- | --- | --- |
| 1 × 4 | 23 / 64 | 200 çevrim | PASS |
| 3 × 12 | 23 / 64 | 200 çevrim | PASS |
| 16 × 16 | 23 / 64 | 200 çevrim | PASS |
| 64 × 64 | 23 / 64 | 200 çevrim | PASS |

Her entegrasyon koşusunda MMIO ile A, B, hatalı C ve sistem resetinden sonraki D işleri başlatıldı. A/B/D'nin bütün sonuç satırları bağımsız INT64 referansla karşılaştırıldı. A çalışırken B ayarları yazıldı; A kimliği/gecikmesi değişmedi ve erken B START'ı SLVERR aldı. A'nın timeout gözleminden sonra geç sonuç ürettiği; çıktı alıcı tarafından kabul edilmeden done IRQ oluşmadığı; son kaydın ve sayaçların korunduğu; C hatasının ve reset sonrası D'nin doğru işlendiği doğrulandı.

Icarus 12, kontrol bloğunun `always_comb` süreci için sabit bit seçimlerinin duyarlılık listesinde genişletildiğini belirten `constant selects ... all bits will be included` notu üretiyor. Derleme tamamlandı ve bütün testler geçti. Bu not bağımsız sentez/lint sonucu değildir; Vivado sentezi ve zamanlama kontrolü henüz yapılmadı.

Ham çıktı: `build/axil-test-matrix.log`. Kullanılan komut:

```sh
make test-matrix \
  IVERILOG=/private/tmp/hardware_secx-iverilog-12/bin/iverilog \
  VVP=/private/tmp/hardware_secx-iverilog-12/bin/vvp
```

Eklenen kaynakların SHA-256 değerleri:

```text
rtl/matvec_axil_ctrl.sv
250d815e0c2b38995cf85c31183f3f8f85d7ff9af74fc247a084bbc204ab8f0a
rtl/kv260_matvec.sv
2068d341c1f257884d8d696c1bf50897a94792c024d94e4586fb91ba5ce48509
sim/axil_master_bfm.sv
c9020633bc795774f089eececfa04f7ffc1e39078202a9750edb3bedf94055d7
sim/axil_signals.svh
4ee3d0ef12f94dad19280dcbe94140bca68104b13e2fd362ec5137ed57558471
sim/tb_matvec_axil_ctrl.sv
8650bafe08634dda5d69dc541b56f309d80e2ad97e70053c38b6fd8093138916
sim/tb_kv260_matvec.sv
1a0a8805e44c3334056c2da797b8a8209b4276013ae261f256a122931d15f58c
```

## E1 DMA modeli ve tampon yeniden kullanımı — 30 Ekim 2026

Icarus Verilog 12.0 ile `make test-matrix`, `SEED=20261029`, `JOBS=20`, `TRIALS=3` çalıştırıldı. Çıkış kodu 0; 14 PASS satırı: kontrol birimi, DMA model birimi ve dört boyutta çekirdek/entegrasyon/yeniden kullanım testleri. Önceki çekirdek ve AXI-Lite testleri de tekrar geçti. Ham çıktı: `build/dma-reuse-test-matrix.log`.

DMA model birimi dokuz kontrol grubuyla geçti: AW/W'nin ayrı sırada kabulü, bekleyen bellek yazısı, B geri basıncı, son yanıttan önce tamamlanmama, meşgul descriptor'ın değişmemesi, reset boyunca RAM'in korunması, hatalı descriptor/paketler ve arena dışı adresin alias oluşturmadan SLVERR alması.

E1 deneyi 1×4, 3×12, 16×16 ve 64×64 boyutlarında üçer koşul ve üç politika ile **36 koşu / 12 eşleştirilmiş koşul** üretti. Rapor betiği politika eşlerini, A olaylarının timeout'a göre aynı zamanlamasını ve metrik tutarlılığını kontrol etti.

| 64×64 politikası | Koşu | Çapraz yazı/koşu | Çapraz bayt/koşu | Yanlış örnek B yanıtı |
| --- | ---: | ---: | ---: | ---: |
| P0 | 3 | 64 | 256 | 3/3 |
| P1 | 3 | 64 | 256 | 0/3 |
| P2 | 3 | 0 | 0 | 0/3 |

P1 eski tamamlanmayı reddettiği halde bellek yazısını engellemedi. P2'de sahiplik devri son yazma yanıtı ve boşalma kontrollerinden sonra yapıldı; 64×64 bekletme süresi 8.123–8.137 çevrim oldu. Bu süre MMIO/test zamanlaması dahil simülasyon maliyetidir. Bütün koşularda çekirdek IRQ'su DMA'nın son yazma yanıtından önce geldi; komşu kontrol desenleri ve normal takip hesapları geçti.

S2MM/RAM yalnız simülasyon modelidir. P0'ın yanlış yanıtı bilerek basitleştirilmiş hizmet modelinde ölçülür; P1/P2 sürücü uygulaması değildir. Bu sonuçlar gerçek KV260/DDR, cache, SMMU, kalıcı takılma, E2 veya resetle toparlanma doğrulaması sayılmaz. Seçilmiş kontrollü koşulardan saldırı olasılığı/güven aralığı çıkarılmaz.

Deney yöntemi: [docs/DMA_DENEYI.md](docs/DMA_DENEYI.md). Boyutlara göre ayrıntılar: [results/reuse/RAPOR.md](results/reuse/RAPOR.md). Bütün koşu metrikleri ve doğrulanan kaynakların SHA-256 kayıtları: [results/reuse/summary.json](results/reuse/summary.json).

## Sistem entegrasyonu ve E2 — 31 Ekim 2026

Üst modüle Vivado AXI/stream/saat/reset arayüz tanımları eklendikten sonra bütün matris tekrar geçti. Artık 18 PASS satırı var: bir kontrol birimi, bir DMA modeli; dört boyutta çekirdek, çevre birimi, E1 ve E2. E1'in 36 koşusuna ek olarak E2'nin 12 kontrollü koşusu tamamlandı. 64×64 E2'de P0/P1 B kimlikli descriptor'la 64 eski A sözcüğü aldı; P2 önce A'yı boşaltıp B'yi doğru hesapladı. Bütün kontrol desenleri ve normal takip işleri geçti.

Linux sürücüsü ARM64 kernel 6.12.113+deb13 başlıklarıyla `W=1 KCFLAGS=-Werror` altında derlendi. C kullanıcı aracı iki platformda, yedi host araç testi ve device tree fixture birleşimi geçti. Vivado Tcl yalnız sözdizimi açısından kontrol edildi; gerçek Vivado sentezi/kart çalıştırması yapılmadı. Yocto tarifleri imaj üretimiyle sınanmadı.

Kalıcı loglar, kaynak SHA-256 özetleri, E2 kayıtları ve araç sürümleri [results/system/](results/system/RAPOR.md) altında saklanır. Kart derlemesi ve gerçek DMA testleri [kurulum rehberindedir](docs/SISTEM_KURULUMU.md).
