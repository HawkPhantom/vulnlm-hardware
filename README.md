# VulnLM Hardware

Cyberdes donanım güvenliği laboratuvarı. Arayüz İngilizce açılır; EN/TR dil seçimi sunar. Gerçek KV260 DMA çıktısıyla, önceki isteğin sonucunun yeni isteğe verilmesinin ürün kararını nasıl değiştirebildiğini gösterir. [Arayüzü kartta çalıştırma](docs/INTERFACE.md) ve [güncel arayüz doğrulaması](results/interface/RAPOR.md).

FPGA tasarımı ve `allow_lab=1` ile yüklenmiş güncel sürücü hazır olduğunda, kartta:

```sh
sudo sh web/run_on_board.sh --port 8080
```

Donanım bağlantısı olmadan `make ui` ile görünüm incelenebilir; işlem düğmesi kapalı kalır ve donanım sonucu üretilmez.

SystemVerilog prototipi: INT8 `y = W x`, INT32 çıktı, AXI4-Stream veri yolu, AXI-Lite kontrolü ve ilk çıktıyı kontrollü geciktirme. Araştırma çerçevesi [ARASTIRMA_PLANI.md](ARASTIRMA_PLANI.md) dosyasında.

Hesaplama çekirdeği, AXI-Lite kontrolü, E1/E2 simülasyonları, Vivado SG DMA proje üreticisi, Linux DMAengine istemcisi ve kart deney araçları eklendi. [Bütün sistemin kurulum rehberi](docs/SISTEM_KURULUMU.md) ve [31 Ekim sistem doğrulama kaydı](results/system/RAPOR.md) başlangıç noktalarıdır. Arayüz ve capture işleminin sonraki değişiklikleri yukarıdaki güncel raporda doğrulanmıştır. ARM64 kernel modülü ve kullanıcı aracı derlendi; simülasyonlar geçti. Vivado sentezi, Linux imajı ve gerçek KV260 çalıştırması henüz yapılmadı. Bunlar keşfedilmiş bir KV260/AMD açığı veya gerçek DDR ölçümü değildir.

## Dosyalar

| Dosya | İçerik |
| --- | --- |
| `rtl/axis_int8_matvec.sv` | Tek iş çalıştıran, parametreli hesaplama çekirdeği |
| `rtl/matvec_axil_ctrl.sv` | Bağımsız AW/W alımı, yapılandırma, kalıcı olaylar ve metrik kayıtları |
| `rtl/kv260_matvec.sv` | Kontrol ile hesaplama çekirdeğini birleştiren üst modül |
| `sim/tb_axis_int8_matvec.sv` | Bağımsız referans hesap, AXI kontrolleri ve hata/reset testleri |
| `sim/axil_master_bfm.sv` | AXI-Lite test yöneticisi ve yanıt/protokol kontrolleri |
| `sim/tb_matvec_axil_ctrl.sv` | Kontrol bloğu testleri, WSTRB ve eşzamanlı olay/onay dahil |
| `sim/tb_kv260_matvec.sv` | MMIO ile başlayan tam işler ve çekirdek/kontrol entegrasyonu |
| `sim/models/` | Yalnız simülasyon için S2MM, sınırlı AXI RAM ve protokol kontrolü |
| `sim/tb_dma_models.sv` | Ayrı AW/W, geciken bellek yazısı/yanıtı ve model hata yolları |
| `sim/tb_dma_buffer_reuse.sv` | P0/P1/P2 sahiplik ve örnek hizmet karşılaştırması |
| `sim/tb_stale_stream.sv` | E2: kalan A akışının B descriptor'ına geçmesi |
| `scripts/report_reuse.py` | Koşu eşleştirmesi, metrik doğrulaması ve rapor üretimi |
| `hw/create_project.tcl` | PS + SG AXI DMA + çekirdek; proje/bitstream/XSA üretim akışı |
| `sw/kernel/kv260_lab.c` | Tek işli DMAengine hizmeti; P2 normal yol ve özel sentetik E1 tamponu |
| `sw/user/kv260ctl.c` | CPU referans karşılaştırması ve E1 politika komutları |
| `web/` | Gerçek ioctl yolu, ürün kalite kapısı, İngilizce/Türkçe VulnLM Hardware arayüzü |
| `docs/INTERFACE.md` | Kartta arayüz kurulumu, deney akışı ve kanıt sözleşmesi |
| `linux/kv260-secx.dtso` | Proje adres/IRQ/saatleriyle eşleşen FPGA device tree örtüsü |
| `linux/meta-hardware-secx/` | Yocto/EDF/PetaLinux için modül ve kullanıcı aracı tarifleri |
| `scripts/run_board_suite.py` | Temiz doğruluk geçişi, E1 pilotu ve koşu kayıtları |
| `scripts/package_firmware.py` | Vivado çıktısını Bootgen/DT paketine dönüştürme |
| `docs/RTL_ARAYUZU.md` | Paket biçimi, kontrol arayüzü ve zamanlama sözleşmesi |
| `docs/AXI_LITE_KAYITLARI.md` | Kayıt haritası ve gelecekteki sürücü erişim sırası |
| `docs/KV260_DMA_ENTEGRASYONU.md` | Gerçek kart bağlantısı ve aşama geçiş ölçütleri |
| `Makefile` | Icarus Verilog ile derleme ve test |

