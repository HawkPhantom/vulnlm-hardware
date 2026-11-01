# axis_int8_matvec arayüz sözleşmesi

## Hesaplama ve parametreler

`y[r] = Σ W[r,c] × x[c]`. INT8 girdiler ikiye tümleyen işaretli tamsayıdır; INT32 biriktirme ve INT32 çıktı kullanılır. Bias, aktivasyon, doyurma ve yeniden kuantizasyon yoktur. Parametreler derleme zamanında sabittir: `ROWS=64`, `COLS=64`. `ROWS` 1–4096; `COLS` 4–4096 ve dördün katı olmalıdır. Bu sınırlar altında en büyük toplamın mutlak değeri INT32'ye sığar.

Her MAC için bir bellek okuma ve bir hesap çevrimi vardır. Aynı anda bir iş işlenir. Performans veya FPGA kaynak tüketimi için henüz sentez sonucu yoktur. Kayıtlı bellek okumaları RAM çıkarımına uygun tutulmuştur; BRAM/DSP eşlemesi ve zamanlama Vivado ile doğrulanacaktır.

## AXI-Stream paket biçimi

Her iki yönde `TDATA=32`, `TKEEP=4`, bir `TLAST` vardır. Aktarım yalnız `TVALID && TREADY` olan yükselen saat kenarında gerçekleşir. Girişteki her geçerli beat için `TKEEP=1111` zorunludur.

Giriş tek paket: önce `x`, sonra satır sıralı `W`.

| Sıra | İçerik | Varsayılan boyutta |
| --- | --- | --- |
| İlk `COLS/4` beat | `x[0]` … `x[COLS−1]` | 16 beat / 64 bayt |
| Sonraki `ROWS×COLS/4` beat | `W[0,0]` … `W[ROWS−1,COLS−1]` | 1024 beat / 4096 bayt |
| Toplam | Tek `TLAST` yalnız son beat'te | 1040 beat / 4160 bayt |

Her beat'te ilk eleman `TDATA[7:0]`, sonraki `TDATA[15:8]`, sonra `[23:16]` ve `[31:24]` alanındadır. Örneğin `x=[−128,−1,0,127]`, ilk beat'te `32'h7f00ff80` üretir. Yazılım baytları aynı sırada paketlemelidir.

Çıkışta her beat bir INT32 satır sonucudur: `y[0]` … `y[ROWS−1]`. `TKEEP=1111`; `TLAST` yalnız son satırda 1'dir. Varsayılan boyutta çıktı 64 beat / 256 bayttır. İş kimliği çıktıya eklenmez; çıktı uzunluğu bu metadata nedeniyle değişmez.

## Kontrol

| Sinyal | Anlamı |
| --- | --- |
| `aclk` | Tek saat alanı |
| `aresetn` | Aktif düşük, senkron reset; en az bir yükselen kenarda 0 tutulur |
| `start_valid/start_ready` | Yükselen kenarda ikisi de 1 ise tek iş kabul edilir |
| `cfg_job_id`, `cfg_generation` | Başlangıç el sıkışmasında alınan 32 bit gözlem kimlikleri |
| `cfg_delay_cycles` | İlk çıkışın `TVALID` yükselişine eklenecek 32 bit çevrim sayısı |
| `busy` | İş çalışıyor veya hata durumu var; hata sırasında da 1 |
| `done` | Son çıktı el sıkışmasından hemen sonra bir çevrimlik bildirim |
| `fault` | Resetlenene kadar hata durumu; yeni giriş/iş/çıktı yok |
| `error_code` | 0 normal; 1 eksik KEEP; 2 erken LAST; 3 eksik son LAST; 4 geçersiz durum |

Başlangıç ayarları `start_valid` süresince el sıkışmaya kadar sabit tutulmalıdır. Busy iken `start_ready=0`; istek kuyruğu yoktur. `start_valid` meşgulken tutulursa hazır olunca yeni iş kabul edilebilir; yalnız busy sırasında verilmiş kısa bir darbe kabul edilmez. AXI-Lite sarmalayıcısı bu sözleşmeyi sağlamalıdır.

İş kabul edilmeden giriş tüketilmez. Tam giriş paketi doğrulanmadan hesap veya çıktı başlamaz. Giriş eksik kalır ve henüz `TLAST` gelmezse çekirdek RECEIVE durumunda bekler; yerleşik watchdog veya zaman aşımı kararı yoktur. Beklenen son beat'te `TLAST` yoksa hata oluşur. `TKEEP` ve `TLAST` aynı anda hatalıysa KEEP hatasına öncelik verilir.

