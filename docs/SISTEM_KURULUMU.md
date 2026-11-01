# KV260 sistemini derleme ve çalıştırma

Bu depo hesap RTL'ini, Vivado block design üreticisini, SG AXI DMA bağlantısını, Linux DMAengine istemcisini, kullanıcı aracını, E1/E2 simülasyonlarını ve kart deneylerini kaydeden çalıştırıcıyı içerir. Yerel testlerin durumu [sistem raporundadır](../results/system/RAPOR.md). Kart üstünde çalıştırma henüz yapılmadı; aşağıdaki adımlar o aşamayı tamamlar.

**VulnLM Hardware arayüzü:** Kullanıcının girdiği ölçümleri gerçek hızlandırıcıya gönderip yanlış istek eşleştirmesinin ürün kararına etkisini gösteren akış [INTERFACE.md](INTERFACE.md) dosyasındadır. Güncel sürücünün `KV_OP_CAPTURE` desteğini ve ilk yüklemede `allow_lab=1` ister. Arayüz/capture eklemelerinin derleme ve test kayıtları [güncel rapordadır](../results/interface/RAPOR.md); önceki sistem raporu tarihsel kayıttır.

## 1. Bilgisayarda doğrulama

```sh
make host-test
make test-matrix
make linux-test
```

İlk komut C aracının ABI, işaretli referans ve byte sırası kontrollerini ve Python araç testlerini çalıştırır. İkinci komut Icarus Verilog 12 ile tüm boyutları sınar. Üçüncü komut Docker üzerinde gerçek ARM64 kernel başlıklarıyla modül derler ve device tree örtüsünü bir test ağacına uygular. Docker'ın ARM64 Linux ortamı gerekir; başka mimaride `--platform linux/arm64` kullanılmalıdır. Bu test modülü karta kurmaz. `build/linux/kv260_lab-verification.ko` yalnız derlendiği kernel içindir; kartın kernel modülü yerine kopyalanmaz.

Bu oturumdaki Mac için:

```sh
make test-matrix \
  IVERILOG=/private/tmp/hardware_secx-iverilog-12/bin/iverilog \
  VVP=/private/tmp/hardware_secx-iverilog-12/bin/vvp
make linux-test DOCKER=/Applications/Docker.app/Contents/Resources/bin/docker
```

Geçici Icarus kurulumu daha sonra silinebilir. Kalıcı araçlar kuruluysa yol belirtmek gerekmez.

## 2. Vivado geliştirme bilgisayarı

KV260 SOM board dosyaları kurulu olmalı. AMD'nin [board deposu](https://github.com/Xilinx/XilinxBoardStore/tree/2025.2/boards/Xilinx/kv260_som) bir kaynak örneğidir; kullanılan Vivado sürümüyle uyumlu dosya seçilip manifestte kaydedilir. Script kurulu tek KV260 SOM tanımını bulur; birden fazla aday varsa `KV260_BOARD_PART` ile tam kimlik seçilir. Harici board deposu `KV260_BOARD_REPO` ile verilebilir.

```sh
make vivado-project
```

Bu komut `build/vivado/` içinde projeyi oluşturur ve block design doğrulamasını çalıştırır. Bağlantılar: 100 MHz tek PL saati, HPM0 kontrolü, HP0 DDR yolu, üç DMA master'ı için SmartConnect, 32 bit stream, SG açık ve 40 bit DMA adresi. Kontrol adresleri DMA için `0xA0000000`, çekirdek için `0xA0010000`; DMA IRQ'ları SPI89/90, çekirdek IRQ bağlantısı SPI91. Linux istemcisi çekirdek terminal kaydını poll eder ve çekirdek IRQ'sunu kapalı tutar. PL IRQ eşlemesi [AMD PG201](https://docs.amd.com/r/en-US/pg201-zynq-ultrascale-plus-processing-system/Programmable-Logic-Clocks-and-Interrupts) ile uyumludur.

Derleme yeni bir çıktı dizininde yapılır; script var olan projeyi üzerine yazmaz:

```sh
vivado -mode batch -source hw/create_project.tcl \
  -tclargs build build/vivado-build
```

Sentez/uygulama başarısızsa, zamanlanmış yol yoksa, negatif setup/hold slack veya DRC hatası varsa kabul işareti üretilmez. Başarılı akış `.bit`, `.xsa`, araç/IP manifesti, zamanlama/kaynak/DRC raporları ve `accepted.json` oluşturur. Uyarılar ve kısıt kapsamı ayrıca incelenmelidir; otomatik kontroller uzman zamanlama incelemesinin yerine geçmez. Kaynaklara yalnız `rtl/` ve gerçek AMD IP'leri alınır; `sim/models/` sentezlenmez.

```sh
python3 scripts/package_firmware.py \
  --vivado-dir build/vivado-build --output build/firmware-run1
```

