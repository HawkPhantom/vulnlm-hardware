# E1: timeout sonrası tampon yeniden kullanımı

30 Ekim 2026'da dört matris boyutunda 36 kontrollü simülasyon koşusu tamamlandı. Sonuçlar [raporda](../results/reuse/RAPOR.md), koşu kayıtları ve doğrulanan kaynakların SHA-256 değerleri [summary.json](../results/reuse/summary.json) içinde.

Deneyin sorusu: **Yazılım A'yı zaman aşımına uğratıp tamponunu B'ye verdiğinde, A'nın önceden kabul edilmiş yazısı hâlâ o tamponu değiştirebilir mi?** İkinci soru, eski tamamlanmayı reddetmek ile eski bellek erişimini durdurmanın aynı korumayı sağlayıp sağlamadığıdır.

## Kurulan düzenek

```text
MMIO test yöneticisi → kv260_matvec kontrolü
paket üreticisi      → INT8 hesap çekirdeği → S2MM modeli → AXI yazma RAM modeli
                                            │                  │
                                     iş kimliği/nesli    gerçek yazma kenarı
                                            └──── olay kaydı ───┘
```

Hesap çekirdeği ve AXI-Lite kontrolü `rtl/` kaynaklarıdır. `sim/models/` içindeki alıcı ve RAM yalnızca simülasyon içindir: AMD AXI DMA, DDR denetleyicisi veya kartta kullanılacak DMA RTL'i değildir. Giriş paketi test düzeneğinden gelir; MM2S bellek okuması modellenmez. P0/P1/P2 de test düzeneğinde uygulanan sahiplik ve yanıt politikalarıdır; henüz Linux sürücüsü değildir.

S2MM modeli bir aktarım ve en fazla bir bekleyen, tek beat'lik 32 bit yazı taşır. AW ve W ayrı kabul edilir; bekleyen VALID/veri sabit tutulur. Bir sonraki yazıya ve tamamlanmaya ancak B yanıtı kabul edildikten sonra geçilir. RAM, AW/W kabulünden sonraki bellek güncellemesini ayrıca bekletebilir. Böylece stream kabulü, AXI adres/veri kabulü, bellek değişimi ve yazma yanıtı ayrı olaylardır.

## Bir koşunun sırası

1. A'nın DMA hedefi ve iş kimliği/nesli sabitlenir; çekirdek MMIO ile başlatılır. A'nın bütün giriş paketi gönderilir.
2. A'nın ilk AW ve W el sıkışmaları gerçekleşir. RAM, kabul edilmiş yazıyı belleğe uygulamadan bekletir. Test bu durumu gözlemlemeden timeout kaydetmez.
3. Deneme numarasına bağlı 12/24/36 çevrim sonunda timeout kaydedilir. P0/P1 tampon sahipliğini B'ye verir ve B deseniyle doldurur; P2 tamponu A için karantinada tutar.
4. Aynı eşleştirilmiş koşuldaki üç politika için aynı anda bekleyen yazı serbest bırakılır. Her bellek güncellemesinde descriptor kimliği ve o andaki tampon sahibi karşılaştırılır.
5. A tamamen boşaltılır; son yazma yanıtı, DMA/RAM boşluğu ve çekirdeğin terminal kayıtları kontrol edilir. P0 örnek hizmeti A'nın tamamlanmasını B'ye bağlar ve RAM içeriğini B yanıtı olarak kopyalar. P1/P2 eski kimlik/nesli reddeder. P2 bundan sonra sahipliği B'ye verir.
6. B için doğru hesap çalıştırılır; bütün sonuçlar ve komşu kontrol desenleri sınanır. P0'daki bu son iş, önceki yanlış yanıtın ardından ayrı bir toparlanma kontrolüdür; yanlış yanıtı düzeltmiş sayılmaz.

Buradaki timeout, mekanizmayı açığa çıkarmak için seçilmiş olay tabanlı bir enjeksiyondur. Gerçek hizmetin p99 değerinden türetilmiş timeout ölçümü değildir. Bekletilen kabul edilmiş yazı, bu simülasyonda bilerek kurulmuştur; kartta aynı pencerenin varlığı ayrıca gösterilmelidir.

| Politika | Timeout sonrası sahiplik | Eski tamamlanma | Ölçülen sonuç |
| --- | --- | --- | --- |
| P0 | Hemen B | Geçerli B yanıtı sanılır | B belleği değişir ve örnek hizmet yanlış yanıt döndürür |
| P1 | Hemen B | Kimlik/nesil kontrolüyle reddedilir | Yanlış yanıt reddedilir; B belleği yine değişir |
| P2 | Eski erişimler bitene kadar A | Reddedilir | Bu koşullarda B sahipliğinde eski yazı oluşmaz |

## Metrikler ve anlamları

| Alan | Tanım |
| --- | --- |
| `cross_owner_writes` | Bellek güncelleme kenarında yazının işi ile tampon sahibinin farklı olduğu başarılı yazı sayısı |
| `cross_owner_bytes` | Bu yazılarda etkin byte strobe sayılarının toplamı; eski veriyle aynı değeri yazmak da erişim ihlalidir |
| `changed_b_bytes` | B'nin başlangıç deseninden farklı bulunan baytlar; yazılan bayt sayısından ayrı tutulur |
| `mock_bad_b_response` | Örnek hizmetin B için kopyaladığı yanıtın bağımsız B referansından farklı olması |
| `a_payload_bytes_returned_to_b` | Örnek B yanıtında A referansına eşit sonuç sözcüklerinin baytları; gerçek istemci/veri sızıntısı ölçümü değildir |
| `old_completion_rejected` | Eski descriptor kimliği/neslinin B olarak kabul edilmemesi |
| `quarantine_cycles` | P2'de timeout ile B'ye ilk sahiplik devri arası; boşaltma, MMIO ve test zamanlaması dahil |
| `core_done_before_dma_done` | Çekirdek IRQ'sunun DMA'nın son B yanıtından önce gözlenmesi |
| `normal_followup_ok` | Sonraki B hesabının bütün satırlarının doğru olması |
| `guard_violations` | Ayrılmış çıktı bölgesi dışındaki kontrol desenlerinin değişmesi |