Hatalı paket FAULTED durumuna geçirir; otomatik paket boşaltma veya sonrakini arama yapılmaz. Giriş DMA'sı beklemede kalabilir. Kontrolcü, DMA/kaynak/FIFO için koordineli toparlanmayı ayrıca uygulamalıdır.

## Gecikme ve geri basınç

`cfg_delay_cycles=D`, ilk satırın hesabından sonra tam `D` ek çevrim bekletir. Daha sonraki satırlara eklenmez. Gecikme değeri iş başında alınır; çalışma sırasında pinlerde değiştirmek işe etki etmez.

Son giriş el sıkışmasının saati `t0` ise ilk `TVALID`, `t0` kenarından `2×COLS+D` çevrim sonra yükselir. İlk çıkışın en erken kabul edilebileceği saat `t0+2×COLS+D+1`'dir. Test düzeneği yükselen kenarda örneklediği ilk geçerli beat için `2×COLS+D+1` farkını ölçer. Böylece pinin yükselmesi ile kabul saati karıştırılmaz.

Çıkış hazır değilken veri ve bütün yan sinyaller sabit kalır; geçerli beat geri çekilmez. İlerleme ve `done`, `TREADY` ile kabulü bekler. Bu davranış [AXI4-Stream el sıkışma kurallarıyla](https://docs.amd.com/r/en-US/ug1483-model-composer-sys-gen-user-guide/AXI4-Stream-Support-in-Model-Composer) uyumludur. Yerleşik çevrim sayacı timeout geldiğini kendiliğinden yorumlamaz.

## Gözlem sayaçları

- `input_beats`: bu işte kabul edilen giriş beat'leri; reddedilmeye neden olan beat dahil.
- `output_beats`: bu işte kabul edilen çıkış beat'leri.
- `elapsed_cycles`: iş başlangıcından sonraki aktif çevrimler; yükleme, hesap, gecikme ve geri basınç dahil. Normal son kabul veya FAULTED girişinde durur.
- `output_stall_cycles`: `TVALID=1, TREADY=0` gözlenen çevrimler.

Sayaçlar iş kabulünde ve resette sıfırlanır; tamamlanma sonrası bir sonraki işe kadar saklanır. Beat sayaçları 32, zaman sayaçları 64 bittir; taşma halinde modüler sarma vardır. Bunlar çekirdek saatine aittir, CPU saatiyle doğrudan fark alınmaz.

`active_job_id/generation` yalnız kontrol metadata'sıdır. Aynı kimliğin içeriğin kendisini doğruladığı veya DMA belleğini izole ettiği iddia edilmez. Bir AXI-Lite sarmalayıcısı `done` darbesini yazılım okuyana kadar saklamalıdır.

Bu sarmalayıcı artık `kv260_matvec` üst modülünde mevcut. Kalıcı olay, tamamlanma kaydı ve atomik metrik okumaları [AXI-Lite kayıt sözleşmesinde](AXI_LITE_KAYITLARI.md) açıklanıyor.

## Reset ve güven sınırı

Reset kontrol durumunu, çıktı geçerliliğini ve sayaçları temizler; dahili x/W belleklerini sıfırlamaz. Yeni işin tam paketi yeniden yüklenmeden bellekler hesap için okunmaz. Bu, bellek sıfırlama/silinme garantisi değildir; fiziksel veri kalıntısı bu sürümde ayrı bir konudur.

Reset sırasında AXI çıkışının geri çekilmesi ancak bağlı veri yolunun da reset/flush protokolünde olduğu sistemde kullanılmalıdır. Bu modülde bağımsız bir `abort` komutu yoktur: bekleyen `TVALID`'i sıradan bir iptalle düşürmek AXI sözleşmesini bozar.

Çekirdek bir AXI bellek master'ı değildir ve DDR adresi bilmez. Yerel `busy=0`, `done=1` veya reset tamamlanması, AXI DMA'nın önceki bellek yazılarının sona erdiğini kanıtlamaz. E1/E2 ve P2 için DMA ile kaynak/FIFO'nun birlikte izlenmesi sonraki entegrasyon aşamasının işidir.