Paketleyici kabul edilmiş artefaktları ister; Bootgen ile `.bit.bin`, `dtc` ile `.dtbo` ve SHA-256 manifesti üretir. Karta yükleme yapmaz. Dönüşüm [AMD Bootgen komutları](https://docs.amd.com/r/en-US/ug1283-bootgen-user-guide/Commands-and-Descriptions) üzerinden yapılır. Bu bilgisayarda Vivado/Bootgen çalıştırılmadı.

## 3. Linux imajı ve sürücü

İlk kart hedefi, üretilen XSA'nın PS/DDR/saat yapılandırmasıyla eşleşen bir Linux imajıdır. Kullanıcının kurulu araç sürümü kesinleşince ona uygun KV260 BSP/EDF akışı sabitlenir. AMD'nin güncel embedded akışında EDF/Yocto da vardır; eski bir PetaLinux sürümünü sırf bu rehberdeki örnek için kurmak gerekmez. [AMD embedded araçları](https://www.amd.com/en/support/downloads/adaptive-socs-and-fpgas/embedded-software.html)

`linux/kernel.config.fragment`, gerekli kernel seçeneklerini listeler. Bu, tek başına boot edilebilir KV260 kernel yapılandırması değildir. Konsol, SD, ağ, fan ve board firmware desteği seçilen BSP'den gelmelidir.

Yocto/EDF/PetaLinux için `linux/meta-hardware-secx/` katmanında modül ve araç tarifleri vardır. Katman deponun bulunduğu konumda kullanılmalı; göreli kaynak yolları `sw/` dosyalarına ulaşır. Build ortamında katman eklenir ve imaja `kernel-module-kv260-lab` ile `kv260ctl` paketleri dahil edilir. BitBake tarifleri bu oturumda çalıştırılmadı; seçilen BSP'nin release serisi ve kaynak açma davranışı ilk imaj derlemesinde doğrulanmalıdır. FPGA/XSA entegrasyonu seçilen BSP'nin yöntemini kullanır.

Çalışan kartta kernel başlıkları ve derleme araçları varsa bağımsız derleme:

```sh
make -C sw/kernel KDIR=/lib/modules/$(uname -r)/build
make -C sw/user
```

Başka bilgisayarda derleniyorsa kartın aynı kernel kaynakları, yapılandırması, `Module.symvers` ve ARM64 toolchain'i kullanılmalıdır. Konteynerdeki genel Debian modülü, özel AMD kernel'iyle uyumlu sayılmaz.

## 4. Firmware ve device tree yükleme koşulları

`linux/kv260-secx.dtso` yalnız bu deponun Vivado tasarımı içindir. Base DT'de `fpga_full` ve `gic` sembolleri bulunmalıdır. Örtü FPGA manager'a `kv260_secx.bit.bin` yükletir ve DMA/çekirdek cihazlarını tanımlar. `fpga_full` bölgesinin adres dönüşümü base DT'den gelir. Eski PL cihazları aynı adres/IRQ'larla etkin bırakılmaz; hazır DPU/başka overlay ile birlikte uygulanmaz.

Örtüdeki fixed-clock, PL0'ın **zaten 100 MHz olarak kurulmuş olduğunu bildirir**; PLL programlamaz. FSBL/platform firmware seçilen XSA'ya göre hazırlanmalı veya platformun saat yönetiminde aynı saat açıkça kurulmalıdır. Stok bir SD imajına bu örtüyü yüklemek tek başına tam kurulum değildir. FPGA bölgesi, saatler ve mevcut overlay yönetimi doğrulandıktan sonra BSP'nin desteklenen overlay yükleyicisi kullanılır. Bu nedenle taşınabilir olmayan, kör bir sysfs yükleme komutu verilmez.

Modül yüklenmeden önce yeni ve temiz FPGA tasarımı etkin olmalıdır. Sürücü ID/sürüm/boyutları ve başlangıç durumunu denetler; daha önce iş çalışmış temizlenmemiş bir çekirdeğe yeniden bağlanmayı reddeder. Rebind veya sürücü boşaltıp tekrar yükleme yerine kontrollü FPGA yeniden yükleme/yeniden başlatma gerekir.

```sh
sudo insmod sw/kernel/kv260_lab.ko
sudo sw/user/kv260ctl info
sudo sw/user/kv260ctl verify 100 20261030 1000
```

`/dev/kv260-lab` yalnız root'a açık oluşturulur. Normal yol yalnız P2 davranışını kullanır. DMA belleği DMAengine sağlayıcısının cihazıyla coherent olarak ayrılır; kullanıcı alanına adres/mmap verilmez. HP0 için `dma-coherent` özelliği uydurulmaz. CPU adresi ile DMA adresi ayrılır. [Linux DMA API](https://docs.kernel.org/core-api/dma-api-howto.html)

## 5. Kart deneyleri

Önce 10.000 temiz iş geçişi:

```sh
sudo python3 scripts/run_board_suite.py --ctl ./sw/user/kv260ctl \
  --output results/board/clean-run1 --count 10000
```

Araç bütün INT32 sonuçları CPU INT64 referansıyla karşılaştırır; her işi JSONL olarak yazar. İlk hatada durur ve kayıtları saklar.

Koşu sonrasında `python3 scripts/report_board.py results/board/clean-run1`, tamamlanmış ve referans kontrolü geçen normal kayıtların p50/p95/p99 aktarım gecikmesini ve E1 varsa politika özetlerini `analysis.json` dosyasına yazar. Başarısız batch'ler ve kaçırılan pencereler ayrıca görünür; temiz başarı diye sayılmaz. Bu gecikmeler submit–release arasıdır; sabit geliş hızlı hizmet kapasitesi ölçümü değildir.

E1 için modülün **ilk yüklemesi** `allow_lab=1` ile yapılır. Bu ayar canlı değiştirilemez; zaten çalışmış çekirdeğe modül yeniden bağlanmaz. Lab komutu ayrıca `CAP_SYS_RAWIO` ister.

```sh
sudo insmod sw/kernel/kv260_lab.ko allow_lab=1
sudo python3 scripts/run_board_suite.py --ctl ./sw/user/kv260ctl \
  --output results/board/e1-pilot1 --count 10000 --e1 --trials 3 \
  --delay-cycles 50000000 --timeout-ms 20
```

50 milyon çevrim 100 MHz tasarım için yaklaşık 500 ms **istenen ek gecikmedir**; kartta ölçülmüş değer değildir. Pilot, gerçekleşen pencereyi kaydeder. Politika sırası tohumla değiştirilir; kaçırılan pencereler silinmez ve başarı sayılmaz. P0/P1 yalnız özel sentetik tamponun mantıksal sahibini erken değiştirir. P2 boşaltmayı bekler. A verisi sabittir; gerçek istemci gizliliği/sızıntı sonucu çıkarılmaz. Yeni B hesabı ayrıca normal takip işi olarak doğrulanır.

`changed_bytes` ve `late_a_words`, CPU'nun boşaltmadan sonra gördüğü içeriktir; bellek yazma kenarı veya AXI işlem sayısı değildir. ILA/AXI izleme henüz karta eklenmedi. E2 modeli simülasyonda vardır; sürücü güvenli olmayan alıcı reseti/yeniden kurmasını donanım API'sine açmaz. Gerçek kart E2, kalıcı takılmadan toparlanma ve tam hizmet yükü ölçümleri tamamlanmış sayılmaz.

## 6. Timeout, kapanış ve hata davranışı

Normal çağrı timeout olduğunda sonuç geçersiz sayılır; sürücü iki DMA callback'i ve kaynak temizliğini beklemeyi sürdürür. Sonra `status=-ETIMEDOUT` döner ve çıktı kullanıcıya kopyalanmaz. Kimlik/nesil, terminal beat sayıları, callback/cookie durumu ve kontrol desenleri uyuşmazsa kaynak broken olur; yeni iş kabul edilmez. DMA kayıtları kernel sağlayıcısıyla eşzamanlı doğrudan programlanmaz. [DMAengine istemci sözleşmesi](https://docs.kernel.org/driver-api/dmaengine/client.html)

**Kalıcı DMA takılmasında çağrı ve cihaz kaldırma işlemi süresiz bekleyebilir.** Bu, ilk sürümün bilinçli hizmet sınırlamasıdır: bellek serbest bırakılmaz veya başka işe verilmez. Tampon havuzu/arka planda toparlanma ve kanıtlanmış izolasyon/reset yolu henüz yoktur. Seri konsol üzerinden kontrollü sistem yeniden başlatması gerekebilir. Deney çalıştırıcısının gözlem süresi dolarsa bekleyen sürecin PID'sini kaydeder ve yeni koşu başlatmaz; timeout'un DMA'yı iptal ettiğini varsaymaz.

Aktif iş varken overlay kaldırma, FPGA yeniden programlama ve modül kaldırma yapılmaz. Bu işlemler bekleyen AXI erişimlerini güvenli hale getirmez. Güç kesme veya firmware güncelleme bu depodaki araçlar tarafından otomatik yapılmaz.

## Tamamlanma ölçütü

Kaynak zinciri yerel testleri geçtiğinde derlenebilir sistem adayı elde edilir. Sistemin **kartta tamamlandığı** ancak Vivado sentez/uygulama raporları, eşleşen imaj/firmware, gerçek DMA doğruluk koşuları ve deney kayıtları alındığında söylenir. Bu son aşamalar için geliştirme bilgisayarına ve KV260'a erişim gereklidir.