A girdisi `x=-3`, satır ağırlığı `1 + row%64`; B girdisi `x=2`, satır ağırlığı `3 + row%5` seçilmiştir. Bağımsız beklenen sonuçlar sırasıyla `-3*COLS*(1+row%64)` ve `2*COLS*(3+row%5)` olur. Bu desenler nedenselliği ayırmak içindir; rastgele gizli veriyle yapılan gizlilik deneyi değildir.

Her boyutta üç eşleştirilmiş koşul kullanılır: yazı gecikmesi 0/3/17, yanıt gecikmesi 0/5/10, çekirdek ek gecikmesi 0/7/14 çevrim. AW/W/B geri basıncı da uygulanır. Rapor, A'nın ilk bellek yazısı, çekirdek IRQ'su ve DMA tamamlanmasının timeout'a göre zamanlarını üç politika arasında eşitlik açısından kontrol eder. Bunlar bağımsız rastgele saldırı örneklemleri değildir.

64×64 için her P0/P1 koşusunda 64 yazı, yani 256 çapraz bayt; P2'de sıfır çapraz yazı gözlendi. P0 örnek hizmeti üç koşunun üçünde yanlış B yanıtı verdi. P1/P2 eski tamamlanmaları reddetti. Bütün takip hesapları ve kontrol desenleri geçti. P2 bekletmesi 8.123–8.137 simülasyon çevrimidir; bir FPGA hız/kapasite sonucu olarak kullanılamaz.

## Yeniden üretme

Gerekenler: Icarus Verilog 12, `make`, Python 3.9+ ve `Europe/Istanbul` saat dilimi verisi. Ek Python paketi gerekmez.

```sh
make test-matrix
make test-dma-models
make test-reuse ROWS=64 COLS=64 SEED=20261029 TRIALS=3
```

`test-matrix`, mevcut çekirdek/kontrol testlerini de çalıştırır ve dört boyutlu raporu yeniler. Yalnız bir boyut için `make report-reuse ROWS=64 COLS=64` kullanılabilir; bu komut `results/reuse/` raporunu yalnız seçilen boyutla değiştirir. `test-reuse` tek başına özet raporu yenilemez.

Ham veriler `build/reuse_<ROWS>x<COLS>.jsonl`, olay izleri `build/reuse_<ROWS>x<COLS>.trace.csv` içindedir. `build/` geçicidir ve `make clean` ile silinir; önemli koşuların izleri temizlemeden önce arşivlenmelidir. Kalıcı özet bütün koşu kayıtlarını ve kaynak özetlerini içerir. Rapor betiği eksik politika eşlerini, tutarsız metrikleri ve kaynaklardan eski ham sonuçları reddeder.

## Gösterilmeyenler

Gerçek AMD AXI DMA/DDR davranışı, Vivado sentezi/zamanlaması, Linux DMA sürücüsü, cache tutarlılığı, SMMU izolasyonu ve kart performansı doğrulanmadı. Kalıcı DMA takılması, resetle kesme ve E2 eski stream verisinin yeni işe karışması bu deneyin kapsamı dışında. P2 burada sonlu A aktarımının normal boşaltılmasını bekler; takılan donanımdan toparlanma çözümü henüz değildir.

Bu sonuç, yanlış yaşam döngüsü politikasının etkisini ve ölçüm yöntemini gösterir. KV260 veya AMD yazılımında keşfedilmiş bir açık iddiası içermez. Gerçek kart aşaması [entegrasyon planında](KV260_DMA_ENTEGRASYONU.md) tanımlıdır.

## E2 ek deneyi ve sistem kaynakları

31 Ekim'de ayrı `sim/tb_stale_stream.sv` düzeneği eklendi. A'nın ilk çıktısı TVALID ile beklerken alıcı tek başına resetlenir; P0/P1 B kimlikli descriptor kurar. Untagged stream'deki A payload'ı, geçerli B descriptor'ıyla RAM'e yazılır. P1'in descriptor kimlik kontrolü bu veri karışımını tanımaz. Test bu kontrolü üretim sürücüsü gibi sunmaz; bağımsız A/B referansları karışımı saptar.

P2 A alıcısını ve sahipliğini korur, kaynak ve alıcıyı tamamen boşaltır; ardından gerçek B işini çalıştırır. Dört boyutta üçer politika, toplam 12 koşu geçti. 64×64 P0/P1'de 64 eski sözcük, P2'de sıfır gözlendi; komşu desenler ve takip hesapları doğruydu. Bu ek test, yukarıdaki E1 raporundan ayrıdır. Kalıcı takılma veya gerçek DMA reset semantiğini doğrulamaz.

Linux sürücüsü, Vivado proje üreticisi ve gerçek kart araçları artık kaynak olarak vardır; Linux modülü gerçek ARM64 başlıklarıyla derlendi. E1/E2 simülasyon politikalarıyla Linux'un normal P2 yolunun doğrulama düzeyi aynı değildir. [Bütün sistem raporu](../results/system/RAPOR.md) ve [kurulum rehberi](SISTEM_KURULUMU.md) bu ayrımı kaydeder.
