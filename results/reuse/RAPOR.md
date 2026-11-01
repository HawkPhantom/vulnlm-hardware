# E1 tampon yeniden kullanım deneyi

Tarih: 2026-11-01 · Icarus Verilog version 12.0 (stable) ()

**36 kontrollü koşu, 12 eşleştirilmiş zamanlama/boyut koşulu.**
P0 ve P1'de A'nın gecikmiş yazıları B'ye verilmiş tamponu değiştirdi. P1 eski tamamlanmayı reddetti fakat yazıları durdurmadı. P2, bu koşullarda eski erişimler bitene kadar tamponu bekleterek çapraz yazıyı önledi.

S2MM/RAM ve hizmet politikaları simülasyon modelidir. Sonuçlar KV260 veya AMD sürücüsünde bulunan bir açık anlamına gelmez.

## 1 × 4

| Politika | Koşu | B belleğine A yazısı, toplam | Çapraz bayt/koşu | Yanlış örnek B yanıtı | Bekletme, çevrim |
| --- | ---: | ---: | ---: | ---: | ---: |
| P0 | 3 | 3 | 4 | 3/3 | 0–0 |
| P1 | 3 | 3 | 4 | 0/3 | 0–0 |
| P2 | 3 | 0 | 0 | 0/3 | 23–33 |

## 3 × 12

| Politika | Koşu | B belleğine A yazısı, toplam | Çapraz bayt/koşu | Yanlış örnek B yanıtı | Bekletme, çevrim |
| --- | ---: | ---: | ---: | ---: | ---: |
| P0 | 3 | 9 | 12 | 3/3 | 0–0 |
| P1 | 3 | 9 | 12 | 0/3 | 0–0 |
| P2 | 3 | 0 | 0 | 0/3 | 61–98 |

## 16 × 16

| Politika | Koşu | B belleğine A yazısı, toplam | Çapraz bayt/koşu | Yanlış örnek B yanıtı | Bekletme, çevrim |
| --- | ---: | ---: | ---: | ---: | ---: |
| P0 | 3 | 48 | 64 | 3/3 | 0–0 |
| P1 | 3 | 48 | 64 | 0/3 | 0–0 |
| P2 | 3 | 0 | 0 | 0/3 | 504–536 |

## 64 × 64

| Politika | Koşu | B belleğine A yazısı, toplam | Çapraz bayt/koşu | Yanlış örnek B yanıtı | Bekletme, çevrim |
| --- | ---: | ---: | ---: | ---: | ---: |
| P0 | 3 | 192 | 256 | 3/3 | 0–0 |
| P1 | 3 | 192 | 256 | 0/3 | 0–0 |
| P2 | 3 | 0 | 0 | 0/3 | 8123–8137 |

## Ölçüm sınırları

- Çapraz yazı, AXI adres/veri kabulünden sonraki gerçek model bellek yazma kenarında, tampon sahibiyle karşılaştırılarak sayılır.
- Bellek bozulması ile örnek hizmetin yanlış yanıt kabulü ayrı alanlardır. P1'de ikinci değer sıfır olması birinciyi temizlemez.
- Komşu tampon/kontrol desenleri değişmedi; bütün normal takip hesapları doğru tamamlandı.
- Her koşuda çekirdek tamamlanması DMA'nın son yazma yanıtından önce gözlendi; çekirdek IRQ'su tampon serbest bırakma koşulu değildir.
- Üç politika için aynı koşuldaki A zamanlaması rapor oluşturulurken yeniden eşleştirildi.
- P2 bekletme süresi hesap, aktarımlar, MMIO kontrolleri ve test zamanlamasını içerir; FPGA performans ölçümü değildir.
- Seçilmiş hata koşuları için başarı oranından bağımsız örneklem güven aralığı veya gerçek saldırı olasılığı çıkarılmaz.
- E2, kalıcı takılma, cache tutarlılığı, SMMU, gerçek AXI DMA ve kart üzerinde doğrulama henüz kapsam dışındadır.

Ham koşular, kaynak özetleri ve ayrıntılı metrikler [summary.json](summary.json) içinde. Zaman çizgileri `build/reuse_<ROWS>x<COLS>.trace.csv` dosyalarındadır.