## Simülasyon

Gereken araçlar: Icarus Verilog 12 veya uyumlu bir sürüm (`iverilog`, `vvp`), `make` ve raporlama için Python 3.9+ (saat dilimi verisiyle). Simülatörün [resmî kaynakları](https://github.com/steveicarus/iverilog/tree/v12_0) kullanılabilir.

```sh
make test
make test-matrix
make test-control
make test-peripheral ROWS=3 COLS=12
make test-dma-models
make test-reuse ROWS=64 COLS=64 TRIALS=3
make test-stale ROWS=64 COLS=64
make host-test
make ui-test
make linux-test
make test ROWS=64 COLS=64 SEED=1234 JOBS=100
make wave
```

`test`, seçilen boyutta çekirdek, kontrol, entegrasyon, DMA modeli, yeniden kullanım ve eski stream deneyini çalıştırır. `test-matrix`, kontrol/DMA modelini bir kez; çekirdek, entegrasyon, yeniden kullanım ve eski stream testlerini 1×4, 3×12, 16×16 ve 64×64 boyutlarında çalıştırıp E1 raporunu yeniler. `JOBS`, her boyuttaki çekirdek testine eklenecek rastgele tam iş sayısıdır; sabit hata/reset senaryoları bunun dışındadır. `TRIALS`, yeniden kullanım deneyinde politika başına koşul sayısıdır. `SEED` aynı girdileri ve geri basınç programını tekrar üretir. `wave`, yalnız çekirdek için `build/matvec.vcd` üretir; büyük boyutlarda dosya büyüyebilir.

`make report-reuse ROWS=64 COLS=64`, yalnız o boyutu çalıştırıp mevcut özet raporu tek boyutla değiştirir. Dört boyutlu rapor için `make test-matrix` kullanılır. JSONL koşuları ve CSV olay izleri geçici `build/` dizinindedir; `results/reuse/summary.json` bütün koşu kayıtlarını ve kaynak özetlerini kalıcı olarak içerir.

Araçlar PATH'te değilse:

```sh
make test-matrix IVERILOG=/tam/yol/iverilog VVP=/tam/yol/vvp
```

Test düzeneği `$fatal` ile başarısız olur; başarılı çalıştırma boyut, tohum, iş ve kontrol sayısını içeren `PASS` satırı verir. Bu sayılar araştırma planındaki 10.000 A/B donanım deneyinin yerine geçmez.

## İlk sürümde doğrulanan davranışlar

- Sıfır girdi, birim matris benzeri satırlar, `127` ve `−128` sınır değerleri, negatif sonuçlar ve rastgele işaretli girdiler.
- Girişte boş çevrimler ve çıkışta ilk/son beat dahil geri basınç. `TVALID`, `TDATA`, `TKEEP`, `TLAST` beklerken sabit kalır.
- Her sonuç satırının bağımsız INT64 referansa eşitliği; tam çıktı sayısı ve yalnız son beat'te `TLAST`.
- İlk çıkışa tam 1 ve 17 çevrim ek gecikme. İş başında alınan ayarların sonradan değiştirilememesi ve meşgulken yeni iş kabul edilmemesi.
- Yazılımın timeout gözlemi yaptıktan sonra aynı işin geç çıktı üretmeye devam etmesi.
- Eksik `TKEEP`, erken `TLAST` ve beklenen sonda eksik `TLAST` için reset gerektiren hata durumu.
- Giriş yükleme, hesap, gecikme, bekleyen çıktı ve kısmi çıktı sonrasında reset; ardından farklı bir tam işin doğruluğu.
- Çevrim ve geri basınç sayaçları; yalnız son çıktı el sıkışmasından sonra bir çevrimlik `done`.

Gerçek çalıştırma sonuçları ve araç bilgisi [SIMULASYON_SONUCLARI.md](SIMULASYON_SONUCLARI.md) dosyasına kaydedilir.

## Kart entegrasyonunda sonraki adım

Vivado bağlantı scripti ve Linux DMAengine istemcisi eklendi. Sıradaki aşama bunları [kurulum rehberiyle](docs/SISTEM_KURULUMU.md) gerçek araç/kart üzerinde doğrulamak. Çekirdeğin `done` sinyali son stream beat'inin kabulünü gösterir; DMA/DDR tamamlanması ayrıca doğrulanır. Vivado'nun tam sürümü ilk kart derlemesinde kaydedilecek. Sürücü normalde P2 uygular; kalıcı takılmada tamponu tutup çağrıyı bekletir. Otomatik resetle toparlanma ve gerçek kart E2 bu sürümde yoktur.
